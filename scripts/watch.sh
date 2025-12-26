#!/bin/bash
# =============================================================================
# System Watch: monitors SSH, BPF, Cilium pod, network state during K3s restart
# =============================================================================
# Run on physical console before restarting K3s.
# Output to screen AND /home/user/debug.csv (survives reboot).
#
# Columns:
#   TS               Timestamp
#   SSH              UP/DOWN: is sshd listening on configured port
#   LOAD             1-minute load average (4.0+ on 4-core = CPU saturated)
#   TC_I             TC ingress BPF programs on ALL interfaces
#   TC_E             TC egress BPF programs on ALL interfaces (CRITICAL)
#   SOCK             Socket LB BPF programs in cgroup (CRITICAL)
#   LINKS            Stale BPF links from previous agent
#   CL_POD           Cilium pod state: NOT_FOUND / SANDBOX_READY / SANDBOX_NOTREADY
#   CL_INIT          Cilium init container state: WAITING / RUNNING / EXITED
#   CL_AGENT         Cilium agent container state: WAITING / RUNNING / FAILED
#   GW               Gateway reachability: OK / DEAD
#   DNS              DNS working: OK / FAIL
#   RTS              Route table entries
#   MEM              Free memory (MB)
# =============================================================================

LOG="/home/user/debug.csv"
SSH_PORT=$(ss -tlnp 2>/dev/null | grep -oP ':\K[0-9]+(?= .*sshd)' | head -1)
SSH_PORT=${SSH_PORT:-62626}

echo "TS,SSH,LOAD,TC_I,TC_E,SOCK,LINKS,CL_POD,CL_INIT,CL_AGENT,GW,DNS,RTS,MEM" | tee "$LOG"

prev_agent=""

while true; do
    TS=$(date +%H:%M:%S.%N | cut -c1-12)

    # SSH
    SS=$(ss -tlnp | grep -q ":${SSH_PORT} " && echo UP || echo DOWN)

    # Load
    LO=$(cat /proc/loadavg | cut -d' ' -f1)

    # BPF on all Cilium interfaces
    TC_I=0; TC_E=0
    for iface in eth0 $(ip -br link 2>/dev/null | awk '/cilium|lxc/{print $1}'); do
        TC_I=$((TC_I + $(tc filter show dev "$iface" ingress 2>/dev/null | grep -c bpf)))
        TC_E=$((TC_E + $(tc filter show dev "$iface" egress 2>/dev/null | grep -c bpf)))
    done

    # Socket LB
    SK=$(ls /sys/fs/bpf/cilium/socketlb/links/cgroup/ 2>/dev/null | wc -l)

    # Stale links
    LK=$(ls /sys/fs/bpf/cilium/tc/globals/ 2>/dev/null | wc -l)

    # Cilium pod state (via crictl: works without API server)
    CIL_POD=$(sudo crictl pods --name cilium -q 2>/dev/null | head -1)
    if [ -n "$CIL_POD" ]; then
        POD_INFO=$(sudo crictl inspectp "$CIL_POD" 2>/dev/null)
        POD_ST=$(echo "$POD_INFO" | jq -r '.status.state // "UNKNOWN"')

        INIT_ID=$(sudo crictl ps -a --pod "$CIL_POD" --name config -q 2>/dev/null | head -1)
        AGENT_ID=$(sudo crictl ps -a --pod "$CIL_POD" --name cilium-agent -q 2>/dev/null | head -1)

        if [ -n "$INIT_ID" ]; then
            INIT_ST=$(sudo crictl inspect "$INIT_ID" 2>/dev/null | jq -r '.status.state // "?"' | head -c8)
        else
            INIT_ST="NONE"
        fi

        if [ -n "$AGENT_ID" ]; then
            AGENT_ST=$(sudo crictl inspect "$AGENT_ID" 2>/dev/null | jq -r '.status.state // "?"' | head -c8)
            # On agent state change, dump logs
            if [ "$AGENT_ID" != "$prev_agent" ]; then
                echo "[$TS] CILIUM AGENT: $AGENT_ST (container $AGENT_ID)" >> "$LOG"
                # Capture first 50 lines of agent log
                sudo crictl logs --tail=50 "$AGENT_ID" 2>/dev/null | head -50 >> /home/user/cilium-agent-startup.log
                prev_agent="$AGENT_ID"
            fi
        else
            AGENT_ST="NONE"
        fi
    else
        POD_ST="NOT_FOUND"
        INIT_ST="NONE"
        AGENT_ST="NONE"
    fi

    # Gateway reachability
    timeout 0.5 ping -c1 <GATEWAY_IP> &>/dev/null && GW="OK" || GW="DEAD"

    # DNS
    timeout 1 host -W1 google.com 127.0.0.1 &>/dev/null && DNS="OK" || DNS="FAIL"

    # Route count
    RTS=$(ip route show 2>/dev/null | wc -l)

    # Memory
    MEM=$(free -m | awk '/^Mem:/ {print $4}')

    echo "${TS},${SS},${LO},${TC_I},${TC_E},${SK},${LK},${POD_ST},${INIT_ST},${AGENT_ST},${GW},${DNS},${RTS},${MEM}"

    sleep 0.5
done | tee -a "$LOG"
