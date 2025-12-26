# Phase 2 Runbook: ArgoCD & GitOps Bootstrap

> Troubleshooting guide for ArgoCD, MetalLB, Traefik, and cert-manager on the homelab cluster.

---

## Prerequisites Checklist

Before deploying Phase 2, verify Phase 1 is healthy:

```bash
# Cluster must be healthy
kubectl get nodes                    # Both nodes Ready
cilium status                        # All OK
kubectl get pods -n kube-system      # All Running, no CrashLoopBackOff

# DNS must work
kubectl run test-dns --rm -it --image=busybox:1.28 --restart=Never -- \
  nslookup kubernetes.default
```

---

## ArgoCD Issues

### ArgoCD pods stuck in Pending

**Symptom:** `kubectl get pods -n argocd` shows pods in `Pending` state.

**Cause:** Insufficient resources on the cluster.

**Fix:**
```bash
# Check node resources
kubectl describe nodes | grep -A5 "Allocated resources"

# Check if pods are waiting for PVCs
kubectl get pvc -n argocd

# If disk space is low, clean up
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50
```

### ArgoCD server CrashLoopBackOff

**Symptom:** `argocd-server` pod keeps restarting.

**Common causes:**

1. **Redis connection failure:**
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100 | grep -i redis
   ```
   **Fix:** Ensure `redisSecretInit.enabled: false` in values.yaml (prevents RBAC race conditions).

2. **Database initialization timeout:**
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
   ```
   **Fix:** Delete the pod and let it restart: sometimes the first init takes too long.

### argocd-application-controller not Ready (0/1 Running)

**Symptom:** `argocd-application-controller-0` shows `0/1 Running` for hours. ArgoCD
UI shows no applications syncing.

**Diagnosis:**
```bash
# 1. Find the controller pod
kubectl get pods -n argocd -l app.kubernetes.io/component=application-controller

# 2. Check readiness probe failures
kubectl describe pod argocd-application-controller-0 -n argocd | grep -A5 Readiness
# Shows: Get "http://10.42.0.200:8082/healthz": dial tcp ...: connection refused

# 3. Check controller logs for API server connectivity
kubectl logs argocd-application-controller-0 -n argocd --tail=50
# If you see: dial tcp 10.43.0.1:443: i/o timeout
# → Controller cannot reach the K8s API server, so healthz never starts
```

**Root Cause Chain:**
```
Controller can't reach K8s API (10.43.0.1:443) → i/o timeout
  → Watcher initialization stuck (infinite retry for Secrets/ConfigMaps)
    → HTTP healthz server on port 8082 never starts
      → Readiness probe gets "connection refused"
        → Pod shows 0/1 Ready
```

**Fix 1: Pod restart (try first):**
```bash
# Delete the pod; StatefulSet recreates it
kubectl delete pod argocd-application-controller-0 -n argocd

# If the new pod gets RunContainerError / CrashLoopBackOff → proceed to Fix 2
```

**Fix 2: Node disk pressure (ARM64 /run tmpfs):**
```bash
# Check new pod events for disk errors
kubectl describe pod argocd-application-controller-0 -n argocd | grep -i "no space"

# If you see: "no space left on device" writing to /run/k3s/containerd/...
# → The node's /run tmpfs is full (common on ARM64 SBC with limited RAM)

# Verify via kubelet proxy:
kubectl proxy --port=8001 &
curl -s http://localhost:8001/api/v1/nodes/<NODE>/proxy/stats/summary | python3 -c "..."
kill %1

# Workaround: cordon the affected node and reschedule pods
kubectl cordon <NODE>                    # e.g. server
kubectl delete pod argocd-application-controller-0 -n argocd
# Pod reschedules to a healthy node
kubectl uncordon <NODE>
```

**Long-term fix for /run tmpfs on ARM64:**
```bash
# SSH into the node and increase /run tmpfs size:
sudo mount -o remount,size=2G /run

# Or add to /etc/fstab for persistence:
# tmpfs /run tmpfs nodev,nosuid,size=2G,mode=755 0 0

# Also check containerd cleanup:
sudo crictl rmi --prune              # Remove unused images
sudo systemctl restart k3s           # Full containerd restart (disruptive)
```

