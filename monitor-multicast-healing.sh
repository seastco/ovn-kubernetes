#!/bin/bash
#
# Real-time Multicast Healing Monitor
# Purpose: Detect the EXACT moment when multicast flooding starts working
#
# Usage: ./monitor-multicast-healing.sh <sender-pod> <receiver-pod> <namespace>
#
# This script continuously monitors:
# 1. NBDB/SBDB state changes
# 2. OVS tunnel establishment
# 3. OpenFlow rule installation
# 4. Actual multicast packet flow
#

set -e

SENDER_POD="${1:-}"
RECEIVER_POD="${2:-}"
NAMESPACE="${3:-}"
INTERVAL="${4:-2}"  # Check interval in seconds

if [[ -z "$SENDER_POD" ]] || [[ -z "$RECEIVER_POD" ]] || [[ -z "$NAMESPACE" ]]; then
    echo "Usage: $0 <sender-pod> <receiver-pod> <namespace> [interval-seconds]"
    echo "Example: $0 mesh-pod-1 mesh-pod-2 my-namespace 2"
    exit 1
fi

# Get pod-to-node mapping
SENDER_NODE=$(kubectl get pod -n "$NAMESPACE" "$SENDER_POD" -o jsonpath='{.spec.nodeName}')
RECEIVER_NODE=$(kubectl get pod -n "$NAMESPACE" "$RECEIVER_POD" -o jsonpath='{.spec.nodeName}')

echo "===== Multicast Healing Monitor ====="
echo "Sender: $SENDER_POD on node $SENDER_NODE"
echo "Receiver: $RECEIVER_POD on node $RECEIVER_NODE"
echo "Monitoring interval: ${INTERVAL}s"
echo "Press Ctrl+C to stop"
echo ""

if [[ "$SENDER_NODE" == "$RECEIVER_NODE" ]]; then
    echo "WARNING: Both pods on same node - no interconnect needed!"
    echo "This monitor is for cross-node multicast issues."
    exit 1
fi

# Get ovnkube-node pods
SENDER_OVNKUBE_POD=$(kubectl get pods -n ovn-kubernetes -o json | \
    jq -r --arg node "$SENDER_NODE" '.items[] | select(.spec.nodeName == $node and .metadata.name | startswith("ovnkube-node")) | .metadata.name')
RECEIVER_OVNKUBE_POD=$(kubectl get pods -n ovn-kubernetes -o json | \
    jq -r --arg node "$RECEIVER_NODE" '.items[] | select(.spec.nodeName == $node and .metadata.name | startswith("ovnkube-node")) | .metadata.name')

echo "Sender ovnkube-node: $SENDER_OVNKUBE_POD"
echo "Receiver ovnkube-node: $RECEIVER_OVNKUBE_POD"
echo ""

# Get receiver pod's LSP name
RECEIVER_LSP=$(kubectl get pod -n "$NAMESPACE" "$RECEIVER_POD" -o json | \
    jq -r '.metadata.name + "_" + .metadata.namespace')

# State tracking
PREV_CHASSIS_BOUND=""
PREV_TUNNEL_EXISTS=""
PREV_FLOW_EXISTS=""

iteration=0

