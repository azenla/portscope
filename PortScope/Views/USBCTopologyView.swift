//
//  USBCTopologyView.swift
//  PortScope
//
//  USB-C topology viewer. Renders host routers (one per Apple TB
//  controller), device routers daisy-chained under them, the adapters
//  inside each router, and the active tunnels carrying traffic between
//  them — every USB-C receptacle's fabric in one window.
//
//  Reference: Microsoft's Windows Device Portal USB4 view
//  (https://learn.microsoft.com/en-us/windows-hardware/design/component-
//  guidelines/usb4-windows-device-portal). The Microsoft layout puts
//  host routers in green, device routers in blue, draws adapters as
//  in-router pills, and gives each tunnel a path identifier built from
//  the adapter port numbers it traverses ("8:1:1:9"). We mirror the
//  same conventions but render the path with arrows ("P8 → P1 → P9").
//
//  Built on top of the existing `SystemSnapshot.tb` data — no new
//  scanning, just a different presentation of the IOThunderboltSwitch /
//  IOThunderboltPort tree.
//

import SwiftUI

// MARK: - Selection model

/// One thing in the diagram can be selected at a time; the sidebar reads
/// off this enum to decide what to render. Identifier is a TBNodeID so
/// the selection survives a snapshot refresh as long as the underlying
/// IORegistry entry is still around.
enum DTTSelection: Hashable {
    case mac                      // the central Mac hub — host-wide summary
    case hostRouter(TBNodeID)
    case deviceRouter(TBNodeID)
    case adapter(TBNodeID)
    case tunnel(TBNodeID)  // keyed by the function adapter that anchors the tunnel
    case usbDevice(TBNodeID)      // a USB hub or leaf device in the downstream tree
    case display(TBNodeID)        // an attached external display
    case pcie(TBNodeID)           // a tunneled PCIe endpoint
}

// MARK: - Topology model (built once per render from the snapshot)

/// Snapshot of the USB4 fabric in a shape that's easy to render. Built
/// from `SystemSnapshot.tb` once when the view body evaluates; not held
/// as state.
private struct DTTModel {
    let hostRouters: [HostRouter]

    /// Total active tunnels across all routers (host-side + device-side
    /// double-count is avoided by keying on the function adapter).
    var tunnelCount: Int {
        var count = 0
        for h in hostRouters { count += h.totalTunnels }
        return count
    }
    /// Total routers — host routers plus everything reachable via the
    /// downstream tree.
    var routerCount: Int {
        var count = hostRouters.count
        for h in hostRouters {
            if let d = h.downstream { count += d.totalRouterCount }
        }
        return count
    }
}

private struct HostRouter: Identifiable {
    let id: TBNodeID
    let controller: TBNode      // IOThunderboltController*
    let switchNode: TBNode      // IOThunderboltSwitch* at depth 0
    let title: String           // e.g. "Host Router 1"
    let socketID: String?       // physical TB port number (Socket ID)
    let adapters: [Adapter]
    let downstream: DeviceRouter?   // first-hop device router, if anything is attached
    /// Thunderbolt-networking peer attached to this controller, when no
    /// downstream router is present. XDomain peers (Mac↔Mac, Mac↔Linux/PC
    /// TB Bridge) don't publish an `IOThunderboltSwitch` so they're
    /// invisible to the device-router probe; we surface them as their
    /// own card under the host instead.
    let peer: ThunderboltPeer?

    /// Active tunnels reachable from this host router (depth ≥ 1).
    var totalTunnels: Int {
        downstream?.totalTunnels ?? 0
    }
}

private struct DeviceRouter: Identifiable {
    let id: TBNodeID
    let switchNode: TBNode
    let title: String           // vendor + model when known
    let vendorName: String?
    let modelName: String?
    let depth: UInt64
    let routeString: UInt64?
    let uid: UInt64?
    let firmware: String?
    let adapters: [Adapter]
    let tunnels: [Tunnel]       // tunnels rooted on this router's function adapters
    let daisyChained: [DeviceRouter]
    /// Displays attached to this router's DP/HDMI tunnels. Each is
    /// rendered as a separate downstream block (not as a leaf inside
    /// the router card) so the graph reads top-down: router → output
    /// → display.
    let displays: [DisplayLeaf]
    /// USB subtree tunneled through this router. Hubs are kept as
    /// nodes with children — the topology view always shows the
    /// full hub chain regardless of the global Show Intermediate
    /// Hubs setting (which only affects the sidebar / CLI).
    let usbTree: [USBNode]
    /// PCIe endpoints tunneled through this router. Rare on Apple
    /// Silicon docks (storage usually tunnels over USB) but kept
    /// for completeness.
    let pcieLeaves: [PCIeLeaf]

    var totalTunnels: Int {
        tunnels.count + daisyChained.reduce(0) { $0 + $1.totalTunnels }
    }
    var totalRouterCount: Int {
        1 + daisyChained.reduce(0) { $0 + $1.totalRouterCount }
    }
}

/// Recursive USB node — covers both hub services (with downstream
/// children) and leaf devices (mice / keyboards / storage / NICs).
private struct USBNode: Identifiable, Hashable {
    let id: TBNodeID
    let title: String
    let subtitle: String?
    let symbol: String          // SF Symbol picked from device class
    let isHub: Bool
    let children: [USBNode]
    /// The backing IORegistry node, kept so the inspector can render a
    /// curated USB summary plus the full raw property table when the
    /// user clicks a device in the topology.
    let node: TBNode
}

/// One external display block attached to a DP/HDMI tunnel.
private struct DisplayLeaf: Identifiable, Hashable {
    let id: TBNodeID
    let title: String
    let subtitle: String?       // "2560 × 1440 · 120 Hz"
}

/// One PCIe endpoint tunneled through a router.
private struct PCIeLeaf: Identifiable, Hashable {
    let id: TBNodeID
    let title: String
    let subtitle: String?
}

private struct Adapter: Identifiable, Hashable {
    let id: TBNodeID
    let portNumber: UInt64
    let description: String     // raw kernel `Description`
    let kind: AdapterKind
    let node: TBNode
    let isTunnelActive: Bool    // function adapter with non-empty Hop Table
    let currentLinkSpeed: UInt64
    let currentLinkWidth: UInt64
    let linkBandwidth: UInt64
    let requiredBandwidth: UInt64
    let maxBandwidth: UInt64
    /// Physical chassis port number (USB-C receptacle 1, 2, 3 on this
    /// Mac). Only meaningful for host-side lane adapters — the kernel
    /// only publishes `Socket ID` there.
    let socketID: String?
    /// Lane port number that carries this adapter's tunnel out of the
    /// router. Decoded from `Hop Table[0].Dst Port`. Nil when the
    /// adapter isn't tunneling. Lets the chip show "→ via P1" so the
    /// user can see which lane is doing the work.
    let routedViaPort: UInt64?
    /// True when this lane adapter is the upstream-facing one (i.e.
    /// the cable terminates here). Only set on device-side routers
    /// where the kernel publishes `Upstream Port Number` on the
    /// switch. Used to label the cable-bearing lane with "↑ cable".
    let isUpstreamLane: Bool
}

private enum AdapterKind: Hashable {
    case lane           // "Thunderbolt Port" — TB lane adapter
    case nhi            // "Thunderbolt Native Host Interface Adapter"
    case dp             // "DP or HDMI Adapter"
    case usb            // "USB Adapter" / "USB Gen T Adapter"
    case pcie           // "PCIe Adapter"
    case inactive       // "Port is inactive"
    case other(String)

    var label: String {
        switch self {
        case .lane: return "Lane"
        case .nhi: return "NHI"
        case .dp: return "DP/HDMI"
        case .usb: return "USB"
        case .pcie: return "PCIe"
        case .inactive: return "Inactive"
        case .other(let s): return s
        }
    }
    var icon: String {
        switch self {
        case .lane: return "bolt.horizontal"
        case .nhi: return "cpu"
        case .dp: return "display"
        case .usb: return "cable.connector"
        case .pcie: return "square.stack.3d.up"
        case .inactive: return "circle.dashed"
        case .other: return "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .lane: return .orange
        case .nhi: return .purple
        case .dp: return .blue
        case .usb: return .teal
        case .pcie: return .green
        case .inactive: return .secondary
        case .other: return .secondary
        }
    }
}

private struct Tunnel: Identifiable, Hashable {
    let id: TBNodeID            // function-adapter's TBNodeID anchors the tunnel
    let kind: AdapterKind       // matches the adapter's kind
    let pathID: String          // arrow-separated port-number path ("P8 → P1 → P9")
    let reservedBW: UInt64      // 100 Mb/s units
    let maxBW: UInt64
    let hopCount: Int           // length of the Hop Table
}

// MARK: - Topology builder

private enum DTTBuilder {
    static func build(from snapshot: SystemSnapshot) -> DTTModel {
        var hosts: [HostRouter] = []
        // TB-tunneled PCIe endpoints live in `snapshot.pcie` under the
        // "Thunderbolt PCIe Slot N" roots, paired to controllers by
        // registry-ID lockstep — `tb.pcieDevicesOverTB` is structurally
        // empty on Apple Silicon.
        let pcieSlots = pcieSlotMap(controllers: snapshot.tb.controllers,
                                    pcieRoots: snapshot.pcie.roots)
        for (idx, controller) in snapshot.tb.controllers.enumerated() {
            guard let hostSwitch = findHostSwitch(in: controller) else { continue }
            let adapters = adapterList(of: hostSwitch)
            // Each host router is anchored on its corresponding TB
            // controller. The "Socket ID" on a depth-0 lane adapter is
            // the physical port number (1, 2, 3 on a MacBook Pro), so
            // we use the first lane adapter's Socket ID as the
            // controller's identity hint.
            let socketID = adapters
                .first { $0.kind == .lane }?
                .node.properties["Socket ID"]?.asString
            // USB attribution: the dock's USB peripherals enumerate
            // under the host's matching `usb-drd<N>` controller, not
            // under the dock's TB switch (see CLAUDE.md "USB devices
            // on a TB-tunneled dock are NOT children of the dock's TB
            // switch"). Match by chassis socket: usb-drd<N>'s
            // locationID top byte equals the lane adapter's Socket ID.
            //
            // We need the downstream device router's title up front so
            // we can filter its self-advertising USB hub entry out of
            // the leaves — pre-probe the switch tree without building
            // the device router yet.
            let downstreamSwitchTitle = previewDeviceRouterTitle(in: hostSwitch)
            let usbTree = collectUSBTreeForSocket(socketID,
                                                  snapshot: snapshot,
                                                  deviceTitle: downstreamSwitchTitle)
            let pcieLeaves = collectPCIeBlocks(snapshot: snapshot,
                                               slot: pcieSlots[controller.id])
            let downstream = findFirstDeviceRouter(in: hostSwitch,
                                                   snapshot: snapshot,
                                                   usbTree: usbTree,
                                                   pcieLeaves: pcieLeaves,
                                                   upstreamAdapters: adapters)
            // TB-networking peers (XDomain) don't publish a switch, so
            // they slip past the device-router probe. Surface them as a
            // sibling slot on the host router. We only look when there's
            // no downstream router — a peer behind a dock would be a
            // rare daisy-chain case and the current renderer wouldn't
            // know where to put it anyway.
            let peer: ThunderboltPeer? = downstream == nil
                ? findThunderboltPeer(in: controller)
                : nil
            hosts.append(HostRouter(
                id: hostSwitch.id,
                controller: controller,
                switchNode: hostSwitch,
                title: "Host Router \(idx + 1)",
                socketID: socketID,
                adapters: adapters,
                downstream: downstream,
                peer: peer
            ))
        }
        return DTTModel(hostRouters: hosts)
    }

    /// Find the depth-0 `IOThunderboltSwitch` somewhere under the
    /// controller — the "Mac Host Router". The kernel doesn't publish
    /// it as a direct child of the controller; it's nested several
    /// levels down through wrapper kexts (HAL / IPService /
    /// LocalNode-adjacent objects), and the exact path depends on the
    /// controller generation. Recurse the whole subtree and stop at
    /// the first switch we find with `Depth = 0`.
    private static func findHostSwitch(in controller: TBNode) -> TBNode? {
        return firstSwitch(in: controller, exactDepth: 0)
    }

    private static func firstSwitch(in node: TBNode, exactDepth: UInt64) -> TBNode? {
        if node.kind == .switch,
           (node.properties["Depth"]?.asUInt ?? 0) == exactDepth {
            return node
        }
        for c in node.children {
            if let s = firstSwitch(in: c, exactDepth: exactDepth) { return s }
        }
        return nil
    }

    /// Find the first downstream switch (depth ≥ 1) reachable from
    /// `parent`. The device switch is published nested inside one of
    /// the host switch's lane ports (the kernel mirrors the cable's
    /// two ends as a host-side port wrapping a device-side port
    /// wrapping the device's switch), so we recurse rather than just
    /// look at direct children.
    private static func findFirstDeviceRouter(in parent: TBNode,
                                              snapshot: SystemSnapshot,
                                              usbTree: [USBNode],
                                              pcieLeaves: [PCIeLeaf],
                                              upstreamAdapters: [Adapter]) -> DeviceRouter? {
        if let (lane, s) = findSwitchWithParent(
            in: parent,
            minDepth: (parent.properties["Depth"]?.asUInt ?? 0) + 1) {
            return makeDeviceRouter(switchNode: s,
                                    upstreamLane: lane,
                                    snapshot: snapshot,
                                    usbTree: usbTree,
                                    pcieLeaves: pcieLeaves,
                                    upstreamAdapters: upstreamAdapters)
        }
        return nil
    }