**Common causes of /run tmpfs exhaustion on K3s:**
1. Default /run size = 50% RAM (4 GB on 8 GB Pi). K3s + Cilium consume ~1.5 GB.
2. Containerd shim task directories not cleaned up after pod deletions.
3. Cilium eBPF maps stored in tmpfs.
4. Solution: Increase /run to 2 GB or move to a physical filesystem.

### Cannot login to ArgoCD UI

**Symptom:** Browser shows connection refused or timeout.

**Fix:**
```bash
# Check if ArgoCD server is running
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

# Port-forward to test locally
kubectl port-forward -n argocd svc/argocd-server 8080:80
# Then open http://localhost:8080

# Get initial password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

### ArgoCD Application shows "ComparisonError"

**Symptom:** App status shows `ComparisonError: rpc error: code = Unknown desc = ...`

**Common causes:**

1. **Git repo not accessible:**
   ```bash
   # Check repo URL in ArgoCD settings
   kubectl get repositories -n argocd

   # For public repos, ensure URL is correct
   curl -sI https://github.com/<GITHUB_USER>/<REPO_NAME> | head -1
   ```

2. **Helm chart repo not added:**
   ArgoCD manages external Helm repos (jetstack, metallb, traefik). These are
   referenced directly in Application manifests: no manual `helm repo add` needed.

### ArgoCD sync fails with "namespace not found"

**Symptom:** Sync error: `namespaces "metallb-system" not found`

**Fix:** Ensure `CreateNamespace=true` sync option is set in the Application manifest:
```yaml
syncPolicy:
  syncOptions:
    - CreateNamespace=true
```

All platform apps in this repo have this option enabled.

### ArgoCD self-managed app causes sync loop

**Symptom:** ArgoCD keeps modifying its own resources, causing constant syncs.

**Fix:** Use `ServerSideApply=true` sync option for the ArgoCD self-managed app:
```yaml
# platform/argocd/apps/argocd.yaml
syncPolicy:
  syncOptions:
    - ServerSideApply=true
```
This prevents field manager conflicts when ArgoCD manages itself.

---

## MetalLB Issues

### LoadBalancer service stuck in "Pending"

**Symptom:** `kubectl get svc` shows EXTERNAL-IP as `<pending>`.

**Diagnosis:**
```bash
# Check MetalLB pods
kubectl get pods -n metallb-system

# Check controller logs
kubectl logs -n metallb-system -l app.kubernetes.io/name=metallb --tail=50

# Check speaker logs (runs on each node)
kubectl logs -n metallb-system -l app.kubernetes.io/name=speaker --tail=50

# Verify IP pool exists
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

**Common causes:**

1. **IPAddressPool not created:**
   ```bash
   kubectl apply -f platform/metallb/config/ip-pool.yaml
   ```

2. **IP range overlaps with existing DHCP range:**
   Check your router's DHCP settings. Pick IPs outside the DHCP pool.
   Example: If DHCP gives out `192.168.0.100-192.168.0.199`, use `192.168.0.200-192.168.0.210`.

3. **L2Advertisement missing `ipAddressPools`:**
   Ensure the L2Advertisement references the pool:
   ```yaml
   spec:
     ipAddressPools:
       - homelab-pool
   ```

### MetalLB speaker pods not running on all nodes

**Symptom:** `kubectl get pods -n metallb-system -l app.kubernetes.io/name=speaker` shows fewer pods than nodes.

**Fix:**
```bash
# Check node labels
kubectl get nodes --show-labels

# Speaker is a DaemonSet: check why it's not scheduling
kubectl describe daemonset speaker -n metallb-system
```

---

## Traefik Issues

### Traefik pods CrashLoopBackOff

**Symptom:** Traefik pods keep restarting.

**Diagnosis:**
```bash
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=100
```

**Common causes:**

1. **Port conflict with existing Traefik (K3s built-in):**
   If K3s was installed WITHOUT `--disable traefik`, the built-in Traefik
   already owns ports 80/443.
   **Fix:** Reinstall K3s with `--disable traefik` (see Phase 1 runbook).

2. **IngressClass conflict:**
   ```bash
   kubectl get ingressclass
   ```
   If multiple IngressClasses exist, ensure Traefik is set as default:
   ```yaml
   ingressClass:
     enabled: true
     isDefaultClass: true
   ```

