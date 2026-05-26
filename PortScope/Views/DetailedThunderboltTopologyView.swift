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

    var totalTunnels: Int {
        tunnels.count + daisyChained.reduce(0) { $0 + $1.totalTunnels }
    }
    var totalRouterCount: Int {
        1 + daisyChained.reduce(0) { $0 + $1.totalRouterCount }
    }
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
    /// User-visible endpoints attributed to this tunnel — the
    /// displays / USB peripherals / PCIe devices it's actually
    /// carrying. Lets the topology read as "this DP tunnel drives
    /// Display 0" rather than just "100 Mb/s reserved on the wire".
    let leaves: [TunnelLeaf]
}

/// One endpoint hanging off a tunnel — a display attached to a DP
/// tunnel, a USB peripheral attached to a USB tunnel, etc.
private struct TunnelLeaf: Identifiable, Hashable {
    let id: TBNodeID            // backing IORegistry id
    let title: String           // user-facing label (vendor + product)
    let subtitle: String?       // resolution / speed / class
    let symbol: String          // SF Symbol to color-code the leaf
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
            let usbLeaves = collectUSBLeavesForSocket(socketID,
                                                     snapshot: snapshot)
            let downstream = findFirstDeviceRouter(in: hostSwitch,
                                                   snapshot: snapshot,
                                                   usbLeaves: usbLeaves)
            hosts.append(HostRouter(
                id: hostSwitch.id,
                controller: controller,
                switchNode: hostSwitch,
                title: "Host Router \(idx + 1)",
                socketID: socketID,
                adapters: adapters,
                downstream: downstream
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
                                              usbLeaves: [TunnelLeaf]) -> DeviceRouter? {
        if let s = findSwitch(in: parent,
                              minDepth: (parent.properties["Depth"]?.asUInt ?? 0) + 1) {
            return makeDeviceRouter(switchNode: s,
                                    snapshot: snapshot,
                                    usbLeaves: usbLeaves)
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
                                         usbLeaves: [TunnelLeaf]) -> DeviceRouter {
        let adapters = adapterList(of: switchNode)
        let tunnels = tunnelList(adapters: adapters,
                                 snapshot: snapshot,
                                 usbLeaves: usbLeaves)
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
                // same pool the parent router was given. In a more
                // accurate world we'd partition the leaves across
                // depths by `Depth Class` in the hop table — the
                // kernel does publish that — but for an MVP each
                // chained dock just sees the full set.
                daisy.append(makeDeviceRouter(switchNode: s,
                                              snapshot: snapshot,
                                              usbLeaves: usbLeaves))
            }
        }
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
            daisyChained: daisy
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

    /// One `Tunnel` per active function adapter on the router.
    /// `usbLeaves` is the pre-filtered list of USB endpoints behind
    /// this device router's chassis socket; `snapshot.displays`
    /// supplies the DP attribution pool.
    private static func tunnelList(adapters: [Adapter],
                                   snapshot: SystemSnapshot,
                                   usbLeaves: [TunnelLeaf]) -> [Tunnel] {
        // Pre-compute leaf pools once per router so building each
        // tunnel's leaves is a cheap lookup. USB tunnels split their
        // pool across the (usually single) USB adapter, displays are
        // distributed across the active DP adapters.
        let usbPool = usbLeaves
        let dpPool = collectDisplayLeaves(snapshot: snapshot)
        let activeDPCount = adapters.filter {
            $0.kind == .dp && $0.isTunnelActive
        }.count
        // Track which DP slot we're filling so multi-display docks
        // map displays 1:1 to adapter tunnels in sort order.
        var dpIndex = 0

        var out: [Tunnel] = []
        for a in adapters where a.isTunnelActive {
            switch a.kind {
            case .lane, .nhi, .inactive, .other:
                continue   // not a function-adapter tunnel
            default:
                break
            }
            let hops = hopTableEntries(a.node)
            // Build a human-friendly path: "P13 → P1 → P7" rather than
            // Microsoft's "13:1:7". Same information, but arrows make
            // direction unambiguous and we don't have to explain a
            // colon convention.
            let pathID = ([a.portNumber] + hops.map { $0.dstPort })
                .map { "P\($0)" }
                .joined(separator: " → ")
            let leaves: [TunnelLeaf] = {
                switch a.kind {
                case .usb: return usbPool
                case .dp:
                    // 1:1 attribution when display count matches DP-
                    // adapter count, otherwise just hand the first
                    // available display to each adapter in order.
                    if activeDPCount == dpPool.count, dpIndex < dpPool.count {
                        let leaf = dpPool[dpIndex]
                        dpIndex += 1
                        return [leaf]
                    }
                    if dpIndex < dpPool.count {
                        let leaf = dpPool[dpIndex]
                        dpIndex += 1
                        return [leaf]
                    }
                    return []
                case .pcie:
                    return []   // dock PCIe endpoints are rare on AS docks
                default:
                    return []
                }
            }()
            out.append(Tunnel(
                id: a.id,
                kind: a.kind,
                pathID: pathID,
                reservedBW: a.requiredBandwidth,
                maxBW: a.maxBandwidth,
                hopCount: hops.count,
                leaves: leaves
            ))
        }
        // Render display tunnels first, then USB, then PCIe.
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
    /// Filtered to `usb-drd*` controllers only (skips the internal
    /// `usb-auss` controller that drives the FaceTime camera /
    /// internal USB — its locationID doesn't follow the per-port
    /// encoding).
    ///
    /// Returns an empty list when the socket ID isn't parseable or
    /// when no controllers match — e.g. on hosts where the user has
    /// nothing plugged into the corresponding receptacle.
    private static func collectUSBLeavesForSocket(_ socketID: String?,
                                                  snapshot: SystemSnapshot)
        -> [TunnelLeaf]
    {
        guard let socketStr = socketID, let socket = UInt64(socketStr) else {
            return []
        }
        var out: [TunnelLeaf] = []
        for controller in snapshot.usb.controllers {
            // Only the per-port USB-C controllers map to a chassis
            // socket — `usb-auss` is internal.
            let nameMatch = controller.properties["IONameMatched"]?.asString
                ?? controller.properties["IONameMatch"]?.asString ?? ""
            guard nameMatch.hasPrefix("usb-drd") else { continue }
            guard let loc = controller.properties["locationID"]?.asUInt else { continue }
            let topByte = (loc >> 24) & 0xFF
            guard topByte + 1 == socket else { continue }
            collectUSBEndpointLeaves(under: controller, into: &out)
        }
        return out.sorted { $0.title < $1.title }
    }

    /// Recursively walk a USB subtree and append meaningful leaf
    /// devices. Hubs / interface stubs / billboard descriptors are
    /// passed through so their children are still considered.
    private static func collectUSBEndpointLeaves(under node: TBNode,
                                                 into out: inout [TunnelLeaf]) {
        for child in node.children {
            switch child.kind {
            case .usbDevice:
                let t = child.title.lowercased()
                if t.contains("billboard") || t.hasSuffix(" hub")
                    || t == "usb hub" {
                    collectUSBEndpointLeaves(under: child, into: &out)
                } else {
                    out.append(TunnelLeaf(
                        id: child.id,
                        title: child.title,
                        subtitle: usbSubtitle(child),
                        symbol: usbSymbol(for: child)
                    ))
                }
            case .usbHub:
                collectUSBEndpointLeaves(under: child, into: &out)
            case .usbController, .other, .usbInterface:
                collectUSBEndpointLeaves(under: child, into: &out)
            default:
                continue
            }
        }
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
           !vendor.isEmpty, vendor != node.title {
            parts.append(vendor)
        }
        if let speed = node.properties["Device Speed"]?.asUInt
            ?? node.properties["kUSBCurrentSpeed"]?.asUInt,
           speed > 0 {
            parts.append(usbSpeedShortLabel(speed))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Every external, currently-lit display. Doesn't attempt to
    /// attribute across multiple device routers — that's done by the
    /// caller assigning displays 1:1 to active DP adapters in sort
    /// order. Good enough for a single-dock setup; on multi-dock
    /// configs the first-fit fallback keeps every display visible at
    /// least once.
    private static func collectDisplayLeaves(snapshot: SystemSnapshot) -> [TunnelLeaf] {
        snapshot.displays.displays
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
                return TunnelLeaf(
                    id: d.backingID,
                    title: d.title,
                    subtitle: sub.isEmpty ? nil : sub.joined(separator: " · "),
                    symbol: AdapterKind.dp.icon
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
    @Environment(\.dismiss) private var dismiss
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

    var body: some View {
        let model = DTTBuilder.build(from: snapshot)
        VStack(spacing: 0) {
            header(model: model)
            Divider()
            HStack(spacing: 0) {
                canvas(model: model)
                    .frame(maxWidth: .infinity)
                Divider()
                sidebar(model: model)
                    .frame(width: 340)
                    .background(.background)
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
    }

    // MARK: Header

    private func header(model: DTTModel) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2).foregroundStyle(.tint)
            Text("Detailed Thunderbolt Topology").font(.title2.bold())
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
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
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
        guard content.width > 0, canvas.width > 0 else { return 1.0 }
        let availW = canvas.width - 32
        let sx = availW / content.width
        return max(0.3, min(1.0, sx))
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
        VStack(alignment: .center, spacing: 28) {
            MacChassisBlock()
            trunkLine(height: 18)
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
                        DeviceRouterTree(router: device, selection: $selection)
                            .frame(width: Self.deviceRouterWidth)
                    } else {
                        VStack(spacing: 6) {
                            trunkLine(height: 12)
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

    @ViewBuilder
    private func sidebar(model: DTTModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let sel = selection {
                    sidebarHeader(for: sel, model: model)
                    sidebarBody(for: sel, model: model)
                } else {
                    sidebarEmpty
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sidebarEmpty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "hand.point.up.left")
                .font(.title2).foregroundStyle(.tertiary)
            Text("Select a router, adapter, or tunnel")
                .font(.callout.weight(.medium))
            Text("Click any element in the diagram to see its raw IORegistry data.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 40)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                selection = .tunnel(t.id)
                            } label: {
                                TunnelChip(tunnel: t,
                                           isSelected: isTunnelSelected(t))
                            }
                            .buttonStyle(.plain)
                            // Indented leaves below the tunnel — the
                            // actual displays / USB peripherals the
                            // tunnel is carrying. Lets the user see
                            // "this DP tunnel drives Display 0" at a
                            // glance instead of having to cross-check
                            // the Displays sidebar section.
                            if !t.leaves.isEmpty {
                                LeafList(leaves: t.leaves,
                                         accent: t.kind.color)
                            }
                        }
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
                HStack(spacing: 6) {
                    Text(tunnel.kind.label)
                        .font(.caption.weight(.semibold))
                    if !tunnel.leaves.isEmpty {
                        Text("· \(tunnel.leaves.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(tunnel.kind.color.opacity(0.8))
                    }
                }
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

// MARK: - Tunnel leaves

/// Compact, indented list of the endpoints a tunnel is carrying.
/// Renders directly below the tunnel chip in the device router card.
/// The accent color matches the tunnel kind so DP leaves read blue,
/// USB leaves teal, etc.
private struct LeafList: View {
    let leaves: [TunnelLeaf]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(leaves) { leaf in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("↳")
                        .font(.caption2.monospaced())
                        .foregroundStyle(accent.opacity(0.7))
                    Image(systemName: leaf.symbol)
                        .font(.caption2)
                        .foregroundStyle(accent.opacity(0.85))
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(leaf.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                        if let sub = leaf.subtitle {
                            Text(sub)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 18)
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
