# Recovery Runbooks

Stuff that broke and how I fixed it.

## Node unreachable (ping works, SSH doesn't)

This is the Cilium silent-death-on-ARM64 bug. The node is alive at the network level but all TCP is dead.

From the physical console:

```bash
# Kill the Cilium BPF programs on eth0 (this immediately restores networking)
sudo tc qdisc del dev eth0 clsact

# Kill any cilium-agent trying to restart
sudo crictl rm -f $(sudo crictl ps -q --name cilium-agent)

# Restart K3s cleanly
sudo systemctl restart k3s
```

If that doesn't work, full cleanup:

```bash
sudo systemctl stop k3s
sudo rm -rf /sys/fs/bpf/cilium /var/lib/cilium /var/run/cilium
sudo reboot
```

## ArgoCD controller keeps crashing (OOMKilled)

Check with `kubectl describe pod -n argocd argocd-application-controller-0`. If it says `OOMKilled`, the memory limit is too low.

```bash
kubectl patch statefulset argocd-application-controller -n argocd --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"1Gi"}]'
```

The kube-prometheus-stack chart generates 82,000+ lines of YAML. The controller needs to load and diff all of that, plus 8 other apps. 512Mi isn't enough.

## Browser shows "The page isn't redirecting properly" for ArgoCD

ArgoCD's `server.insecure` flag isn't reaching the deployment. The Helm chart stores it as a nested key but the deployment reads a flat key.

```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd --type json \
  -p '[{"op":"add","path":"/data/server.insecure","value":"true"}]'
kubectl rollout restart deployment argocd-server -n argocd
```

## ConfigMap changes don't take effect (ignoreDifferences blocks it)

When `ignoreDifferences` has `/data` for a ConfigMap, ArgoCD won't update it even if the values change. Delete the ConfigMap and ArgoCD recreates it with the correct content:

```bash
kubectl delete configmap <name> -n <namespace>
```

## Grafana stuck at 2/3 ready

One of the three containers is crashing. Check which one:

```bash
kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{range .items[*].status.containerStatuses[*]}{.name}={.ready} {end}'
```

If `grafana` is `false`, check if it's a SQLite migration error. The PVC might have stale data:

```bash
# Clean the PVC
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana --force --grace-period=0
```

If the sidecar containers are failing, they can't reach the K8s API to discover ConfigMaps. Check the network policy isn't blocking them.

## Loki pods crashing or unschedulable

The most common issue on a 4GB node is the memcached defaults. Loki's chart reserves ~10GB for chunks cache. Patch it:

```bash
kubectl patch sts loki-chunks-cache -n monitoring --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"128Mi"}]'
kubectl patch sts loki-results-cache -n monitoring --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"64Mi"}]'
```

## After complete cluster reboot

Order matters. Bring up server first (control plane), wait for the API server, then bring up agent.

1. Boot server, wait 60 seconds
2. `kubectl get nodes` should show server Ready
3. Boot agent
4. Cilium starts on both nodes automatically
5. ArgoCD detects any drift and self-heals
6. All apps should be back within 5-10 minutes
