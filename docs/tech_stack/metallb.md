# MetalLB: Load Balancer for Bare Metal Kubernetes

> **Official site:** [metallb.universe.tf](https://metallb.universe.tf/)
> **GitHub:** [metallb/metallb](https://github.com/metallb/metallb) · **License:** Apache 2.0
> **CNCF Status:** Sandbox

## Overview

MetalLB is a **network load balancer** for Kubernetes clusters that don't run on
a cloud provider. In cloud environments (AWS, GCP, Azure), creating a
`type: LoadBalancer` Service automatically provisions a cloud load balancer.
On bare metal, these services stay in `<pending>` forever.

MetalLB fills this gap by implementing the LoadBalancer API using standard
networking protocols (ARP/NDP or BGP).

## How It Works

### Layer 2 Mode (used in this project)

```
 External Network                    Kubernetes Cluster
 ────────────────                    ──────────────────

 Client: curl <METALLB_IP>
    │
    │   ARP Request: "Who has <METALLB_IP>?"
    ├──────────────────────────────────────────────►
    │                                                ┌─────────────────┐
    │   ARP Reply: "I do! MAC aa:bb:cc:dd"          │ Speaker (leader) │
    ◄───────────────────────────────────────────────│ on server        │
    │                                                └────────┬────────┘
    │   TCP SYN :443                                          │
    ├──────────────────────────────────────────────►          │
    │                                                ┌────────▼────────┐
    │                                                │ Traefik Service  │
    │                                                │ type: LB        │
    │                                                │ → backend pods  │
    │                                                └─────────────────┘
```

**How L2 mode works:**
1. MetalLB Speaker DaemonSet runs on every node
2. One node is elected as the **leader** for each LoadBalancer IP
3. The leader responds to ARP (IPv4) / NDP (IPv6) requests for the service IP
4. Traffic arrives at the leader node, then kube-proxy/Cilium distributes to pods
5. If the leader fails, another node takes over (automatic failover via memberlist)

### BGP Mode (not used, documented for reference)

Uses BGP peering with network routers. Each node advertises service IPs via BGP,
enabling **true load balancing** via ECMP (Equal-Cost Multi-Path).

## Architecture

```
 ┌───────────────────────────────────────────────────────────┐
 │                   MetalLB Components                       │
 │                                                            │
 │  ┌─────────────────────┐    ┌─────────────────────┐       │
 │  │     Controller       │    │   Speaker (DaemonSet)│       │
 │  │                     │    │                      │       │
 │  │ • Watches Services  │    │ • Runs on every node │       │
 │  │ • Allocates IPs     │    │ • ARP/NDP responder  │       │
 │  │ • Creates memberlist│    │ • BGP peering        │       │
 │  │   for speaker       │    │ • Leader election    │       │
 │  │   coordination      │    │                      │       │
 │  └─────────────────────┘    └─────────────────────┘       │
 │                                                            │
 │  ┌──────────────────────────────────────────────────────┐ │
 │  │                   CRDs                                │ │
 │  │  IPAddressPool   L2Advertisement   BGPAdvertisement  │ │
 │  │  (which IPs)     (how to announce) (BGP config)      │ │
 │  └──────────────────────────────────────────────────────┘ │
 └───────────────────────────────────────────────────────────┘
```

## Key Resources

### IPAddressPool

Defines the range of IPs available for LoadBalancer services:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - <METALLB_IP>-<METALLB_IP_END>   # 11 IPs
```

### L2Advertisement

Announces IPs via ARP (no BGP router needed):

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
```

### BGPAdvertisement (advanced)

For BGP mode with router peering:

```yaml
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: homelab-bgp
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
```

## Best Practices

### IP Range Selection

```
 Router DHCP Pool              MetalLB Pool
 ┌──────────────────┐         ┌──────────────┐
 │ <GATEWAY_IP>00   │         │ <METALLB_IP>│
 │       to         │  GAP    │      to       │
 │ <GATEWAY_IP>99   │ ──────► │ <METALLB_IP_END>│
 └──────────────────┘         └──────────────┘
```

- **Avoid DHCP overlap:** Choose IPs outside your router's DHCP range
- **Reserve in router:** Some routers let you reserve IPs; prevents accidental assignment
- **Size for growth:** 10-20 IPs is plenty for most homelabs

### Layer 2 vs BGP

| Aspect | Layer 2 | BGP |
|--------|---------|-----|
| Router config | None | BGP peering required |
| Load distribution | All traffic to leader node | ECMP across nodes |
| Failover time | Seconds (ARP cache) | Sub-second (BGP) |
| Node bottleneck | Yes (single node per IP) | No |
| Complexity | Low | High |
| Best for | Homelab, small clusters | Production, multi-rack |

### Health Checks

```bash
# Verify all components
kubectl get pods -n metallb-system            # All Running
kubectl get ipaddresspool -n metallb-system   # Pool exists
kubectl get l2advertisement -n metallb-system # Advertisement exists

# Check speaker logs
kubectl logs -n metallb-system -l component=speaker --tail=20

# Test with a service
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=LoadBalancer
kubectl get svc nginx  # Should show EXTERNAL-IP
curl http://<EXTERNAL-IP>
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **ARP spoofing** | Layer 2 mode is vulnerable; use BGP in untrusted networks |
| **IP exhaustion** | Set reasonable pool size; monitor IP allocation |
| **Speaker compromise** | Speaker runs as DaemonSet with host network; restrict RBAC |
| **Memberlist encryption** | Enable `secretKey` for speaker-to-speaker communication |
| **BGP authentication** | Use MD5 passwords for BGP peer authentication |

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `EXTERNAL-IP: <pending>` | No IPAddressPool configured | Create pool with valid IPs |
| `EXTERNAL-IP: <pending>` | IPAddressPool has wrong IPs | Check IPs are valid for your network |
| Speaker `Init:Error` | Node cgroup issue | Fix `/run` tmpfs size; restart node |
| Service unreachable | Speaker not running on node | Check DaemonSet; verify node conditions |
| ARP response not working | Different VLAN/subnet | L2 mode requires same L2 domain |

## Configuration in This Project

```yaml
# platform/metallb/config/ip-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - <METALLB_IP>-<METALLB_IP_END>
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
```

**Deployment:** Managed via ArgoCD (`metallb-config` app, sync wave 1).
Uses Layer 2 mode for simplicity: no BGP router configuration needed.

## Official References

- [Documentation](https://metallb.universe.tf/)
- [Installation](https://metallb.universe.tf/installation/)
- [Layer 2 Configuration](https://metallb.universe.tf/configuration/#layer-2-configuration)
- [BGP Configuration](https://metallb.universe.tf/configuration/#bgp-configuration)
- [IPAddressPool CRD](https://metallb.universe.tf/configuration/ip-address-pool/)
- [Troubleshooting](https://metallb.universe.tf/troubleshooting/)
