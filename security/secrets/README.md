# Secrets Management

This directory contains templates and documentation for secrets management.
**Never commit raw Kubernetes Secret manifests to this repository.**

## Strategy

We use [SealedSecrets](https://github.com/bitnami-labs/sealed-secrets) (Phase 5) to encrypt
secrets before committing them to Git. The workflow is:

1. Create a local Kubernetes Secret manifest (gitignored)
2. Seal it with `kubeseal` to produce a SealedSecret manifest
3. Commit only the SealedSecret manifest (safe for public repos)

## Quick Start

```bash
# Install kubeseal CLI
go install github.com/bitnami-labs/sealed-secrets/cmd/kubeseal@latest

# Create a secret locally (never commit this!)
kubectl create secret generic my-secret \
  --from-literal=password=CHANGE_ME \
  --namespace my-namespace \
  --dry-run=client -o yaml > my-secret.yaml

# Seal it (safe to commit)
kubeseal --format yaml < my-secret.yaml > sealed-my-secret.yaml

# Clean up the raw secret
rm my-secret.yaml
```

## Files in this Directory

- `*.example`: Template files showing the structure (committed)
- `*.yaml`: SealedSecret manifests (committed, encrypted)
- Raw secret files are gitignored globally
