# cert-manager: TLS Certificate Automation for Kubernetes

> **Official site:** [cert-manager.io](https://cert-manager.io/) · **Docs:** [cert-manager.io/docs](https://cert-manager.io/docs/)
> **GitHub:** [cert-manager/cert-manager](https://github.com/cert-manager/cert-manager) · **License:** Apache 2.0
> **CNCF Status:** Graduated

## Overview

cert-manager automates the management and issuance of **TLS certificates**
within Kubernetes. It requests certificates from various issuers, stores them
as Kubernetes Secrets, and automatically renews them before expiry.

## How It Works

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                      cert-manager                                │
 │                                                                  │
 │  1. User creates Certificate CRD                                 │
 │  ┌─────────────────────────┐                                    │
 │  │ apiVersion: cert-manager│                                    │
 │  │ kind: Certificate       │                                    │
 │  │ spec:                   │                                    │
 │  │   dnsNames:             │                                    │
 │  │   - argocd.homelab.local│                                    │
 │  │   secretName: argocd-tls│     5. Secret stored in cluster    │
 │  │   issuerRef:            │     ┌──────────────────────┐      │
 │  │     name: selfsigned    │     │ Secret/argocd-tls    │      │
 │  └──────────┬──────────────┘     │   tls.crt: <PEM>     │      │
 │             │                    │   tls.key: <PEM>     │      │
 │             ▼                    └──────────▲───────────┘      │
 │  2. Order CRD created                        │                  │
 │  ┌─────────────────────────┐                │                  │
 │  │ Order (internal)        │                │                  │
 │  └──────────┬──────────────┘                │                  │
 │             │                                │                  │
 │             ▼                                │                  │
 │  3. Challenge solved                         │                  │
 │  ┌─────────────────────────┐    ┌────────────┴───────────┐    │
 │  │ Challenge (internal)    │    │ HTTP01: creates temp    │    │
 │  │ type: HTTP01 or DNS01   │    │ Ingress for validation  │    │
 │  │ status: Ready           │    │ DNS01: creates TXT rec  │    │
 │  └──────────┬──────────────┘    └────────────────────────┘    │
 │             │                                                   │
 │             ▼                                                   │
 │  4. Certificate issued                                          │
 │  ┌─────────────────────────┐                                   │
 │  │ CertificateRequest      │                                   │
 │  │ status: Ready            │                                   │
 │  └─────────────────────────┘                                   │
 └─────────────────────────────────────────────────────────────────┘
```

## Core Resources

### Issuer (namespace-scoped)

Creates certificates within a single namespace:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ca-issuer
  namespace: my-app
spec:
  ca:
    secretName: ca-key-pair
```

### ClusterIssuer (cluster-wide)

Available to all namespaces:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: admin@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
```

### Certificate

Defines what certificate to request:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-tls
  namespace: argocd
spec:
  secretName: argocd-tls
  dnsNames:
    - argocd.homelab.local
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
```

## Issuer Types

### SelfSigned

For internal homelab PKI: no external validation:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

### CA (from SelfSigned root)

Build a private CA chain:

```yaml
# Step 1: Create a self-signed root CA
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-root-ca
spec:
  isCA: true
  commonName: homelab-ca
  secretName: root-ca-secret
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
---
# Step 2: Create a CA issuer from the root
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: homelab-ca
spec:
  ca:
    secretName: root-ca-secret
---
# Step 3: Issue certs signed by the root CA
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-tls
spec:
  secretName: argocd-tls
  issuerRef:
    name: homelab-ca
    kind: ClusterIssuer
```

### ACME (Let's Encrypt)

For public-facing services with real domain names:

```yaml
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    # For testing: https://acme-staging-v02.api.letsencrypt.org/directory
```

**Challenge types:**

| Type | How it works | Requirements |
|------|-------------|--------------|
| **HTTP01** | Creates temp Ingress, Let's Encrypt fetches token | Port 80 open, valid DNS |
| **DNS01** | Creates TXT record via DNS provider API | API credentials for DNS provider |

## Architecture

```
 ┌───────────────────────────────────────────────────────────────┐
 │                  cert-manager Components                       │
 │                                                                │
 │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
 │  │  Controller  │  │    Webhook   │  │  CA Injector │        │
 │  │              │  │              │  │              │        │
 │  │ • Watches    │  │ • Validates  │  │ • Injects CA │        │
 │  │   Certificate│  │   CRDs       │  │   bundles    │        │
 │  │   CRDs       │  │ • Mutation   │  │   into       │        │
 │  │ • Creates    │  │   webhooks   │  │   webhooks   │        │
 │  │   Orders &   │  │ • TLS cert   │  │   and CRDs   │        │
 │  │   Challenges │  │   for API    │  │              │        │
 │  │ • Manages    │  │              │  │              │        │
 │  │   lifecycle  │  │              │  │              │        │
 │  └──────────────┘  └──────────────┘  └──────────────┘        │
 └───────────────────────────────────────────────────────────────┘
```

## Best Practices

### Certificate Lifecycle

- **Renewal:** cert-manager automatically renews 30 days before expiry
- **Duration:** Default 90 days; set `duration: 2160h` for longer validity
- **Monitoring:** Set up alerts for certificates nearing expiry
- **Backup:** Secret resources are backed up with etcd snapshots

### Issuer Selection

| Environment | Issuer Type | Why |
|-------------|------------|-----|
| **Local dev** | SelfSigned | Fast, no external dependencies |
| **Homelab** | CA from SelfSigned root | Internal PKI; trust the CA on devices |
| **Homelab public** | ACME staging | Test Let's Encrypt without rate limits |
| **Production** | ACME production | Publicly trusted certificates |

### Resource Configuration

```yaml
# Production-grade setup
spec:
  secretName: my-tls
  duration: 2160h          # 90 days
  renewBefore: 360h        # Renew 15 days before expiry
  dnsNames:
    - example.com
    - '*.example.com'      # Wildcard cert (requires DNS01)
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA       # Smaller, faster than RSA
    size: 256
    rotationPolicy: Always # Rotate key on renewal
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Private key storage** | Stored as K8s Secret; encrypt etcd at rest |
| **ACME account key** | Store securely; rotate if compromised |
| **DNS01 credentials** | Use dedicated API tokens with minimum scope |
| **SelfSigned trust** | Don't use for public services; add CA to client trust stores |
| **Certificate expiry** | Monitor with Prometheus + Grafana alerts |
| **Webhook TLS** | cert-manager bootstraps its own webhook cert; wait 60s after install |

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `Certificate` stuck in `Pending` | Issuer not Ready | Check `kubectl describe issuer` |
| `Challenge` stuck in `Pending` | HTTP01: port 80 not reachable | Ensure ingress works |
| `Challenge` stuck in `Pending` | DNS01: wrong API credentials | Verify DNS provider token |
| Webhook pod `CrashLoopBackOff` | Bootstrap cert not generated | Wait 60s; reinstall if persistent |
| `Order` failed | Rate limit hit (Let's Encrypt) | Use staging for testing |
| `secret not found` in Ingress | Certificate not issued yet | Create the Certificate CRD first |

## Configuration in This Project

```yaml
# platform/argocd/apps/cert-manager.yaml
spec:
  source:
    chart: cert-manager
    repoURL: https://charts.jetstack.io
    targetRevision: v1.15.3
    helm:
      parameters:
        - name: "installCRDs"
          value: "true"
        - name: "prometheus.enabled"
          value: "true"
```

**Deployment:** Managed via ArgoCD (`cert-manager` app, sync wave 1).
CRDs installed automatically via `installCRDs: true`.

**Current state:** cert-manager CRDs are installed and ready. A ClusterIssuer
(for self-signed or Let's Encrypt) will be configured when TLS certificates
are needed for specific services (Phase 4+).

## Official References

- [Documentation](https://cert-manager.io/docs/)
- [Installation](https://cert-manager.io/docs/installation/)
- [Issuer Configuration](https://cert-manager.io/docs/configuration/)
- [Certificate Resources](https://cert-manager.io/docs/usage/certificate/)
- [ACME / Let's Encrypt](https://cert-manager.io/docs/configuration/acme/)
- [SelfSigned Issuer](https://cert-manager.io/docs/configuration/selfsigned/)
- [CA Issuer](https://cert-manager.io/docs/configuration/ca/)
- [Troubleshooting](https://cert-manager.io/docs/troubleshooting/)
- [Helm Chart](https://artifacthub.io/packages/helm/cert-manager/cert-manager)