### Ingress not routing traffic

**Symptom:** Service has ExternalIP but curl returns 404 or connection refused.

**Diagnosis:**
```bash
# Check ingress resources
kubectl get ingress -A

# Check Traefik logs for routing decisions
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50 | grep -i error

# Test with verbose curl
curl -v http://<EXTERNAL-IP> -H "Host: argocd.homelab.local"
```

**Common causes:**

1. **Ingress host doesn't match Traefik rule:**
   Ensure the `hosts` in your Ingress match the Traefik entrypoint configuration.

2. **TLS secret missing:**
   If ingress has TLS configured but no secret exists, Traefik may reject requests.
   **Fix:** Create a self-signed cert or use cert-manager.

---

## cert-manager Issues

### cert-manager pods not ready

**Symptom:** `kubectl get pods -n cert-manager` shows pods in Pending or CrashLoopBackOff.

**Diagnosis:**
```bash
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager --tail=100
kubectl logs -n cert-manager -l app.kubernetes.io/name=webhook --tail=100
kubectl logs -n cert-manager -l app.kubernetes.io/name=cainjector --tail=100
```

**Common causes:**

1. **Webhook certificate not generated:**
   The webhook needs a TLS cert to serve HTTPS. cert-manager bootstraps this
   with a self-signed issuer. If the webhook pod can't start, it's a chicken-and-egg problem.
   **Fix:** Wait 30-60 seconds: the bootstrap issuer takes time to generate the webhook cert.

2. **CRDs not installed:**
   ```bash
   kubectl get crd | grep cert-manager
   ```
   If CRDs are missing, reinstall with `--set installCRDs=true`.

### Certificate not being issued

**Symptom:** `kubectl get certificate -A` shows no certificates or status not Ready.

**Diagnosis:**
```bash
# Check Certificate resources
kubectl get certificate -A -o wide

# Check CertificateRequest resources
kubectl get certificaterequest -A

# Check Order and Challenge resources (for Let's Encrypt)
kubectl get order -A
kubectl get challenge -A

# Check cert-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager --tail=100
```

**Common causes:**

1. **No ClusterIssuer configured:**
   cert-manager needs an Issuer or ClusterIssuer to know how to obtain certs.
   For homelab, start with a self-signed ClusterIssuer:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: selfsigned
   spec:
     selfSigned: {}
   ```

2. **DNS challenge failing (Let's Encrypt):**
   For production certs, you need DNS-01 challenge with your DNS provider.
   For homelab, use self-signed or local CA.

---

## App-of-Apps Pattern Issues

### Child apps not being created

**Symptom:** `homelab-apps` app is synced but child apps don't appear.

**Diagnosis:**
```bash
# Check the root app status
kubectl get application homelab-apps -n argocd -o yaml

# Check what files ArgoCD sees in the repo path
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50

# Verify the apps directory has valid YAML
ls -la platform/argocd/apps/
```

**Common causes:**

1. **YAML files not valid Kubernetes resources:**
   Each file in `platform/argocd/apps/` must be a valid ArgoCD Application manifest.

2. **Repo URL mismatch:**
   The `repoURL` in `bootstrap/argocd-app.yaml` must match the configured repository
   in ArgoCD settings.

### Sync wave ordering issues

**Symptom:** Apps sync in wrong order (e.g., metallb-config before metallb).

**Fix:** Use sync wave annotations:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Lower numbers sync first
```

Current wave ordering:
- `-1`: ArgoCD (self-managed): syncs first
- `0`: MetalLB (CRDs must exist before config)
- `1`: MetalLB config, Traefik, cert-manager (no ordering dependency)

---

## Recovery Procedures

### Full ArgoCD recovery

If ArgoCD is completely broken:

```bash
# 1. Delete the broken installation
helm uninstall argocd -n argocd
kubectl delete namespace argocd

# 2. Reinstall from scratch
kubectl create namespace argocd
helm install argocd argo/argo-cd --namespace argocd -f platform/argocd/values.yaml

# 3. Re-apply bootstrap
kubectl apply -f platform/argocd/bootstrap/argocd-app.yaml

# 4. Wait for sync
kubectl get applications -n argocd --watch
```

