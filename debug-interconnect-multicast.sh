#!/bin/bash
#
# OVN Interconnect Multicast Debug Script
# Purpose: Diagnose multicast flooding delays in Layer2 interconnect mode
#
# Usage: ./debug-interconnect-multicast.sh <network-name> <namespace>
#
# This script must be run DURING the 5-minute multicast blackout period!
#

set -e

NETWORK_NAME="${1:-}"
NAMESPACE="${2:-}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="./multicast-debug-${TIMESTAMP}"

if [[ -z "$NETWORK_NAME" ]] || [[ -z "$NAMESPACE" ]]; then
    echo "Usage: $0 <network-name> <namespace>"
    echo "Example: $0 blue-network my-app-namespace"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "===== OVN Interconnect Multicast Debug ====="
echo "Network: $NETWORK_NAME"
echo "Namespace: $NAMESPACE"
echo "Output: $OUTPUT_DIR"
echo ""

# Get all pods in the namespace on this network
echo "[1/8] Getting pods in namespace $NAMESPACE..."
kubectl get pods -n "$NAMESPACE" -o wide > "$OUTPUT_DIR/pods.txt"
PODS=$(kubectl get pods -n "$NAMESPACE" -o json)
echo "$PODS" > "$OUTPUT_DIR/pods.json"

# Extract pod-to-node mapping
echo "[2/8] Mapping pods to nodes..."
POD_NODE_MAP=$(echo "$PODS" | jq -r '.items[] | "\(.metadata.name):\(.spec.nodeName)"')
echo "$POD_NODE_MAP" > "$OUTPUT_DIR/pod-node-map.txt"

# Get unique nodes
NODES=$(echo "$PODS" | jq -r '.items[].spec.nodeName' | sort -u)
echo "Nodes involved:"
echo "$NODES" | tee "$OUTPUT_DIR/nodes.txt"
echo ""

# For each node, check NBDB and SBDB state
echo "[3/8] Checking NBDB/SBDB state on each node..."

check_node_dbs() {
    local node=$1
    local output_file=$2

    echo "=== Node: $node ===" >> "$output_file"

    # Find the ovnkube-node pod on this node
    OVNKUBE_NODE_POD=$(kubectl get pods -n ovn-kubernetes -o json | \
        jq -r --arg node "$node" '.items[] | select(.spec.nodeName == $node and .metadata.name | startswith("ovnkube-node")) | .metadata.name')

    if [[ -z "$OVNKUBE_NODE_POD" ]]; then
        echo "ERROR: Could not find ovnkube-node pod on $node" >> "$output_file"
        return 1
    fi

    echo "ovnkube-node pod: $OVNKUBE_NODE_POD" >> "$output_file"
    echo "" >> "$output_file"

    # Check NBDB: Get all LSPs for this network
    echo "--- NBDB: Logical Switch Ports for network $NETWORK_NAME ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c nb-ovsdb -- \
        ovn-nbctl --no-leader-only list Logical_Switch_Port | \
        grep -A 20 "external_ids.*network.*$NETWORK_NAME" >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    # Check NBDB: Logical Switch config (multicast settings)
    echo "--- NBDB: Logical Switch multicast config ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c nb-ovsdb -- \
        ovn-nbctl --no-leader-only find Logical_Switch \
        external_ids:network="$NETWORK_NAME" >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    # Check SBDB: Port Bindings
    echo "--- SBDB: Port Bindings ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c sb-ovsdb -- \
        ovn-sbctl --no-leader-only list Port_Binding | \
        grep -A 15 "type.*remote\|external_ids.*pod=true" >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    # Check SBDB: Chassis entries
    echo "--- SBDB: Chassis (remote nodes) ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c sb-ovsdb -- \
        ovn-sbctl --no-leader-only list Chassis | \
        grep -A 10 "is-remote.*true" >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    # Check SBDB: Encap entries
    echo "--- SBDB: Encapsulation (tunnels) ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c sb-ovsdb -- \
        ovn-sbctl --no-leader-only list Encap >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    # Check SBDB: Multicast Groups
    echo "--- SBDB: Multicast Groups ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c sb-ovsdb -- \
        ovn-sbctl --no-leader-only list Multicast_Group >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    echo "=== End Node: $node ===" >> "$output_file"
    echo "" >> "$output_file"
}

