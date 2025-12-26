# Why I built it this way

These are the decisions I made while building this homelab, with the actual reasoning. Not just "best practices" from blog posts.

## K3s instead of kubeadm

I started with an ARM64 SBC. Kubeadm with etcd needs about 2GB of RAM just for the control plane, and the Pi only has 8GB total. K3s uses SQLite instead of etcd, ships as a single binary, and handles ARM64 without any special config. It also bundles containerd, CoreDNS, and local-path-provisioner. Exactly what you need for a homelab and nothing you don't.

I considered k3d (K3s in Docker) but running Docker on a Pi just to run K3s inside it seemed silly when K3s runs natively.

## Cilium instead of Calico or Flannel

Wanted eBPF networking mostly for learning. Cilium replaces both the CNI and kube-proxy, which means one less daemon on each node. Hubble gives you network flow visibility without sidecars, which is nice when every megabyte of RAM counts.

The catch: Cilium 1.19.x doesn't work on ARM64. I burned two full days on this. The agent starts, attaches BPF programs to sockets at the kernel level, and then silently drops every TCP connection from the host. SSH daemon keeps listening, the node shows Ready in `kubectl get nodes`, but you can't connect to anything. No error logs, no kernel messages, nothing. Just dead air.

Tried every flag combination: `enableHostLegacyRouting`, `bpf.enableTCX=false`, `socketLB.hostNamespaceOnly`, `bpf.lbLocalhost=false`. Nothing helped. The only fix was pinning to 1.18.9. There's [an open issue](https://github.com/cilium/cilium/issues/46010) about it that matches my symptoms.

I also learned that if you run pods on the control plane with Cilium's kube-proxy replacement, the ClusterIP for the API server (10.43.0.1:443) becomes unreachable from those pods. Something to do with how Cilium handles service IPs when the API server is on the same node. So the control plane stays tainted with `NoSchedule`. It only runs system daemons.

## ArgoCD instead of Flux

ArgoCD has a web UI. For a homelab where I'm learning GitOps, being able to actually see what's synced, what's drifting, and what failed is incredibly useful. Flux is more "pure GitOps" with no UI, but for one person managing a 2-node cluster, visibility beats purity.

The App-of-Apps pattern means I apply one bootstrap manifest and ArgoCD creates every other Application CR from the `platform/argocd/apps/` directory. Adding a new app is just committing a new YAML file.

Had to learn about `ignoreDifferences` the hard way. Kubernetes adds default values to resources that Helm doesn't include in its templates, so ArgoCD constantly shows them as OutOfSync. Also, Helm renders multi-line ConfigMap data as quoted strings with `\n`, but Kubernetes stores them as YAML block scalars with `|`. ArgoCD's diff engine can't reconcile the two and treats the whole resource as different. The fix is adding `ignoreDifferences` entries for `/data` on those ConfigMaps.

Another fun one: the ArgoCD `server.insecure: true` config value was stored in a nested ConfigMap key (`server: map[insecure:true]`) but the deployment reads it as a flat key (`server.insecure`). The env var was empty, so ArgoCD kept redirecting HTTP→HTTPS infinitely behind Traefik. Browser showed "The page isn't redirecting properly."

## Traefik instead of NGINX

Traefik has built-in cert-manager integration and a middleware system. When Home Assistant backup uploads were timing out after 30 seconds, I just had to add a Traefik middleware that removes buffering limits. No sidecar containers, no Lua plugins, just a CRD.

The ingress `status.loadBalancer` field was empty forever because Traefik doesn't populate it by default. Adding `publishedService.enabled=true` fixed it. Without it, ArgoCD shows every ingress as eternally Progressing.

## Home Assistant as a StatefulSet

Home Assistant uses SQLite, and SQLite doesn't support concurrent writers. If two pods try to access the database simultaneously, you get corruption. StatefulSet with `Recreate` strategy and a PVC means there's always exactly one pod, and the data survives restarts.

Originally mounted `configuration.yaml` from a ConfigMap via `subPath`. This made it read-only. Backup restore couldn't write to it. Fixed by switching to an init container that copies the ConfigMap to the PVC on first boot, then leaving the file under HA's control.

Also had to relax the health probes. During a backup restore, HA can be CPU-bound for minutes processing a large file. Default probe timeouts killed the pod mid-restore. Increased liveness to 30s timeout with 10 failures (5-minute grace period).

## The monitoring stack

kube-prometheus-stack bundles Prometheus, Grafana, and Alertmanager in one Helm chart. The Grafana sidecar auto-discovers dashboards and datasources from ConfigMaps with labels. No manual provisioning needed.

For Loki, had to switch from the default memcached settings. The chart defaults chunks-cache to 9830Mi which is more RAM than my entire cluster. Reduced it to 128Mi.

The OTel Collector broke because I had `tls: insecure: true` in the pprof extension config. The version I'm running doesn't support that key. Simple fix, but taught me to always check the actual error logs, not the ArgoCD status (which just said "Healthy" and "Synced" while the pod was CrashLoopBackOff-ing).

## Network policies

Applied default-deny to `home-assistant` namespace. It's a single pod with well-defined ingress from Traefik and monitoring, so it's easy to lock down. For `monitoring` and `argocd`, the inter-service dependencies are too complex for a full default-deny in a homelab. I use allow-only policies there, which at least document what traffic should flow.

Also ran kube-bench for CIS compliance. It flagged 8 checks as failures, but all of them were because it looks in `/etc/kubernetes/pki/` while K3s stores things under `/var/lib/rancher/k3s/`. The filter script in `security/scans/` explains each one.