    /// Walk the tree under `node` and return the first IOThunderboltSwitch
    /// whose `Depth` is ≥ `minDepth`. We stop at the first one because
    /// each lane port wraps at most one downstream router; deeper
    /// daisy-chained routers will be picked up by the recursion in
    /// `makeDeviceRouter`.
    private static func findSwitch(in node: TBNode, minDepth: UInt64) -> TBNode? {
        findSwitchWithParent(in: node, minDepth: minDepth)?.switchNode
    }

    /// Like `findSwitch`, but also captures the lane port immediately
    /// wrapping the switch — the cable-bearing *upstream* lane. The kernel
    /// publishes a device router's upstream lane as the PARENT of the
    /// device switch (host lane → device-side peer lane → switch), never
    /// as one of the switch's children, so `adapterList(of: switchNode)`
    /// can never see it. Same approach as `TopologyMapper.findDownstreamLink`.
    private static func findSwitchWithParent(in node: TBNode, minDepth: UInt64)
        -> (upstreamLane: TBNode?, switchNode: TBNode)?
    {
        if node.kind == .switch,
           (node.properties["Depth"]?.asUInt ?? 0) >= minDepth {
            return (nil, node)
        }
        for c in node.children {
            if let found = findSwitchWithParent(in: c, minDepth: minDepth) {
                if found.upstreamLane == nil,
                   node.kind == .port,
                   node.properties["Description"]?.asString == "Thunderbolt Port" {
                    // We are the immediate lane wrapper of the switch.
                    return (node, found.switchNode)
                }
                return found
            }
        }
        return nil
    }

    private static func makeDeviceRouter(switchNode: TBNode,
                                         upstreamLane: TBNode?,
                                         snapshot: SystemSnapshot,
                                         usbTree: [USBNode],
                                         pcieLeaves: [PCIeLeaf],
                                         upstreamAdapters: [Adapter]) -> DeviceRouter {
        var adapters = adapterList(of: switchNode)
        // The cable-bearing upstream lane is the kernel's *parent* of the
        // device switch, never a child, so adapterList can't see it.
        // Inject it with its authoritative numbers (Link Bandwidth /
        // reservations live there — the in-switch mirror lane reports 0)
        // so the "↑ cable" chip renders and CableConnector reads real
        // bandwidth.
        if let lane = upstreamLane,
           !adapters.contains(where: { $0.id == lane.id }) {
            let p = lane.properties
            adapters.append(Adapter(
                id: lane.id,
                portNumber: p["Port Number"]?.asUInt ?? 0,
                description: p["Description"]?.asString ?? "Thunderbolt Port",
                kind: .lane,
                node: lane,
                isTunnelActive: tbLaneLinkUp(props: p,
                                             childCount: lane.children.count),
                currentLinkSpeed: p["Current Link Speed"]?.asUInt ?? 0,
                currentLinkWidth: p["Current Link Width"]?.asUInt ?? 0,
                linkBandwidth: p["Link Bandwidth"]?.asUInt ?? 0,
                requiredBandwidth: p["Required Bandwidth Allocated"]?.asUInt ?? 0,
                maxBandwidth: p["Maximum Bandwidth Allocated"]?.asUInt ?? 0,
                socketID: p["Socket ID"]?.asString,
                routedViaPort: nil,
                isUpstreamLane: true
            ))
            adapters.sort { $0.portNumber < $1.portNumber }
        }
        let tunnels = tunnelList(adapters: adapters, upstream: upstreamAdapters)
        var daisy: [DeviceRouter] = []
        let myDepth = switchNode.properties["Depth"]?.asUInt ?? 0
        // Daisy-chained docks sit inside one of *this* router's lane
        // ports — same wrapping pattern as the host→device cable
        // mirror. Walk the subtree and pick up every switch strictly
        // deeper than us. Each lane port yields at most one child
        // switch; the recursive `makeDeviceRouter` rebuilds the
        // sub-tree from there.
        for c in switchNode.children {
            if c.kind == .switch { continue }   // already this router
            if let (lane, s) = findSwitchWithParent(in: c, minDepth: myDepth + 1) {
                // Daisy-chained docks share the same host-side
                // chassis port, so they pull USB leaves from the
                // same pool the parent router was given. Their
                // upstream adapters are this router's (placeholder
                // numbers — tunnelList falls back to the gate).
                daisy.append(makeDeviceRouter(switchNode: s,
                                              upstreamLane: lane,
                                              snapshot: snapshot,
                                              usbTree: usbTree,
                                              pcieLeaves: pcieLeaves,
                                              upstreamAdapters: adapters))
            }
        }
        // The first-hop router on the cable gets the USB tree we
        // pre-built from the host's matching usb-drd controller.
        // Daisy-chained children pass it through (see comment above);
        // a more accurate split would partition by hop-table Depth
        // Class but for an MVP each chained dock sees the full set.
        // Only attribute the tree to depth-1 routers so we don't
        // double-render the same devices on a chain.
        let attributedUSB = myDepth == 1 ? usbTree : []
        let attributedDisplays = myDepth == 1
            ? collectDisplayBlocks(snapshot: snapshot,
                                   adapters: adapters)
            : []
        let attributedPCIe = myDepth == 1 ? pcieLeaves : []
        let vendor = switchNode.properties["Device Vendor Name"]?.asString
        let model = switchNode.properties["Device Model Name"]?.asString
        let title: String
        switch (vendor, model) {
        case (let v?, let m?): title = "\(v) \(m)"
        case (nil, let m?): title = m
        case (let v?, nil): title = v
        default: title = "Thunderbolt Device"
        }
        return DeviceRouter(
            id: switchNode.id,
            switchNode: switchNode,
            title: title,
            vendorName: vendor,
            modelName: model,
            depth: switchNode.properties["Depth"]?.asUInt ?? 1,
            routeString: switchNode.properties["Route String"]?.asUInt,
            uid: switchNode.properties["UID"]?.asUInt,
            firmware: switchNode.properties["Firmware Version"]?.asString,
            adapters: adapters,
            tunnels: tunnels,
            daisyChained: daisy,
            displays: attributedDisplays,
            usbTree: attributedUSB,
            pcieLeaves: attributedPCIe
        )
    }

    // The kernel's `Thunderbolt Version` BCD is deliberately NOT decoded
    // into a "USB4 Spec X.Y" label — Apple maps the high nibble loosely
    // on TB5 hardware and the result is misleading (DiagramView dropped
    // the same field for the same reason).

    /// Pull every `IOThunderboltPort` directly under a switch and turn
    /// it into a typed `Adapter`. Children of the switch that aren't
    /// ports (other switches, IPService, etc.) are skipped.
    private static func adapterList(of switchNode: TBNode) -> [Adapter] {
        var out: [Adapter] = []
        // Upstream port number is published on the switch itself —
        // identifies which lane port the cable enters this router
        // through. Lets device-side lane adapters show "↑ cable".
        // (On Apple Silicon the upstream lane is usually the *parent*
        // of the switch — injected by `makeDeviceRouter` — but some
        // controller generations publish it as a child, so keep the
        // match.) Depth-gated: a depth-0 host root has no upstream cable.
        let depth = switchNode.properties["Depth"]?.asUInt ?? 0
        let upstreamPort = depth > 0
            ? switchNode.properties["Upstream Port Number"]?.asUInt
            : nil
        for c in switchNode.children where c.kind == .port {
            let portN = c.properties["Port Number"]?.asUInt ?? 0
            let desc = c.properties["Description"]?.asString ?? ""
            let kind = adapterKind(description: desc)
            let speed = c.properties["Current Link Speed"]?.asUInt ?? 0
            let width = c.properties["Current Link Width"]?.asUInt ?? 0
            let linkBW = c.properties["Link Bandwidth"]?.asUInt ?? 0
            let reqBW = c.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
            let maxBW = c.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
            let isUpstreamLane = (kind == .lane)
                && (upstreamPort != nil)
                && (upstreamPort == portN)
            // A function adapter (DP/USB/PCIe) is "tunneling" when it
            // has a non-empty Hop Table. Lane adapters need a live-peer
            // signal beyond Current Link Speed — a device router's empty
            // downstream lanes publish idle defaults (CLS=8 / LBW=100)
            // that would render as active TB3 links (see `tbLaneLinkUp`).
            // A child lane matching the switch's upstream port number is
            // up by definition when the switch itself is connected.
            let isActiveTunnel: Bool = {
                if case .lane = kind {
                    return isUpstreamLane
                        || tbLaneLinkUp(props: c.properties,
                                        childCount: c.children.count)
                }
                if case .nhi = kind { return false }
                if case .inactive = kind { return false }
                if case .array(let arr) = c.properties["Hop Table"] {
                    return !arr.isEmpty
                }
                return false
            }()
            // For function adapters with a live tunnel, the Hop Table's
            // first entry's Dst Port is the lane port that carries this
            // tunnel out of the router. For lane adapters it's nil.
            let routedVia: UInt64? = {
                guard isActiveTunnel else { return nil }
                switch kind {
                case .dp, .usb, .pcie:
                    return firstHopDstPort(c)
                default:
                    return nil
                }
            }()
            out.append(Adapter(
                id: c.id,
                portNumber: portN,
                description: desc,
                kind: kind,
                node: c,
                isTunnelActive: isActiveTunnel,
                currentLinkSpeed: speed,
                currentLinkWidth: width,
                linkBandwidth: linkBW,
                requiredBandwidth: reqBW,
                maxBandwidth: maxBW,
                socketID: c.properties["Socket ID"]?.asString,
                routedViaPort: routedVia,
                isUpstreamLane: isUpstreamLane
            ))
        }
        return out.sorted { $0.portNumber < $1.portNumber }
    }

    /// Read `Hop Table[0].Dst Port` — the lane port that an active
    /// function adapter routes its tunnel through.
    private static func firstHopDstPort(_ port: TBNode) -> UInt64? {
        guard case let .array(arr) = port.properties["Hop Table"],
              case let .dictionary(kv) = arr.first else { return nil }
        let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
        return d["Dst Port"]?.asUInt
    }

    /// One `Tunnel` per active function adapter on the router. No
    /// attached leaves — those live on the device router as
    /// separately laid-out blocks (`displays`, `usbTree`,
    /// `pcieLeaves`).
    ///
    /// Device-side function adapters publish placeholder reservations
    /// (DP: Required = Maximum = 1 = 100 Mb/s) on live tunnels. The
    /// authoritative numbers live on the matching *upstream-side*
    /// function adapter (the host root for a first-hop dock); same-kind
    /// active adapters are paired in port-number order, consuming each
    /// upstream adapter once. When no real upstream number resolves
    /// (e.g. daisy-chained routers whose upstream is itself a device
    /// router), the existing `max(required, max) >= 10` placeholder
    /// gate applies and the tunnel renders as "Active" with no number
    /// (reserved/max forced to 0).
    private static func tunnelList(adapters: [Adapter],
                                   upstream: [Adapter]) -> [Tunnel] {
        var upstreamByKind: [AdapterKind: [Adapter]] = [:]
        for u in upstream where u.isTunnelActive {
            switch u.kind {
            case .dp, .usb, .pcie:
                upstreamByKind[u.kind, default: []].append(u)
            default:
                break
            }
        }
        upstreamByKind = upstreamByKind.mapValues {
            $0.sorted { $0.portNumber < $1.portNumber }
        }
        var consumed: [AdapterKind: Int] = [:]

        var out: [Tunnel] = []
        for a in adapters where a.isTunnelActive {
            switch a.kind {
            case .lane, .nhi, .inactive, .other:
                continue   // not a function-adapter tunnel
            default:
                break
            }
            // Consume the next unclaimed same-kind upstream adapter so
            // multi-tunnel classes (two DP streams) stay index-aligned.
            let idx = consumed[a.kind] ?? 0
            consumed[a.kind] = idx + 1
            let candidates = upstreamByKind[a.kind] ?? []
            let match: Adapter? = idx < candidates.count ? candidates[idx] : nil

            var reserved = a.requiredBandwidth
            var maxBW = a.maxBandwidth
            if max(reserved, maxBW) < 10 {
                if let m = match,
                   max(m.requiredBandwidth, m.maxBandwidth) >= 10 {
                    reserved = m.requiredBandwidth
                    maxBW = m.maxBandwidth
                } else {
                    reserved = 0
                    maxBW = 0
                }
            }

            let hops = hopTableEntries(a.node)
            let pathID = ([a.portNumber] + hops.map { $0.dstPort })
                .map { "P\($0)" }
                .joined(separator: " → ")
            out.append(Tunnel(
                id: a.id,
                kind: a.kind,
                pathID: pathID,
                reservedBW: reserved,
                maxBW: maxBW,
                hopCount: hops.count
            ))
        }
        return out.sorted { lhs, rhs in
            let order: (AdapterKind) -> Int = { k in
                switch k {
                case .dp: return 0
                case .usb: return 1
                case .pcie: return 2
                default: return 3
                }
            }
            if order(lhs.kind) != order(rhs.kind) {
                return order(lhs.kind) < order(rhs.kind)
            }
            return lhs.pathID < rhs.pathID
        }
    }

