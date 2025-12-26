#!/usr/bin/env bash
# =============================================================================
# Phase 5: K3s CIS Benchmark Scanner (S5.7)
# =============================================================================
# Runs kube-bench against the K3s cluster and filters out known false
# positives caused by K3s' non-standard filesystem layout.
#
# Usage:
#   bash security/scans/scan-cis.sh           # Worker nodes (default)
#   bash security/scans/scan-cis.sh master    # Control plane
#   bash security/scans/scan-cis.sh node --raw  # Show unfiltered results
# =============================================================================
set -euo pipefail

TARGET="${1:-node}"
RAW="${2:-}"

echo "=========================================="
echo "  Phase 5: K3s CIS Benchmark (kube-bench)"
echo "  Target: $TARGET"
echo "=========================================="
echo ""

JOB_NAME="kube-bench-$(echo "$TARGET" | tr -d ' ')"
NAMESPACE="kube-system"

# Clean up previous runs
kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null

kubectl apply -f - << YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
spec:
  template:
    spec:
      hostPID: true
      containers:
      - name: kube-bench
        image: docker.io/aquasec/kube-bench:latest
        command:
        - kube-bench
        - run
        - --targets
        - "$TARGET"
        - --benchmark
        - k3s-cis-1.8
        volumeMounts:
        - name: var-lib-etcd
          mountPath: /var/lib/etcd
          readOnly: true
        - name: var-lib-kubelet
          mountPath: /var/lib/kubelet
          readOnly: true
        - name: var-lib-rancher
          mountPath: /var/lib/rancher
          readOnly: true
        - name: etc-systemd
          mountPath: /etc/systemd
          readOnly: true
        - name: etc-kubernetes
          mountPath: /etc/kubernetes
          readOnly: true
      restartPolicy: Never
      volumes:
      - name: var-lib-etcd
        hostPath:
          path: /var/lib/etcd
      - name: var-lib-kubelet
        hostPath:
          path: /var/lib/kubelet
      - name: var-lib-rancher
        hostPath:
          path: /var/lib/rancher
      - name: etc-systemd
        hostPath:
          path: /etc/systemd
      - name: etc-kubernetes
        hostPath:
          path: /etc/kubernetes
  backoffLimit: 0
YAML

echo "Waiting for job to complete (may take 5+ minutes on a Pi)..."
for _ in $(seq 1 60); do
  ST=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
  if [ "$ST" = "1" ]; then
    echo "Job finished."
    break
  fi
  sleep 10
done

# Fetch logs
LOGS=$(kubectl logs -n "$NAMESPACE" "job/$JOB_NAME" 2>/dev/null || echo "")

if [ -z "$LOGS" ]; then
    echo "No logs available. Check manually:"
    echo "  kubectl logs -n $NAMESPACE job/$JOB_NAME"
    exit 1
fi

echo ""
echo "Clean up: kubectl delete job $JOB_NAME -n $NAMESPACE"
echo ""

# =====================================================================
# Post-processing
# =====================================================================

if [ "$RAW" = "--raw" ]; then
    echo "=== RAW RESULTS (all checks) ==="
    echo "$LOGS" | grep -E '\[(PASS|FAIL|WARN)\]' || echo "(no results found)"
    exit 0
fi

# Known K3s false positives: kube-bench checks standard kubeadm paths,
# but K3s stores files under /var/lib/rancher/k3s/
#
# Reference: https://github.com/k3s-io/k3s/issues/7736
# Reference: https://docs.k3s.io/security/hardening-guide

echo "=== FILTERED RESULTS ==="
echo "(K3s false positives excluded: see comments in script)"
echo ""

declare -A JUSTIFICATION=(
    ["1.1.1"]="K3s embeds API server: no standalone apiserver.service file."
    ["1.2.1"]="K3s embeds API server: no standalone apiserver binary."
    ["4.1.1"]="K3s kubeconfig at /etc/rancher/k3s/k3s.yaml, not /etc/kubernetes/."
    ["4.1.2"]="K3s embeds kubelet: no standalone kubelet.service file."
    ["4.1.3"]="K3s has no kube-proxy: replaced by Cilium kubeProxyReplacement."
    ["4.1.4"]="K3s has no kube-proxy: replaced by Cilium kubeProxyReplacement."
    ["4.1.5"]="K3s kubelet.conf at /var/lib/rancher/k3s/agent/, not /etc/kubernetes/."
    ["4.1.6"]="K3s kubelet.conf at /var/lib/rancher/k3s/agent/, not /etc/kubernetes/."
    ["4.1.7"]="K3s CA at /var/lib/rancher/k3s/server/tls/, not /etc/kubernetes/pki/."
    ["4.1.8"]="K3s CA at /var/lib/rancher/k3s/server/tls/, not /etc/kubernetes/pki/."
    ["4.2.9"]="K3s auto-manages TLS certs: args managed internally."
)

REAL=0
FP=0

while IFS= read -r line; do
    if echo "$line" | grep -q '\[FAIL\]'; then
        # Extract check ID like "4.1.3"
        CID=$(echo "$line" | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
        if [ -n "$CID" ] && [ -n "${JUSTIFICATION[$CID]:-}" ]; then
            FP=$((FP + 1))
            echo "  ⊘ $line"
            echo "     → ${JUSTIFICATION[$CID]}"
        else
            REAL=$((REAL + 1))
            echo "  ✗ $line"
        fi
    fi
done <<< "$LOGS"

echo ""
echo "=========================================="
echo "  Summary"
echo "=========================================="
if [ $REAL -eq 0 ]; then
    echo "  ✅ All applicable CIS checks pass (real failures: 0)"
else
    echo "  ⚠️  Real failures: $REAL"
fi
echo "  ⊘  K3s false positives (ignored): $FP"
echo ""
echo "  Run with --raw to see unfiltered results"
echo "  Reference: https://github.com/k3s-io/k3s/issues/7736"