for node in $NODES; do
    echo "Checking node: $node"
    check_node_dbs "$node" "$OUTPUT_DIR/node-${node}-dbs.txt"
done

echo "[4/8] Checking OVS tunnel state..."

check_ovs_tunnels() {
    local node=$1
    local output_file=$2

    echo "=== OVS Tunnels on Node: $node ===" >> "$output_file"

    OVNKUBE_NODE_POD=$(kubectl get pods -n ovn-kubernetes -o json | \
        jq -r --arg node "$node" '.items[] | select(.spec.nodeName == $node and .metadata.name | startswith("ovnkube-node")) | .metadata.name')

    if [[ -z "$OVNKUBE_NODE_POD" ]]; then
        echo "ERROR: Could not find ovnkube-node pod on $node" >> "$output_file"
        return 1
    fi

    # Show all Geneve tunnels
    echo "--- Geneve Tunnel Interfaces ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c ovn-controller -- \
        ovs-vsctl show | grep -A 5 "type: geneve" >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    # Show tunnel statistics
    echo "--- Tunnel Port Statistics ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c ovn-controller -- \
        ovs-ofctl dump-ports br-int | grep -i genev >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    echo "=== End OVS Tunnels: $node ===" >> "$output_file"
    echo "" >> "$output_file"
}

for node in $NODES; do
    echo "Checking OVS tunnels on node: $node"
    check_ovs_tunnels "$node" "$OUTPUT_DIR/node-${node}-ovs-tunnels.txt"
done

echo "[5/8] Checking OpenFlow rules for multicast..."

check_openflow_multicast() {
    local node=$1
    local output_file=$2

    echo "=== OpenFlow Multicast Rules on Node: $node ===" >> "$output_file"

    OVNKUBE_NODE_POD=$(kubectl get pods -n ovn-kubernetes -o json | \
        jq -r --arg node "$node" '.items[] | select(.spec.nodeName == $node and .metadata.name | startswith("ovnkube-node")) | .metadata.name')

    if [[ -z "$OVNKUBE_NODE_POD" ]]; then
        echo "ERROR: Could not find ovnkube-node pod on $node" >> "$output_file"
        return 1
    fi

    # Dump flows related to multicast
    echo "--- Multicast Flows (table 0-64) ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c ovn-controller -- \
        ovs-ofctl dump-flows br-int | \
        grep -i "dl_dst=01:00:5e\|multicast\|flood" >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    # Check for specific network's logical switch flows
    echo "--- Logical Switch Flows ---" >> "$output_file"
    kubectl exec -n ovn-kubernetes "$OVNKUBE_NODE_POD" -c sb-ovsdb -- \
        ovn-sbctl --no-leader-only lflow-list | \
        grep -i "outport.*unknown\|multicast" | head -50 >> "$output_file" 2>&1 || true
    echo "" >> "$output_file"

    echo "=== End OpenFlow: $node ===" >> "$output_file"
    echo "" >> "$output_file"
}

for node in $NODES; do
    echo "Checking OpenFlow rules on node: $node"
    check_openflow_multicast "$node" "$OUTPUT_DIR/node-${node}-openflow.txt"
done

echo "[6/8] Checking pod annotations and tunnel IDs..."

check_pod_annotations() {
    local output_file=$1

    echo "=== Pod Annotations ===" >> "$output_file"

    kubectl get pods -n "$NAMESPACE" -o json | \
        jq -r '.items[] | {
            name: .metadata.name,
            node: .spec.nodeName,
            annotations: .metadata.annotations
        }' >> "$output_file"

    echo "" >> "$output_file"
}