    /// Find the dock's USB peripherals via the host-side chassis
    /// socket they share. On Apple Silicon the dock's USB devices
    /// enumerate under the host's `usb-drd<N>` controller — same
    /// kernel object a directly attached USB device would land in.
    ///
    /// Mapping: per CLAUDE.md "TopologyMapper.usbDevicesByPort maps
    /// each usb-drd<N> to a physical port via locationID >> 24 (drd0
    /// → Port 1, etc.)". So drd0 has locationID top byte = 0 but
    /// serves chassis Socket 1; drd1 → Socket 2; drd2 → Socket 3.
    /// The off-by-one used to defeat the match — the matcher now
    /// expects `topByte + 1 == socket`.
    ///
    /// `deviceTitle` lets the matcher filter out the dock's own
    /// self-advertising USB hub entries (the dock typically enumerates
    /// itself as a USB device named "Anker Prime Docking Station"
    /// under its own USB tree, which would otherwise appear as a
    /// leaf under its own card).
    ///
    /// Filtered to `usb-drd*` controllers only (skips the internal
    /// `usb-auss` controller that drives the FaceTime camera /
    /// internal USB — its locationID doesn't follow the per-port
    /// encoding).
    ///
    /// Returns an empty list when the socket ID isn't parseable or
    /// when no controllers match — e.g. on hosts where the user has
    /// nothing plugged into the corresponding receptacle.
    /// Build the USB subtree behind the host's chassis socket as a
    /// recursive `USBNode` structure. Unlike the legacy flat-list
    /// version (which served the now-removed `TunnelLeaf` model),
    /// this keeps hubs as nodes with children so the topology
    /// view can render the full hub-of-hubs chain. The global
    /// "Show Intermediate Hubs" toggle has no effect here — the
    /// detailed topology always wants the complete tree.
    private static func collectUSBTreeForSocket(_ socketID: String?,
                                                snapshot: SystemSnapshot,
                                                deviceTitle: String?)
        -> [USBNode]
    {
        guard let socketStr = socketID, let socket = UInt64(socketStr) else {
            return []
        }
        var out: [USBNode] = []
        for controller in snapshot.usb.controllers {
            let nameMatch = controller.properties["IONameMatched"]?.asString
                ?? controller.properties["IONameMatch"]?.asString ?? ""
            guard nameMatch.hasPrefix("usb-drd") else { continue }
            guard let loc = controller.properties["locationID"]?.asUInt else { continue }
            let topByte = (loc >> 24) & 0xFF
            guard topByte + 1 == socket else { continue }
            out.append(contentsOf: buildUSBSubtree(under: controller,
                                                   deviceTitle: deviceTitle))
        }
        return out
    }

    /// Walk a USB subtree and produce typed `USBNode`s. Hubs become
    /// nodes with children populated by recursing. Billboard
    /// descriptors and dock self-references are skipped but their
    /// children (rare) are spliced into the parent's child list so
    /// nothing real is lost.
    private static func buildUSBSubtree(under node: TBNode,
                                        deviceTitle: String?) -> [USBNode] {
        var out: [USBNode] = []
        for child in node.children {
            switch child.kind {
            case .usbHub:
                let kids = buildUSBSubtree(under: child,
                                           deviceTitle: deviceTitle)
                out.append(USBNode(
                    id: child.id,
                    title: hubTitle(child),
                    subtitle: usbSubtitle(child),
                    symbol: "rectangle.3.group",
                    isHub: true,
                    children: kids,
                    node: child
                ))
            case .usbDevice:
                let t = child.title.lowercased()
                if t.contains("billboard") {
                    // Billboard descriptors carry alt-mode metadata,
                    // not a real peripheral. Skip but splice their
                    // children up just in case.
                    out.append(contentsOf:
                        buildUSBSubtree(under: child,
                                        deviceTitle: deviceTitle))
                } else if isDockSelfReference(child, deviceTitle: deviceTitle) {
                    out.append(contentsOf:
                        buildUSBSubtree(under: child,
                                        deviceTitle: deviceTitle))
                } else {
                    let kids = buildUSBSubtree(under: child,
                                               deviceTitle: deviceTitle)
                    out.append(USBNode(
                        id: child.id,
                        title: child.title,
                        subtitle: usbSubtitle(child),
                        symbol: usbSymbol(for: child),
                        isHub: false,
                        children: kids,
                        node: child
                    ))
                }
            case .usbController, .usbInterface, .other:
                // Wrapper kexts (XHCI port wrappers, interface stubs,
                // Apple's `.other` USB port classes) get spliced
                // through so their devices show under the actual
                // hub above them, not under a meaningless wrapper.
                out.append(contentsOf:
                    buildUSBSubtree(under: child, deviceTitle: deviceTitle))
            default:
                continue
            }
        }
        return out
    }

    /// Friendly title for a hub — "USB 3.0 Hub" / "USB 2.0 Hub" /
    /// "Anker Prime Docking Station Hub" / etc.
    private static func hubTitle(_ node: TBNode) -> String {
        // Prefer the product string the device publishes. Fall back
        // to a class-derived label.
        if let product = node.properties["kUSBProductString"]?.asString
            ?? node.properties["USB Product Name"]?.asString,
           !product.isEmpty {
            return product
        }
        return node.title.isEmpty ? "USB Hub" : node.title
    }

    /// Pre-probe a host switch's subtree to extract the downstream
    /// device router's title without doing the full DeviceRouter
    /// build. Used so USB leaf collection can filter out the dock's
    /// own self-advertising USB hub entries before the device router
    /// model is constructed. Returns nil when no device is attached.
    private static func previewDeviceRouterTitle(in hostSwitch: TBNode) -> String? {
        let minDepth = (hostSwitch.properties["Depth"]?.asUInt ?? 0) + 1
        guard let s = findSwitch(in: hostSwitch, minDepth: minDepth) else {
            return nil
        }
        let vendor = s.properties["Device Vendor Name"]?.asString
        let model = s.properties["Device Model Name"]?.asString
        return [vendor, model].compactMap { $0 }.joined(separator: " ")
    }


    /// Decide whether a USB device entry is the dock's own
    /// self-advertising hub. Three signals — any one is enough:
    ///
    /// * Its title (product string) contains "Docking Station" AND
    ///   shares a substantial token with the dock router's name
    ///   ("Anker", "CalDigit", "Kensington", etc).
    /// * Its title contains the literal dock router title (e.g.
    ///   "Anker Thunderbolt 5 Docking Station" pass-through).
    /// * Its vendor string indicates a hub chip vendor ("VIA Labs",
    ///   "Genesys Logic") AND the title contains "Docking" — those
    ///   are dock-internal hub chips advertising as devices.
    private static func isDockSelfReference(_ node: TBNode,
                                            deviceTitle: String?) -> Bool {
        guard let deviceTitle, !deviceTitle.isEmpty else { return false }
        let title = node.title
        let lowerTitle = title.lowercased()
        let dockTitle = deviceTitle.lowercased()
        let hubChipVendors = ["via labs", "genesys logic", "genesyslogic", "asmedia"]
        let vendor = (node.properties["kUSBVendorString"]?.asString
            ?? node.properties["USB Vendor Name"]?.asString
            ?? "").lowercased()
        let isHubChip = hubChipVendors.contains { vendor.contains($0) }
        let mentionsDocking = lowerTitle.contains("docking")
            || lowerTitle.contains(" dock")
        if isHubChip && mentionsDocking { return true }
        // Token-based match: the dock's title typically reads
        // "Vendor Model (qualifier)". Take the first vendor token
        // and check if both the leaf's title and the dock's title
        // share it (e.g. "Anker").
        let dockFirstToken = dockTitle.split(separator: " ").first.map(String.init) ?? ""
        if !dockFirstToken.isEmpty, dockFirstToken.count >= 3,
           lowerTitle.contains(dockFirstToken), mentionsDocking {
            return true
        }
        return false
    }

    /// Pick a friendlier SF Symbol per USB device class. The kernel
    /// publishes `bDeviceClass` reliably for HID + storage; for
    /// vendor-specific (0xFF) the title's a better signal than the
    /// class code. Falls back to the generic cable icon.
    private static func usbSymbol(for node: TBNode) -> String {
        let title = node.title.lowercased()
        if title.contains("keyboard") { return "keyboard" }
        if title.contains("mouse") || title.contains("trackpad") {
            return "computermouse"
        }
        if title.contains("lan") || title.contains("ethernet")
            || title.contains("network") {
            return "network"
        }
        if title.contains("storage") || title.contains("ssd")
            || title.contains("disk") || title.contains("drive") {
            return "externaldrive"
        }
        if title.contains("audio") || title.contains("dac")
            || title.contains("headphone") {
            return "headphones"
        }
        if title.contains("camera") || title.contains("webcam") {
            return "camera"
        }
        if title.contains("av adapter") || title.contains("hdmi")
            || title.contains("displayport") {
            return "tv"
        }
        if title.contains("dock") {
            return "shippingbox"
        }
        // Fall back to the bDeviceClass — HID class is the most
        // common useful one.
        if let cls = node.properties["bDeviceClass"]?.asUInt {
            switch cls {
            case 0x03: return "keyboard"              // HID
            case 0x08: return "externaldrive"         // Mass Storage
            case 0x09: return "rectangle.3.group"     // Hub (shouldn't reach here)
            case 0x0E: return "video"                 // Video
            default: break
            }
        }
        return "cable.connector"
    }

