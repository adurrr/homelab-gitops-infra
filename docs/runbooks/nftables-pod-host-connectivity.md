# Runbook: Control-plane Pod-to-Host Connectivity Lost (nftables)

> **Status:** ✅ Resolved
> **Date:** 2026-01-02
> **Affected node:** server (ARM64 RPi 4B, control plane, K3s API server)
> **Symptom:** Pods on server cannot reach `10.43.0.1:443` (kubernetes ClusterIP) or any local host service. `tcpdump` on all host interfaces sees zero packets. Cilium BPF trace shows `-> stack` with `ifindex 0` (packet handed to kernel), then nothing.

---

## 1. Problem Statement

After applying changes to Cilium (attempted migration to `routingMode: native` with `enableK8sHostFirewallBypass: true` for better performance), then reverting to `routingMode: tunnel`, the following symptoms persisted on server:

- Pod → `10.43.0.1:443` (kubernetes service) → timeout
- Pod → `192.168.1.10:6443` (API server direct) → timeout
- Pod → `8.8.8.8` (external) → timeout
- Pod → other pods on server (e.g. `10.42.0.20`) → timeout
- Pod → `10.42.0.254` (cilium_host) → **WORKS** (0.3ms)
- Pod → `192.168.1.10` (eth0) → **WORKS** (0.2ms)

The asymmetry was the clue: only traffic that didn't need IP forwarding worked. The split between L2-reachable and L3-routed destinations pointed at the kernel, not Cilium.

---

## 2. Investigation Timeline

### Step 1: Verify cilium is healthy
```bash
kubectl exec -n kube-system <cilium-pod-on-server> -- cilium-dbg status --brief
# Result: Cilium: Ok, 71/71 controllers healthy, BPF Maps populated
# cilium bpf lb list shows 10.43.0.1:443/TCP (1) → 192.168.1.10:6443/TCP (17) (1) ✓
```

Cilium agent is functional and the LB map has the right entry. Not a Cilium config issue.

### Step 2: Trace the packet through cilium datapath
```bash
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg monitor --type trace
# Run wget from a test pod → 10.43.0.1:443
# Result: -> stack flow ..., identity pod->host state new ifindex 0
#          orig-ip 0.0.0.0: 10.42.0.11:port -> 192.168.1.10:6443 tcp SYN
```

Cilium BPF processed the packet, did the ClusterIP→nodeIP translation, and emitted it to the kernel stack with `CTX_ACT_OK`. No drop in BPF, no policy deny.

### Step 3: tcpdump on all host interfaces
```bash
# In a privileged pod with hostNetwork
tcpdump -i any -nn 'host 10.42.0.11 and port 6443'
# Result: 18 packets received by filter, 0 packets captured
# tcpdump -i cilium_host: 0 packets
# tcpdump -i eth0: 0 packets
# tcpdump -i lo: 0 packets
```

The kernel's packet filter matched packets, but nothing reached any interface or the local stack. The packets were being dropped between BPF and the wire.

### Step 4: Check kernel-level drop points
```bash
# rp_filter, iptables, cilium policy verdicts
cat /proc/sys/net/ipv4/conf/eth0/rp_filter
# Result: 2 (strict mode) ← suspect, but setting to 0 didn't fix it

iptables -t nat -L POSTROUTING
# Result: CILIUM_POST_nat chain present with MASQUERADE rule
# iptables -t filter -L CILIUM_INPUT → ACCEPT for proxy traffic only
# iptables -t filter -L KUBE-FIREWALL → DROP for !127.0.0.0/8 → 127.0.0.0/8 (not matching)
```

rp_filter and cilium chains looked OK. The real answer was elsewhere.

### Step 5: dmesg reveals the dropper
```bash
dmesg | tail -50
```

Output:
```
nftables-dropped: IN=lxc<test-pod> OUT= MAC=... SRC=10.42.0.11 DST=192.168.1.10
  LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=29070 DF PROTO=TCP SPT=48702 DPT=6443
  WINDOW=64860 RES=0x00 SYN URGP=0 MARK=0x8e6c0f00
```

