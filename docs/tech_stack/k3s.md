# K3s: Lightweight Kubernetes

> **Official site:** [k3s.io](https://k3s.io/) · **Docs:** [docs.k3s.io](https://docs.k3s.io/)
> **GitHub:** [k3s-io/k3s](https://github.com/k3s-io/k3s) · **License:** Apache 2.0

## Overview

K3s is a **CNCF-certified Kubernetes distribution** built by Rancher (now SUSE)
for resource-constrained environments. It packages the entire Kubernetes
control plane, container runtime, networking, and storage into a **single binary
under 100 MB**.

Unlike `kubeadm` or full `kubelet`, K3s is designed for:

- Edge computing and IoT
- ARM64 devices (ARM64 SBC)
- Development and CI/CD environments
- Homelab and small production clusters

## Architecture

```
 ┌──────────────────────────────────────┐
 │            K3s Server                 │
 │                                       │
 │  ┌──────────┐  ┌──────────┐          │
 │  │ API      │  │ Scheduler│          │
 │  │ Server   │  │          │          │
 │  └──────────┘  └──────────┘          │
 │  ┌──────────┐  ┌──────────────────┐  │
 │  │Controller│  │  Embedded SQLite  │  │
 │  │ Manager  │  │  (or etcd for HA) │  │
 │  └──────────┘  └──────────────────┘  │
 │  ┌────────────────────────────────┐  │
 │  │  Tunnel Proxy (WebSocket)      │  │
 │  │  Agents connect via port 6443  │  │
 │  └────────────────────────────────┘  │
 └──────────┬───────────────────────────┘
            │ WebSocket (NAT-friendly)
 ┌──────────▼───────────────────────────┐
 │            K3s Agent                  │
 │                                       │
 │  ┌──────────┐  ┌──────────────────┐  │
 │  │ kubelet  │  │   containerd     │  │
 │  │          │  │   (bundled)      │  │
 │  └──────────┘  └──────────────────┘  │
 │  ┌────────────────────────────────┐  │
 │  │          CNI (replaceable)     │  │
 │  │          Default: Flannel      │  │
 │  └────────────────────────────────┘  │
 └──────────────────────────────────────┘
```

## Key Features

| Feature | Description |
|---------|-------------|
| **Single binary** | No external dependencies; one binary runs everything |
| **Embedded containerd** | No Docker daemon required |
| **SQLite datastore** | Default for single-server; etcd for HA >1 node |
| **Automatic TLS** | Self-signed CA, auto-renewing certs |
| **Packaged AddOns** | Flannel, CoreDNS, Traefik, ServiceLB, metrics-server |
| **ARM64 first** | Optimized for ARM64 SBC and ARM edge devices |
| **Rootless mode** | Experimental support for non-root execution |

## Bundled Components (and how to replace them)

K3s ships with pre-configured components that can be disabled:

| Component | Disable flag | Replaced by |
|-----------|-------------|-------------|
| Flannel CNI | `--flannel-backend=none` | Cilium |
| kube-proxy | `--disable-kube-proxy` | Cilium eBPF |
| Traefik v1 | `--disable traefik` | Traefik v3 (Helm) |
| ServiceLB | `--disable servicelb` | MetalLB |
| Network Policy | `--disable-network-policy` | Cilium |
| Metrics Server | `--disable metrics-server` | ArgoCD-managed |

## Best Practices

### Installation

```bash
# Always use a strong token
export K3S_TOKEN=$(openssl rand -hex 32)

# Server: disable components you'll manage via GitOps
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable metrics-server \
  --token=${K3S_TOKEN} \
  --write-kubeconfig-mode=644" sh -

# Agent: join with token
curl -sfL https://get.k3s.io | K3S_URL=https://<SERVER_IP>:6443 \
  K3S_TOKEN=${K3S_TOKEN} sh -
```

### Configuration

- **One line per flag**: Pass `INSTALL_K3S_EXEC` as a single line: newlines break systemd unit files
- **TLS SAN**: Add `--tls-san=<EXTERNAL_IP>` if accessing the API from outside the node
- **Kubeconfig permissions**: `--write-kubeconfig-mode=644` makes it readable without sudo

### Resource Management

- **Minimum**: 512 MB RAM per node
- **Recommended**: 1 GB+ for workloads
- **Storage**: 20 GB+ for images and persistent volumes
- **ARM64**: Default `/run` tmpfs is 50% of RAM; increase to 2 GB for containerd: `mount -o remount,size=2G /run`

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Default admin kubeconfig** | Restrict file permissions; use RBAC for users |
| **Token exposure** | Store K3S_TOKEN in gitignored `.env` file; rotate regularly |
| **Embedded SQLite** | Not encrypted at rest; use etcd with TLS for HA |
| **Default Traefik** | Disable and replace with own version for TLS control |
| **API server exposure** | Bind to internal IP; use firewall rules |
| **Container runtime** | Keep containerd updated; enable seccomp/AppArmor profiles |
| **Root access** | K3s components run as root; consider rootless mode for untrusted workloads |

## Use Cases

| Use Case | Why K3s |
|----------|---------|
| **Homelab** | Minimal resources, single binary, easy setup |
| **Edge/IoT** | Runs on ARM, low memory footprint |
| **CI/CD** | Quick cluster creation/destruction |
| **Development** | Local K8s without Docker Desktop |
| **Small production** | Up to ~500 nodes, HA with embedded etcd |

## Comparison: K3s vs kubeadm

| Aspect | kubeadm | K3s |
|--------|---------|-----|
| Installation | Multi-step, per-component | One command |
| Binary size | ~500 MB+ (multiple) | ~100 MB (single) |
| External deps | etcd, container runtime | None (bundled) |
| ARM64 | Manual setup | First-class |
| Upgrades | Manual per component | One binary replace |
| Default CNI | None (choose) | Flannel (replaceable) |

## Configuration in This Project

```yaml
# infra/k3s/server-install.sh
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable metrics-server \
  --token=${K3S_TOKEN} \
  --tls-san=${SERVER_IP} \
  --write-kubeconfig-mode=644" sh -
```

**Why these flags:**
- All disabled components are managed via ArgoCD (Phase 2) or replaced by Cilium (Phase 1)
- `--tls-san` enables API access from admin machine using the node IP
- `--write-kubeconfig-mode` avoids sudo for kubectl

## Official References

- [Architecture](https://docs.k3s.io/architecture)
- [Installation](https://docs.k3s.io/quick-start)
- [Configuration](https://docs.k3s.io/installation/configuration)
- [Packaged Components](https://docs.k3s.io/installation/packaged-components)
- [Networking Options](https://docs.k3s.io/networking/basic-network-options)
- [Security Hardening](https://docs.k3s.io/security/hardening-guide)
- [Advanced Options](https://docs.k3s.io/advanced)
