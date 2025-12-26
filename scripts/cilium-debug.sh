#!/bin/bash
# =============================================================================
# Cilium Startup Debug: captures EXACT moment networking dies
# =============================================================================
# Run this on the PHYSICAL CONSOLE of server, BEFORE restarting K3s.
# It captures: pod logs, BPF attach events, network state, conntrack.
# All output saved to /home/user/cilium-debug.log (survives reboot).
#
# Usage:
#   1. sudo systemctl restart k3s    (starts K3s)
#   2. This script auto-detects Cilium pod startup and captures it
# =============================================================================

LOG="/home/user/cilium-debug-$(date +%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "=== Cilium Startup Debug started at $(date) ==="
echo "Kernel: $(uname -r)"
echo "Cilium version expected: 1.19.3"
echo ""

# --- Monitor Cilium pod lifecycle ---
monitor_cilium_pod() {
    local prev_phase=""
    local prev_init=""
    local prev_agent=""

    while true; do
        # Get Cilium pod info via crictl (works even if API server is down)
        CIL_POD=$(sudo crictl pods --name cilium -q 2>/dev/null | head -1)

        if [ -n "$CIL_POD" ]; then
            # Pod state
            POD_STATE=$(sudo crictl inspectp "$CIL_POD" 2>/dev/null | jq -r '.status.state // "UNKNOWN"')

            # Container statuses
            INIT_STATE=$(sudo crictl ps -a --pod "$CIL_POD" --name config -q 2>/dev/null | head -1)
            AGENT_STATE=$(sudo crictl ps -a --pod "$CIL_POD" --name cilium-agent -q 2>/dev/null | head -1)

            if [ "$POD_STATE" != "$prev_phase" ]; then
                echo "[$(date +%H:%M:%S)] CILIUM POD PHASE: $POD_STATE"
                prev_phase="$POD_STATE"
            fi

            if [ -n "$INIT_STATE" ] && [ "$INIT_STATE" != "$prev_init" ]; then
                INIT_STATUS=$(sudo crictl inspect "$INIT_STATE" 2>/dev/null | jq -r '.status.state // "unknown"')
                echo "[$(date +%H:%M:%S)] CILIUM INIT CONTAINER: $INIT_STATUS"
                prev_init="$INIT_STATE"
            fi

            if [ -n "$AGENT_STATE" ] && [ "$AGENT_STATE" != "$prev_agent" ]; then
                AGENT_STATUS=$(sudo crictl inspect "$AGENT_STATE" 2>/dev/null | jq -r '.status.state // "unknown"')
                echo "[$(date +%H:%M:%S)] CILIUM AGENT CONTAINER: $AGENT_STATUS"
                prev_agent="$AGENT_STATE"

                # When agent starts, capture its logs
                if [ "$AGENT_STATUS" = "CONTAINER_RUNNING" ]; then
                    echo "[$(date +%H:%M:%S)] CAPTURING CILIUM AGENT LOGS..."
                    timeout 30 sudo crictl logs --tail=200 "$AGENT_STATE" 2>/dev/null >> "$LOG"
                fi
            fi
        else
            # No Cilium pod yet
            if [ "$prev_phase" != "NOT_FOUND" ]; then
                prev_phase="NOT_FOUND"
            fi
        fi

        sleep 0.5
    done
}

# --- Monitor BPF attachment points ---
monitor_bpf() {
    local prev_tc_i=0 prev_tc_e=0 prev_sock=0

    while true; do
        # TC filters on all interfaces
        TC_I_COUNT=0
        TC_E_COUNT=0
        for iface in eth0 $(ip -br link 2>/dev/null | awk '/cilium|lxc/{print $1}'); do
            TC_I_COUNT=$((TC_I_COUNT + $(tc filter show dev "$iface" ingress 2>/dev/null | grep -c bpf)))
            TC_E_COUNT=$((TC_E_COUNT + $(tc filter show dev "$iface" egress 2>/dev/null | grep -c bpf)))
        done

        # Socket LB programs in cgroup
        SOCK_COUNT=$(ls /sys/fs/bpf/cilium/socketlb/links/cgroup/ 2>/dev/null | wc -l)

        # Stale BPF links
        LINKS_COUNT=$(ls /sys/fs/bpf/cilium/tc/globals/ 2>/dev/null | wc -l)

        if [ "$TC_I_COUNT" != "$prev_tc_i" ]; then
            echo "[$(date +%H:%M:%S)] TC INGRESS BPF: ${prev_tc_i} → ${TC_I_COUNT} programs"
            prev_tc_i="$TC_I_COUNT"
        fi
        if [ "$TC_E_COUNT" != "$prev_tc_e" ]; then
            echo "[$(date +%H:%M:%S)] TC EGRESS BPF: ${prev_tc_e} → ${TC_E_COUNT} programs"
            prev_tc_e="$TC_E_COUNT"
        fi
        if [ "$SOCK_COUNT" != "$prev_sock" ]; then
            echo "[$(date +%H:%M:%S)] SOCKET LB CGROUP: ${prev_sock} → ${SOCK_COUNT} programs (${LINKS_COUNT} links)"
            prev_sock="$SOCK_COUNT"
        fi

        sleep 0.5
    done
}

# --- Monitor network state before/after ---
monitor_network() {
    while true; do
        # Route table changes
        ROUTE_COUNT=$(ip route show 2>/dev/null | wc -l)
        echo "ROUTES|$(date +%H:%M:%S)|$ROUTE_COUNT"

        # Check if node can reach gateway
        timeout 1 ping -c1 <GATEWAY_IP> &>/dev/null && GW="REACHABLE" || GW="DEAD"
        echo "GATEWAY|$(date +%H:%M:%S)|$GW"

        # Check local DNS
        timeout 1 host -W1 google.com 127.0.0.1 &>/dev/null && DNS="OK" || DNS="FAIL"
        echo "DNS|$(date +%H:%M:%S)|$DNS"

        sleep 2
    done
}

# --- Monitor Cilium agent health via exec ---
monitor_agent_internal() {
    while true; do
        AGENT_ID=$(sudo crictl ps -q --name cilium-agent --state Running 2>/dev/null | head -1)
        if [ -n "$AGENT_ID" ]; then
            # Try to get status from inside the container
            echo "[$(date +%H:%M:%S)] === CILIUM STATUS (internal) ==="
            sudo crictl exec "$AGENT_ID" cilium status --brief 2>/dev/null || echo "cilium status failed"
            echo "[$(date +%H:%M:%S)] === CILIUM ENDPOINTS ==="
            sudo crictl exec "$AGENT_ID" cilium endpoint list 2>/dev/null || echo "endpoint list failed"
        fi
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Capture pre-start state
# ---------------------------------------------------------------------------
echo "=== PRE-START NETWORK STATE ==="
echo "--- ip addr ---"
ip addr show eth0 2>/dev/null
echo "--- ip route ---"
ip route show 2>/dev/null
echo "--- iptables ---"
sudo iptables -L -n 2>/dev/null | head -20
echo "--- BPF before start ---"
ls /sys/fs/bpf/cilium/ 2>/dev/null || echo "(no cilium BPF dir)"
echo "--- K3s status ---"
sudo systemctl status k3s --no-pager -l 2>/dev/null | head -10
echo ""
echo "=== MONITORING STARTED: restart K3s NOW ==="
echo ""

# Run monitors in parallel
trap 'kill $(jobs -p) 2>/dev/null' EXIT
monitor_cilium_pod &
monitor_bpf &
monitor_network &

# Wait for all
wait