**The smoking gun.** The host's nftables firewall was logging drops of the exact packets we were sending.

### Step 6: Read the nftables config
```bash
cat /etc/nftables.conf
```

```nft
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # Allow traffic from trusted management network
        ip saddr 192.168.1.0/24 accept    # ← only the LAN, not pod CIDR

        tcp dport <SSH_PORT> accept
        # ... NFS ports from LAN only ...

        limit rate 5/minute burst 5 packets log prefix "nftables-dropped: " level info
        drop
    }
    # ... forward/output chains ...
}
```

**Root cause found:** The host firewall only allows source IPs in `192.168.1.0/24` (the management LAN). Pod CIDR `10.42.0.0/16` is not in the allow list, so every pod-to-host connection was being dropped at the nftables layer.

---

## 3. The Fix

Add a rule to the nftables config to allow the K3s pod CIDR (cilium):

```bash
# 1. Add the rule to the config file (right after the management-LAN allow rule)
#    Replace <MANAGEMENT_LAN> with your actual LAN subnet (e.g. 192.168.1.0/24)
sudo sed -i '/ip saddr <MANAGEMENT_LAN> accept/a\
\
        # Allow K3s pod CIDR (cilium) - required for pod-to-host connectivity\
        ip saddr 10.42.0.0/16 accept' /etc/nftables.conf

# 2. Verify the change
grep -n "10.42" /etc/nftables.conf

# 3. Reload nftables
sudo systemctl reload nftables

# 4. Verify the rule is active
sudo nft list chain inet filter input | grep "10.42"
```

### Verification

Before fix:
```
$ kubectl exec server-test-pod -- wget --timeout=5 https://10.43.0.1:443/version
wget: download timed out
```

After fix:
```
$ kubectl exec server-test-pod -- wget --no-check-certificate --timeout=5 https://10.43.0.1:443/version
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "Unauthorized",
  ...
}
```

The K3s API server is now reachable from pods on server. The 401 Unauthorized is the expected response for an unauthenticated request.

---

## 4. What Didn't Work (Lessons Learned)

| Approach | Result | Why it didn't work |
|----------|--------|-------------------|
| Set `rp_filter=0` on eth0 | No effect | The drop was in nftables, not in rp_filter |
| Build `ip_tables.ko` from source | Failed | Source tree was 6.18.0; running kernel 6.18.29. Cross-version modpost fails on missing xt_* symbols. Would need `--force-vermagic` to load. |
| Revert Cilium to `routingMode: tunnel` | Partial | The nftables was dropping traffic regardless of Cilium mode. The "broken" native mode and the "fixed" tunnel mode both had the same host-firewall problem. |
| Cordoning server | Workaround | Stops new pod scheduling but doesn't fix the root cause. The control plane still needs pod-to-host traffic for system components. |
| Force-restart DaemonSets | Partial | New pods came up healthy initially, but crashed again when they tried to reach local services. |

### Why cilium `ifindex 0` in the trace was misleading

The `-> stack` event with `ifindex 0` (also called `TRACE_IFINDEX_UNKNOWN`) in cilium monitor looks like the packet should be processed by the kernel. But it doesn't tell you what happens after the kernel receives it. The packet enters the stack, runs through PREROUTING, makes a routing decision (local delivery), and then hits the INPUT chain — where nftables drops it. Cilium's view ends at the BPF return; the rest is the kernel's responsibility.

---

## 5. Files Modified This Session

| File | Change | Reason |
|------|--------|--------|
| `/etc/nftables.conf` (on server) | Added `ip saddr 10.42.0.0/16 accept` rule | Root cause fix for pod-to-host connectivity |
| `infra/cilium/values.yaml` | No change (was already correct) | Cilium config was always fine; the issue was the host firewall |
| No Git-tracked files changed | — | The fix is on the host, not in the GitOps repo |