check_pod_annotations "$OUTPUT_DIR/pod-annotations.json"

echo "[7/8] Checking node annotations (chassis-id, encap-ip, zone)..."

check_node_annotations() {
    local output_file=$1

    echo "=== Node Annotations ===" >> "$output_file"

    for node in $NODES; do
        echo "--- Node: $node ---" >> "$output_file"
        kubectl get node "$node" -o json | \
            jq -r '.metadata | {
                name: .name,
                labels: .labels,
                annotations: .annotations
            }' >> "$output_file"
        echo "" >> "$output_file"
    done
}

check_node_annotations "$OUTPUT_DIR/node-annotations.json"

echo "[8/8] Checking ovnkube-controller logs for errors..."

check_controller_logs() {
    local output_file=$1

    echo "=== ovnkube-controller Recent Logs ===" >> "$output_file"

    # Get ovnkube-controller pods (could be on master nodes)
    CONTROLLER_PODS=$(kubectl get pods -n ovn-kubernetes -o json | \
        jq -r '.items[] | select(.metadata.name | startswith("ovnkube-node")) | .metadata.name')

    for pod in $CONTROLLER_PODS; do
        echo "--- Controller Pod: $pod ---" >> "$output_file"
        kubectl logs -n ovn-kubernetes "$pod" -c ovnkube-controller --tail=100 | \
            grep -i "error\|warn\|chassis\|remote\|interconnect" >> "$output_file" 2>&1 || true
        echo "" >> "$output_file"
    done
}

check_controller_logs "$OUTPUT_DIR/controller-logs.txt"

echo ""
echo "===== Debug Complete ====="
echo "Results saved to: $OUTPUT_DIR"
echo ""
echo "===== ANALYSIS CHECKLIST ====="
echo ""
echo "1. Check NBDB LSPs (node-*-dbs.txt):"
echo "   - Are remote LSPs created with type='remote'?"
echo "   - Do they have 'requested-chassis' option set?"
echo "   - Do they have 'requested-tnl-key' (tunnel ID)?"
echo ""
echo "2. Check SBDB Port_Bindings (node-*-dbs.txt):"
echo "   - Are Port_Bindings created for remote LSPs?"
echo "   - Are they bound to correct chassis?"
echo "   - Check 'chassis' column - should reference remote chassis"
echo ""
echo "3. Check SBDB Chassis entries (node-*-dbs.txt):"
echo "   - Are remote chassis entries present?"
echo "   - Do they have 'is-remote=true'?"
echo "   - Are Encap records present with correct IPs?"
echo ""
echo "4. Check OVS Tunnels (node-*-ovs-tunnels.txt):"
echo "   - Are Geneve tunnels established to remote nodes?"
echo "   - Check tunnel statistics - any tx/rx packets?"
echo ""
echo "5. Check OpenFlow rules (node-*-openflow.txt):"
echo "   - Are multicast flooding rules installed?"
echo "   - Check for 'output:<tunnel-port>' actions"
echo ""
echo "6. Check Multicast Groups (node-*-dbs.txt):"
echo "   - Are Multicast_Group entries present?"
echo "   - Do they include remote ports in flood list?"
echo ""
echo "===== COMMON ISSUES ====="
echo ""
echo "ISSUE 1: Remote LSP created but no Port_Binding"
echo "  → ovn-northd lag - check ovn-northd logs"
echo ""
echo "ISSUE 2: Port_Binding exists but chassis column is empty"
echo "  → Chassis entry missing - check ZoneChassisHandler"
echo ""
echo "ISSUE 3: Chassis exists but no Encap records"
echo "  → Node missing k8s.ovn.org/node-encap-ips annotation"
echo ""
echo "ISSUE 4: Encap exists but no OVS tunnel"
echo "  → ovn-controller issue - check ovn-controller logs"
echo ""
echo "ISSUE 5: Tunnel exists but no multicast flows"
echo "  → Multicast_Group not populated - SBDB issue"
echo ""
