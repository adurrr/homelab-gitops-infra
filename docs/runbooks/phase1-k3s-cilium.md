# Phase 1 Runbook: K3s Cluster with Cilium CNI

> **Status:** ✅ Complete
> **Date:** May 2026
> **Nodes:** server (server, ARM64 RPi) + agent (agent, amd64)
> **K3s:** v1.35.4+k3s1 | **Cilium:** v1.19.3

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Installation Steps](#2-installation-steps)
3. [Verification](#3-verification)
4. [Troubleshooting](#4-troubleshooting)
5. [Lessons Learned](#5-lessons-learned)

---

## 1. Prerequisites

### Hardware
- **Server node (server):** ARM64 SBC, ARM64, Debian 13 (trixie)
- **Agent node (agent):** x86_64 node, Debian 13 (trixie)
- **Admin machine:** Your workstation with `kubectl`, `cilium` CLI, SSH access

### Software (on admin machine)
```bash
# Cilium CLI: install from https://github.com/cilium/cilium-cli/releases
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz{,.sha256sum}
```

### SSH Access
```bash
# Must be able to SSH into both nodes from admin machine
ssh server "echo OK"
ssh agent "echo OK"
```

### Ansible Bootstrap
```bash
# Run first to install kernel modules, sysctl, tools
make ansible-bootstrap
```

### Environment Configuration
```bash
cp infra/env.example infra/.env
vim infra/.env  # Fill in real IPs, hostnames, and K3S_TOKEN
```

### Cilium Values
```bash
cp infra/cilium/values.example.yaml infra/cilium/values.yaml
vim infra/cilium/values.yaml  # Update k8sServiceHost to your server IP
```

---

## 2. Installation Steps

### Step 1: Install K3s Server

```bash
source infra/.env && bash infra/k3s/server-install.sh
```

**What this does:**
- Installs K3s with these flags:
  ```
  --flannel-backend=none        # Cilium replaces flannel as CNI
  --disable-network-policy      # Cilium provides its own network policy
  --disable traefik             # Managed via ArgoCD in Phase 2
  --disable-kube-proxy          # Cilium replaces kube-proxy with eBPF
  --disable metrics-server      # Managed via ArgoCD in Phase 2
  --tls-san <SERVER_IP>         # Allows remote kubectl access
  --write-kubeconfig-mode=644   # Allows copying kubeconfig
  ```

**Manual alternative (if SSH/passwordless sudo not set up):**
```bash
ssh server
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --flannel-backend=none --disable-network-policy --disable traefik --disable-kube-proxy --disable metrics-server --tls-san <CONTROL_PLANE_IP> --write-kubeconfig-mode=644 --token=<YOUR-TOKEN>' sh -
```

### Step 2: Copy Kubeconfig

```bash
scp server:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab
sed -i 's/127.0.0.1/<CONTROL_PLANE_IP>/' ~/.kube/config-homelab
export KUBECONFIG=~/.kube/config-homelab
kubectl get nodes  # Should show server as Ready
```

### Step 3: Install K3s Agent

```bash
source infra/.env && bash infra/k3s/agent-install.sh
```

**Manual alternative:**
```bash
ssh agent
curl -sfL https://get.k3s.io | K3S_URL=https://<CONTROL_PLANE_IP>:6443 K3S_TOKEN=<YOUR-TOKEN> sh -
```

### Step 4: Verify Cluster

```bash
kubectl get nodes
# Both nodes should show Ready
```

### Step 5: Install Cilium

```bash
make cilium-install
# Or manually:
cilium install --version 1.19.3 -f infra/cilium/values.yaml
```

### Step 6: Verify Cilium

```bash
cilium status
# All components should show OK
```

---

## 3. Verification

### Cluster Health
```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

### Cilium Status
```bash
cilium status
```

### DNS Resolution
```bash
kubectl run dns-test --rm -it --image=busybox:1.28 --restart=Never -- nslookup kubernetes.default
```

### Cross-Node Networking
```bash
cilium connectivity test
```

### Run Phase 1 Tests
```bash
export KUBECONFIG=~/.kube/config-homelab
make test-phase1
```

---

## 4. Troubleshooting

### Issue 1: Disk Full on Server Node

**Symptoms:**
- Pods in `CrashLoopBackOff` or `Error` state
- `cilium status` shows errors on cilium pods
- Logs contain `no space left on device`
- `metrics-server`, `local-path-provisioner`, `coredns` all failing

**Root Cause:**
The server node's root filesystem was full, preventing container creation and Cilium state writes.

**Fix:**
```bash
ssh server
# Check disk usage
df -h
du -sh /var/lib/rancher/k3s/* | sort -rh | head -20
du -sh /var/log/* | sort -rh | head -10

# Clean up
sudo journalctl --vacuum-size=100M
sudo k3s crictl rmi --prune  # Remove unused container images
sudo rm -rf /var/lib/rancher/k3s/agent/containerd/io.containerd.snapshotter.*/*  # Stale snapshots
```

**Prevention:**
- Monitor disk usage with Prometheus
- Set log rotation policies
- Use `local-path-provisioner` with size limits

---

### Issue 2: K3s Installed Without `--disable-kube-proxy`

**Symptoms:**
- CoreDNS `kubernetes` plugin not ready
- `cilium status` shows errors
- Hubble Relay in `CrashLoopBackOff`
- `kubectl logs` shows `kube-proxy running in dual-stack mode` and `Using iptables Proxier`
- Service IP routing broken: pods can't reach API server

**Root Cause:**
K3s was installed with only `--flannel-backend=none --disable-network-policy`, missing `--disable-kube-proxy`. Cilium's `kubeProxyReplacement: true` conflicts with K3s's built-in kube-proxy. Both try to manage service IP routing, causing conflicts.

**Fix:**
```bash
# On server node (server)
sudo k3s-uninstall.sh
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --flannel-backend=none --disable-network-policy --disable traefik --disable-kube-proxy --disable metrics-server --tls-san <CONTROL_PLANE_IP> --write-kubeconfig-mode=644 --token=<YOUR-TOKEN>' sh -

# On agent node (agent)
sudo k3s-agent-uninstall.sh
curl -sfL https://get.k3s.io | K3S_URL=https://<CONTROL_PLANE_IP>:6443 K3S_TOKEN=<YOUR-TOKEN> sh -

# From admin machine
scp server:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab
sed -i 's/127.0.0.1/<CONTROL_PLANE_IP>/' ~/.kube/config-homelab
export KUBECONFIG=~/.kube/config-homelab

# Reinstall Cilium
cilium uninstall
cilium install --version 1.19.3 -f infra/cilium/values.yaml
```

**Key flags explained:**
| Flag | Why |
|------|-----|
| `--flannel-backend=none` | Cilium replaces flannel as CNI |
| `--disable-network-policy` | Cilium provides its own network policy engine |
| `--disable traefik` | Managed via ArgoCD in Phase 2 |
| `--disable-kube-proxy` | **Critical**: Cilium replaces kube-proxy with eBPF |
| `--disable metrics-server` | Managed via ArgoCD in Phase 2 |

---

### Issue 3: systemd Unit File Parse Error

**Symptoms:**
```
Failed to restart k3s.service: Unit k3s.service has a bad unit file setting.
/etc/systemd/system/k3s.service:47: Unbalanced quoting, ignoring
```

**Root Cause:**
Newlines in the `INSTALL_K3S_EXEC` string caused systemd's unit file parser to fail. The install script uses line continuations (`\`) which work in bash but break systemd.

**Fix:**
Pass `INSTALL_K3S_EXEC` as a single line:
```bash
# WRONG (newlines break systemd):
INSTALL_K3S_EXEC='server \
  --flannel-backend=none \
  --disable-kube-proxy'

# CORRECT (single line):
INSTALL_K3S_EXEC='server --flannel-backend=none --disable-kube-proxy'
```

**Note:** The `server-install.sh` script handles this correctly by passing the full string to SSH in one line.

---

### Issue 4: CoreDNS Not Ready: `kubernetes` Plugin Failing

**Symptoms:**
- CoreDNS pod shows `0/1 Running` (e.g. `coredns-c4dbffb5f-r4dql  0/1  Running  0  2m6s`)
- Logs repeat: `[INFO] plugin/ready: Plugins not ready: "kubernetes"`
- `kubectl get endpoints kube-dns` shows empty or `notReadyAddresses`
- DNS queries from pods fail: `nslookup: can't resolve 'kubernetes.default'`

**Root Cause:**
CoreDNS's `kubernetes` plugin needs to watch the Kubernetes API server to discover services and endpoints. If it can't reach the API server (due to kube-proxy conflict, network issues, or timing), it never becomes ready.

**Quick Diagnostic: Find Your Root Cause:**

```bash
# Step 1: Check CoreDNS logs for the specific error
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=30

# Step 2: Check if kube-proxy is running (it shouldn't be)
kubectl get pods -n kube-system | grep kube-proxy
# If you see kube-proxy pods → Issue 2 (missing --disable-kube-proxy)

# Step 3: Check if Cilium is healthy
cilium status
# If Cilium is not OK → fix Cilium first, CoreDNS depends on it

# Step 4: Check if the API server is reachable from within the cluster
kubectl run api-test --rm -it --image=busybox:1.28 --restart=Never -- wget -q -O- --timeout=5 https://kubernetes.default:443
# If this times out → networking issue (Issues 2, 10, or 11)
```

**Fix by Root Cause:**

| Root Cause | Indicator | Fix |
|---|---|---|
| kube-proxy conflict | `kube-proxy` pods exist in `kube-system` | See **Issue 2**: reinstall K3s with `--disable-kube-proxy` |
| Cilium not ready yet | `cilium status` shows errors | Wait for Cilium to be healthy, then restart CoreDNS |
| BPF masquerade missing | API server unreachable from pods | See **Issue 10**: add `enableBpfMasquerade: true` |
| UFW blocking VXLAN | Cross-node traffic fails | See **Issue 11**: allow UDP 8472 on all nodes |
| Timing / stale state | Everything else looks healthy | Restart CoreDNS (see below) |

**Fix: Restart CoreDNS (for timing/stale state):**
1. First, ensure `--disable-kube-proxy` is set (see Issue 2)
2. Ensure Cilium is healthy (`cilium status` shows OK)
3. Restart CoreDNS after Cilium is properly installed:
   ```bash
   kubectl delete pod -n kube-system -l k8s-app=kube-dns
   ```
4. Wait 30 seconds and verify:
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   kubectl get endpoints kube-dns -n kube-system  # Should show ready addresses
   ```
5. Test DNS resolution:
   ```bash
   kubectl run dns-test --rm -it --image=busybox:1.28 --restart=Never -- nslookup kubernetes.default
   ```

---

### Issue 5: Hubble Relay CrashLoopBackOff

**Symptoms:**
- `hubble-relay` pod in `CrashLoopBackOff`
- Logs show: `dns: A record lookup error: lookup hubble-peer.kube-system.svc.cluster.local. on 10.43.0.10:53: read udp ... i/o timeout`
- `cilium status` shows `Hubble Relay: 1 errors`

**Root Cause:**
Hubble Relay depends on DNS to find the `hubble-peer` service. If CoreDNS is not ready (Issue 4), Hubble Relay can't resolve the service address and crashes.

**Fix:**
1. Fix CoreDNS first (see Issue 4)
2. Restart Hubble Relay to clear stale network state:
   ```bash
   kubectl rollout restart deployment hubble-relay -n kube-system
   sleep 30
    cilium status  # Should show Hubble Relay: OK
    ```

**Variant: TLS certificate authority mismatch after Cilium reinstall**

If you `cilium uninstall` then `cilium install` (or `cilium upgrade` that regenerates the CA), the `cilium-ca` secret is replaced: the old CA is gone. The `hubble-relay-client-certs` secret, signed by the old CA, is also deleted. If the Cilium operator fails to regenerate it, hubble-relay will fail with:

```
tls: unknown certificate authority
```

This happens because the relay pod mounts a TLS client cert signed by a now-invalid CA. The operator **will not** recreate the relay deployment on its own: it only manages the certs. Since the deployment itself was nuked during uninstall/reinstall, there are two failure modes:

1. **Relay exists but has stale certs**: Logs show `tls: unknown certificate authority`. The `hubble-relay-client-certs` secret exists but is signed by the old (deleted) CA.
2. **Relay deployment doesn't exist**: The operator didn't recreate it after uninstall. No pods, no secret.

**Fix for either variant:**
```bash
# Re-run cilium upgrade: this recreates the deployment AND generates fresh certs signed by the current CA
cilium upgrade --version 1.19.3 -f infra/cilium/values.yaml
```

Verify:
```bash
kubectl get secret hubble-relay-client-certs -n kube-system  # Should exist, age ~seconds
cilium status | grep -i relay  # Should show Hubble Relay: OK
```

**What changed:** The initial `cilium install` creates certs during first bootstrap. If Cilium is later reinstalled (e.g., to fix networking issues), the new install generates a fresh CA and the operator may not trigger a relay deployment recreation. The `cilium upgrade` command is the reliable path to recreate both the deployment and its certs in sync.

---

### Issue 6: Cilium BPF Masquerade Conflicts

**Symptoms:**
- DNS queries timeout (not refused)
- `cilium connectivity test` fails with `context deadline exceeded`
- Pods can't reach services via ClusterIP

**Root Cause:**
The `enableMasqueradeToRouteSource: true` and `bpf.masquerade: true` settings in Cilium values conflicted with K3s's built-in networking. These settings are not needed when K3s is properly configured with `--disable-kube-proxy`.

**Fix:**
Remove these settings from `infra/cilium/values.yaml`:
```yaml
# REMOVE these:
enableMasqueradeToRouteSource: true
bpf:
  masquerade: true
```

Reinstall Cilium:
```bash
cilium uninstall
cilium install --version 1.19.3 -f infra/cilium/values.yaml
```

---

### Issue 7: Agent Node Can't Join Server

**Symptoms:**
- `k3s-agent` service stuck in `activating (start)`
- Logs show: `Waiting to retrieve agent configuration; server is not ready`
- `curl https://<SERVER_IP>:6443` returns `Connection refused`

**Root Cause:**
The server node was crashing/restarting (due to disk full or kube-proxy conflict), so port 6443 was intermittently unavailable.

**Fix:**
1. Fix the server node first (Issues 1 or 2)
2. Verify server is stable:
   ```bash
   ssh server
   sudo ss -tlnp | grep 6443  # Should show LISTEN on *:6443
   systemctl status k3s       # Should show active (running)
   ```
3. Then reinstall agent:
   ```bash
   ssh agent
   sudo k3s-agent-uninstall.sh
   curl -sfL https://get.k3s.io | K3S_URL=https://<CONTROL_PLANE_IP>:6443 K3S_TOKEN=<YOUR-TOKEN> sh -
   ```

---

### Issue 8: `kubectl exec` Fails with OCI Runtime Error

**Symptoms:**
```
error executing command in container: failed to exec in container:
OCI runtime exec failed: exec failed: unable to start container process:
exec: "sh": executable file not found in $PATH
```

**Root Cause:**
This happens when the container image doesn't have `sh` (e.g., distroless images) or when `containerd`/`runc` has issues. In our case, it was caused by disk full (Issue 1) corrupting container state.

**Fix:**
1. Clean up disk space (Issue 1)
2. Restart the affected pods:
   ```bash
   kubectl delete pod -n kube-system -l k8s-app=cilium
   ```
3. If using `busybox:1.28`, it has `sh`. Some minimal images don't.

---

### Issue 9: local-path-provisioner CrashLoopBackOff

**Symptoms:**
- `local-path-provisioner` pod in `CrashLoopBackOff`
- Logs show: `dial tcp 10.43.0.1:443: i/o timeout`
- Error: `invalid empty flag helper-pod-file and it also does not exist at ConfigMap kube-system/local-path-config`

**Root Cause:**
The provisioner pod was created before Cilium's BPF service maps were fully synced. It can't reach the API server via the ClusterIP `10.43.0.1`, so it fails to read the `local-path-config` ConfigMap.

**Fix:**
```bash
kubectl rollout restart deployment local-path-provisioner -n kube-system
sleep 30
kubectl get pods -n kube-system -l app=local-path-provisioner
```

---

### Issue 10: Pods Cannot Reach the Internet

**Symptoms:**
- `kubectl exec <pod> -- wget -q -O- --timeout=5 http://1.1.1.1` times out
- `kubectl exec <pod> -- ping -c 1 <gateway>` fails with 100% packet loss
- `cilium connectivity test` fails on `pod-to-cidr` and `pod-to-world` scenarios
- iptables MASQUERADE counters stay at 0:
  ```bash
  sudo iptables -t nat -L CILIUM_POST_nat -n -v
  # Shows: 0 packets, 0 bytes on MASQUERADE rule
  ```

**Root Cause:**
When `kubeProxyReplacement: true`, Cilium routes all pod traffic through eBPF programs, bypassing the kernel's iptables stack. Without `enableBpfMasquerade: true`, pod IPs (10.42.x.x) are NOT translated (SNAT'd) to the node IP when leaving the cluster. Your router/firewall (e.g. OPNsense) sees packets from unknown 10.42.x.x source addresses and drops them.

**Note:** This also breaks CoreDNS's `kubernetes` plugin (Issue 4), since CoreDNS can't reach the API server via ClusterIP without proper masquerading. If CoreDNS is stuck at `0/1 Running`, check this issue before restarting CoreDNS.

**Why iptables MASQUERADE doesn't help:**
The iptables MASQUERADE rules exist in the `CILIUM_POST_nat` chain but their packet counters stay at 0 because eBPF handles the forwarding decision before traffic reaches iptables. The MASQUERADE rule is never hit.

**Fix:**
```bash
# 1. Add to infra/cilium/values.yaml (after tunnelProtocol: vxlan):
enableBpfMasquerade: true

# 2. Upgrade Cilium
cilium upgrade --version 1.19.3 -f infra/cilium/values.yaml

# 3. If the configmap doesn't update, patch it manually:
kubectl patch cm cilium-config -n kube-system --type merge \
  -p '{"data":{"enable-bpf-masquerade":"true"}}'

# 4. Restart Cilium pods to pick up the new config
kubectl rollout restart ds cilium -n kube-system

# 5. Wait 60 seconds and verify
sleep 60
kubectl exec -n cilium-test-1 client -- wget -q -O- --timeout=5 http://1.1.1.1
```

**Verify the fix:**
```bash
# Check configmap
kubectl get cm cilium-config -n kube-system -o jsonpath='{.data.enable-bpf-masquerade}'
# Should output: true

# Check Cilium agent logs
kubectl logs -n kube-system -l k8s-app=cilium --tail=50 | grep -i masquerade
# Should NOT show "BPF host routing requires enable-bpf-masquerade"

# Test from pods on both nodes
kubectl exec -n cilium-test-1 client -- wget -q -O- --timeout=5 http://1.1.1.1  # server pod
kubectl exec -n cilium-test-1 client3 -- wget -q -O- --timeout=5 http://1.1.1.1  # agent pod
```

---

### Issue 11: Cross-Node VXLAN Traffic Blocked by UFW

**Symptoms:**
- Same-node pod-to-pod works, cross-node fails
- `cilium connectivity test` fails on cross-node scenarios
- `bridge fdb show dev cilium_vxlan` is empty (normal: Cilium uses BPF, not kernel FDB)
- VXLAN RX counter on one node stays at 0:
  ```bash
  ssh <node> "ip -s link show cilium_vxlan"
  # RX: bytes 0 packets 0  ← no traffic received
  ```

**Root Cause:**
UFW (Uncomplicated Firewall) on one or more nodes blocks incoming VXLAN traffic (UDP port 8472). The VXLAN tunnel encapsulates pod traffic in UDP packets sent to port 8472. If UFW drops these packets, cross-node communication fails.

**Fix:**
```bash
# On the node with UFW active (check with: sudo ufw status):
sudo ufw allow 8472/udp   # VXLAN tunnel
sudo ufw allow 6443/tcp   # K3s API server
sudo ufw allow 6444/udp   # K3s agent join

# Verify
sudo ufw status
# Should show 8472/udp ALLOW

# Test cross-node connectivity
ssh <other-node> "ping -c 2 10.42.0.1"  # From agent to server pod CIDR
```

**Why `bridge fdb` is empty:**
Cilium uses BPF-managed VXLAN (`external` mode), not kernel-managed VXLAN. The kernel's bridge FDB is intentionally empty: Cilium's eBPF programs handle the VXLAN encapsulation/decapsulation directly. This is normal and expected.

---

### Issue 12: `autoDirectNodeRoutes` Crashes Cilium with VXLAN

**Symptoms:**
- Cilium pods in `CrashLoopBackOff`
- Logs show: `fatal msg="auto-direct-node-routes cannot be used with tunneling. Packets must be routed through the tunnel device."`

**Root Cause:**
`autoDirectNodeRoutes: true` is incompatible with `tunnelProtocol: vxlan`. This setting is only valid for native (direct) routing mode, not tunnel mode.

**Fix:**
```bash
# Remove from infra/cilium/values.yaml:
# autoDirectNodeRoutes: true  ← DELETE THIS LINE

# Reinstall Cilium
cilium uninstall --wait
cilium install --version 1.19.3 -f infra/cilium/values.yaml
```

---

## 5. Lessons Learned

### 1. Always Use `--disable-kube-proxy` with Cilium
When using Cilium's `kubeProxyReplacement: true`, you **must** disable K3s's built-in kube-proxy. Otherwise, both try to manage service IP routing, causing conflicts that break DNS and all cluster networking.

### 2. Disk Space Matters
A full disk on the server node causes cascading failures across the entire cluster. Monitor disk usage and set up alerts.

### 3. Order of Operations Matters
The correct sequence is:
1. Install K3s server with **all** required flags
2. Join agent node
3. Verify cluster (both nodes Ready)
4. Install Cilium
5. Restart CoreDNS (if needed)
6. Restart Hubble Relay (if needed)
7. Restart local-path-provisioner (if needed)

If you install Cilium before K3s is properly configured, you'll need to uninstall and reinstall everything.

### 8. Restart Dependent Pods After Cilium Install
After Cilium is installed, pods that were created before Cilium's BPF maps were ready may have stale network state. **Restart in this order:**
```bash
# 1. CoreDNS first: it's the foundation for all service discovery
kubectl delete pod -n kube-system -l k8s-app=kube-dns
sleep 15

# 2. Verify CoreDNS is ready before proceeding
kubectl get endpoints kube-dns -n kube-system  # Should show ready addresses

# 3. Then restart other dependent pods
kubectl rollout restart deployment local-path-provisioner -n kube-system
kubectl rollout restart deployment hubble-relay -n kube-system
```

### 4. CoreDNS Is the Canary
If CoreDNS's `kubernetes` plugin is not ready, **nothing else will work**. All service discovery depends on it. Use the diagnostic flow in **Issue 4** to identify the root cause before restarting CoreDNS: a restart alone won't fix underlying networking issues. Common causes: kube-proxy conflict (Issue 2), missing BPF masquerade (Issue 10), or UFW blocking VXLAN (Issue 11).

### 5. Keep Cilium Values Minimal: Except BPF Masquerade
Don't add advanced settings (`enableMasqueradeToRouteSource`, `bpf.masquerade`) unless you have a specific need. **However**, `enableBpfMasquerade: true` is REQUIRED when `kubeProxyReplacement: true`: without it, pods cannot reach the internet because their IPs aren't SNAT'd to the node IP.

### 9. `cilium upgrade` May Not Update the ConfigMap
The `cilium upgrade` command sometimes fails to propagate new values to the `cilium-config` ConfigMap. If a setting doesn't take effect after upgrade, patch the configmap manually and restart Cilium pods:
```bash
kubectl patch cm cilium-config -n kube-system --type merge \
  -p '{"data":{"enable-bpf-masquerade":"true"}}'
kubectl rollout restart ds cilium -n kube-system
```

### 10. UFW Must Allow VXLAN Traffic
If any node runs UFW, it must allow UDP port 8472 for the VXLAN tunnel. Without this, cross-node pod communication fails silently: packets are dropped before reaching Cilium's BPF programs.

### 11. `bridge fdb` Is Always Empty with Cilium
Cilium uses BPF-managed VXLAN (`external` mode), not kernel-managed VXLAN. The kernel's bridge FDB is intentionally empty. Don't use `bridge fdb` to debug Cilium VXLAN: use `cilium status`, `cilium node list`, and `ip -s link show cilium_vxlan` instead.

### 6. Use `--disable metrics-server`
K3s bundles metrics-server, but it conflicts with the version you'll install via ArgoCD in Phase 2. Disable it upfront to avoid CrashLoopBackOff.

### 7. Single-Line `INSTALL_K3S_EXEC`
When passing `INSTALL_K3S_EXEC` to the K3s installer, use a single line. Newlines break systemd's unit file parser.

---

## Quick Reference

### Reinstall Everything from Scratch
```bash
# On server (server)
sudo k3s-uninstall.sh
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --flannel-backend=none --disable-network-policy --disable traefik --disable-kube-proxy --disable metrics-server --tls-san <CONTROL_PLANE_IP> --write-kubeconfig-mode=644 --token=<YOUR-TOKEN>' sh -

# On agent (agent)
sudo k3s-agent-uninstall.sh
curl -sfL https://get.k3s.io | K3S_URL=https://<CONTROL_PLANE_IP>:6443 K3S_TOKEN=<YOUR-TOKEN> sh -

# From admin machine
scp server:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab
sed -i 's/127.0.0.1/<CONTROL_PLANE_IP>/' ~/.kube/config-homelab
export KUBECONFIG=~/.kube/config-homelab

cilium uninstall
cilium install --version 1.19.3 -f infra/cilium/values.yaml
cilium status
```

### Common Diagnostic Commands
```bash
# Check node status
kubectl get nodes -o wide

# Check all pods in kube-system
kubectl get pods -n kube-system -o wide

# Check CoreDNS
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20
kubectl get endpoints kube-dns -n kube-system

# Check Cilium
cilium status
cilium connectivity test

# Check Hubble Relay
kubectl logs -n kube-system -l k8s-app=hubble-relay --tail=20

# Check disk space on nodes
ssh server 'df -h /'
ssh agent 'df -h /'

# Check k3s service
ssh server 'systemctl status k3s'
ssh agent 'systemctl status k3s-agent'

# Check ports
ssh server 'sudo ss -tlnp | grep -E "6443|6444"'
```