The local `infra/cilium/values.yaml` (gitignored) matches the desired state. The Git-tracked `infra/cilium/values.example.yaml` is the template.

---

## 6. Open Issues After This Session

### 6a. loki-canary crashlooping (separate from nftables)
- 14+ restarts since session start
- Connects to loki successfully (10.42.1.20:3100 via vxlan), then gets `error reading websocket, will retry in 10 seconds: read tcp ...: use of closed network connection`
- Likely a loki-canary ↔ loki protocol/version mismatch, not a network issue
- **Not caused by the nftables issue.** Needs separate investigation.

### 6b. prometheus-node-exporter restarting
- 17+ restarts since session start
- Logs show it IS up: `Listening on [::]:9100, TLS is disabled`
- Likely a liveness/readiness probe failure (Prometheus scraping issue), not the exporter itself
- **Not caused by the nftables issue.** Needs separate investigation.

### 6c. K8sGPT blocked on AI quota
- OpenCodeGo backend hit monthly limit (HTTP 429)
- 3 stale results from earlier session won't be re-analyzed until quota resets (7 days) or backend is switched
- Existing 3 results:
  - `monitoringlokicanarypmmx7` (loki-canary CrashLoopBackOff)
  - `monitoringprometheusgrafana7598f94dc9btfgf` (prometheus-grafana Pending)
  - `monitoringprometheusprometheusnodeexporter57c8s` (prometheus-node-exporter Error)

### 6d. nftables config has 5 duplicate `ip saddr 10.42.0.0/16 accept` rules
- The `sed` command matched 5 occurrences of `192.168.1.0/24 accept` in the config (the original rule + 4 in the ANSIBLE MANAGED NFS block)
- Functionally harmless but ugly. Clean up later with a single `nft delete rule` loop or rewrite the config file properly.

### 6e. Control-plane cordoned
- `kubectl cordon server` was applied to stop new pod scheduling
- Consistent with original AD-001 (server is control-plane only)
- Can be uncordoned once the connectivity is verified stable for 24h+

---

## 7. Architectural Insight

**The host nftables firewall is the source of truth for pod-to-host ingress, not the cilium NetworkPolicy.**

- Cilium NetworkPolicy (Kubernetes NetworkPolicy CRDs translated to cilium BPF) controls **pod-to-pod** traffic
- The host nftables firewall controls **host ingress** (anything reaching a host-network socket)
- These are two completely separate enforcement layers
- Cilium's `enableK8sHostFirewallBypass: true` only bypasses cilium's own host firewall BPF — it does NOT touch the kernel's nftables

This means any time you add a new pod CIDR (e.g., change `cluster-pool-ipv4-cidr` in cilium config), you must also update the host nftables to allow the new CIDR.

**Recommendation for the Ansible bootstrap:** add a task that includes the cilium pod CIDR in `/etc/nftables.conf` as part of the homelab base config.

---

## 8. How to Verify Connectivity From Now On

Quick health check (paste on server SSH or run from any node):

```bash
# Pick a node and run a test pod on it
kubectl run server-test --image=alpine:latest --rm -i --restart=Never --overrides='{"spec":{"nodeName":"server","containers":[{"name":"c","image":"alpine:latest","command":["sh","-c","apk add --no-cache curl; curl -k --max-time 5 https://10.43.0.1:443/version || echo FAILED; sleep 30"]}]}}'

# Expected: JSON response with "Unauthorized" (not a timeout, not "FAILED")
```

If this times out, check:
1. `sudo nft list chain inet filter input | grep "10.42"` — rule must be present
2. `dmesg | grep nftables-dropped | tail -5` — should be empty for pod traffic
3. `kubectl exec -n kube-system <cilium-pod> -- cilium-dbg status` — should be Ok
4. `kubectl exec -n kube-system <cilium-pod> -- cilium-dbg bpf lb list | grep 10.43.0.1` — entry should be present

If all four are good but connectivity still fails, the issue is elsewhere.
