# Traefik: Cloud-Native Reverse Proxy & Ingress Controller

> **Official site:** [traefik.io](https://traefik.io/) · **Docs:** [doc.traefik.io](https://doc.traefik.io/traefik/)
> **GitHub:** [traefik/traefik](https://github.com/traefik/traefik) · **License:** MIT

## Overview

Traefik is a **cloud-native reverse proxy and load balancer** designed for
microservices. It acts as the **entry point** for all HTTP/HTTPS traffic into
a Kubernetes cluster, routing requests to backend services based on hostname,
path, headers, and other criteria.

In this project, Traefik v3 replaces the **built-in Traefik v1** that ships
with K3s (K3s's Traefik is disabled via `--disable traefik`).

## How It Works

```
 External Request                   Kubernetes Cluster
 ────────────────                   ──────────────────

 https://argocd.homelab.local
    │
    │  DNS → <METALLB_IP>
    ▼
 ┌──────────────────────────────────────────────────────┐
 │                    Traefik Proxy                       │
 │                                                        │
 │  ┌──────────┐    ┌──────────┐    ┌──────────────────┐ │
 │  │Entrypoint│───►│  Router  │───►│    Service       │ │
 │  │:443      │    │          │    │                  │ │
 │  │TLS term  │    │ Host:    │    │ K8s Service:     │ │
 │  │          │    │ argocd.  │    │ argocd-server:443│ │
 │  │          │    │ homelab. │    │                  │ │
 │  │          │    │ local    │    │ → Pod 10.42.x.x  │ │
 │  └──────────┘    └────┬─────┘    └──────────────────┘ │
 │                       │                                │
 │                  ┌────▼─────┐                          │
 │                  │Middleware │  (optional)              │
 │                  │ Chain     │                          │
 │                  │ • Auth    │                          │
 │                  │ • Redirect│                          │
 │                  │ • Headers │                          │
 │                  └──────────┘                          │
 └──────────────────────────────────────────────────────┘
```

## Core Concepts

### Entrypoints

Network ports that Traefik listens on:

```yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
```

### Routers

Match incoming requests to services using rules:

```yaml
# HTTP Router
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`argocd.homelab.local`)
      kind: Rule
      services:
        - name: argocd-server
          port: 443
  tls:
    secretName: argocd-tls
```

### Middlewares

Transform requests between the router and the service:

| Middleware | Purpose |
|-----------|---------|
| **BasicAuth** | Password-protect routes |
| **RedirectScheme** | HTTP → HTTPS redirect |
| **RateLimit** | Throttle requests |
| **StripPrefix** | Remove path prefix before forwarding |
| **Headers** | Add/remove custom headers |
| **ForwardAuth** | Delegate auth to external service |
| **Compress** | Enable gzip compression |
| **CircuitBreaker** | Stop forwarding to failing backends |

### Services

Backend endpoints that handle requests. In Kubernetes, these map to K8s Services
and ultimately to Pods.

## Kubernetes Integration

### Standard Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - argocd.homelab.local
      secretName: argocd-tls
  rules:
    - host: argocd.homelab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

### Traefik CRDs (preferred)

Traefik provides its own CRDs for more features:

| CRD | Purpose |
|-----|---------|
| **IngressRoute** | HTTP/TCP/UDP routing (richer than K8s Ingress) |
| **Middleware** | Reusable middleware definitions |
| **TLSOption** | TLS configuration (min version, cipher suites) |
| **TLSStore** | Default TLS certificate store |
| **ServersTransport** | Fine-grained backend connection settings |

## Best Practices

### TLS Configuration

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: modern
spec:
  minVersion: VersionTLS12
  cipherSuites:
    - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
```

### Resource Sizing (homelab)

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

### Logging

```yaml
logs:
  general:
    level: INFO       # DEBUG for troubleshooting
  access:
    enabled: true     # Log every request
```

### Metrics

```yaml
metrics:
  prometheus:
    enabled: true     # Expose Prometheus metrics on :9100
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **TLS termination** | Terminate at Traefik; use cert-manager for auto-renewal |
| **HTTP → HTTPS** | Always redirect; use RedirectScheme middleware |
| **Exposed admin port** | Disable dashboard (or restrict with BasicAuth + IP whitelist) |
| **TLS version** | Set minimum TLS 1.2; disable weak ciphers |
| **Host header injection** | Traefik validates Host headers by default |
| **Rate limiting** | Apply RateLimit middleware to public endpoints |
| **Traefik itself** | Restrict image to specific version; don't use `latest` |

## Why Replace K3s Built-in Traefik

| Aspect | K3s Traefik v1 | Traefik v3 (this project) |
|--------|---------------|--------------------------|
| Version | v1 (end of life) | v3 (actively developed) |
| CRDs | Limited | IngressRoute, Middleware, TLSOption, TLSStore |
| Middleware | Basic | 25+ built-in types |
| Configuration | Static file or CLI | Kubernetes CRDs + Helm values |
| TLS | Manual cert management | Native cert-manager integration |
| Upgrade path | Tied to K3s version | Independent Helm lifecycle |
| Observability | Basic access logs | Structured logs + Prometheus metrics |

## Configuration in This Project

```yaml
# platform/argocd/apps/traefik.yaml
spec:
  source:
    chart: traefik
    repoURL: https://traefik.github.io/charts
    targetRevision: 32.1.0
    helm:
      parameters:
        - name: "ingressClass.enabled"
          value: "true"
        - name: "ingressClass.isDefaultClass"
          value: "true"
        - name: "ports.web.expose.default"
          value: "true"
        - name: "ports.websecure.expose.default"
          value: "true"
        - name: "ports.websecure.tls.enabled"
          value: "true"
        - name: "logs.general.level"
          value: "INFO"
        - name: "logs.access.enabled"
          value: "true"
        - name: "metrics.prometheus.enabled"
          value: "true"
```

**Deployment:** Managed via ArgoCD (`traefik` app, sync wave 1).
Runs as **DaemonSet** (one pod per node) with host ports 80/443.
MetalLB assigns the LoadBalancer IP for external access.

## Official References

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Kubernetes Ingress Provider](https://doc.traefik.io/traefik/routing/providers/kubernetes-ingress/)
- [Kubernetes CRD Provider](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/)
- [Middlewares](https://doc.traefik.io/traefik/middlewares/overview/)
- [TLS](https://doc.traefik.io/traefik/https/tls/)
- [Helm Chart](https://github.com/traefik/traefik-helm-chart)
- [Migration from v1 to v2/v3](https://doc.traefik.io/traefik/migration/v1-to-v2/)