### Reset a stuck Application

```bash
# Force a hard refresh
argocd app get <app-name> --hard-refresh

# Or via kubectl
kubectl patch application <app-name> -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# If still stuck, delete and let ArgoCD recreate
kubectl delete application <app-name> -n argocd
# ArgoCD's self-heal will recreate it from Git
```

### Recover from bad config commit

```bash
# 1. Revert the bad commit in Git
git revert <bad-commit-hash>
git push

# 2. ArgoCD auto-syncs within the sync interval (default 3 minutes)
# Or force sync:
argocd app sync homelab-apps
```

---

## Validation Commands

```bash
# Quick health check
kubectl get pods -n argocd
kubectl get pods -n metallb-system
kubectl get pods -n traefik
kubectl get pods -n cert-manager

# Check all ArgoCD applications
kubectl get applications -n argocd

# Run Phase 2 test suite
make test-phase2

# Check LoadBalancer IPs
kubectl get svc -A | grep LoadBalancer
```

---

## Additional Issues Found During Phase 2 Live Debug (2026-05-22)

### Child apps stuck on "Unknown" status

**Symptom:** `homelab-apps` is Synced/Healthy but all child apps show `Unknown/Unknown`.

**Root cause:** ArgoCD Application Controller pod (`argocd-application-controller-0`) stuck in `ContainerCreating` due to node cgroup issue (see below). Without the controller running, no apps can be evaluated.

**Fix:**
```bash
# Check controller pod
kubectl get pods -n argocd -l app.kubernetes.io/component=application-controller

# If stuck, move to healthy node
kubectl cordon <BAD_NODE>
kubectl delete pod argocd-application-controller-0 -n argocd
# Wait for reschedule on healthy node
```

### Cgroup slice failures on K3s nodes (`no space left on device`)

**Symptom:** Pods stuck in `ContainerCreating` or `Init:RunContainerError` on a specific node. Events show:
```
failed to create containerd task: failed to write bundle spec:
write /run/k3s/containerd/.../config.json: no space left on device
```

**Root cause:** `/run` tmpfs is full. K3s stores containerd runtime data in `/run/k3s/containerd/`. On ARM64 nodes with limited RAM, the default `/run` size (50% RAM) can fill up with stale containerd task directories.

**Fix on the affected node:**
```bash
# SSH into the node
# Check /run usage
df -h /run

# Clean up unused container images
sudo crictl rmi --prune

# Increase /run tmpfs size
sudo mount -o remount,size=2G /run

# Restart K3s
sudo systemctl restart k3s
```

**Prevention:** Add to `/etc/fstab` for persistence:
```
tmpfs /run tmpfs nodev,nosuid,size=2G,mode=755 0 0
```

### Self-managed ArgoCD causes version downgrade

**Symptom:** ArgoCD pods showing chart version 7.7.0 but were originally installed with chart 9.5.15. This causes `ComparisonError: .status.terminatingReplicas: field not declared in schema`.

**Root cause:** The `argocd` child app in `platform/argocd/apps/argocd.yaml` had `targetRevision: 7.7.0` which deploys ArgoCD v2.13.0. K3s v1.35.4 uses Kubernetes 1.35 which introduced `terminatingReplicas` in Deployment status: a field not known to ArgoCD v2.13.0's schema.

**Fix:**
1. Update `targetRevision` to `9.5.15` (ArgoCD v3.4.2) in `platform/argocd/apps/argocd.yaml`
2. Add `ignoreDifferences` for the `terminatingReplicas` field:
```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /status/terminatingReplicas
  - group: apps
    kind: StatefulSet
    jsonPointers:
      - /status/terminatingReplicas
```

### SSA field ownership blocks Helm upgrades

**Symptom:** `helm upgrade` fails with hundreds of SSA field conflict errors (conflicts with "argocd-controller").

**Root cause:** The self-managed ArgoCD app uses `ServerSideApply: true`. The ArgoCD controller owns many fields on its own resources via SSA. A Helm upgrade tries to manage these fields under the `helm` manager, causing conflicts.

**Fix:** Use `kubectl apply --server-side --force-conflicts` with rendered chart manifests:
```bash
helm template argocd argo/argo-cd -n argocd --version 9.5.15 \
  -f platform/argocd/values.yaml > /tmp/manifests.yaml
kubectl apply --server-side --force-conflicts -f /tmp/manifests.yaml
```