    private static func usbSubtitle(_ node: TBNode) -> String? {
        var parts: [String] = []
        if let vendor = node.properties["kUSBVendorString"]?.asString
            ?? node.properties["USB Vendor Name"]?.asString,
           !vendor.isEmpty, vendor != node.title,
           !isPlaceholderVendor(vendor) {
            parts.append(vendor)
        }
        // Use the device's declared protocol version (bcdUSB) rather
        // than the kernel's negotiated `Device Speed`. The negotiated
        // value reports "Full Speed → USB 1.1" for HID devices (mice
        // / keyboards), which is technically correct but reads as
        // "ancient hardware" to users. The declared bcdUSB ("USB
        // 2.0", "USB 3.2") is the device's nominal protocol class,
        // which is what users mean when they ask "what kind of USB
        // device is this". Version-only label — bcdUSB doesn't encode
        // the Gen/lane ceiling, so no speed claim is rendered.
        if let bcd = node.properties["bcdUSB"]?.asUInt,
           let declared = usbDeclaredVersionLabel(bcd) {
            parts.append(declared)
        } else if let speed = node.properties["Device Speed"]?.asUInt
            ?? node.properties["kUSBCurrentSpeed"]?.asUInt,
                  speed > 0 {
            parts.append(usbSpeedShortLabel(speed))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Some USB devices publish placeholder / redacted vendor
    /// strings (Apple's Type-C Digital AV Adapter literally
    /// publishes "xxxxxxxx"). Suppress those so they don't show
    /// up as a confusing subtitle.
    private static func isPlaceholderVendor(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        // String of x's — Apple's redaction placeholder.
        if trimmed.allSatisfy({ $0 == "x" || $0 == "X" }) { return true }
        // Anything purely "?" / "-" / dashes is also non-information.
        let placeholderChars: Set<Character> = ["?", "-", "_", "•"]
        if trimmed.allSatisfy({ placeholderChars.contains($0) }) { return true }
        return false
    }

    /// External displays attached to this device router's active
    /// DP/HDMI adapters. Currently uses a simple global pull — every
    /// connected external display is attributed to depth-1 routers.
    /// Good enough for single-dock setups; a multi-dock case would
    /// need per-adapter attribution.
    private static func collectDisplayBlocks(snapshot: SystemSnapshot,
                                             adapters: [Adapter]) -> [DisplayLeaf] {
        let activeDPCount = adapters.filter {
            $0.kind == .dp && $0.isTunnelActive
        }.count
        guard activeDPCount > 0 else { return [] }
        return snapshot.displays.displays
            .filter { !$0.isBuiltIn && $0.isConnected }
            .sorted { $0.deviceTreeName < $1.deviceTreeName }
            .map { d in
                var sub: [String] = []
                if let w = d.widthPixels, let h = d.heightPixels, w > 0, h > 0 {
                    sub.append("\(w) × \(h)")
                }
                if let hz = d.currentRefreshHz ?? d.maxRefreshHz {
                    sub.append("\(Int(hz.rounded())) Hz")
                }
                return DisplayLeaf(
                    id: d.backingID,
                    title: d.title,
                    subtitle: sub.isEmpty ? nil : sub.joined(separator: " · ")
                )
            }
    }

    /// For each TB controller, find the "Thunderbolt PCIe Slot N" root
    /// allocated alongside it in the IOKit registry. Apple Silicon
    /// allocates the TB controller and its TB PCIe downstream root port
    /// as adjacent IORegistry entries; there's no explicit
    /// cross-reference, so walk both id-sorted lists in lockstep,
    /// consuming each slot once a controller claims it. The allocation
    /// doesn't strictly interleave (this MBP: controllers 0xBEC, 0xBF0,
    /// 0xC8B; slots 0xC07, 0xCAA, 0xCC6) — a naive non-consuming "first
    /// slot with a greater id" pairs two controllers with the same slot
    /// and orphans another. Mirrors `tbControllerPCIeSlotMap` in
    /// SidebarView.swift — keep the two in sync.
    private static func pcieSlotMap(controllers: [TBNode],
                                    pcieRoots: [PCINode]) -> [TBNodeID: PCINode] {
        let slots = pcieRoots
            .filter { $0.slotName?.contains("Slot-") == true }
            .sorted { $0.id.raw < $1.id.raw }
        let ctrls = controllers.sorted { $0.id.raw < $1.id.raw }
        var out: [TBNodeID: PCINode] = [:]
        var slotIndex = 0
        for c in ctrls {
            while slotIndex < slots.count, slots[slotIndex].id.raw <= c.id.raw {
                slotIndex += 1
            }
            guard slotIndex < slots.count else { break }
            out[c.id] = slots[slotIndex]
            slotIndex += 1
        }
        return out
    }

    /// PCIe endpoints tunneled through this controller's device router.
    /// Sourced from the controller's "Thunderbolt PCIe Slot N" subtree in
    /// `snapshot.pcie` — `tb.pcieDevicesOverTB` is structurally empty on
    /// Apple Silicon (tunneled PCIe enumerates under the PCI plane, not
    /// the TB tree). The legacy list is still appended for Intel hosts,
    /// where it's the populated source.
    private static func collectPCIeBlocks(snapshot: SystemSnapshot,
                                          slot: PCINode?) -> [PCIeLeaf] {
        var out: [PCIeLeaf] = []
        var seen = Set<UInt64>()
        if let slot {
            var stack = [slot]
            while let n = stack.popLast() {
                if n.kind == .endpoint, seen.insert(n.id.raw).inserted {
                    out.append(PCIeLeaf(id: n.id,
                                        title: n.title,
                                        subtitle: n.subtitle))
                }
                stack.append(contentsOf: n.children)
            }
        }
        for node in snapshot.tb.pcieDevicesOverTB where seen.insert(node.id.raw).inserted {
            out.append(PCIeLeaf(id: node.id,
                                title: node.title,
                                subtitle: node.subtitle))
        }
        return out
    }

    /// Decode `Hop Table` rows into `(dstPort, dstHopID)` tuples. The
    /// kernel publishes the table as an array of dicts; we only need
    /// the dst port for the path-ID display.
    private static func hopTableEntries(_ port: TBNode) -> [(dstPort: UInt64, dstHop: UInt64)] {
        var out: [(UInt64, UInt64)] = []
        guard case let .array(arr) = port.properties["Hop Table"] else { return [] }
        for elem in arr {
            guard case let .dictionary(kv) = elem else { continue }
            let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
            let dstPort = d["Dst Port"]?.asUInt ?? 0
            let dstHop = d["Dst Hop ID"]?.asUInt ?? 0
            out.append((dstPort, dstHop))
        }
        return out
    }

    private static func adapterKind(description: String) -> AdapterKind {
        switch description {
        case "Thunderbolt Port":                       return .lane
        case "Thunderbolt Native Host Interface Adapter": return .nhi
        case "DP or HDMI Adapter":                     return .dp
        case "USB Adapter", "USB Gen T Adapter":       return .usb
        case "PCIe Adapter":                           return .pcie
        case "Port is inactive":                       return .inactive
        default:                                       return .other(description)
        }
    }
}

// MARK: - Main view

struct USBCTopologyView: View {
    let snapshot: SystemSnapshot
    @State private var selection: DTTSelection? = nil
    /// User-controlled zoom factor (1.0 = 100%). Persists across
    /// resizes; the "Fit" button recomputes it from current sizes.
    @State private var zoom: Double = 1.0
    /// Natural size of the topology content (before scaling). Tracked
    /// via a PreferenceKey so the canvas can compute a fit-to-window
    /// scale without having to estimate row heights.
    @State private var contentSize: CGSize = .zero
    /// Live canvas size (the area available for drawing, between the
    /// header and the sidebar). Used as the denominator when fitting.
    @State private var canvasSize: CGSize = .zero
    /// Set the first time we auto-fit on appear so the user's zoom
    /// choice isn't clobbered every time the snapshot updates.
    @State private var didAutoFit: Bool = false
    /// Live pinch multiplier — applied on top of `zoom` while the
    /// user is mid-gesture and committed back into `zoom` on release.
    /// Lets the user smoothly zoom on a trackpad without each pinch
    /// snapping to a discrete zoom step.
    @GestureState private var pinchScale: Double = 1.0
    /// Cached topology model. Built once per snapshot rather than on
    /// every body re-evaluation — pinch / pan gestures retrigger the
    /// body 60×/sec and the rebuild walks thousands of IOReg nodes
    /// which was visibly hanging the canvas. Rebuilt via .task(id:)
    /// when the snapshot identity changes.
    @State private var cachedModel: DTTModel = DTTModel(hostRouters: [])
    /// Hide the Thunderbolt fabric internals — the per-router adapter
    /// chips and tunnel chips. Off by default for a clean, device-centric
    /// fan-out; power users flip it on to inspect the USB4 plumbing.
    @AppStorage("topoShowTBInternals") private var showTBInternals = false
    /// Show the full cascaded USB hub chain. Off by default — leaf
    /// devices are promoted up so a busy dock reads as its actual
    /// peripherals instead of a stack of generic "USB 3.0 Hub" rows.
    @AppStorage("topoShowIntermediateHubs") private var showIntermediateHubs = false

    init(snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        // Build the model eagerly so the first frame is already populated
        // — no empty-state flash before `.task` runs. `.task(id:)` still
        // rebuilds it when the ViewModel publishes a fresh snapshot.
        _cachedModel = State(initialValue: DTTBuilder.build(from: snapshot))
    }

    var body: some View {
        let model = cachedModel
        VStack(spacing: 0) {
            header(model: model)
            Divider()
            HStack(spacing: 0) {
                canvas(model: model)
                    .frame(maxWidth: .infinity)
                Divider()
                inspector(model: model)
                    .frame(width: 348)
                    .background(.background)
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
        // Build the topology model once when the view appears and
        // again whenever the snapshot is replaced. Anchoring the
        // identity on `capturedAt` is cheap (a `Date`) and changes
        // exactly when the ViewModel publishes a fresh scan.
        .task(id: snapshot.capturedAt) {
            let model = DTTBuilder.build(from: snapshot)
            cachedModel = model
            // Drop a selection that no longer resolves in the rebuilt model
            // (e.g. the dock was unplugged) — otherwise the inspector stays
            // open showing nothing but its Close button.
            if let sel = selection, !resolves(sel, in: model) {
                selection = nil
            }
        }
    }

    private func resolves(_ sel: DTTSelection, in model: DTTModel) -> Bool {
        switch sel {
        case .mac:                  return true
        case .hostRouter(let id):   return findHost(id: id, in: model) != nil
        case .deviceRouter(let id): return findDevice(id: id, in: model) != nil
        case .adapter(let id):      return findAdapter(id: id, in: model) != nil
        case .tunnel(let id):       return findTunnel(id: id, in: model) != nil
        case .usbDevice(let id):    return findUSB(id: id, in: model) != nil
        case .display(let id):      return findDisplay(id: id, in: model) != nil
        case .pcie(let id):         return findPCIe(id: id, in: model) != nil
        }
    }

    // MARK: Header

    private func header(model: DTTModel) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2).foregroundStyle(.tint)
            Text("USB-C Topology").font(.title2.bold())
            Text("·").foregroundStyle(.tertiary)
            statChip(systemImage: "cpu",
                     count: model.routerCount,
                     singular: "router",
                     plural: "routers")
            statChip(systemImage: "arrow.triangle.swap",
                     count: model.tunnelCount,
                     singular: "tunnel",
                     plural: "tunnels")
            Spacer()
            topologyToggles
            Divider().frame(height: 18).padding(.horizontal, 4)
            zoomControls
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    /// Two compact switches that thin out the diagram: hide the
    /// Thunderbolt fabric internals, and collapse the cascaded USB hub
    /// chain down to its leaf devices. Both default off so the first
    /// look is the clean device-centric fan.
    private var topologyToggles: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $showTBInternals) {
                Label("TB internals", systemImage: "bolt.horizontal")
            }
            .help("Show the per-router adapters and tunnels")
            Toggle(isOn: $showIntermediateHubs) {
                Label("Hub chain", systemImage: "rectangle.3.group")
            }
            .help("Show every intermediate USB hub instead of just the devices")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .fixedSize()
    }

    /// Compact zoom toolbar — minus / percentage / plus / fit. Keeps
    /// the zoom in a sensible range so the user can't get lost.
    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                setZoom(zoom - 0.1)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out")
            .keyboardShortcut("-", modifiers: .command)

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46)

