# Cilium: eBPF-Based Networking, Observability & Security

> **Official site:** [cilium.io](https://cilium.io/) · **Docs:** [docs.cilium.io](https://docs.cilium.io/)
> **GitHub:** [cilium/cilium](https://github.com/cilium/cilium) · **License:** Apache 2.0
> **CNCF Status:** Graduated

## Overview

Cilium is an open-source **CNI (Container Network Interface) plugin** that uses
**eBPF (extended Berkeley Packet Filter)** to provide networking, security, and
observability for Kubernetes. Instead of iptables rules, Cilium programs the
Linux kernel directly for orders-of-magnitude better performance.

## How eBPF Works

```
 Traditional (iptables)              Cilium (eBPF)
 ────────────────────────             ──────────────

 App → Socket → Netfilter             App → Socket (intercepted!)
              │                                │
              ├─ PREROUTING                   eBPF program at
              ├─ INPUT                        connect() syscall
              ├─ FORWARD                      │
              ├─ OUTPUT                       ├─ O(1) BPF map lookup
              └─ POSTROUTING                  │  (hash table)
                                              ├─ Direct backend IP
    Every packet traverses                    └─ No DNAT needed
    O(n) iptables chains

    eBPF programs run in the kernel at specific hook points:
    ┌─────────────────────────────────────────────┐
    │  XDP           (driver level, 10G+)         │
    │  TC Ingress    (before netfilter)           │
    │  Socket        (connect/accept syscalls)     │
    │  TC Egress     (after netfilter)            │
    └─────────────────────────────────────────────┘
```

**Key idea:** eBPF allows inserting sandboxed programs into the Linux kernel at
runtime without changing kernel source or loading modules. Cilium uses eBPF at
multiple hook points for different functions.

## Cilium Architecture

```
 ┌────────────────────────────────────────────────────────────┐
 │                     Cilium DaemonSet                        │
 │                                                            │
 │  ┌──────────────────────────────────────────────────────┐ │
 │  │                  cilium-agent                         │ │
 │  │                                                       │ │
 │  │  ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌─────────┐ │ │
 │  │  │Service  │  │Network  │  │Bandwidth │  │Encrypt  │ │ │
 │  │  │Load     │  │Policy   │  │Manager   │  │(IPSec/  │ │ │
 │  │  │Balancing│  │Enforce. │  │          │  │WireGuard│ │ │
 │  │  └─────────┘  └─────────┘  └──────────┘  └─────────┘ │ │
 │  │                                                       │ │
 │  │              Programs eBPF Maps                       │ │
 │  │  ┌────────────────────────────────────────────────┐  │ │
 │  │  │ Service Map   │ Endpoint Map │ Policy Map      │  │ │
 │  │  │ ClusterIP→    │ Pod IP→      │ Identity→       │  │ │
 │  │  │ Backend list  │ Network info │ Allowed peers   │  │ │
 │  │  └────────────────────────────────────────────────┘  │ │
 │  └──────────────────────────────────────────────────────┘ │
 │                                                            │
 │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
 │  │ Hubble Relay │  │ Hubble UI    │  │ Cluster Mesh │    │
 │  │ Flow aggreg. │  │ Web console  │  │ Multi-cluster│    │
 │  └──────────────┘  └──────────────┘  └──────────────┘    │
 └────────────────────────────────────────────────────────────┘
```

## Key Features

### 1. kube-proxy Replacement

| Feature | iptables (kube-proxy) | Cilium eBPF |
|---------|----------------------|-------------|
| Service lookup | O(n) sequential rules | O(1) hash map |
| Load balancing | Per-packet DNAT | Socket-level at `connect()` |
| Rule updates | Flush and rewrite all chains | Atomic BPF map update |
| Connection tracking | conntrack table per connection | Not needed for intra-cluster |
| Observability | None built-in | Hubble L3/L4/L7 flows |

**Socket-level load balancing:** Cilium intercepts the `connect()` syscall before
packets exist. It translates the ClusterIP to a backend pod IP directly at the
socket layer, eliminating DNAT and conntrack entries entirely.

### 2. Network Policy (L3-L7)

Cilium policies go beyond traditional CIDR/port rules:

- **Identity-based:** Pods with matching labels share a security identity
- **DNS-aware:** Allow/deny traffic to FQDNs (`*.github.com`)
- **L7-aware:** HTTP method, path, headers; gRPC method; Kafka topic
- **ICMP/ICMPv6:** Control ping and traceroute independently

### 3. Hubble Observability

Hubble is Cilium's built-in observability platform:

- **Service dependency graph:** Which services talk to which?
- **Flow logs:** Every L3/L4/L7 connection with metadata
- **DNS visibility:** Which domains does each pod resolve?
- **Policy verdict:** Which connections were allowed/denied?
- **Latency metrics:** HTTP/gRPC response time percentiles

### 4. Transparent Encryption

- **WireGuard:** Simple, fast, kernel-level encryption
- **IPSec:** Standards-based, hardware offload support
- Both work transparently: no application changes needed

## Best Practices

### Installation on K3s

```bash
# 1. Disable K3s defaults (must happen during K3s install)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy" sh -

# 2. Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-arm64.tar.gz
sudo tar xzvfC cilium-linux-arm64.tar.gz /usr/local/bin

# 3. Install Cilium with K3s-compatible settings
cilium install --version 1.19.3 \
  --set kubeProxyReplacement=true \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16" \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set operator.replicas=1
```

### Resource Sizing

| Cluster Size | cilium-agent CPU | cilium-agent Memory |
|-------------|-----------------|---------------------|
| Small (1-10 nodes) | 60m request | 250Mi |
| Medium (10-50) | 250m request | 500Mi |
| Large (50+) | 500m+ | 1Gi+ |

### Verification

```bash
# Check status
cilium status

# Full connectivity test (creates test pods)
cilium connectivity test

# Check Hubble
cilium hubble status
cilium hubble observe --follow
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **eBPF program loading** | Requires `CAP_SYS_ADMIN`; restrict to cilium-agent |
| **Network policy bypass** | Always deploy default-deny policy; then add allows |
| **Hubble data exposure** | Enable TLS for Hubble; restrict UI access |
| **Encryption overhead** | WireGuard: ~10% throughput loss; acceptable for homelab |
| **Kernel compatibility** | Requires Linux 5.10+; verify on ARM64 |
| **Container breakout** | eBPF programs are sandboxed by the kernel verifier |

## Configuration in This Project

```yaml
# infra/cilium/values.yaml
kubeProxyReplacement: true
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
ipam:
  operator:
    clusterPoolIPv4PodCIDRList: "10.42.0.0/16"  # K3s default
operator:
  replicas: 1  # Single replica for homelab
tunnelProtocol: vxlan
```

**Why these settings:**
- `kubeProxyReplacement: true`: Full kube-proxy replacement with eBPF
- `clusterPoolIPv4PodCIDRList: 10.42.0.0/16`: Must match K3s default pod CIDR
- `operator.replicas: 1`: Sufficient for 2-node homelab
- `tunnelProtocol: vxlan`: Simpler than geneve for homelab networking
- Hubble enabled for flow visibility

## Use Cases

| Use Case | Why Cilium |
|----------|-----------|
| **Homelab** | Replace iptables for better performance; built-in observability |
| **Multi-tenant** | Identity-based policies isolate tenants |
| **Compliance** | L7 policies enforce API-level access control |
| **Edge/MEC** | Low overhead; runs on ARM64 |
| **Service Mesh** | Built-in (no sidecar); simpler than Istio |

## Comparison: Cilium vs Flannel vs Calico

| Feature | Flannel | Calico | Cilium |
|---------|---------|--------|--------|
| Data plane | VXLAN overlay | iptables/eBPF | eBPF |
| kube-proxy replacement | No | Yes (eBPF mode) | Yes (default) |
| Network policy | None | L3/L4 | L3-L7 |
| Observability | None | None (or Calico Cloud) | Hubble built-in |
| Encryption | None | WireGuard | WireGuard + IPSec |
| Performance | Moderate | Good | Excellent (O(1)) |
| Complexity | Low | Medium | Medium-High |

## Official References

- [Introduction to Cilium](https://docs.cilium.io/en/stable/overview/intro/)
- [eBPF Datapath](https://docs.cilium.io/en/stable/network/ebpf/)
- [kube-proxy Replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Network Policy](https://docs.cilium.io/en/stable/security/policy/)
- [Hubble](https://docs.cilium.io/en/stable/observability/)
- [Installation on K3s](https://docs.cilium.io/en/stable/gettingstarted/k3s/)
- [Helm Values Reference](https://github.com/cilium/cilium/tree/main/install/kubernetes/cilium)