### Repo-server init container SSA merge bug

**Symptom:** `argocd-repo-server` pod stuck in `Init:Error`. Init container `copyutil` fails with:
```
/bin/cp: target '/bin/cp --update=none ...': No such file or directory
```

**Root cause:** ServerSideApply merged two different init container specs from different chart versions:
- Old chart (9.5.15): `command: ["/bin/cp", "-n", ...]`
- New chart (7.7.0): added `args: ["/bin/cp --update=none ... && /bin/ln ..."]`
The merged result had both conflicting `command` and `args`, breaking the container.

**Fix:** Remove the stale `args` from the init container:
```bash
kubectl patch deployment argocd-repo-server -n argocd --type json \
  -p '[{"op":"remove","path":"/spec/template/spec/initContainers/0/args"}]'
```

### CRD schema drift caused by metallb controller

**Symptom:** `metallb` app shows `OutOfSync` because `bgppeers.metallb.io` CRD differs from chart version.

**Root cause:** The MetalLB controller updates CRD schemas at runtime, causing persistent drift from the Helm chart manifest.

**Fix:** Add `ignoreDifferences` for CRD spec changes:
```yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers:
      - /spec
```

### App-of-apps sync stuck waiting for AppProject health

**Symptom:** `homelab-apps` root app shows `OutOfSync` with an operation stuck at:
```
waiting for healthy state of argoproj.io/AppProject/applications and 2 more resources
```
Every git commit re-triggers the sync, which gets stuck again.

**Root cause:** When AppProject YAML files are included in the root app's sync directory (`platform/argocd/apps/`), each sync creates/modifies the AppProject CRDs and then waits for them to become "Healthy." AppProjects have no built-in health probe in ArgoCD, so the health check never completes and the sync waits forever.

**Fix:** Manage AppProjects as static resources: apply them once manually and keep them out of the GitOps sync path:

```bash
# Apply once during bootstrap (before root app)
kubectl create -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
# ... full spec ...
EOF

# Then apply the root app as normal
kubectl apply -f platform/argocd/bootstrap/argocd-app.yaml
```

AppProjects should NOT be in `platform/argocd/apps/`. The root app manages child Application CRDs only.

### Child Application YAML formatting causes spurious OutOfSync

**Symptom:** Root app `homelab-apps` shows `OutOfSync` with `Application/argocd: sync=OutOfSync` even though the spec content matches git.

**Root cause:** ArgoCD's comparison detects minor metadata differences in child Applications:
1. The `argocd.argoproj.io/instance` label added by ArgoCD at runtime
2. YAML formatting differences (literal block scalar chomping `|-` vs `|`)
3. Generation number differences

These are harmless runtime differences that don't affect the actual desired state.

**Fix:** Add `ignoreDifferences` to the root app (`bootstrap/argocd-app.yaml`):

```yaml
ignoreDifferences:
  - group: argoproj.io
    kind: Application
    jsonPointers:
      - /metadata/labels/argocd.argoproj.io~1instance
      - /spec/source/helm/values
```

The `~1` encodes a `/` in JSON Pointer notation.

### ArgoCD "Progressing" health on K3s v1.35 (cosmetic)

**Symptom:** The self-managed `argocd` application always shows `Progressing` health, even though all 7 pods are `1/1 Running` and all Deployments show `available=ready=1`.

**Root cause:** K3s v1.35 uses Kubernetes 1.35 which changed Deployment condition behavior: the `Progressing` condition now stays `True` permanently after successful rollout (with `NewReplicaSetAvailable` reason). ArgoCD interprets `Progressing=True` as the app still being in a progressing state.

**Impact:** Purely cosmetic. All services function normally. The app shows `Progressing` in the UI but is fully operational.

**Workaround attempted (not working):** Health overrides via `argocd-cm` ConfigMap (`resource.customizations.health.apps_Deployment`) don't persist because the self-managed ArgoCD app reverts manual ConfigMap changes. Attempting to add them via Helm `values` block also doesn't take effect in ArgoCD v3.4.2.

**Resolution:** Accepted as a known cosmetic issue. No functional impact.