            Button {
                setZoom(zoom + 0.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in")
            .keyboardShortcut("=", modifiers: .command)

            Button {
                zoom = fitScaleFor(content: contentSize, canvas: canvasSize)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Fit to window")
            .keyboardShortcut("0", modifiers: .command)

            Button {
                setZoom(1.0)
            } label: {
                Text("1:1").font(.caption.monospacedDigit())
            }
            .buttonStyle(.borderless)
            .help("Reset to 100%")
        }
    }

    /// Compute the scale that fits the topology horizontally. We
    /// deliberately ignore the canvas height: a daisy-chained dock
    /// stack is naturally tall, and forcing both dimensions to fit
    /// makes everything postage-stamp-sized just so the bottom of
    /// the topology lands inside the window. Width-first fit keeps
    /// the routers readable; vertical overflow scrolls in the
    /// surrounding ScrollView (and the user can pinch in/out).
    /// Clamped to [0.3, 1.0] so tiny windows still show *something*
    /// of the topology even if it horizontally overflows. Takes
    /// explicit args because SwiftUI defers @State writes until the
    /// next view pass.
    private func fitScaleFor(content: CGSize, canvas: CGSize) -> Double {
        // Two-axis fit: take the more restrictive of the width and height
        // ratios so the whole topology lands inside the viewport. The
        // earlier width-first form worked fine when the dock card was
        // the tallest thing on the canvas — but with a tall device router
        // (a 14-port dock with adapters + tunnel chips) the content
        // overflows vertically and the user has to scroll to see the
        // bottom rows. Fitting both axes keeps the overview-style read.
        guard content.width > 0, content.height > 0,
              canvas.width > 0, canvas.height > 0 else { return 1.0 }
        let availW = canvas.width - 32
        let availH = canvas.height - 32
        let sx = availW / content.width
        let sy = availH / content.height
        return max(0.3, min(1.0, min(sx, sy)))
    }

    /// Convenience: fit using whatever sizes we have on file.
    private func fitScale() -> Double {
        fitScaleFor(content: contentSize, canvas: canvasSize)
    }

    /// Clamp + apply a zoom value.
    private func setZoom(_ value: Double) {
        zoom = max(0.2, min(2.0, value))
    }

    /// Try to auto-fit on first mount once both sizes are known.
    /// Idempotent — the `didAutoFit` flag stops it firing on every
    /// subsequent layout pass so the user's manual zoom sticks.
    private func attemptAutoFit(canvas: CGSize, content: CGSize) {
        guard !didAutoFit else { return }
        guard canvas.width > 0, content.width > 0 else { return }
        zoom = fitScaleFor(content: content, canvas: canvas)
        didAutoFit = true
    }

    private func statChip(systemImage: String, count: Int,
                          singular: String, plural: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(count) \(count == 1 ? singular : plural)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Canvas

    /// The canvas hosts the topology inside a scroll view with both
    /// axes enabled. The content is rendered at its natural size and
    /// scaled via `.scaleEffect`; the surrounding frame is sized to
    /// `natural * zoom` so the ScrollView understands how much to
    /// scroll and the content stays anchored top-left even when it's
    /// smaller than the canvas. A PreferenceKey reports the natural
    /// content size so the Fit button can compute a scale; a
    /// GeometryReader at the canvas level captures the available
    /// drawing area.
    private func canvas(model: DTTModel) -> some View {
        GeometryReader { canvasGeo in
            // Effective zoom = persistent + live pinch multiplier.
            // Both clamps below cap the visible range so the user
            // can't pinch into oblivion.
            let liveZoom = max(0.2, min(3.0, zoom * pinchScale))
            let scaledW = max(contentSize.width * liveZoom, 1)
            let scaledH = max(contentSize.height * liveZoom, 1)
            // Reserve no more than the scaled content needs
            // horizontally; let the natural canvas height set the
            // vertical viewport. Padding the reservation by one full
            // canvas width on each side enables the user to pan
            // beyond the strict bounds (closer to a desktop-graph
            // experience than to a strict "no scroll past edges"
            // ScrollView).
            let frameW = max(canvasGeo.size.width, scaledW)
            let frameH = max(canvasGeo.size.height, scaledH)
            ScrollView([.vertical, .horizontal]) {
                ZStack {
                    topologyContent(model: model)
                        .background(
                            GeometryReader { contentGeo in
                                Color.clear.preference(
                                    key: TopologyContentSizeKey.self,
                                    value: contentGeo.size
                                )
                            }
                        )
                        .scaleEffect(liveZoom, anchor: .topLeading)
                        .frame(width: scaledW, height: scaledH,
                               alignment: .topLeading)
                }
                .frame(width: frameW, height: frameH)
            }
            .background(LinearGradient(
                colors: [Color.secondary.opacity(0.05),
                         Color.secondary.opacity(0.10)],
                startPoint: .top, endPoint: .bottom))
            // Trackpad pinch zoom — applies on top of the persisted
            // zoom so two-finger gestures feel native. Drag pan is
            // already provided by the surrounding ScrollView.
            .gesture(
                MagnificationGesture()
                    .updating($pinchScale) { value, state, _ in
                        state = value
                    }
                    .onEnded { value in
                        zoom = max(0.2, min(3.0, zoom * value))
                    }
            )
            .onAppear {
                canvasSize = canvasGeo.size
                attemptAutoFit(canvas: canvasGeo.size, content: contentSize)
            }
            .onChange(of: canvasGeo.size) { _, new in
                canvasSize = new
                attemptAutoFit(canvas: new, content: contentSize)
            }
            .onPreferenceChange(TopologyContentSizeKey.self) { new in
                contentSize = new
                attemptAutoFit(canvas: canvasSize, content: new)
            }
        }
    }

    /// The actual topology drawing — a Mac-centered radial fan. Rendered
    /// at natural size; the canvas applies the zoom transform. The heavy
    /// lifting (left/right balancing, curved cable connectors via anchor
    /// preferences) lives in `RadialTopology`.
    private func topologyContent(model: DTTModel) -> some View {
        Group {
            if model.hostRouters.isEmpty {
                emptyState
            } else {
                RadialTopology(model: model,
                               selection: $selection,
                               showTBInternals: showTBInternals,
                               showIntermediateHubs: showIntermediateHubs)
            }
        }
        .padding(56)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No Thunderbolt / USB4 controllers")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("This Mac doesn't expose a USB4 fabric, or nothing has been scanned yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(width: 520, height: 320)
    }

    // MARK: Inspector

    /// Always-visible inspector. With nothing selected (or the Mac hub
    /// selected) it shows a host overview — marketing name, fabric counts,
    /// and a tap-to-jump list of everything attached. With any other
    /// selection it shows that item's detail behind a "← Overview" button.
    /// Keeping it permanently on means the window never has a dead right
    /// margin and the overview is always one glance away.
    @ViewBuilder
    private func inspector(model: DTTModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let sel = selection, sel != .mac {
                    inspectorBackBar
                    sidebarHeader(for: sel, model: model)
                    sidebarBody(for: sel, model: model)
                } else {
                    if selection == .mac { inspectorBackBar }
                    overview(model: model)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "← Overview" affordance shown above any item detail. Esc also
    /// clears the selection back to the overview.
    private var inspectorBackBar: some View {
        HStack {
            Button {
                selection = nil
            } label: {
                Label("Overview", systemImage: "chevron.backward")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to overview (Esc)")
            Spacer()
        }
    }

    // MARK: Inspector — overview (no / Mac selection)

    @ViewBuilder
    private func overview(model: DTTModel) -> some View {
        let host = MacPortCatalog.current
        sidebarTitle(symbol: macSymbol,
                     color: .primary,
                     title: host.entry?.marketingName ?? "This Mac",
                     subtitle: host.modelID.isEmpty ? "USB4 fabric host" : host.modelID)
        SidebarSection(title: "Fabric") {
            SidebarRow(label: "USB-C ports", value: "\(model.hostRouters.count)")
            SidebarRow(label: "Routers", value: "\(model.routerCount)")
            SidebarRow(label: "Active tunnels", value: "\(model.tunnelCount)")
        }
        let attached = model.hostRouters.filter { $0.downstream != nil || $0.peer != nil }
        if attached.isEmpty {
            Text("Nothing is plugged into a USB-C port right now. Connect a dock, display, or drive and it'll fan out from the Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SidebarSection(title: "Attached (\(attached.count))") {
                ForEach(attached) { h in
                    Button {
                        if let d = h.downstream { selection = .deviceRouter(d.id) }
                        else { selection = .hostRouter(h.id) }
                    } label: {
                        overviewRow(host: h)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        SidebarSection(title: "Tips") {
            tipRow(symbol: "hand.tap", text: "Click any node — router, adapter, display, or USB device — to inspect it.")
            tipRow(symbol: "bolt.horizontal", text: "Turn on TB internals to reveal adapters and tunnels.")
            tipRow(symbol: "rectangle.3.group", text: "Turn on the hub chain to expand cascaded USB hubs.")
        }
    }

    /// SF Symbol for the central Mac hub, guessed from the catalogue
    /// chassis string. Falls back to a laptop — the overwhelmingly common
    /// USB4 host — when the chassis is unknown.
    private var macSymbol: String {
        let c = (MacPortCatalog.current.entry?.chassis ?? "").lowercased()
        if c.contains("mini") { return "macmini" }
        if c.contains("studio") { return "macstudio" }
        if c.contains("imac") { return "desktopcomputer" }
        if c.contains("pro") && (c.contains("tower") || c.contains("rack")) { return "macpro.gen3" }
        return "laptopcomputer"
    }

    private func overviewRow(host h: HostRouter) -> some View {
        HStack(spacing: 10) {
            Image(systemName: h.peer != nil ? "personalhotspot" : "shippingbox.fill")
                .foregroundStyle(h.peer != nil ? Color.teal : .blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.downstream?.title ?? h.peer?.displayTitle ?? h.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(h.socketID.map { "USB-C · Socket \($0)" } ?? "USB-C")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func tipRow(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption2).foregroundStyle(.tertiary).frame(width: 16)
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Inspector — per-selection header + body

    @ViewBuilder
    private func sidebarHeader(for sel: DTTSelection,
                               model: DTTModel) -> some View {
        switch sel {
        case .mac:
            EmptyView()   // handled by `overview`
        case .hostRouter(let id):
            if let h = findHost(id: id, in: model) {
                sidebarTitle(symbol: "cpu",
                             color: .green,
                             title: h.title,
                             subtitle: h.socketID.map { "Socket ID \($0)" })
            }
        case .deviceRouter(let id):
            if let d = findDevice(id: id, in: model) {
                sidebarTitle(symbol: "shippingbox.fill",
                             color: .blue,
                             title: d.title,
                             subtitle: "Depth \(d.depth)")
            }
        case .adapter(let id):
            if let a = findAdapter(id: id, in: model) {
                sidebarTitle(symbol: a.kind.icon,
                             color: a.kind.color,
                             title: "Port \(a.portNumber) · \(a.kind.label)",
                             subtitle: a.description)
            }
        case .tunnel(let id):
            if let t = findTunnel(id: id, in: model) {
                sidebarTitle(symbol: t.kind.icon,
                             color: t.kind.color,
                             title: "\(t.kind.label) Tunnel",
                             subtitle: "Path \(t.pathID)")
            }
        case .usbDevice(let id):
            if let u = findUSB(id: id, in: model) {
                sidebarTitle(symbol: u.symbol,
                             color: AdapterKind.usb.color,
                             title: u.title,
                             subtitle: u.isHub ? "USB hub" : "USB device")
            }
        case .display(let id):
            if let d = findDisplay(id: id, in: model) {
                sidebarTitle(symbol: "display",
                             color: AdapterKind.dp.color,
                             title: d.title,
                             subtitle: d.subtitle ?? "External display")
            }
        case .pcie(let id):
            if let p = findPCIe(id: id, in: model) {
                sidebarTitle(symbol: "square.stack.3d.up",
                             color: AdapterKind.pcie.color,
                             title: p.title,
                             subtitle: p.subtitle ?? "PCIe endpoint")
            }
        }
    }

    private func sidebarTitle(symbol: String,
                              color: Color,
                              title: String,
                              subtitle: String?) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: symbol).font(.title3).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func sidebarBody(for sel: DTTSelection,
                             model: DTTModel) -> some View {
        switch sel {
        case .mac:
            EmptyView()   // handled by `overview`
        case .hostRouter(let id):
            if let h = findHost(id: id, in: model) {
                hostRouterDetail(host: h)
            }
        case .deviceRouter(let id):
            if let d = findDevice(id: id, in: model) {
                deviceRouterDetail(device: d)
            }
        case .adapter(let id):
            if let a = findAdapter(id: id, in: model) {
                adapterDetail(adapter: a)
            }
        case .tunnel(let id):
            if let t = findTunnel(id: id, in: model) {
                tunnelDetail(tunnel: t)
            }
        case .usbDevice(let id):
            if let u = findUSB(id: id, in: model) {
                usbDeviceDetail(node: u)
            }
        case .display(let id):
            if let d = findDisplay(id: id, in: model) {
                displayDetail(leaf: d)
            }
        case .pcie(let id):
            if let p = findPCIe(id: id, in: model) {
                pcieDetail(leaf: p)
            }
        }
    }

    private func hostRouterDetail(host: HostRouter) -> some View {
        SidebarSection(title: "Router") {
            SidebarRow(label: "Vendor ID",
                       value: hexLabel(host.switchNode.properties["Vendor ID"]?.asUInt,
                                       digits: 4))
            SidebarRow(label: "Device ID",
                       value: hexLabel(host.switchNode.properties["Device ID"]?.asUInt,
                                       digits: 4))
            SidebarRow(label: "UID",
                       value: hexLabel(host.switchNode.properties["UID"]?.asUInt,
                                       digits: 16))
            if let route = host.switchNode.properties["Route String"]?.asUInt {
                SidebarRow(label: "Route String",
                           value: String(format: "0x%016llX", route))
            }
            SidebarRow(label: "Adapters",
                       value: "\(host.adapters.count)")
        }
    }

    private func deviceRouterDetail(device: DeviceRouter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarSection(title: "Identity") {
                if let v = device.vendorName {
                    SidebarRow(label: "Vendor", value: v)
                }
                if let m = device.modelName {
                    SidebarRow(label: "Model", value: m)
                }
                SidebarRow(label: "Depth", value: "\(device.depth)")
                if let fw = device.firmware {
                    SidebarRow(label: "Firmware", value: fw)
                }
            }
            SidebarSection(title: "Identifiers") {
                SidebarRow(label: "UID", value: hexLabel(device.uid, digits: 16))
                if let route = device.routeString {
                    SidebarRow(label: "Route String",
                               value: String(format: "0x%016llX", route))
                }
            }
            if !device.tunnels.isEmpty {
                SidebarSection(title: "Tunnels (\(device.tunnels.count))") {
                    ForEach(device.tunnels) { t in
                        TunnelChip(tunnel: t, isSelected: false)
                    }
                }
            }
        }
    }

    private func adapterDetail(adapter: Adapter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarSection(title: "Adapter") {
                SidebarRow(label: "Port Number", value: "\(adapter.portNumber)")
                SidebarRow(label: "Description", value: adapter.description)
                if adapter.kind == .lane {
                    SidebarRow(label: "Current Link Speed",
                               value: tbGenerationShortLabel(adapter.currentLinkSpeed))
                    if adapter.currentLinkWidth > 0 {
                        SidebarRow(label: "Current Link Width",
                                   value: tbCurrentLinkWidthLabel(adapter.currentLinkWidth))
                    }
                }
                if adapter.linkBandwidth > 0 {
                    SidebarRow(label: "Link Bandwidth",
                               value: tbBandwidthLabel(adapter.linkBandwidth))
                }
                // Device-side function adapters publish placeholder
                // Required=Max=1 (100 Mb/s) on live tunnels — only show
                // numbers for a real reservation (≥ 1 Gb/s); the Tunnel
                // row below already says Active.
                if max(adapter.requiredBandwidth, adapter.maxBandwidth) >= 10 {
                    SidebarRow(label: "Reserved",
                               value: tbBandwidthLabel(adapter.requiredBandwidth))
                    SidebarRow(label: "Max Planned",
                               value: tbBandwidthLabel(adapter.maxBandwidth))
                }
                SidebarRow(label: "Tunnel",
                           value: adapter.isTunnelActive ? "Active" : "Idle")
            }
        }
    }

    private func tunnelDetail(tunnel: Tunnel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarSection(title: "Tunnel") {
                SidebarRow(label: "Type", value: tunnel.kind.label)
                SidebarRow(label: "Path", value: tunnel.pathID)
                SidebarRow(label: "Hops", value: "\(tunnel.hopCount)")
                if tunnel.reservedBW > 0 || tunnel.maxBW > 0 {
                    SidebarRow(label: "Reserved",
                               value: tbBandwidthLabel(tunnel.reservedBW))
                    SidebarRow(label: "Max Planned",
                               value: tbBandwidthLabel(tunnel.maxBW))
                } else {
                    // Placeholder reservation that couldn't be resolved
                    // from the upstream router — the tunnel is up, the
                    // kernel just doesn't publish a real number here.
                    SidebarRow(label: "Reserved",
                               value: "Active (no static reservation)")
                }
            }
        }
    }

    private func usbDeviceDetail(node u: USBNode) -> some View {
        let p = u.node.properties
        let bcd = p["bcdUSB"]?.asUInt
        let negotiated = p["Device Speed"]?.asUInt ?? p["kUSBCurrentSpeed"]?.asUInt
        return VStack(alignment: .leading, spacing: 14) {
            SidebarSection(title: u.isHub ? "Hub" : "Device") {
                if let vendor = (p["kUSBVendorString"]?.asString ?? p["USB Vendor Name"]?.asString),
                   !vendor.isEmpty {
                    SidebarRow(label: "Vendor", value: vendor)
                }
                if let product = (p["kUSBProductString"]?.asString ?? p["USB Product Name"]?.asString),
                   !product.isEmpty {
                    SidebarRow(label: "Product", value: product)
                }
                if let serial = (p["kUSBSerialNumberString"]?.asString ?? p["USB Serial Number"]?.asString),
                   !serial.isEmpty {
                    SidebarRow(label: "Serial", value: serial)
                }
                if let declared = usbDeclaredVersionLabel(bcd) {
                    SidebarRow(label: "Protocol", value: declared)
                }
                if let neg = negotiated, neg > 0 {
                    SidebarRow(label: "Negotiated", value: usbSpeedShortLabel(neg))
                }
                if let vid = p["idVendor"]?.asUInt, let pid = p["idProduct"]?.asUInt {
                    SidebarRow(label: "VID / PID",
                               value: String(format: "0x%04llX / 0x%04llX", vid, pid))
                }
                if let loc = p["locationID"]?.asUInt {
                    SidebarRow(label: "Location", value: String(format: "0x%08llX", loc))
                }
            }
            if usbIsDowngraded(bcdUSB: bcd, currentSpeed: negotiated) {
                Label("Negotiated below its rated protocol — usually a 2.0 hub or USB-A cable in the path.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RawPropertyDisclosure(node: u.node)
        }
    }

    @ViewBuilder
    private func displayDetail(leaf: DisplayLeaf) -> some View {
        let info = snapshot.displays.displays.first { $0.backingID == leaf.id }
        SidebarSection(title: "Display") {
            SidebarRow(label: "Name", value: leaf.title)
            if let w = info?.widthPixels, let h = info?.heightPixels, w > 0, h > 0 {
                SidebarRow(label: "Resolution", value: "\(w) × \(h)")
            }
            if let hz = info?.currentRefreshHz ?? info?.maxRefreshHz {
                SidebarRow(label: "Refresh", value: "\(Int(hz.rounded())) Hz")
            }
            if let sub = leaf.subtitle, info == nil {
                SidebarRow(label: "Mode", value: sub)
            }
        }
    }

    private func pcieDetail(leaf: PCIeLeaf) -> some View {
        SidebarSection(title: "PCIe Endpoint") {
            SidebarRow(label: "Name", value: leaf.title)
            if let sub = leaf.subtitle {
                SidebarRow(label: "Detail", value: sub)
            }
        }
    }

    private func hexLabel(_ value: UInt64?, digits: Int) -> String {
        guard let v = value else { return "—" }
        return String(format: "0x%0\(digits)llX", v)
    }

    // MARK: Helpers — find by id

    private func findHost(id: TBNodeID, in model: DTTModel) -> HostRouter? {
        model.hostRouters.first { $0.id == id }
    }
    private func findDevice(id: TBNodeID, in model: DTTModel) -> DeviceRouter? {
        for h in model.hostRouters {
            if let d = h.downstream, let found = findDevice(id: id, in: d) {
                return found
            }
        }
        return nil
    }
    private func findDevice(id: TBNodeID, in router: DeviceRouter) -> DeviceRouter? {
        if router.id == id { return router }
        for d in router.daisyChained {
            if let f = findDevice(id: id, in: d) { return f }
        }
        return nil
    }
    private func findAdapter(id: TBNodeID, in model: DTTModel) -> Adapter? {
        for h in model.hostRouters {
            if let a = h.adapters.first(where: { $0.id == id }) { return a }
            if let d = h.downstream, let a = findAdapter(id: id, in: d) { return a }
        }
        return nil
    }
    private func findAdapter(id: TBNodeID, in router: DeviceRouter) -> Adapter? {
        if let a = router.adapters.first(where: { $0.id == id }) { return a }
        for d in router.daisyChained {
            if let a = findAdapter(id: id, in: d) { return a }
        }
        return nil
    }
    private func findTunnel(id: TBNodeID, in model: DTTModel) -> Tunnel? {
        for h in model.hostRouters {
            if let d = h.downstream, let t = findTunnel(id: id, in: d) { return t }
        }
        return nil
    }
    private func findTunnel(id: TBNodeID, in router: DeviceRouter) -> Tunnel? {
        if let t = router.tunnels.first(where: { $0.id == id }) { return t }
        for d in router.daisyChained {
            if let t = findTunnel(id: id, in: d) { return t }
        }
        return nil
    }
    private func findUSB(id: TBNodeID, in model: DTTModel) -> USBNode? {
        for h in model.hostRouters {
            if let d = h.downstream, let u = findUSB(id: id, in: d) { return u }
        }
        return nil
    }
    private func findUSB(id: TBNodeID, in router: DeviceRouter) -> USBNode? {
        for n in router.usbTree {
            if let u = findUSB(id: id, in: n) { return u }
        }
        for c in router.daisyChained {
            if let u = findUSB(id: id, in: c) { return u }
        }
        return nil
    }
    private func findUSB(id: TBNodeID, in node: USBNode) -> USBNode? {
        if node.id == id { return node }
        for c in node.children {
            if let u = findUSB(id: id, in: c) { return u }
        }
        return nil
    }
    private func findDisplay(id: TBNodeID, in model: DTTModel) -> DisplayLeaf? {
        for h in model.hostRouters {
            if let d = h.downstream, let x = findDisplay(id: id, in: d) { return x }
        }
        return nil
    }
    private func findDisplay(id: TBNodeID, in router: DeviceRouter) -> DisplayLeaf? {
        if let x = router.displays.first(where: { $0.id == id }) { return x }
        for c in router.daisyChained {
            if let x = findDisplay(id: id, in: c) { return x }
        }
        return nil
    }
    private func findPCIe(id: TBNodeID, in model: DTTModel) -> PCIeLeaf? {
        for h in model.hostRouters {
            if let d = h.downstream, let x = findPCIe(id: id, in: d) { return x }
        }
        return nil
    }
    private func findPCIe(id: TBNodeID, in router: DeviceRouter) -> PCIeLeaf? {
        if let x = router.pcieLeaves.first(where: { $0.id == id }) { return x }
        for c in router.daisyChained {
            if let x = findPCIe(id: id, in: c) { return x }
        }
        return nil
    }
}

// MARK: - Radial topology (Mac-centered fan-out)

/// Which side of the Mac a spoke sits on. Drives both stack alignment
/// and which edge of the Mac its cable leaves from.
private enum TopoSide { case left, right }

/// Pre-computed styling for one host→device cable, carried through the
/// anchor preference so the connector canvas can draw it without
/// re-reading the model.
private struct CableStyle: Equatable {
    var active: Bool
    var color: Color
    var lineWidth: CGFloat
    /// Idle ports get a thin dashed spoke so every receptacle is visible
    /// without competing with live links.
    var dashed: Bool
}

/// One node's bounds plus the metadata the connector canvas needs.
private struct ConnectorAnchorItem {
    enum Role { case mac; case panel(side: TopoSide, style: CableStyle) }
    let role: Role
    let anchor: Anchor<CGRect>
}

private struct ConnectorAnchorsKey: PreferenceKey {
    static let defaultValue: [ConnectorAnchorItem] = []
    static func reduce(value: inout [ConnectorAnchorItem],
                       nextValue: () -> [ConnectorAnchorItem]) {
        value.append(contentsOf: nextValue())
    }
}

/// The Mac-centered fan. Host routers are balanced into a left and a
/// right column flanking the central Mac hub; a `Canvas` behind the
/// nodes draws a smooth curved cable from the Mac out to each port
/// panel, coloured and weighted by the negotiated link generation.
private struct RadialTopology: View {
    let model: DTTModel
    @Binding var selection: DTTSelection?
    let showTBInternals: Bool
    let showIntermediateHubs: Bool

    var body: some View {
        let split = balancedSplit(model.hostRouters)
        HStack(alignment: .center, spacing: 130) {
            column(split.left, side: .left)
            MacHub(model: model, selection: $selection)
                .anchorPreference(key: ConnectorAnchorsKey.self, value: .bounds) {
                    [ConnectorAnchorItem(role: .mac, anchor: $0)]
                }
            column(split.right, side: .right)
        }
        .backgroundPreferenceValue(ConnectorAnchorsKey.self) { items in
            GeometryReader { proxy in
                ConnectorCanvas(items: items, proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func column(_ hosts: [HostRouter], side: TopoSide) -> some View {
        VStack(alignment: side == .left ? .trailing : .leading, spacing: 30) {
            ForEach(hosts) { host in
                PortPanel(host: host,
                          side: side,
                          selection: $selection,
                          showTBInternals: showTBInternals,
                          showIntermediateHubs: showIntermediateHubs)
                    .anchorPreference(key: ConnectorAnchorsKey.self, value: .bounds) {
                        [ConnectorAnchorItem(role: .panel(side: side,
                                                          style: cableStyle(for: host)),
                                             anchor: $0)]
                    }
            }
        }
    }

    /// Split host routers so the two columns carry roughly equal visual
    /// weight (a dock counts for more than an empty port). Greedy
    /// largest-first assignment to the lighter side; ties go right so a
    /// lone device sits on the right. Within a side, ports stay in
    /// socket order for a stable, predictable layout.
    private func balancedSplit(_ hosts: [HostRouter]) -> (left: [HostRouter], right: [HostRouter]) {
        var left: [HostRouter] = []
        var right: [HostRouter] = []
        var lw = 0.0, rw = 0.0
        for h in hosts.sorted(by: { weight($0) > weight($1) }) {
            if rw <= lw { right.append(h); rw += weight(h) }
            else { left.append(h); lw += weight(h) }
        }
        let order: (HostRouter, HostRouter) -> Bool = {
            (Int($0.socketID ?? "") ?? .max) < (Int($1.socketID ?? "") ?? .max)
        }
        return (left.sorted(by: order), right.sorted(by: order))
    }

    private func weight(_ h: HostRouter) -> Double {
        if let d = h.downstream {
            // A dock with a deep downstream tree is the tallest thing on
            // the canvas — weight it by what hangs off it.
            return 3 + Double(d.usbTree.count + d.displays.count) * 0.4
        }
        return h.peer != nil ? 2 : 1
    }

    /// Map the negotiated TB link generation to a cable colour + weight.
    /// Speed codes per CLAUDE.md: 0x2 = TB5/USB4v2, 0x4 = TB4/USB4v1,
    /// 0x8 = TB3, 0 = inactive.
    private func cableStyle(for host: HostRouter) -> CableStyle {
        let active = host.downstream != nil || host.peer != nil
        let speed = host.adapters.first(where: \.isTunnelActive)?.currentLinkSpeed ?? 0
        switch speed {
        case 0x2: return CableStyle(active: true, color: .purple, lineWidth: 5, dashed: false)
        case 0x4: return CableStyle(active: true, color: .blue,   lineWidth: 4, dashed: false)
        case 0x8: return CableStyle(active: true, color: .teal,   lineWidth: 3, dashed: false)
        default:
            return CableStyle(active: active,
                              color: active ? .blue : .secondary,
                              lineWidth: active ? 3 : 1.5,
                              dashed: !active)
        }
    }
}

// MARK: - Connector canvas

/// Draws the curved cables from the Mac hub to each port panel using the
/// bounds anchors collected from the layout. Active links get a soft
/// glow underlay; idle ports get a thin dashed spoke. Endpoints are
/// capped with a small filled dot so the cable visibly "plugs in".
private struct ConnectorCanvas: View {
    let items: [ConnectorAnchorItem]
    let proxy: GeometryProxy

    var body: some View {
        Canvas { ctx, _ in
            guard let macItem = items.first(where: {
                if case .mac = $0.role { return true } else { return false }
            }) else { return }
            let mac = proxy[macItem.anchor]

            for item in items {
                guard case let .panel(side, style) = item.role else { continue }
                let rect = proxy[item.anchor]
                let start = CGPoint(x: side == .right ? mac.maxX : mac.minX,
                                    y: mac.midY)
                let end = CGPoint(x: side == .right ? rect.minX : rect.maxX,
                                  y: rect.midY)
                let dx = (end.x - start.x) * 0.5
                let path = Path { p in
                    p.move(to: start)
                    p.addCurve(to: end,
                               control1: CGPoint(x: start.x + dx, y: start.y),
                               control2: CGPoint(x: end.x - dx, y: end.y))
                }
                if style.active {
                    ctx.stroke(path,
                               with: .color(style.color.opacity(0.16)),
                               style: StrokeStyle(lineWidth: style.lineWidth + 7,
                                                  lineCap: .round))
                }
                // Active cables fade from a faint tint at the Mac to a
                // saturated colour at the device, so the link reads as
                // energy flowing outward from the centre.
                let shading: GraphicsContext.Shading = style.active
                    ? .linearGradient(
                        Gradient(colors: [style.color.opacity(0.35),
                                          style.color.opacity(0.95)]),
                        startPoint: start, endPoint: end)
                    : .color(style.color.opacity(0.40))
                ctx.stroke(path,
                           with: shading,
                           style: StrokeStyle(lineWidth: style.lineWidth,
                                              lineCap: .round,
                                              dash: style.dashed ? [3, 5] : []))
                for pt in [start, end] {
                    let r = CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)
                    ctx.fill(Path(ellipseIn: r),
                             with: .color(style.color.opacity(style.active ? 0.9 : 0.5)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Mac hub (center node)

private struct MacHub: View {
    let model: DTTModel
    @Binding var selection: DTTSelection?

    private var isSelected: Bool { selection == .mac }

    private var name: String {
        MacPortCatalog.current.entry?.marketingName ?? "This Mac"
    }
    private var symbol: String {
        let c = (MacPortCatalog.current.entry?.chassis ?? "").lowercased()
        if c.contains("mini") { return "macmini" }
        if c.contains("studio") { return "macstudio" }
        if c.contains("imac") { return "desktopcomputer" }
        if c.contains("pro") && (c.contains("tower") || c.contains("rack")) { return "macpro.gen3" }
        return "laptopcomputer"
    }

    var body: some View {
        Button {
            selection = .mac
        } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.primary)
                Text(name)
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(model.hostRouters.count) USB-C · \(model.tunnelCount) tunnel\(model.tunnelCount == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 208, height: 208)
            .background(
                Circle().fill(.regularMaterial)
            )
            .overlay(
                Circle().fill(
                    RadialGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                                   center: .center, startRadius: 6, endRadius: 120))
            )
            .overlay(
                Circle().stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.18),
                                lineWidth: isSelected ? 2.5 : 1.5)
            )
            .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Port panel (one per host router / USB-C receptacle)

/// One USB-C receptacle and everything fanning out behind it. The panel
/// always leads with a port header (selectable host router); a device,
/// a TB-networking peer, or an "available" hint follows. Thunderbolt
/// internals (adapter chips + tunnels) are gated behind the toolbar
/// toggle so the default view stays device-centric and clean.
private struct PortPanel: View {
    let host: HostRouter
    let side: TopoSide
    @Binding var selection: DTTSelection?
    let showTBInternals: Bool
    let showIntermediateHubs: Bool

    private var isSelected: Bool {
        if case .hostRouter(let id) = selection { return id == host.id }
        return false
    }
    private var accent: Color {
        host.downstream != nil ? .blue : (host.peer != nil ? .teal : .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            portHeader
            if let device = host.downstream {
                if showTBInternals && !host.adapters.isEmpty {
                    AdapterGrid(adapters: host.adapters, selection: $selection)
                        .frame(width: 320, alignment: .leading)
                }
                DeviceBlockView(device: device,
                                selection: $selection,
                                showTBInternals: showTBInternals,
                                showIntermediateHubs: showIntermediateHubs)
            } else if let peer = host.peer {
                ThunderboltPeerCard(peer: peer)
            } else {
                Text("Available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.10)))
            }
        }
        .padding(14)
        .frame(minWidth: 200, alignment: .leading)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.accentColor : accent.opacity(0.30),
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
    }

    private var portHeader: some View {
        Button {
            selection = .hostRouter(host.id)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(accent.opacity(0.16)).frame(width: 30, height: 30)
                    Image(systemName: "cable.connector.horizontal")
                        .font(.caption)
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.socketID.map { "USB-C Port \($0)" } ?? "USB-C Port")
                        .font(.callout.weight(.semibold))
                    Text(linkLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var linkLabel: String {
        let a = host.adapters.first(where: \.isTunnelActive)
        if let a, let rate = tbCurrentLinkRateLabel(speed: a.currentLinkSpeed,
                                                     width: a.currentLinkWidth) {
            return rate
        }
        if host.downstream != nil || host.peer != nil { return "Connected" }
        return "No device attached"
    }
}

// MARK: - Device block (router + its downstream, recursive for daisy chains)

/// A device router card with its downstream tree, recursing into
/// daisy-chained sub-routers. A struct (not a `some View` function)
/// because recursive view-builder functions don't compile.
private struct DeviceBlockView: View {
    let device: DeviceRouter
    @Binding var selection: DTTSelection?
    let showTBInternals: Bool
    let showIntermediateHubs: Bool

    private var isSelected: Bool {
        if case .deviceRouter(let id) = selection { return id == device.id }
        return false
    }
    private func isTunnelSelected(_ t: Tunnel) -> Bool {
        if case .tunnel(let id) = selection { return id == t.id }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            deviceCard
            if showTBInternals {
                if !device.adapters.isEmpty {
                    AdapterGrid(adapters: device.adapters, selection: $selection)
                        .frame(width: 320, alignment: .leading)
                }
                if !device.tunnels.isEmpty {
                    ForEach(device.tunnels) { t in
                        Button { selection = .tunnel(t.id) } label: {
                            TunnelChip(tunnel: t, isSelected: isTunnelSelected(t))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            DownstreamTree(displays: device.displays,
                           usbTree: device.usbTree,
                           pcieLeaves: device.pcieLeaves,
                           flattenHubs: !showIntermediateHubs,
                           selection: $selection)
            ForEach(device.daisyChained) { child in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.30))
                        .frame(width: 2)
                    DeviceBlockView(device: child,
                                    selection: $selection,
                                    showTBInternals: showTBInternals,
                                    showIntermediateHubs: showIntermediateHubs)
                }
            }
        }
    }

    private var deviceCard: some View {
        Button {
            selection = .deviceRouter(device.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.title)
                        .font(.callout.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fw = device.firmware {
                        Text("Firmware \(fw)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if device.depth > 1 {
                    Text("Depth \(device.depth)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.16)))
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.blue.opacity(0.28),
                        lineWidth: isSelected ? 2 : 1)
        )
    }
}

// MARK: - Raw property disclosure (inspector)

/// Collapsible "IO Registry Details" section wrapping the shared
/// `PropertyTableView`. Lets the topology inspector expose the full raw
/// property dump for a clicked USB device without crowding the curated
/// summary above it.
private struct RawPropertyDisclosure: View {
    let node: TBNode
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption.bold()).frame(width: 12)
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.secondary)
                    Text("IO Registry Details").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                PropertyTableView(node: node).padding(.top, 8)
            }
        }
    }
}

// MARK: - Thunderbolt-networking peer card

/// Card rendered in place of a device router when the host is paired
/// with a TB-networking peer (XDomain). Structured like the device
/// router card so the visual hierarchy reads the same — but tinted
/// teal so the user can tell at a glance "this isn't a normal TB
/// device, it's a peer host." Shows vendor + hostname, the host-side
/// network interface (en6 / en2 / …) with link speed and link state,
/// MAC, vendor/device IDs, domain UUID.
private struct ThunderboltPeerCard: View {
    let peer: ThunderboltPeer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "personalhotspot")
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayTitle)
                        .font(.callout.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Thunderbolt Networking peer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(peer.ipConnectionUp ? "Established" : "Pending")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(
                        (peer.ipConnectionUp ? Color.teal : Color.secondary).opacity(0.18)
                    ))
                    .foregroundStyle(peer.ipConnectionUp ? .teal : .secondary)
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 6) {
                if let bsd = peer.interfaceBSDName {
                    peerRow(symbol: "network",
                            label: "Interface",
                            value: bsdLabel(bsd: bsd, peer: peer))
                }
                if let mac = peer.interfaceMAC {
                    peerRow(symbol: "barcode.viewfinder",
                            label: "MAC",
                            value: mac)
                }
                if let vid = peer.vendorID, let did = peer.deviceID {
                    peerRow(symbol: "number",
                            label: "Vendor / Device",
                            value: String(format: "0x%04X / 0x%04X", vid, did))
                }
                if let uuid = peer.domainUUID {
                    peerRow(symbol: "lock.shield",
                            label: "Domain UUID",
                            value: uuid)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Color.teal.opacity(0.16), Color.teal.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.teal.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: Color.teal.opacity(0.10), radius: 4, x: 0, y: 1)
    }

    private func bsdLabel(bsd: String, peer: ThunderboltPeer) -> String {
        var parts = [bsd]
        if let speed = peer.linkSpeedLabel { parts.append(speed) }
        if !peer.interfaceLinkActive { parts.append("link down") }
        return parts.joined(separator: " · ")
    }

    private func peerRow(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Adapter grid (chips)

private struct AdapterGrid: View {
    let adapters: [Adapter]
    @Binding var selection: DTTSelection?

    // Wider than the previous 90 px so the trailing connectivity
    // caption ("Socket 3" / "→ P1" / "↑ cable") doesn't crash into the
    // adapter label.
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(adapters) { a in
                Button {
                    selection = .adapter(a.id)
                } label: {
                    AdapterChip(adapter: a, isSelected: isSelected(a))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isSelected(_ a: Adapter) -> Bool {
        if case .adapter(let id) = selection { return id == a.id }
        return false
    }
}

// MARK: - Adapter chip

private struct AdapterChip: View {
    let adapter: Adapter
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: adapter.kind.icon)
                .font(.caption2)
                .foregroundStyle(adapter.isTunnelActive
                                 ? adapter.kind.color
                                 : Color.secondary.opacity(0.7))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text("Port \(adapter.portNumber)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                Text(adapter.kind.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let caption = connectivityLabel {
                Text(caption)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(adapter.kind.color.opacity(0.9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(adapter.kind.color.opacity(0.10))
                    )
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(adapter.isTunnelActive
                      ? adapter.kind.color.opacity(0.15)
                      : Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor
                                   : adapter.isTunnelActive
                                     ? adapter.kind.color.opacity(0.35)
                                     : Color.clear,
                        lineWidth: isSelected ? 2 : 1)
        )
    }

    /// Routing hint shown on the right of the chip:
    /// - host lane adapter:  "Socket 3"  (chassis port number)
    /// - device upstream lane: "↑ cable" (the lane the cable enters)
    /// - function adapter: "→ P1"  (which lane it tunnels through)
    private var connectivityLabel: String? {
        switch adapter.kind {
        case .lane:
            if adapter.isUpstreamLane { return "↑ cable" }
            if let socket = adapter.socketID { return "Socket \(socket)" }
            return nil
        case .dp, .usb, .pcie:
            if let v = adapter.routedViaPort { return "→ P\(v)" }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Tunnel chip

private struct TunnelChip: View {
    let tunnel: Tunnel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tunnel.kind.icon)
                .foregroundStyle(tunnel.kind.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.kind.label)
                    .font(.caption.weight(.semibold))
                Text(tunnel.pathID)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if tunnel.reservedBW > 0 {
                    Text(tbBandwidthLabel(tunnel.reservedBW))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(tunnel.kind.color)
                } else if tunnel.maxBW == 0 {
                    // Placeholder reservation (couldn't resolve a real
                    // number from the upstream router) — the tunnel is
                    // live, so say so instead of "100 Mb/s".
                    Text("Active")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tunnel.kind.color)
                }
                if tunnel.maxBW > tunnel.reservedBW && tunnel.maxBW > 0 {
                    Text("peak \(tbBandwidthLabel(tunnel.maxBW))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(tunnel.kind.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.accentColor
                                   : tunnel.kind.color.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1)
        )
    }
}

// MARK: - Sidebar building blocks

private struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

private struct SidebarRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Downstream tree (displays / USB / PCIe blocks)

/// Lays out the connected endpoints below a device router card as
/// individual blocks. Three vertical columns: displays on the left
/// (one block each), USB hub/device tree in the middle (real tree
/// with parent-child trunks), PCIe endpoints on the right (rare).
/// Each column is gated on having data — empty columns disappear.
private struct DownstreamTree: View {
    let displays: [DisplayLeaf]
    let usbTree: [USBNode]
    let pcieLeaves: [PCIeLeaf]
    /// When true, intermediate USB hubs are collapsed away and their
    /// leaf devices promoted up — mirrors the "hide intermediate hubs"
    /// behaviour elsewhere in the app.
    let flattenHubs: Bool
    @Binding var selection: DTTSelection?

    private var usbNodes: [USBNode] { flattenUSBNodes(usbTree, flatten: flattenHubs) }
    private var hasContent: Bool {
        !displays.isEmpty || !usbNodes.isEmpty || !pcieLeaves.isEmpty
    }

    var body: some View {
        if hasContent {
            HStack(alignment: .top, spacing: 24) {
                if !displays.isEmpty {
                    DownstreamColumn(label: "Displays",
                                     accent: AdapterKind.dp.color) {
                        ForEach(displays) { d in
                            Button { selection = .display(d.id) } label: {
                                DisplayBlock(display: d, isSelected: isSelected(.display(d.id)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !usbNodes.isEmpty {
                    DownstreamColumn(label: "USB",
                                     accent: AdapterKind.usb.color) {
                        USBTreeView(nodes: usbNodes, selection: $selection)
                    }
                }
                if !pcieLeaves.isEmpty {
                    DownstreamColumn(label: "PCIe",
                                     accent: AdapterKind.pcie.color) {
                        ForEach(pcieLeaves) { l in
                            Button { selection = .pcie(l.id) } label: {
                                PCIeBlock(leaf: l, isSelected: isSelected(.pcie(l.id)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func isSelected(_ s: DTTSelection) -> Bool { selection == s }
}

/// Collapse intermediate USB hubs, promoting their leaf devices up so a
/// busy dock reads as its actual peripherals. A no-op when `flatten` is
/// false. Devices keep any (rare) downstream children, also flattened.
private func flattenUSBNodes(_ nodes: [USBNode], flatten: Bool) -> [USBNode] {
    guard flatten else { return nodes }
    var out: [USBNode] = []
    for n in nodes {
        if n.isHub {
            out.append(contentsOf: flattenUSBNodes(n.children, flatten: true))
        } else {
            out.append(USBNode(id: n.id,
                               title: n.title,
                               subtitle: n.subtitle,
                               symbol: n.symbol,
                               isHub: false,
                               children: flattenUSBNodes(n.children, flatten: true),
                               node: n.node))
        }
    }
    return out
}

/// One vertical column under a router with a small heading tag.
/// `content` typically holds a stack of block views.
private struct DownstreamColumn<Content: View>: View {
    let label: String
    let accent: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold).monospaced())
                .foregroundStyle(accent.opacity(0.7))
            content()
        }
    }
}

/// USB tree renderer. Flattens the hierarchy into a list of rows
/// up front (linear walk, O(N)) and renders as a single VStack
/// where each row carries its own indent + trunk drawing. No
/// recursion in the view tree — eliminates the StackLayout proposal
/// cycle that was hanging on deep dock chains. Rows size to their
/// content (no truncation, no width caps) and the tree shows every
/// hub at every depth.
private struct USBTreeView: View {
    let nodes: [USBNode]
    @Binding var selection: DTTSelection?

    var body: some View {
        let rows = USBTreeLayout.flatten(nodes)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                Button {
                    selection = .usbDevice(row.id)
                } label: {
                    USBRow(row: row, isSelected: isSelected(row.id))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isSelected(_ id: TBNodeID) -> Bool {
        if case .usbDevice(let s) = selection { return s == id }
        return false
    }
}

/// One flattened tree row carrying the metadata its renderer needs
/// to draw the indent stripes correctly:
/// - `depth`: how many trunk columns to draw on the left.
/// - `ancestorOpen`: for each ancestor depth, true if the ancestor
///   has a sibling after it (draw `│`) or false if it was the last
///   one (draw blank). Reading this right-to-left tells the row
///   which columns to fill.
/// - `isLastSibling`: which corner glyph (`└` vs `├`) goes in this
///   row's own column.
private struct USBTreeRow: Identifiable {
    let id: TBNodeID
    let node: USBNode
    let depth: Int
    let ancestorOpen: [Bool]
    let isLastSibling: Bool
    /// Count of non-hub leaves reachable from a hub. Set on hub rows
    /// so the user sees "USB2.0 Hub · 5 devices" without expanding.
    let leafCount: Int?
}

private enum USBTreeLayout {
    static func flatten(_ nodes: [USBNode],
                        depth: Int = 0,
                        ancestors: [Bool] = []) -> [USBTreeRow] {
        var out: [USBTreeRow] = []
        for (i, node) in nodes.enumerated() {
            let isLast = i == nodes.count - 1
            out.append(USBTreeRow(
                id: node.id,
                node: node,
                depth: depth,
                ancestorOpen: ancestors,
                isLastSibling: isLast,
                leafCount: node.isHub ? leafCount(under: node) : nil
            ))
            if !node.children.isEmpty {
                // Ancestor stays "open" — needs a `│` column on
                // child rows — only when this node has a sibling
                // coming after it. The last sibling's ancestor
                // column is blank.
                out.append(contentsOf: flatten(node.children,
                                               depth: depth + 1,
                                               ancestors: ancestors + [!isLast]))
            }
        }
        return out
    }

    private static func leafCount(under node: USBNode) -> Int {
        var n = 0
        for c in node.children {
            if c.isHub { n += leafCount(under: c) } else { n += 1 }
        }
        return n
    }
}

/// Width of one indent column. Trunk lines are drawn at the middle
/// of this column.
private enum USBRowMetrics {
    static let indentWidth: CGFloat = 18
    static let trunkColor: Color = AdapterKind.usb.color.opacity(0.45)
}

/// A single row in the flattened USB tree. Draws its own indent
/// stripes (vertical `│`s where an ancestor still has siblings
/// to come, blank otherwise) followed by a `├` / `└` corner glyph
/// at its own depth, then the device / hub block.
private struct USBRow: View {
    let row: USBTreeRow
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Ancestor trunk columns — one per depth above us.
            ForEach(0..<row.depth, id: \.self) { d in
                trunkColumn(open: row.ancestorOpen[d])
            }
            // Our own corner: ├ if more siblings follow, └ if last.
            if row.depth > 0 {
                cornerColumn(isLast: row.isLastSibling)
            }
            // The block itself — sizes to content, no truncation.
            block
        }
        .padding(.vertical, 1)
    }

    /// A full-height column. `open` controls whether to draw the
    /// vertical trunk (an ancestor with siblings still to come) or
    /// leave blank (an ancestor that was the last sibling).
    @ViewBuilder
    private func trunkColumn(open: Bool) -> some View {
        ZStack {
            if open {
                Rectangle()
                    .fill(USBRowMetrics.trunkColor)
                    .frame(width: 1)
            }
        }
        .frame(width: USBRowMetrics.indentWidth)
    }

    /// The corner column at this row's own depth — vertical above
    /// the row's mid-line (always), horizontal stub to the right,
    /// and (for non-last siblings) a continuation below.
    @ViewBuilder
    private func cornerColumn(isLast: Bool) -> some View {
        GeometryReader { geo in
            let mid = geo.size.height / 2
            Path { p in
                // Vertical line down from the top to the mid-line.
                p.move(to: CGPoint(x: USBRowMetrics.indentWidth / 2, y: 0))
                p.addLine(to: CGPoint(x: USBRowMetrics.indentWidth / 2, y: mid))
                // Horizontal stub from mid-line to the right edge.
                p.addLine(to: CGPoint(x: USBRowMetrics.indentWidth,
                                      y: mid))
                // For ├ rows, continue the vertical down to the
                // bottom so the trunk meets the next sibling.
                if !isLast {
                    p.move(to: CGPoint(x: USBRowMetrics.indentWidth / 2,
                                       y: mid))
                    p.addLine(to: CGPoint(x: USBRowMetrics.indentWidth / 2,
                                          y: geo.size.height))
                }
            }
            .stroke(USBRowMetrics.trunkColor, lineWidth: 1)
        }
        .frame(width: USBRowMetrics.indentWidth)
    }

    /// The actual device / hub block. Hubs read as a lighter row
    /// with the device count appended; devices have the solid block
    /// styling so leaves stand out.
    @ViewBuilder
    private var block: some View {
        if row.node.isHub {
            HStack(spacing: 6) {
                Image(systemName: row.node.symbol)
                    .font(.caption)
                    .foregroundStyle(AdapterKind.usb.color.opacity(0.7))
                Text(row.node.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let n = row.leafCount, n > 0 {
                    Text("· \(n) device\(n == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AdapterKind.usb.color.opacity(0.6))
                }
            }
            .fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: BlockMetrics.cornerRadius)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BlockMetrics.cornerRadius)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 6) {
                Image(systemName: row.node.symbol)
                    .font(.caption)
                    .foregroundStyle(AdapterKind.usb.color)
                    .frame(width: 14)
                Text(row.node.title)
                    .font(.caption.weight(.medium))
                if let sub = row.node.subtitle {
                    Text(sub)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: BlockMetrics.cornerRadius)
                    .fill(AdapterKind.usb.color.opacity(isSelected ? 0.20 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: BlockMetrics.cornerRadius)
                    .stroke(isSelected ? Color.accentColor : AdapterKind.usb.color.opacity(0.40),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
    }
}

/// Shared block geometry. Removed the fixed-width cap so blocks
/// reflow to their content; the FlowLayout (or VStack) parent
/// handles wrapping. Only the corner radius is kept as a metric.
private enum BlockMetrics {
    static let cornerRadius: CGFloat = 6
}

/// Shared compact block layout. Used by Display / PCIe leaves —
/// USB rows render through `USBRow` because they need the indent
/// trunk lines. Sizes to content; truncation would defeat the
/// "show everything" requirement.
private struct LeafBlock<Title: View, Sub: View>: View {
    let symbol: String
    let accent: Color
    var isSelected: Bool = false
    @ViewBuilder var title: () -> Title
    @ViewBuilder var subtitle: () -> Sub

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(accent)
                .frame(width: 14)
            title()
            subtitle()
        }
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: BlockMetrics.cornerRadius)
                .fill(accent.opacity(isSelected ? 0.20 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BlockMetrics.cornerRadius)
                .stroke(isSelected ? Color.accentColor : accent.opacity(0.40),
                        lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

/// One external-display block.
private struct DisplayBlock: View {
    let display: DisplayLeaf
    var isSelected: Bool = false
    var body: some View {
        LeafBlock(symbol: AdapterKind.dp.icon,
                  accent: AdapterKind.dp.color,
                  isSelected: isSelected) {
            Text(display.title)
                .font(.caption.weight(.medium))
        } subtitle: {
            if let sub = display.subtitle {
                Text(sub)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One PCIe endpoint block.
private struct PCIeBlock: View {
    let leaf: PCIeLeaf
    var isSelected: Bool = false
    var body: some View {
        LeafBlock(symbol: AdapterKind.pcie.icon,
                  accent: AdapterKind.pcie.color,
                  isSelected: isSelected) {
            Text(leaf.title)
                .font(.caption.weight(.medium))
        } subtitle: {
            if let sub = leaf.subtitle {
                Text(sub)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preference keys

/// Reports the natural (unscaled) size of the topology content so the
/// canvas can drive its Fit-to-window calculation. Coalesces multiple
/// reports by taking the last non-zero value.
private struct TopologyContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 || next.height > 0 { value = next }
    }
}

// MARK: - Preview

#if DEBUG
private func previewNode(_ id: UInt64, _ kind: TBNodeKind, _ title: String,
                         _ props: [String: IORegValue] = [:],
                         children: [TBNode] = []) -> TBNode {
    TBNode(id: TBNodeID(raw: id), kind: kind, title: title, subtitle: nil,
           className: "Preview", properties: props,
           propertyOrder: props.keys.sorted(), children: children, registryPath: nil)
}

private func previewSnapshot() -> SystemSnapshot {
    let hop: IORegValue = .array([.dictionary([("Dst Port", .number(1))])])

    // Dock device router (depth 1) with DP + USB function adapters.
    let dpAdapter = previewNode(0x201, .port, "DP", [
        "Port Number": .number(5), "Description": .string("DP or HDMI Adapter"),
        "Hop Table": hop])
    let usbAdapter = previewNode(0x202, .port, "USB", [
        "Port Number": .number(9), "Description": .string("USB Adapter"),
        "Hop Table": hop])
    let deviceSwitch = previewNode(0x200, .switch, "Dock", [
        "Depth": .number(1),
        "Device Vendor Name": .string("Anker"),
        "Device Model Name": .string("Prime TB5 Docking Station"),
        "Firmware Version": .string("1.2.3")],
        children: [dpAdapter, usbAdapter])

    // Host switch (depth 0): lane port wrapping the dock plus the
    // host-side DP / USB function adapters anchoring the tunnels.
    let lane1 = previewNode(0x101, .port, "Lane", [
        "Port Number": .number(1), "Description": .string("Thunderbolt Port"),
        "Socket ID": .string("1"),
        "Current Link Speed": .number(2), "Current Link Width": .number(2),
        "Link Bandwidth": .number(800)],
        children: [deviceSwitch])
    let dpHost = previewNode(0x102, .port, "DP", [
        "Port Number": .number(5), "Description": .string("DP or HDMI Adapter"),
        "Hop Table": hop,
        "Required Bandwidth Allocated": .number(170),
        "Maximum Bandwidth Allocated": .number(400)])
    let usbHost = previewNode(0x103, .port, "USB", [
        "Port Number": .number(9), "Description": .string("USB Adapter"), "Hop Table": hop])
    let controller1 = previewNode(0x10, .controller, "TB Controller 1", children: [
        previewNode(0x100, .switch, "Host", ["Depth": .number(0)],
                    children: [lane1, dpHost, usbHost])])

    // Two idle receptacles (sockets 2 and 3) for the dashed-spoke look.
    func idleController(_ cid: UInt64, _ sid: UInt64, socket: String) -> TBNode {
        previewNode(cid, .controller, "TB Controller", children: [
            previewNode(sid, .switch, "Host", ["Depth": .number(0)], children: [
                previewNode(sid + 1, .port, "Lane", [
                    "Port Number": .number(1),
                    "Description": .string("Thunderbolt Port"),
                    "Socket ID": .string(socket)])])])
    }

    // USB devices behind the dock, enumerated under usb-drd0 (socket 1).
    let kbd = previewNode(0x301, .usbDevice, "Keychron K2", [
        "kUSBProductString": .string("Keychron K2"),
        "kUSBVendorString": .string("Keychron"),
        "bcdUSB": .number(0x0200)])
    let ssd = previewNode(0x302, .usbDevice, "Samsung T7", [
        "kUSBProductString": .string("Samsung T7 SSD"),
        "kUSBVendorString": .string("Samsung"),
        "bcdUSB": .number(0x0320), "Device Speed": .number(4)])
    let usbCtl = previewNode(0x30, .usbController, "xHCI", [
        "IONameMatched": .string("usb-drd0"), "locationID": .number(0)],
        children: [previewNode(0x300, .usbHub, "USB 3.2 Hub",
                               ["kUSBProductString": .string("USB 3.2 Hub")],
                               children: [kbd, ssd])])

    let display = DisplayInfo(
        backingID: TBNodeID(raw: 0xD100), deviceTreeName: "dispext0",
        node: previewNode(0xD100, .other, "Studio Display"),
        title: "Studio Display", subtitle: "5120 × 2880 · 60 Hz",
        isConnected: true, isBuiltIn: false,
        widthPixels: 5120, heightPixels: 2880,
        minRefreshHz: 60, maxRefreshHz: 60, currentRefreshHz: 60,
        colorBitDepth: 10, pixelEncoding: "RGB", colorSpace: "P3",
        colorAccuracyIndex: nil, supportsHDR: true,
        variableRefreshCapable: false, variableRefreshActive: false,
        timingModeCount: 1)

    return SystemSnapshot(
        tb: TBSnapshot(capturedAt: Date(),
                       controllers: [controller1,
                                     idleController(0x11, 0x110, socket: "2"),
                                     idleController(0x12, 0x120, socket: "3")],
                       pcieDevicesOverTB: [], usbDevicesOverTB: []),
        usb: USBSnapshot(capturedAt: Date(), controllers: [usbCtl], tbContext: [:]),
        accessories: [],
        internalHardware: .empty,
        displays: DisplaySnapshot(displays: [display], hdcpChannels: [], panelTCON: nil),
        pcie: .empty,
        capturedAt: Date())
}

#Preview("USB-C Topology") {
    USBCTopologyView(snapshot: previewSnapshot())
        .frame(width: 1280, height: 820)
}
#endif