while true; do
    iteration=$((iteration + 1))
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] Iteration $iteration"

    # ========================================
    # CHECK 1: Is remote LSP created in sender's NBDB?
    # ========================================
    REMOTE_LSP_EXISTS=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c nb-ovsdb -- \
        ovn-nbctl --no-leader-only find Logical_Switch_Port name="$RECEIVER_LSP" 2>/dev/null | \
        grep -c "type.*remote" || echo "0")

    if [[ "$REMOTE_LSP_EXISTS" == "0" ]]; then
        echo "  ❌ NBDB: Remote LSP for $RECEIVER_POD NOT created yet"
    else
        echo "  ✅ NBDB: Remote LSP exists (type=remote)"

        # Check tunnel key assignment
        TUNNEL_KEY=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c nb-ovsdb -- \
            ovn-nbctl --no-leader-only get Logical_Switch_Port "$RECEIVER_LSP" options:requested-tnl-key 2>/dev/null || echo "none")
        echo "     Tunnel Key: $TUNNEL_KEY"

        # Check requested chassis
        REQ_CHASSIS=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c nb-ovsdb -- \
            ovn-nbctl --no-leader-only get Logical_Switch_Port "$RECEIVER_LSP" options:requested-chassis 2>/dev/null || echo "none")
        echo "     Requested Chassis: $REQ_CHASSIS"
    fi

    # ========================================
    # CHECK 2: Is receiver node's chassis in sender's SBDB?
    # ========================================
    CHASSIS_EXISTS=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c sb-ovsdb -- \
        ovn-sbctl --no-leader-only find Chassis hostname="$RECEIVER_NODE" 2>/dev/null | \
        grep -c "is-remote.*true" || echo "0")

    if [[ "$CHASSIS_EXISTS" == "0" ]]; then
        echo "  ❌ SBDB: Chassis for $RECEIVER_NODE NOT found"
    else
        echo "  ✅ SBDB: Chassis exists (is-remote=true)"

        # Check encap IP
        ENCAP_IP=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c sb-ovsdb -- \
            ovn-sbctl --no-leader-only find Encap chassis_name:hostname="$RECEIVER_NODE" | \
            grep -oP 'ip\s*:\s*"\K[^"]+' || echo "none")
        echo "     Encap IP: $ENCAP_IP"
    fi

    # ========================================
    # CHECK 3: Is Port_Binding bound to chassis?
    # ========================================
    PORT_BINDING_CHASSIS=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c sb-ovsdb -- \
        ovn-sbctl --no-leader-only find Port_Binding logical_port="$RECEIVER_LSP" 2>/dev/null | \
        grep -oP 'chassis\s*:\s*\K[a-f0-9-]+' || echo "none")

    if [[ "$PORT_BINDING_CHASSIS" == "none" ]] || [[ -z "$PORT_BINDING_CHASSIS" ]]; then
        echo "  ❌ SBDB: Port_Binding NOT bound to chassis"
        CHASSIS_BOUND="no"
    else
        echo "  ✅ SBDB: Port_Binding bound to chassis $PORT_BINDING_CHASSIS"
        CHASSIS_BOUND="yes"

        # TRANSITION DETECTED
        if [[ "$PREV_CHASSIS_BOUND" != "yes" ]] && [[ "$CHASSIS_BOUND" == "yes" ]]; then
            echo ""
            echo "  🎯 TRANSITION: Port_Binding just got bound to chassis!"
            echo "     Time: $timestamp"
            echo ""
        fi
    fi
    PREV_CHASSIS_BOUND="$CHASSIS_BOUND"

    # ========================================
    # CHECK 4: Is Geneve tunnel established?
    # ========================================
    if [[ "$CHASSIS_EXISTS" != "0" ]] && [[ -n "$ENCAP_IP" ]] && [[ "$ENCAP_IP" != "none" ]]; then
        TUNNEL_PORT=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c ovn-controller -- \
            ovs-vsctl find interface type=geneve options:remote_ip="$ENCAP_IP" 2>/dev/null | \
            grep -oP 'name\s*:\s*"\K[^"]+' || echo "none")

        if [[ "$TUNNEL_PORT" == "none" ]] || [[ -z "$TUNNEL_PORT" ]]; then
            echo "  ❌ OVS: Geneve tunnel to $ENCAP_IP NOT established"
            TUNNEL_EXISTS="no"
        else
            echo "  ✅ OVS: Geneve tunnel exists: $TUNNEL_PORT"
            TUNNEL_EXISTS="yes"

            # Check tunnel stats
            TX_PACKETS=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c ovn-controller -- \
                ovs-ofctl dump-ports br-int "$TUNNEL_PORT" 2>/dev/null | \
                grep -oP 'tx pkts=\K[0-9]+' || echo "0")
            RX_PACKETS=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c ovn-controller -- \
                ovs-ofctl dump-ports br-int "$TUNNEL_PORT" 2>/dev/null | \
                grep -oP 'rx pkts=\K[0-9]+' || echo "0")
            echo "     Tunnel Stats: TX=$TX_PACKETS RX=$RX_PACKETS"

            # TRANSITION DETECTED
            if [[ "$PREV_TUNNEL_EXISTS" != "yes" ]] && [[ "$TUNNEL_EXISTS" == "yes" ]]; then
                echo ""
                echo "  🎯 TRANSITION: Geneve tunnel just got established!"
                echo "     Time: $timestamp"
                echo ""
            fi
        fi
        PREV_TUNNEL_EXISTS="$TUNNEL_EXISTS"
    fi

    # ========================================
    # CHECK 5: Are OpenFlow multicast rules installed?
    # ========================================
    MULTICAST_FLOW_COUNT=$(kubectl exec -n ovn-kubernetes "$SENDER_OVNKUBE_POD" -c ovn-controller -- \
        ovs-ofctl dump-flows br-int 2>/dev/null | \
        grep -c "dl_dst=01:00:5e" || echo "0")

    if [[ "$MULTICAST_FLOW_COUNT" == "0" ]]; then
        echo "  ❌ OVS: No multicast flows found"
        FLOW_EXISTS="no"
    else
        echo "  ✅ OVS: $MULTICAST_FLOW_COUNT multicast flow(s) installed"
        FLOW_EXISTS="yes"

        # TRANSITION DETECTED
        if [[ "$PREV_FLOW_EXISTS" != "yes" ]] && [[ "$FLOW_EXISTS" == "yes" ]]; then
            echo ""
            echo "  🎯 TRANSITION: Multicast flows just got installed!"
            echo "     Time: $timestamp"
            echo ""
        fi
    fi
    PREV_FLOW_EXISTS="$FLOW_EXISTS"

    # ========================================
    # CHECK 6: Can receiver actually receive multicast?
    # ========================================
    # Note: This requires tcpdump running on receiver pod
    # You would run: kubectl exec -n $NAMESPACE $RECEIVER_POD -- tcpdump -i any -n "multicast" -c 1 -W 2
    # But we'll skip this in the monitor to avoid interference

    echo ""

    # Summary status
    if [[ "$CHASSIS_BOUND" == "yes" ]] && [[ "$TUNNEL_EXISTS" == "yes" ]] && [[ "$FLOW_EXISTS" == "yes" ]]; then
        echo "  ✅✅✅ ALL CHECKS PASSED - Multicast should be working!"
        echo ""
        echo "If multicast still NOT working, the issue is likely:"
        echo "  - Application-level (wrong multicast group)"
        echo "  - Network policy blocking traffic"
        echo "  - Pod interface issues"
        echo ""
        break
    fi

    sleep "$INTERVAL"
done

echo "===== Monitoring Complete ====="
echo ""
echo "FINAL STATE:"
echo "  Remote LSP created: $([ "$REMOTE_LSP_EXISTS" != "0" ] && echo "YES" || echo "NO")"
echo "  Chassis entry exists: $([ "$CHASSIS_EXISTS" != "0" ] && echo "YES" || echo "NO")"
echo "  Port_Binding bound: $CHASSIS_BOUND"
echo "  Geneve tunnel established: $TUNNEL_EXISTS"
echo "  Multicast flows installed: $FLOW_EXISTS"
echo ""
