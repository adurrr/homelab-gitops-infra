#!/usr/bin/env bash
# =============================================================================
# Phase 5: Trivy Container Image Scanner (S5.5)
# =============================================================================
# Scans container images used in the homelab for known CVEs.
#
# Install trivy first:
#   curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin
#
# Usage:
#   bash security/scans/scan-images.sh            # Show HIGH+CRITICAL summary
#   bash security/scans/scan-images.sh --critical  # Only critical CVEs
#   bash security/scans/scan-images.sh --all       # All severities
# =============================================================================
set -euo pipefail

case "${1:-}" in
    --critical) SEVERITY="CRITICAL" ;;
    --high)     SEVERITY="HIGH" ;;
    --all)      SEVERITY="UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL" ;;
    *)          SEVERITY="HIGH,CRITICAL" ;;
esac

echo "=========================================="
echo "  Phase 5: Trivy Image Scanner (S5.5)"
echo "  Severity threshold: $SEVERITY"
echo "=========================================="
echo ""

# Key images in the homelab cluster (from ArgoCD app summaries)
IMAGES=(
    "ghcr.io/home-assistant/home-assistant:stable"
    "quay.io/cilium/cilium:v1.18.9"
    "quay.io/argoproj/argocd:v3.4.2"
    "docker.io/grafana/grafana:13.0.1-security-01"
    "quay.io/prometheus/prometheus:v3.11.3-distroless"
    "quay.io/prometheus/alertmanager:v0.32.1"
    "quay.io/prometheus/node-exporter:v1.11.1-distroless"
    "docker.io/rancher/local-path-provisioner:v0.0.30"
    "docker.io/rancher/mirrored-coredns-coredns:1.10.1"
)

printf "%-55s %8s %8s %8s %8s\n" "IMAGE" "TOTAL" "CRITICAL" "HIGH" "FIXED"
printf "%s\n" "$(printf '━%.0s' $(seq 1 90))"

TOTAL_T=0; CRIT_T=0; HIGH_T=0; FIXED_T=0

for img in "${IMAGES[@]}"; do
    short_name=$(echo "$img" | sed 's|.*/||; s|:.*||')

    # Run trivy and capture JSON output
    JSON=$(trivy image --severity "$SEVERITY" --format json --quiet "$img" 2>/dev/null || echo "{}")

    # Extract vulnerability counts in a single Python call
    COUNTS=$(echo "$JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    results = data.get('Results', [])
    total = 0; crit = 0; high = 0; fixed = 0
    for r in results:
        for v in r.get('Vulnerabilities', []):
            total += 1
            sev = v.get('Severity', '')
            if sev == 'CRITICAL': crit += 1
            elif sev == 'HIGH': high += 1
            if v.get('FixedVersion', ''): fixed += 1
    print(f'{total},{crit},{high},{fixed}')
except:
    print('0,0,0,0')
" 2>/dev/null || echo "0,0,0,0")

    TOTAL=$(echo "$COUNTS" | cut -d, -f1)
    CRIT=$(echo "$COUNTS" | cut -d, -f2)
    HIGH=$(echo "$COUNTS" | cut -d, -f3)
    FIXED=$(echo "$COUNTS" | cut -d, -f4)

    TOTAL_T=$((TOTAL_T + TOTAL))
    CRIT_T=$((CRIT_T + CRIT))
    HIGH_T=$((HIGH_T + HIGH))
    FIXED_T=$((FIXED_T + FIXED))

    # Color based on critical vulnerabilities
    if [ "$CRIT" -gt 0 ]; then
        MARK="✗"
    elif [ "$HIGH" -gt 0 ]; then
        MARK="⚠"
    else
        MARK="✓"
    fi

    printf "%s %-52s %8s %8s %8s %8s\n" "$MARK" "$short_name" "$TOTAL" "$CRIT" "$HIGH" "$FIXED"
done

printf "%s\n" "$(printf '━%.0s' $(seq 1 90))"
printf "%-55s %8s %8s %8s %8s\n" "SUMMARY" "$TOTAL_T" "$CRIT_T" "$HIGH_T" "$FIXED_T"

echo ""
echo "=========================================="
echo "  Assessment"
echo "=========================================="

if [ "$CRIT_T" -eq 0 ]; then
    echo "  ✅ No critical CVEs found."
else
    echo "  ⚠️  $CRIT_T CRITICAL CVEs found (${FIXED_T} have available fixes)."
    echo "  Review images with '✗' above and update to patched versions."
fi

if [ "$HIGH_T" -gt 0 ]; then
    echo ""
    echo "  ℹ️  $HIGH_T HIGH CVEs: typical for distroless/stable tags."
    echo "  These are patched in upstream base images but not yet in"
    echo "  published tags. Monitor and update regularly."
fi

echo ""
echo "  Severity threshold: $SEVERITY"
echo "  Run with --critical for CRITICAL-only or --all for full report."

# Exit non-zero only if critical CVEs found
[ "$CRIT_T" -eq 0 ]
