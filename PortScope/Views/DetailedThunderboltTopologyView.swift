//
//  DetailedThunderboltTopologyView.swift
//  PortScope
//
//  Microsoft Device Portal-style Thunderbolt / USB4 topology viewer.
//  Renders host routers (one per Apple TB controller), device routers
//  daisy-chained under them, the adapters inside each router, and the
//  active tunnels carrying traffic between them. The "detailed" half
//  of the topology pair — the simplified view (DiagramView) shows the
//  chassis-port-and-cable layout for users who don't care about the
//  inner router structure.
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
    case hostRouter(TBNodeID)
    case deviceRouter(TBNodeID)
    case adapter(TBNodeID)
    case tunnel(TBNodeID)  // keyed by the function adapter that anchors the tunnel
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
    let usb4SpecLabel: String?
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
            let downstream = findFirstDeviceRouter(in: hostSwitch,
                                                   snapshot: snapshot,
                                                   usbTree: usbTree)
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
                                              usbTree: [USBNode]) -> DeviceRouter? {
        if let s = findSwitch(in: parent,
                              minDepth: (parent.properties["Depth"]?.asUInt ?? 0) + 1) {
            return makeDeviceRouter(switchNode: s,
                                    snapshot: snapshot,
                                    usbTree: usbTree)
        }
        return nil
    }

    /// Walk the tree under `node` and return the first IOThunderboltSwitch
    /// whose `Depth` is ≥ `minDepth`. We stop at the first one because
    /// each lane port wraps at most one downstream router; deeper
    /// daisy-chained routers will be picked up by the recursion in
    /// `makeDeviceRouter`.
    private static func findSwitch(in node: TBNode, minDepth: UInt64) -> TBNode? {
        if node.kind == .switch,
           (node.properties["Depth"]?.asUInt ?? 0) >= minDepth {
            return node
        }
        for c in node.children {
            if let s = findSwitch(in: c, minDepth: minDepth) { return s }
        }
        return nil
    }

    private static func makeDeviceRouter(switchNode: TBNode,
                                         snapshot: SystemSnapshot,
                                         usbTree: [USBNode]) -> DeviceRouter {
        let adapters = adapterList(of: switchNode)
        let tunnels = tunnelList(adapters: adapters)
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
            if let s = findSwitch(in: c, minDepth: myDepth + 1) {
                // Daisy-chained docks share the same host-side
                // chassis port, so they pull USB leaves from the
                // same pool the parent router was given.
                daisy.append(makeDeviceRouter(switchNode: s,
                                              snapshot: snapshot,
                                              usbTree: usbTree))
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
        let attributedPCIe = myDepth == 1
            ? collectPCIeBlocks(snapshot: snapshot)
            : []
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
            usb4SpecLabel: usb4SpecLabel(
                raw: switchNode.properties["Thunderbolt Version"]?.asUInt
            ),
            adapters: adapters,
            tunnels: tunnels,
            daisyChained: daisy,
            displays: attributedDisplays,
            usbTree: attributedUSB,
            pcieLeaves: attributedPCIe
        )
    }

    /// Translate the kernel's TB version BCD into a "Spec X.Y" string.
    private static func usb4SpecLabel(raw: UInt64?) -> String? {
        guard let v = raw else { return nil }
        let major = (v >> 4) & 0xF
        let minor = v & 0xF
        return "USB4 Spec \(major).\(minor)"
    }

    /// Pull every `IOThunderboltPort` directly under a switch and turn
    /// it into a typed `Adapter`. Children of the switch that aren't
    /// ports (other switches, IPService, etc.) are skipped.
    private static func adapterList(of switchNode: TBNode) -> [Adapter] {
        var out: [Adapter] = []
        // Upstream port number is published on the switch itself —
        // identifies which lane port the cable enters this router
        // through. Lets device-side lane adapters show "↑ cable".
        let upstreamPort = switchNode.properties["Upstream Port Number"]?.asUInt
        for c in switchNode.children where c.kind == .port {
            let portN = c.properties["Port Number"]?.asUInt ?? 0
            let desc = c.properties["Description"]?.asString ?? ""
            let kind = adapterKind(description: desc)
            let speed = c.properties["Current Link Speed"]?.asUInt ?? 0
            let width = c.properties["Current Link Width"]?.asUInt ?? 0
            let linkBW = c.properties["Link Bandwidth"]?.asUInt ?? 0
            let reqBW = c.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
            let maxBW = c.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
            // A function adapter (DP/USB/PCIe) is "tunneling" when it
            // has a non-empty Hop Table. Lane adapters use Current Link
            // Speed instead.
            let isActiveTunnel: Bool = {
                if case .lane = kind { return speed > 0 }
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
            let isUpstreamLane = (kind == .lane)
                && (upstreamPort != nil)
                && (upstreamPort == portN)
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
    private static func tunnelList(adapters: [Adapter]) -> [Tunnel] {
        var out: [Tunnel] = []
        for a in adapters where a.isTunnelActive {
            switch a.kind {
            case .lane, .nhi, .inactive, .other:
                continue   // not a function-adapter tunnel
            default:
                break
            }
            let hops = hopTableEntries(a.node)
            let pathID = ([a.portNumber] + hops.map { $0.dstPort })
                .map { "P\($0)" }
                .joined(separator: " → ")
            out.append(Tunnel(
                id: a.id,
                kind: a.kind,
                pathID: pathID,
                reservedBW: a.requiredBandwidth,
                maxBW: a.maxBandwidth,
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
                    children: kids
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
                        children: kids
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
        // device is this".
        if let bcd = node.properties["bcdUSB"]?.asUInt,
           let cap = usbCapabilityFromBCD(bcd) {
            parts.append(cap.shortLabel)
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

    /// PCIe endpoints tunneled through this device router. On Apple
    /// Silicon most docks tunnel their storage over USB rather than
    /// PCIe (the dock's NVMe lives behind a USB-mass-storage bridge),
    /// so this typically returns empty. We still walk
    /// `snapshot.tb.pcieDevicesOverTB` for completeness.
    private static func collectPCIeBlocks(snapshot: SystemSnapshot) -> [PCIeLeaf] {
        return snapshot.tb.pcieDevicesOverTB.map { node in
            PCIeLeaf(
                id: node.id,
                title: node.title,
                subtitle: node.subtitle
            )
        }
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

struct DetailedThunderboltTopologyView: View {
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

    var body: some View {
        let model = cachedModel
        VStack(spacing: 0) {
            header(model: model)
            Divider()
            HStack(spacing: 0) {
                canvas(model: model)
                    .frame(maxWidth: .infinity)
                if selection != nil {
                    Divider()
                    sidebar(model: model)
                        .frame(width: 340)
                        .background(.background)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: selection)
        }
        .frame(minWidth: 1180, minHeight: 760)
        // Build the topology model once when the view appears and
        // again whenever the snapshot is replaced. Anchoring the
        // identity on `capturedAt` is cheap (a `Date`) and changes
        // exactly when the ViewModel publishes a fresh scan.
        .task(id: snapshot.capturedAt) {
            cachedModel = DTTBuilder.build(from: snapshot)
        }
    }

    // MARK: Header

    private func header(model: DTTModel) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2).foregroundStyle(.tint)
            Text("Thunderbolt Topology").font(.title2.bold())
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
            zoomControls
            Divider().frame(height: 18).padding(.horizontal, 4)
            legendDot(color: .green, label: "Host")
            legendDot(color: .blue, label: "Device")
        }
        .padding()
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

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color.opacity(0.7)).frame(width: 10, height: 10)
            Text(label).font(.caption).foregroundStyle(.secondary)
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

    /// The actual topology drawing. Rendered at natural size; the
    /// canvas applies the zoom transform.
    private func topologyContent(model: DTTModel) -> some View {
        VStack(alignment: .center, spacing: 0) {
            MacChassisBlock()
            trunkLine(height: 18)
            hostBranchingTrunk(routers: model.hostRouters)
            hostRoutersBar(routers: model.hostRouters)
        }
        .padding(40)
        .fixedSize()
    }

    private func trunkLine(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 2, height: height)
    }

    /// Horizontal bus + per-column vertical drops between the "This Mac"
    /// pill and the host router cards. Mirrors the way the dock card's
    /// downstream tree branches into separate display / USB / PCIe blocks
    /// — visually the host routers are siblings hanging off the Mac,
    /// not children of just the centre column. A single straight
    /// `trunkLine` made HR1 and HR3 look orphaned because the line only
    /// reached the middle host card.
    ///
    /// Drawn with `Canvas` rather than nested HStacks/ZStacks so the
    /// drops land at the precise pixel centres of the host router
    /// columns. **Column widths aren't uniform**: a column with a
    /// downstream device router (the 520-pt dock card) or a TB-networking
    /// peer (also 520) is wider than a column whose host has nothing
    /// attached (just the 360-pt host card). The trunk reads each
    /// router's downstream/peer status and computes per-column widths +
    /// centres from that, so the drops always land on the host card
    /// centre — which is what `HostRouterCard` is itself centred around
    /// inside its column.
    private func hostBranchingTrunk(routers: [HostRouter]) -> some View {
        let widths = columnWidths(for: routers)
        let spacing: CGFloat = 28
        let dropHeight: CGFloat = 18
        // Walk left → right summing column widths + spacing to find each
        // column's centre, then the total width.
        var cursor: CGFloat = 0
        var centers: [CGFloat] = []
        for (idx, w) in widths.enumerated() {
            centers.append(cursor + w / 2)
            cursor += w
            if idx < widths.count - 1 { cursor += spacing }
        }
        let totalWidth = cursor

        return Canvas { ctx, _ in
            let stroke = GraphicsContext.Shading.color(Color.secondary.opacity(0.35))
            if let first = centers.first, let last = centers.last, centers.count > 1 {
                var bus = Path()
                bus.move(to: CGPoint(x: first, y: 1))
                bus.addLine(to: CGPoint(x: last, y: 1))
                ctx.stroke(bus, with: stroke, lineWidth: 2)
            }
            for x in centers {
                var drop = Path()
                drop.move(to: CGPoint(x: x, y: 0))
                drop.addLine(to: CGPoint(x: x, y: dropHeight))
                ctx.stroke(drop, with: stroke, lineWidth: 2)
            }
        }
        .frame(width: totalWidth, height: dropHeight)
    }

    /// Width of each host router's column in `hostRoutersBar` — the
    /// natural width of the widest child in the VStack. A column with a
    /// downstream device router or TB peer expands to `deviceRouterWidth`
    /// (520), since both render at that width; otherwise it stays at the
    /// host-card width (360). Keep in sync with the conditional branches
    /// inside `hostRoutersBar`.
    private func columnWidths(for routers: [HostRouter]) -> [CGFloat] {
        routers.map { host in
            (host.downstream != nil || host.peer != nil)
                ? Self.deviceRouterWidth
                : Self.hostColumnWidth
        }
    }

    /// Per-host column width. Wide enough to fit three adapter
    /// chips (at min 110 px) per row in the host router card.
    private static let hostColumnWidth: CGFloat = 360
    /// Device router cards expand wider than the host column so a
    /// dock with 14+ adapters and 4 tunnels reads as a single dense
    /// card instead of an absurdly tall thin strip.
    private static let deviceRouterWidth: CGFloat = 520

    private func hostRoutersBar(routers: [HostRouter]) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(routers) { host in
                VStack(spacing: 0) {
                    HostRouterCard(
                        host: host,
                        selection: $selection
                    )
                    .frame(width: Self.hostColumnWidth)
                    if let device = host.downstream {
                        // The cable line + downstream device router
                        // sits directly under the host card so the
                        // visual flow reads top→bottom. The device
                        // card can expand wider than the host column
                        // — it's centered under the host so the
                        // visual lineage is still obvious.
                        CableConnector(
                            speed: host.adapters.first(where: \.isTunnelActive)?.currentLinkSpeed ?? 0,
                            width: host.adapters.first(where: \.isTunnelActive)?.currentLinkWidth ?? 0,
                            linkBandwidth: device.adapters.first(where: { $0.kind == .lane })?.linkBandwidth ?? 0,
                            tunnels: device.tunnels
                        )
                        // The card itself is constrained to a fixed
                        // width so its layout stays predictable; the
                        // downstream tree under it (USB hubs + leaves
                        // + displays) is free to grow with the device
                        // count.
                        DeviceRouterTree(router: device,
                                         selection: $selection)
                    } else if let peer = host.peer {
                        // TB-networking peer (XDomain) — Mac/Linux/PC
                        // on the other end. No device router, no
                        // tunnels in the normal sense; render the cable
                        // line + a dedicated peer card instead. Use
                        // the host's XDomain-bearing lane adapter for
                        // the cable speed/width (the lane has a Hop
                        // Table entry for the XDomain control channel
                        // even though there's no tunneled device).
                        CableConnector(
                            speed: host.adapters.first(where: \.isTunnelActive)?.currentLinkSpeed ?? 0,
                            width: host.adapters.first(where: \.isTunnelActive)?.currentLinkWidth ?? 0,
                            linkBandwidth: host.adapters.first(where: \.isTunnelActive)?.linkBandwidth ?? 0,
                            tunnels: []
                        )
                        ThunderboltPeerCard(peer: peer)
                            .frame(width: Self.deviceRouterWidth)
                    } else {
                        // Match the cable-connector "tail" pattern so
                        // empty / device / peer slots all align at the
                        // same y-offset under the host card: 16-px line,
                        // muted pill, no trailing line.
                        VStack(spacing: 4) {
                            trunkLine(height: 16)
                            Text("No device attached")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                        }
                    }
                }
                .frame(alignment: .top)
            }
        }
    }

    // MARK: Sidebar

    /// Selection-driven inspector. The whole sidebar is gated on
    /// `selection != nil` by the caller (the canvas takes the full width
    /// when nothing is selected), so this view only ever renders for a
    /// real selection. A dedicated close button at the top clears the
    /// selection — placed at the leading edge of the sidebar (right next
    /// to the divider that splits canvas / sidebar) so it's directly
    /// reachable when the user wants to dismiss without aiming for a
    /// small system traffic-light.
    @ViewBuilder
    private func sidebar(model: DTTModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sidebarCloseBar
                if let sel = selection {
                    sidebarHeader(for: sel, model: model)
                    sidebarBody(for: sel, model: model)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Big, easy-to-hit close affordance at the very top of the sidebar.
    /// Made deliberately large (32-pt hit target) with a label so the user
    /// doesn't have to aim for a tiny X — matches the "easy to hit"
    /// requirement.
    private var sidebarCloseBar: some View {
        HStack {
            Button {
                selection = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                    Text("Close")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close inspector (Esc)")
            Spacer()
        }
    }

    @ViewBuilder
    private func sidebarHeader(for sel: DTTSelection,
                               model: DTTModel) -> some View {
        switch sel {
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
                if let spec = device.usb4SpecLabel {
                    SidebarRow(label: "Spec", value: spec)
                }
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
                if adapter.requiredBandwidth > 0 || adapter.maxBandwidth > 0 {
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
                SidebarRow(label: "Reserved",
                           value: tbBandwidthLabel(tunnel.reservedBW))
                SidebarRow(label: "Max Planned",
                           value: tbBandwidthLabel(tunnel.maxBW))
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
}

// MARK: - Mac chassis block

private struct MacChassisBlock: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac").font(.headline)
                Text("USB4 fabric host").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(
                    colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Host router card

private struct HostRouterCard: View {
    let host: HostRouter
    @Binding var selection: DTTSelection?

    private var isSelected: Bool {
        if case .hostRouter(let id) = selection { return id == host.id }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                selection = .hostRouter(host.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.green)
                    Text(host.title).font(.callout.bold())
                    Spacer()
                    if let s = host.socketID {
                        Text("Socket \(s)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                    }
                }
            }
            .buttonStyle(.plain)
            Divider().opacity(0.4)
            AdapterGrid(adapters: host.adapters, selection: $selection)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Color.green.opacity(0.16), Color.green.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.green.opacity(0.32),
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: Color.green.opacity(0.10), radius: 4, x: 0, y: 1)
    }
}

// MARK: - Cable connector (host → device link)

private struct CableConnector: View {
    let speed: UInt64       // Current Link Speed (kernel raw)
    let width: UInt64       // Current Link Width
    let linkBandwidth: UInt64
    let tunnels: [Tunnel]   // active tunnels carried over the link

    var body: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 2, height: 16)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "cable.connector").font(.caption)
                        .foregroundStyle(.primary)
                    Text(linkLabel)
                        .font(.caption.monospacedDigit().weight(.medium))
                }
                if !tunnels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tunnels) { t in
                            HStack(spacing: 3) {
                                Image(systemName: t.kind.icon)
                                    .font(.system(size: 9))
                                Text(t.kind.label)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(
                                Capsule().fill(t.kind.color.opacity(0.18))
                            )
                            .foregroundStyle(t.kind.color)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 2, height: 16)
        }
    }

    private var linkLabel: String {
        if let rate = tbCurrentLinkRateLabel(speed: speed, width: width) {
            return rate
        }
        if linkBandwidth > 0 { return tbBandwidthLabel(linkBandwidth) }
        return "Link"
    }
}

// MARK: - Device router tree

private struct DeviceRouterTree: View {
    let router: DeviceRouter
    @Binding var selection: DTTSelection?

    var body: some View {
        VStack(spacing: 14) {
            DeviceRouterCard(router: router, selection: $selection)
                .frame(width: 520)

            // Downstream blocks (displays / USB tree / PCIe) live
            // below the router card, joined by a short trunk line.
            let tree = DownstreamTree(
                displays: router.displays,
                usbTree: router.usbTree,
                pcieLeaves: router.pcieLeaves
            )
            if tree.hasContent {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2, height: 16)
                tree
            }

            // Daisy-chained downstream routers follow.
            ForEach(router.daisyChained) { child in
                VStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 2, height: 16)
                    DeviceRouterTree(router: child, selection: $selection)
                }
            }
        }
    }
}

// MARK: - Device router card

private struct DeviceRouterCard: View {
    let router: DeviceRouter
    @Binding var selection: DTTSelection?

    private var isSelected: Bool {
        if case .deviceRouter(let id) = selection { return id == router.id }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                selection = .deviceRouter(router.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(router.title)
                            .font(.callout.bold())
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let spec = router.usb4SpecLabel {
                            Text(spec)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("Depth \(router.depth)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.18)))
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
            Divider().opacity(0.4)
            AdapterGrid(adapters: router.adapters, selection: $selection)
            if !router.tunnels.isEmpty {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tunnels")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(router.tunnels) { t in
                        Button {
                            selection = .tunnel(t.id)
                        } label: {
                            TunnelChip(tunnel: t,
                                       isSelected: isTunnelSelected(t))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Color.blue.opacity(0.16), Color.blue.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.blue.opacity(0.32),
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: Color.blue.opacity(0.10), radius: 4, x: 0, y: 1)
    }

    private func isTunnelSelected(_ t: Tunnel) -> Bool {
        if case .tunnel(let id) = selection { return id == t.id }
        return false
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

    /// True only when there's something to render. Lets the caller
    /// skip the trunk line that connects router → tree.
    var hasContent: Bool {
        !displays.isEmpty || !usbTree.isEmpty || !pcieLeaves.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            if !displays.isEmpty {
                DownstreamColumn(label: "Displays",
                                 accent: AdapterKind.dp.color) {
                    ForEach(displays) { DisplayBlock(display: $0) }
                }
            }
            if !usbTree.isEmpty {
                DownstreamColumn(label: "USB",
                                 accent: AdapterKind.usb.color) {
                    USBTreeView(nodes: usbTree)
                }
            }
            if !pcieLeaves.isEmpty {
                DownstreamColumn(label: "PCIe",
                                 accent: AdapterKind.pcie.color) {
                    ForEach(pcieLeaves) { PCIeBlock(leaf: $0) }
                }
            }
        }
    }
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

    var body: some View {
        let rows = USBTreeLayout.flatten(nodes)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                USBRow(row: row)
            }
        }
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
            .padding(.horizontal, 4)
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
                    .fill(AdapterKind.usb.color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: BlockMetrics.cornerRadius)
                    .stroke(AdapterKind.usb.color.opacity(0.40),
                            lineWidth: 1)
            )
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
                .fill(accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BlockMetrics.cornerRadius)
                .stroke(accent.opacity(0.40), lineWidth: 1)
        )
    }
}

/// One external-display block.
private struct DisplayBlock: View {
    let display: DisplayLeaf
    var body: some View {
        LeafBlock(symbol: AdapterKind.dp.icon,
                  accent: AdapterKind.dp.color) {
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
    var body: some View {
        LeafBlock(symbol: AdapterKind.pcie.icon,
                  accent: AdapterKind.pcie.color) {
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
