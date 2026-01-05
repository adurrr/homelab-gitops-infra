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

## The alerting strategy

I was collecting mountains of metrics, logs, and traces but had zero notification pipeline. Prometheus was scraping, Loki was ingesting, the OTel Collector was forwarding, and Alertmanager was deployed with its default empty config. No receivers, no routes, no inhibition rules. When something broke, I found out when I tried to use it.

The decision was to put alert rules in PrometheusRule CRDs stored in Git rather than Grafana managed alerts. PrometheusRule CRDs survive cluster rebuilds, align with the GitOps source-of-truth principle (Constitution Rule #2), and put 100% of alert definitions in version control. Grafana managed alerts are still available for multi-source correlation (e.g., "Loki sees auth failures AND Prometheus sees latency spike"), but infrastructure alerts live in CRDs.

For notification, I chose Telegram. Alertmanager has no native Telegram receiver, so there's a webhook_configs pointing at a lightweight bridge service that translates Alertmanager's JSON payload into Telegram's Bot API format. The bridge is a separate deployment; the Alertmanager config just holds the URL. I also left a placeholder receiver for Rocketchat, since that's the long-term chat platform.

The route tree sends critical alerts through immediately (10s group_wait) and warning alerts with more relaxed grouping (2m group_wait, 15m repeat). Info alerts go to a null receiver, they exist for dashboard context but shouldn't page anyone.

Inhibition rules were the thing I almost skipped and would have regretted. Without them, a single node going NotReady triggers 10+ pod-level alerts simultaneously. The inhibition rules say: if KubeNodeNotReady is firing, suppress KubePodCrashLooping and KubePodNotReady for pods on that node. Same for CrashLooping suppressing PodNotReady. The `equal:` matching only works if alert rules explicitly set the labels they're matching on. I made sure the node, namespace, and pod labels are set correctly.

The dead man's switch is a Watchdog alert (just `vector(1)`) that fires constantly. If it ever stops, either Prometheus or Alertmanager is dead. It goes to the same Telegram channel so I notice the silence.

What I deliberately did NOT do: no PagerDuty (overkill for a 2-node homelab), no Grafana managed alerts for infrastructure rules (keep them in GitOps), no email notifications (too noisy, and I already check Telegram). The one thing I might add later is a second notification channel for critical alerts, a fallback in case the Telegram bridge goes down, but for now the Watchdog alert serves as the canary for that.

## Self-healing: what's automated and what isn't

Right now, the only automated self-healing is ArgoCD's `selfHeal: true` on observability apps. If my fat fingers run `kubectl edit` and change something ArgoCD manages, it gets reverted within three minutes. Pod restarts happen naturally through Kubernetes liveness probes. That's it. No operator is auto-scaling, auto-rolling-back, or auto-killing anything.

I broke it into three tiers so I don't accidentally automate something that makes things worse:

**Tier 1 - Auto (safe):** ArgoCD drift correction and pod restarts via liveness probes. These are idempotent and can't cascade. If ArgoCD reverts a manual edit, the worst case is I lose a debugging session in progress. If a pod restarts, it goes back to a known good state.

**Tier 2 - PR-based (needs human, planned for later):** Things like increasing memory limits after an OOMKill, or rolling back an image after a failed deployment. The idea (from tools like Heal8s) is that an alert triggers a GitHub PR with the proposed fix, and a human reviews and merges it. None of this is deployed yet, it stays in the "it would be cool" column until I've had the cluster running stably for months and trust the alerting pipeline completely.

**Tier 3 - Manual only (never automate):** Cluster networking issues (Cilium bugs can be brutal; I burned two days on the 1.19.x ARM64 regression), data corruption (Home Assistant uses SQLite, and a bad auto-rollback could corrupt the database), security incidents (you don't auto-kill a pod that might contain useful forensic evidence), and resource quota exhaustion (adding more resources might be the wrong fix if there's a leak).

For runtime security, I chose Tetragon over Falco. The main reason: my cluster already runs Cilium 1.18.9, and Tetragon is literally Cilium's security observability layer, it shares the same eBPF programs and kernel hooks. Deploying Falco would mean a second eBPF probe, second set of kernel instrumentation, and additional resource overhead on already-constrained ARM64 nodes. Tetragon gets me process-level visibility with essentially zero added cost. But I'm keeping enforcement (kill/block actions) disabled until I've observed it for at least a week. Nothing worse than a security tool killing legitimate workloads because I misconfigured a rule.

K8sGPT runs in analysis-only mode. It has 30+ built-in analyzers that catch things Prometheus can't see: Services with no endpoints (broken selectors), Ingress with missing TLS secrets, HPA targeting missing Deployments, PVCs that can't bind. These are exactly the kind of silent failures that go unnoticed because nothing alerts on them. The auto-remediation feature is explicitly Alpha; the K8sGPT project itself warns against production use, so I'm keeping that firmly disabled. Analysis and notification is the sweet spot: tell me what's wrong, let me decide what to do about it.
