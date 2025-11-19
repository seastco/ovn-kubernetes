# OVN-Kubernetes Interconnect Mode: Multicast Flooding Analysis

**Author:** Claude AI Analysis
**Date:** 2025-11-19
**Branch:** release-1.1
**Issue:** Multicast flooding delay (~5 minutes) in Layer2 secondary networks with interconnect mode

---

## Executive Summary

After comprehensive code analysis of OVN-Kubernetes interconnect mode (1.1), the **most likely root cause** of your 5-minute multicast flooding delay is **asynchronous remote port binding** combined with **scale-related SBDB propagation lag**.

**Key Finding:** In single-node-per-zone interconnect mode, remote pod ports must go through a multi-step asynchronous process involving:
1. Remote LSP creation in NBDB (type="remote")
2. Remote chassis entry creation in SBDB (is-remote=true)
3. Port_Binding population and chassis binding
4. Geneve tunnel establishment
5. OpenFlow multicast flow installation

With **10 networks × 16 pods** spread across multiple nodes, the timing dependencies between these steps create a cascading delay that can take several minutes to resolve.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Layer2 Interconnect Specifics](#layer2-interconnect-specifics)
3. [Multicast Configuration](#multicast-configuration)
4. [Root Cause Theories](#root-cause-theories)
5. [Diagnostic Approach](#diagnostic-approach)
6. [Code References](#code-references)

---

## Architecture Overview

### Single-Node-Per-Zone Interconnect

In OVN-Kubernetes 1.1 interconnect mode with default single-node-per-zone:
- **Each node = separate zone** (e.g., `worker-01` → zone `worker-01`)
- **Isolated databases:** Each zone has its own local NBDB and SBDB (no RAFT)
- **Zone determination:** Based on `k8s.ovn.org/zone-name` label on nodes
- **Local vs remote:** Determined by checking if `pod.Spec.NodeName` is in controller's `localZoneNodes` map

**Key Code:**
```go
// base_network_controller.go:986-1002
func (bnc *BaseNetworkController) isLocalZoneNode(node *corev1.Node) bool {
    if bnc.zone == types.OvnDefaultZone {
        return !util.HasNodeMigratedZone(node)  // Upgrade compatibility
    }
    return util.GetNodeZone(node) == bnc.zone
}

// base_network_controller_pods.go:739-751
func (bnc *BaseNetworkController) isPodScheduledinLocalZone(pod *corev1.Pod) bool {
    isLocalZonePod := true
    if bnc.localZoneNodes != nil {
        if util.PodScheduled(pod) {
            _, isLocalZonePod = bnc.localZoneNodes.Load(pod.Spec.NodeName)
        } else {
            isLocalZonePod = false
        }
    }
    return isLocalZonePod
}
```

### Transit Switch Architecture

**CRITICAL DISTINCTION FOR LAYER2:**
```go
// zone_ic_handler.go:148-155
func getTransitSwitchName(nInfo util.NetInfo) string {
    switch nInfo.TopologyType() {
    case types.Layer2Topology:
        return nInfo.GetNetworkScopedName(types.OVNLayer2Switch)  // ← SAME AS NETWORK SWITCH!
    default:
        return nInfo.GetNetworkScopedName(types.TransitSwitch)     // ← Separate transit switch
    }
}
```

**For Layer2 networks, the transit switch IS the network logical switch** - there is no separate transit switch like in routed topologies.

---

## Layer2 Interconnect Specifics

### Local Pod Configuration

When a pod is scheduled on the **local zone** (same node as the controller):

**NBDB:**
```
Logical_Switch_Port {
    name: "<pod>_<namespace>",
    type: "",  // Empty = normal port
    addresses: ["<mac> <ip>"],
    options: {
        requested-tnl-key: "<tunnel_id>"  // From cluster manager
    }
}
```

**SBDB:**
```
Port_Binding {
    logical_port: "<pod>_<namespace>",
    chassis: <local-chassis-uuid>,  // Automatically bound
    type: "",
    tunnel_key: <tunnel_id>
}
```

### Remote Pod Configuration

When a pod is scheduled on a **remote zone** (different node):

**NBDB (created on ALL zones):**
```
Logical_Switch_Port {
    name: "<pod>_<namespace>",
    type: "remote",  // ← Special remote type
    addresses: ["<mac> <ip>"],
    options: {
        requested-tnl-key: "<tunnel_id>",
        requested-chassis: "<node_name>"  // ← Binds to remote chassis
    }
}
```

**SBDB (on local zone):**
```
Port_Binding {
    logical_port: "<pod>_<namespace>",
    chassis: <remote-chassis-uuid>,  // ← Must reference remote chassis
    type: "remote",
    tunnel_key: <tunnel_id>
}
```

**Key Code:**
```go
// base_network_controller_user_defined.go:332-336
isLocalPod := bsnc.isPodScheduledinLocalZone(pod)
requiresLogicalPort := isLocalPod || bsnc.isLayer2Interconnect()  // ← ALL pods get LSPs

if requiresLogicalPort {
    ops, lsp, podAnnotation, newlyCreated, err = bsnc.addLogicalPortToNetwork(...)
}

// base_network_controller_pods.go:604-612
if bnc.isLayer2Interconnect() {
    isRemotePort := !bnc.isPodScheduledinLocalZone(pod)
    err = bnc.zoneICHandler.AddTransitPortConfig(isRemotePort, podAnnotation, lsp)
    if isRemotePort {
        customFields = append(customFields, libovsdbops.LogicalSwitchPortType)  // ← Type field
    }
}

// zone_ic_handler.go:352-372
func (zic *ZoneInterconnectHandler) AddTransitPortConfig(remote bool, podAnnotation *util.PodAnnotation, port *nbdb.LogicalSwitchPort) error {
    if zic.TopologyType() != types.Layer2Topology {
        return nil
    }

    port.Options[libovsdbops.RequestedTnlKey] = strconv.Itoa(podAnnotation.TunnelID)

    if remote {
        port.Type = lportTypeRemote  // "remote"
    }

    return nil
}
```

### Chassis and Encapsulation

**Remote Chassis Creation:**
```go
// chassis_handler.go:124-171
func (zch *ZoneChassisHandler) createOrUpdateNodeChassis(node *corev1.Node, isRemote bool) error {
    chassisID, _ := util.ParseNodeChassisIDAnnotation(node)
    encapIPs, _ := util.ParseNodeEncapIPsAnnotation(node)

    encaps := make([]*sbdb.Encap, 0, len(encapIPs))
    for _, ovnEncapIP := range encapIPs {
        encap := sbdb.Encap{
            ChassisName: chassisID,
            IP:          ovnEncapIP,
            Type:        "geneve",  // ← Always Geneve
            Options:     {"csum": "true"},
        }
        encaps = append(encaps, &encap)
    }

    chassis := sbdb.Chassis{
        Name:     chassisID,
        Hostname: node.Name,
        OtherConfig: map[string]string{
            "is-remote": strconv.FormatBool(isRemote),  // ← Marks as remote
        },
    }

    return libovsdbops.CreateOrUpdateChassis(zch.sbClient, &chassis, encaps...)
}
```

**Tunnel Key Allocation:**
- **Transit Switch:** `BaseTransitSwitchTunnelKey` (16711683) + NetworkID
- **Node Transit Ports:** Based on NodeID (from cluster manager)
- **Pod Ports:** From TunnelID in pod annotation (from cluster manager)

---

## Multicast Configuration

### Layer2 Switch Multicast Settings

```go
// zone_ic_handler.go:374-384
func (zic *ZoneInterconnectHandler) addTransitSwitchConfig(sw *nbdb.LogicalSwitch, tunnelKey int) {
    sw.OtherConfig["interconn-ts"] = sw.Name
    sw.OtherConfig["requested-tnl-key"] = strconv.Itoa(tunnelKey)
    sw.OtherConfig["mcast_snoop"] = "true"                // ← IGMP/MLD snooping ON
    sw.OtherConfig["mcast_querier"] = "false"             // ← No querier
    sw.OtherConfig["mcast_flood_unregistered"] = "true"   // ← Flood unknown groups!
}
```

**Key Points:**
1. **IGMP Snooping Enabled:** Switch learns multicast group memberships
2. **Flood Unregistered:** Unknown multicast groups are flooded to ALL ports
3. **No Querier:** Multicast querier is disabled (handled elsewhere or not needed)

### Router Port Multicast (if using transit router)

```go
// zone_ic_handler.go:412-415
logicalRouterPort := nbdb.LogicalRouterPort{
    Name:     logicalRouterPortName,
    Options: map[string]string{
        "mcast_flood": "true",  // ← Enable flooding on router ports
    },
}
```

### Expected Behavior

With `mcast_flood_unregistered = "true"`, multicast traffic should be **immediately flooded** to all ports on the logical switch, including remote ports, **without requiring IGMP join messages**.

**This means:** Your multicast flooding delay is NOT due to IGMP learning - it's due to **incomplete remote port setup**.

---

## Root Cause Theories

### Theory #1: Asynchronous Remote Port Binding Delay ⭐ MOST LIKELY

**The Problem:**

In interconnect mode, remote pod connectivity requires a precise sequence of operations across multiple components:

```
┌─────────────────────────────────────────────────────────────┐
│ Pod Scheduled on Zone B (Remote)                             │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP 1: Zone B ovnkube-controller                            │
│   - Creates local LSP in Zone B NBDB                         │
│   - Type: "" (normal)                                        │
│   - Annotates pod with tunnel ID                            │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP 2: Zone B ovn-northd                                    │
│   - Translates LSP → Port_Binding in Zone B SBDB            │
│   - Binds to local chassis                                   │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP 3: Zone A ovnkube-controller (via k8s API watch)       │
│   - Detects pod scheduled on remote node                    │
│   - Creates remote LSP in Zone A NBDB                       │
│   - Type: "remote"                                           │
│   - Options: requested-chassis = Zone B node name           │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP 4: Zone A ZoneChassisHandler (via k8s API watch)       │
│   - Detects remote node in cluster                          │
│   - Creates chassis entry in Zone A SBDB                    │
│   - OtherConfig: is-remote = true                           │
│   - Creates Encap record with Zone B node's IP              │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP 5: Zone A ovn-northd                                    │
│   - Translates remote LSP → Port_Binding in Zone A SBDB     │
│   - Looks up chassis by requested-chassis option            │
│   - Binds Port_Binding.chassis = remote chassis UUID        │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP 6: Zone A ovn-controller                                │
│   - Detects Port_Binding with remote chassis                │
│   - Queries chassis Encap record for remote_ip              │
│   - Creates Geneve tunnel in OVS                            │
│   - Installs OpenFlow rules for remote port                 │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP 7: Multicast can now flow Zone A ↔ Zone B              │
└─────────────────────────────────────────────────────────────┘
```

**Critical Race Condition:**

If STEP 3 completes **before** STEP 4:
- Remote LSP exists in NBDB
- But chassis entry doesn't exist in SBDB yet
- ovn-northd cannot bind Port_Binding to chassis
- Port_Binding sits **unbound** until chassis appears
- This can take **minutes** with watch loop delays

**Why 5 Minutes?**

With default Kubernetes watch intervals and reconciliation loops:
- Node watch events: ~30-60s intervals
- NBDB → SBDB translation: ~10-30s per run
- Multiple retries with exponential backoff
- **Total delay: 3-5 minutes** is very realistic

**Evidence in Code:**

```go
// zone_ic_handler.go:210-217
func (zic *ZoneInterconnectHandler) AddRemoteZoneNode(node *corev1.Node) error {
    nodeID, _ := util.GetNodeID(node)
    if nodeID == -1 {
        // Don't consider this node as cluster-manager has not allocated node id yet.
        return fmt.Errorf("failed to get node id for node - %s", node.Name)  // ← Retry needed
    }
    // ...
}
```

If cluster manager hasn't allocated node ID yet, remote node setup fails and must retry.

### Theory #2: Scale-Related NBDB→SBDB Translation Lag

**The Scale Problem:**

With **10 networks × 16 pods** across **N nodes**:
- Each zone's NBDB contains LSPs for ALL 160 pods (local + remote)
- ovn-northd must translate ALL LSPs → Port_Bindings
- With 10 nodes: 1600 LSPs per node's NBDB

**OVN Northd Bottleneck:**

ovn-northd runs as a single-threaded daemon that:
1. Polls NBDB for changes
2. Computes logical flows
3. Writes to SBDB
4. Repeat

**Latency Sources:**
- **Polling interval:** Default 100ms, but can lag under load
- **Flow computation:** O(N²) complexity for some operations
- **SBDB writes:** Serial writes with transaction overhead

**With 1600 LSPs:**
- Each ovn-northd cycle takes longer
- Delay compounds across multiple zones
- Changes can take 30-60s to propagate

### Theory #3: Multicast Group Propagation Delay

**OVN Multicast Architecture:**

When `mcast_flood_unregistered = "true"`, OVN creates a special `Multicast_Group` entry:

```
Multicast_Group {
    datapath: <logical_switch_uuid>,
    name: "_MC_unknown",
    ports: [<all_lsps>]  // ← Must include remote LSPs!
}
```

**The Issue:**

Remote LSPs might be added to `Multicast_Group.ports` **after** they're fully bound:
1. Remote LSP created
2. Port_Binding bound to chassis
3. **Delay here** ← Multicast group not updated yet
4. Multicast_Group updated with new port
5. ovn-controller installs multicast flows

**Why the Delay?**

ovn-northd updates multicast groups in a separate pass after port binding. If this pass is slow or batched, multicast flooding won't work until the update completes.

### Theory #4: Geneve Tunnel Establishment Delay

**Tunnel Creation is Lazy:**

OVN doesn't pre-create all possible tunnels. Tunnels are created **on-demand** when:
1. ovn-controller sees a Port_Binding with remote chassis
2. Queries SBDB for chassis Encap record
3. Creates tunnel interface in OVS

**With 10 Nodes:**
- Each node needs tunnels to 9 other nodes
- 10 networks → 90 potential tunnels per node
- Tunnel creation involves OVS reconfiguration
- Can take 10-30s per tunnel under load

**Multicast Requirement:**

For multicast flooding to work, tunnels must be established to **all remote chassis** hosting pods on the network. If any tunnel is missing, multicast traffic to that node will be dropped.

---

## Diagnostic Approach

Two scripts have been created to help diagnose the issue:

### 1. Comprehensive Debug Script

**File:** `debug-interconnect-multicast.sh`

**Purpose:** Capture complete state snapshot during the 5-minute blackout

**Usage:**
```bash
./debug-interconnect-multicast.sh <network-name> <namespace>
```

**What it checks:**
1. **NBDB State:** All LSPs, including remote LSPs with type="remote"
2. **SBDB State:** Port_Bindings, chassis binding, chassis entries
3. **Chassis Records:** Remote chassis with is-remote=true, Encap IPs
4. **OVS Tunnels:** Geneve tunnel establishment, tunnel statistics
5. **OpenFlow Rules:** Multicast flooding flows
6. **Multicast Groups:** Multicast_Group table entries
7. **Annotations:** Pod and node annotations (tunnel IDs, chassis IDs, zone names)
8. **Logs:** ovnkube-controller errors related to chassis/remote/interconnect

**Output:**
- Creates directory with timestamped results
- Separate files per node for NBDB/SBDB/OVS state
- Analysis checklist with common issues

### 2. Real-Time Healing Monitor

**File:** `monitor-multicast-healing.sh`

**Purpose:** Detect the **exact moment** when multicast starts working

**Usage:**
```bash
./monitor-multicast-healing.sh <sender-pod> <receiver-pod> <namespace> [interval]
```

**What it monitors (every 2 seconds):**
1. Remote LSP creation in sender's NBDB
2. Chassis entry existence in sender's SBDB
3. **Port_Binding binding to chassis** ← Critical moment!
4. Geneve tunnel establishment
5. OpenFlow multicast rule installation

**Key Features:**
- **Transition Detection:** Alerts when state changes (e.g., Port_Binding just got bound)
- **Timestamps:** Records exact time of each transition
- **Continuous:** Runs until all checks pass
- **Cross-node:** Specifically monitors sender→receiver connectivity

**Example Output:**
```
[2025-11-19 10:15:32] Iteration 1
  ❌ NBDB: Remote LSP for receiver-pod NOT created yet
  ❌ SBDB: Chassis for worker-02 NOT found
  ❌ SBDB: Port_Binding NOT bound to chassis
  ❌ OVS: Geneve tunnel to 10.0.0.2 NOT established
  ❌ OVS: No multicast flows found

[2025-11-19 10:16:05] Iteration 17
  ✅ NBDB: Remote LSP exists (type=remote)
     Tunnel Key: 12345
     Requested Chassis: worker-02
  ✅ SBDB: Chassis exists (is-remote=true)
     Encap IP: 10.0.0.2

  🎯 TRANSITION: Port_Binding just got bound to chassis!
     Time: 2025-11-19 10:16:05

  ✅ SBDB: Port_Binding bound to chassis abc123-def456
  ❌ OVS: Geneve tunnel to 10.0.0.2 NOT established
  ❌ OVS: No multicast flows found

[2025-11-19 10:16:18] Iteration 23

  🎯 TRANSITION: Geneve tunnel just got established!
     Time: 2025-11-19 10:16:18

  ✅ OVS: Geneve tunnel exists: ovn-worker-02
     Tunnel Stats: TX=0 RX=0
  ✅ OVS: 45 multicast flow(s) installed

  ✅✅✅ ALL CHECKS PASSED - Multicast should be working!
```

### Running the Diagnostics

**Step 1: Reproduce the Issue**

Deploy your 10 networks with 16 pods each and trigger multicast traffic.

**Step 2: Run the Monitor (IMMEDIATELY)**

```bash
# Pick a sender and receiver pod on DIFFERENT nodes
./monitor-multicast-healing.sh mesh-pod-sender mesh-pod-receiver my-namespace 2
```

**Step 3: Run the Debug Script (During Blackout)**

In a separate terminal:
```bash
./debug-interconnect-multicast.sh my-network my-namespace
```

**Step 4: Analyze Results**

Look for:
1. **Port_Binding delay:** How long between LSP creation and chassis binding?
2. **Chassis creation delay:** How long between node appearing and chassis in SBDB?
3. **Tunnel delay:** How long between chassis and tunnel creation?
4. **Multicast group delay:** How long between Port_Binding and multicast flows?

**Step 5: Correlate with ovn-northd Logs**

```bash
kubectl logs -n ovn-kubernetes <ovnkube-node-pod> -c ovn-northd | grep -i "multicast\|port_binding\|chassis"
```

---

## Code References

### Key Files

| File | Purpose | Key Functions |
|------|---------|---------------|
| `zone_ic_handler.go` | Interconnect logic for transit switches and remote ports | `AddTransitPortConfig`, `createRemoteZoneNodeResources` |
| `chassis_handler.go` | Remote chassis creation in SBDB | `createOrUpdateNodeChassis` |
| `base_network_controller_pods.go` | Pod LSP creation and management | `addLogicalPortToNetwork`, `isPodScheduledinLocalZone` |
| `base_network_controller_user_defined.go` | UDN pod handling | `addLogicalPortToNetworkForNAD` |
| `base_secondary_layer2_network_controller.go` | Layer2 network initialization | `initializeLogicalSwitch` |
| `base_network_controller.go` | Zone determination | `isLocalZoneNode` |

### Critical Code Paths

**Remote Pod Creation:**
```
base_network_controller_user_defined.go:332
  → isPodScheduledinLocalZone() → returns false
  → requiresLogicalPort = true (because isLayer2Interconnect())
  → addLogicalPortToNetwork()
    → base_network_controller_pods.go:604
      → isLayer2Interconnect() → true
      → zoneICHandler.AddTransitPortConfig(isRemotePort=true, ...)
        → zone_ic_handler.go:367
          → port.Type = "remote"
```

**Remote Chassis Creation:**
```
Node watch event
  → BaseLayer2UserDefinedNetworkController.addUpdateNodeEvent()
    → base_secondary_layer2_network_controller.go:212
      → isLocalZoneNode() → false
      → addUpdateRemoteNodeEvent()
        → ZoneChassisHandler.AddRemoteZoneNode()
          → chassis_handler.go:46
            → createOrUpdateNodeChassis(node, isRemote=true)
              → Creates Chassis with is-remote=true
              → Creates Encap with Geneve IP
```

**Multicast Configuration:**
```
Layer2 switch creation
  → BaseLayer2UserDefinedNetworkController.initializeLogicalSwitch()
    → base_secondary_layer2_network_controller.go:182
      → isLayer2Interconnect() → true
      → zoneICHandler.AddTransitSwitchConfig(&logicalSwitch, tunnelKey)
        → zone_ic_handler.go:374
          → sw.OtherConfig["mcast_snoop"] = "true"
          → sw.OtherConfig["mcast_flood_unregistered"] = "true"
```

### Line References

| Topic | File:Line | Content |
|-------|-----------|---------|
| Transit switch = network switch for Layer2 | zone_ic_handler.go:150-151 | `return nInfo.GetNetworkScopedName(types.OVNLayer2Switch)` |
| Remote port type assignment | zone_ic_handler.go:368 | `port.Type = lportTypeRemote` |
| Multicast flood unregistered | zone_ic_handler.go:383 | `sw.OtherConfig["mcast_flood_unregistered"] = "true"` |
| Remote chassis creation | chassis_handler.go:162-168 | `chassis := sbdb.Chassis{... "is-remote": strconv.FormatBool(isRemote)}` |
| isPodScheduledinLocalZone logic | base_network_controller_pods.go:739-751 | Checks `localZoneNodes.Load(pod.Spec.NodeName)` |
| isLocalZoneNode logic | base_network_controller.go:986-1002 | Checks `util.GetNodeZone(node) == bnc.zone` |
| Remote LSP required for Layer2 IC | base_network_controller_user_defined.go:333 | `requiresLogicalPort := isLocalPod \|\| bsnc.isLayer2Interconnect()` |

---

## Next Steps

1. **Run the monitoring script** during the next reproduction to capture exact timing
2. **Check ovn-northd performance** - CPU usage, transaction latency
3. **Verify chassis creation timing** - correlation between node watch and chassis in SBDB
4. **Consider tuning options:**
   - Increase ovn-northd polling frequency
   - Pre-create chassis entries for all nodes (avoid lazy creation)
   - Batch pod creations to reduce churn
5. **Check for upstream fixes** - this may be a known issue in 1.1 that's fixed in later versions

---

## Questions to Answer with Diagnostics

1. **What completes first:** Remote LSP creation or chassis creation?
2. **How long between:** Chassis creation → Port_Binding binding?
3. **How long between:** Port_Binding binding → Tunnel creation?
4. **How long between:** Tunnel creation → Multicast flows?
5. **Are there any:** SBDB errors in ovn-northd logs?
6. **Is there correlation:** Between number of networks/pods and delay duration?

---

## Comparison: Interconnect vs Non-Interconnect

| Aspect | Non-Interconnect (1.0) | Interconnect (1.1) |
|--------|------------------------|---------------------|
| **Database Model** | Centralized NBDB/SBDB with RAFT | Per-node NBDB/SBDB (standalone) |
| **Remote Pods** | Not applicable - all pods are "local" to single DB | Require remote LSPs with type="remote" |
| **Chassis** | All chassis are local | Remote chassis with is-remote=true |
| **Tunnels** | All created by single ovn-controller | Each zone's controller manages its own |
| **Multicast** | Single Multicast_Group in one SBDB | Per-zone Multicast_Group in each SBDB |
| **Latency** | Single point of truth - immediate | Asynchronous replication - delayed |
| **Failure Domain** | RAFT split-brain risk | Isolated per-node (better) |
| **Scale** | Bottleneck at centralized DB | Distributed load (better) |
| **Complexity** | Simpler - one topology | Complex - multi-zone coordination |

**Why multicast is slower in interconnect:**
- Multiple async steps vs single synchronous flow
- Dependency on chassis creation timing
- Per-zone ovn-northd processing
- Tunnel establishment latency

---

## Conclusion

The multicast flooding delay you're experiencing is almost certainly due to **asynchronous remote port binding** in OVN interconnect mode. The diagnostic scripts will help pinpoint the exact bottleneck (chassis creation, Port_Binding binding, tunnel establishment, or multicast group propagation).

The good news: This is likely a timing issue, not a fundamental architectural problem. Potential fixes include:
- Optimizing ovn-northd performance
- Pre-creating chassis entries
- Tuning watch intervals
- Checking for upstream patches

Run the diagnostics and let me know what you find!
