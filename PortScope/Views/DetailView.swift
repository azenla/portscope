//
//  DetailView.swift
//  PortScope
//
//  Curated, human-readable presentation of a TB entity. Internals are tucked
//  away behind a single "Developer details" disclosure at the bottom.
//

import SwiftUI

struct DetailView: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void
    let parentLookup: (TBNodeID) -> TBNode?
    /// Looks up the TB switch ancestor for a USB controller, when applicable.
    let tbContextForUSB: (TBNodeID) -> TBNodeID?
    /// Ancestor chain (oldest-first, `.other` wrappers filtered) for the
    /// breadcrumb above the hero header.
    let ancestors: [TBNode]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BreadcrumbBar(ancestors: ancestors, onNavigate: onNavigate)
                HeroHeader(node: node)
                summary(for: node)
                DeveloperDisclosure(node: node)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    @ViewBuilder
    private func summary(for node: TBNode) -> some View {
        switch node.kind {
        case .controller: ControllerView(node: node, onNavigate: onNavigate)
        case .switch: RouterView(node: node, onNavigate: onNavigate, parentLookup: parentLookup)
        case .port: PortView(node: node, parentLookup: parentLookup)
        case .localNode: LocalNodeView(node: node)
        case .usbController:
            USBControllerView(node: node,
                              tbContext: tbContextForUSB(node.id),
                              onNavigate: onNavigate)
        case .usbHub:
            USBHubView(node: node,
                       tbContext: ancestorTBContext(for: node),
                       onNavigate: onNavigate)
        case .usbDevice:
            USBDeviceView(node: node,
                          tbContext: ancestorTBContext(for: node),
                          onNavigate: onNavigate)
        case .usbInterface:
            USBInterfaceView(node: node)
        case .pcieDevice, .pcieBridge, .networkIf, .usbBus:
            GenericDeviceView(node: node)
        case .battery:
            BatteryView(node: node)
        case .batteryManager:
            // The manager is just a thin wrapper around the battery; surface
            // the battery directly when we can.
            if let battery = node.children.first(where: { $0.kind == .battery }) {
                BatteryView(node: battery)
            } else {
                GenericDeviceView(node: node)
            }
        case .i2cBus, .spiBus, .busDevice, .socCoprocessor:
            // No scanner surfaces these as sidebar roots anymore; they can
            // still appear inside generic registry subtrees, so give them
            // the generic property page rather than nothing.
            GenericDeviceView(node: node)
        default:
            EmptyView()
        }
    }

    /// Walk parents up to find a USB controller, then look up its TB context.
    private func ancestorTBContext(for node: TBNode) -> TBNodeID? {
        var current: TBNode? = node
        for _ in 0..<16 {
            guard let c = current else { return nil }
            if c.kind == .usbController { return tbContextForUSB(c.id) }
            current = parentLookup(c.id)
        }
        return nil
    }
}

// MARK: - Hero header

private struct HeroHeader: View {
    let node: TBNode

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(node.kind.accentColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: node.kind.sfSymbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(node.kind.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title).font(.title2).bold().textSelection(.enabled)
                if let s = node.subtitle, !s.isEmpty {
                    Text(s).foregroundStyle(.secondary)
                }
                StatusPill(node: node)
            }
            Spacer()
        }
    }
}

private struct StatusPill: View {
    let node: TBNode

    var body: some View {
        if let (label, color) = state {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption.weight(.medium)).foregroundStyle(color)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    private var state: (String, Color)? {
        switch node.kind {
        case .port:
            // Lane adapters report Link Up/Inactive via Current Link Speed.
            // Function adapters (DP / USB / PCIe) don't have a link speed —
            // their "is this tunnel up?" signal is a non-empty Hop Table.
            // Treating them with the lane heuristic shows "Inactive" on an
            // active DP output, which is confusing.
            let desc = node.properties["Description"]?.asString ?? ""
            if isFunctionAdapterDescription(desc) {
                return hasActiveHopTable(node) ? ("Active", .green) : ("Idle", .secondary)
            }
            if desc == "Port is inactive" { return ("Disabled", .secondary) }
            let speed = node.properties["Current Link Speed"]?.asUInt ?? 0
            if speed == 0 { return ("Inactive", .secondary) }
            // Empty downstream lane ports on device routers publish idle
            // defaults (CLS=8 / LBW=100) — require a real peer signal
            // (nested peer port, hop table, or live Link Bandwidth) before
            // claiming the link is up. See `tbLaneLinkUp`.
            if !tbLaneLinkUp(props: node.properties, childCount: node.children.count) {
                return ("Idle", .secondary)
            }
            return ("Link Up", .green)
        case .switch:
            let depth = node.properties["Depth"]?.asUInt ?? 0
            return depth == 0 ? ("Built-in", .blue) : ("Connected", .green)
        case .controller:
            return ("Online", .green)
        default:
            return nil
        }
    }
}

/// Find the first switch (router) reachable under this lane port, walking
/// through intermediate port wrappers. Returns nil when nothing is plugged
/// in. Mirrors `TopologyMapper.findDownstreamLink` but stays in the view
/// layer so we don't have to thread the topology mapper into every PortView.
nonisolated private func findDownstreamSwitch(under node: TBNode) -> TBNode? {
    var stack = node.children
    while !stack.isEmpty {
        let n = stack.removeFirst()
        if n.kind == .switch { return n }
        if n.kind == .port { stack.append(contentsOf: n.children) }
    }
    return nil
}

/// Climb the IOService tree from a node to the first switch (router)
/// ancestor — the *upstream side* of whatever link the node sits on. For a
/// host lane adapter that's the host root switch; for the device-side peer
/// lane it climbs through the host lane to the same root. Used to read
/// tunnel reservations from the side where the kernel publishes real
/// numbers (the device-side router's function adapters carry placeholders).
private func findAncestorSwitch(of node: TBNode,
                                parentLookup: (TBNodeID) -> TBNode?) -> TBNode? {
    var current: TBNode? = parentLookup(node.id)
    for _ in 0..<16 {
        guard let c = current else { return nil }
        if c.kind == .switch { return c }
        current = parentLookup(c.id)
    }
    return nil
}

/// True when the kernel's adapter description points at a TB *function*
/// adapter (carries a tunnel — DP/HDMI, USB, PCIe) rather than a lane
/// adapter (the bidirectional TB link itself) or the NHI host interface.
nonisolated private func isFunctionAdapterDescription(_ desc: String) -> Bool {
    switch desc {
    case "DP or HDMI Adapter",
         "USB Adapter",
         "USB Gen T Adapter",
         "PCIe Adapter":
        return true
    default:
        return false
    }
}

/// Non-empty `Hop Table` is the kernel-authoritative signal that a tunnel
/// is currently routed through a function adapter, regardless of whatever
/// bandwidth value it reports (DP adapters in particular publish the
/// placeholder Required=Max=1 on a live stream — see CLAUDE.md note).
nonisolated private func hasActiveHopTable(_ node: TBNode) -> Bool {
    if case .array(let entries) = node.properties["Hop Table"], !entries.isEmpty {
        return true
    }
    return false
}

// MARK: - Controller

private struct ControllerView: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Find the controller's root router (depth 0) to show port summary.
            let rootRouter = node.children.compactMap { findRoot($0) }.first
            let externalDevice = firstExternalDeviceName(in: node)
            let externalCount = countExternalRouters(in: node)

            StatGrid(stats: [
                Stat(label: "Connected Device",
                     value: externalDevice ?? "None",
                     symbol: externalDevice == nil ? "circle.dashed" : "shippingbox"),
                Stat(label: "Time Sync (TMU)",
                     value: tmuLabel(node.properties["TMU Mode"]?.asUInt),
                     symbol: "clock"),
                Stat(label: "Bus Power",
                     value: (node.properties["Using Bus Power"]?.asBool ?? false) ? "Active" : "Idle",
                     symbol: "bolt"),
                Stat(label: "Adapters",
                     value: rootRouter.map { "\($0.children.count)" } ?? "—",
                     symbol: "rectangle.connected.to.line.below"),
                Stat(label: "Chain Routers",
                     value: "\(externalCount)",
                     symbol: "link"),
                Stat(label: "Domain UUID",
                     value: domainUUID() ?? "—",
                     symbol: "number")
            ])

            if let root = rootRouter {
                AdapterBreakdown(router: root,
                                 title: "Built-in Adapters",
                                 onNavigate: onNavigate)
            }
        }
    }

    /// Walk the controller's tree to find the first external (depth > 0)
    /// router and pull a humanised vendor/model label off it.
    private func firstExternalDeviceName(in n: TBNode) -> String? {
        var stack = n.children
        while !stack.isEmpty {
            let cur = stack.removeFirst()
            if cur.kind == .switch, (cur.properties["Depth"]?.asUInt ?? 0) > 0 {
                let vendor = cur.properties["Device Vendor Name"]?.asString
                let model = cur.properties["Device Model Name"]?.asString
                if let v = vendor, let m = model { return "\(v) \(m)" }
                if let m = model { return m }
                return cur.title
            }
            stack.append(contentsOf: cur.children)
        }
        return nil
    }

    /// Pull the local node's domain UUID. Lives one level under the controller.
    private func domainUUID() -> String? {
        for c in node.children where c.kind == .localNode {
            if let u = c.properties["Domain UUID"]?.asString { return u }
        }
        return nil
    }

    private func findRoot(_ n: TBNode) -> TBNode? {
        if n.kind == .switch { return n }
        for c in n.children {
            if let f = findRoot(c) { return f }
        }
        return nil
    }

    private func countExternalRouters(in n: TBNode) -> Int {
        var c = 0
        walk(n) { node in
            if node.kind == .switch, (node.properties["Depth"]?.asUInt ?? 0) > 0 {
                c += 1
            }
        }
        return c
    }

    private func tmuLabel(_ v: UInt64?) -> String {
        switch v {
        case 0: return "Disabled"
        case 1: return "Low resolution"
        case 2: return "High res, unidirectional"
        case 3: return "High res, bidirectional"
        default: return v.map(String.init) ?? "—"
        }
    }
}

// MARK: - Router (switch)

private struct RouterView: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void
    let parentLookup: (TBNodeID) -> TBNode?

    var body: some View {
        let depth = node.properties["Depth"]?.asUInt ?? 0
        let firmware = shortFirmware(node.properties["Firmware Version"]?.asString)

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Vendor",
                     value: node.properties["Device Vendor Name"]?.asString ?? "—",
                     symbol: "building.2"),
                Stat(label: "Model",
                     value: node.properties["Device Model Name"]?.asString ?? "—",
                     symbol: "shippingbox"),
                // The kernel field labelled "Thunderbolt Version" is
                // actually the USB4 spec compliance level (encoded as
                // major.minor — 0x40 → 4.0), not a TB marketing
                // generation. A TB5 dock typically reports "Spec 4.0"
                // because TB5 is built on USB4 v4.0; reading the field
                // as a TB-generation label (the old "Thunderbolt
                // Generation: Spec 4.0") makes users with TB5 docks
                // think they have TB4 hardware. The marketing name in
                // the title already carries the real generation.
                Stat(label: "USB4 Spec Version",
                     value: tbVersionLabel(node.properties["Thunderbolt Version"]?.asUInt),
                     symbol: "bolt.horizontal.circle"),
                Stat(label: "Chain Depth",
                     value: depth == 0 ? "0 (host)" : "\(depth)",
                     symbol: "arrow.triangle.branch"),
                Stat(label: "Firmware",
                     value: firmware ?? "Not reported",
                     symbol: "memorychip"),
                Stat(label: "Unique ID",
                     value: hex(node.properties["UID"]?.asUInt, width: 16),
                     symbol: "barcode",
                     isSecret: true)
            ])

            if depth > 0, let uplink = findUpstreamLane() {
                // Reservations come from the *upstream* router's function
                // adapters (the host root for a first-hop dock) — this
                // router's own adapters publish placeholders (DP: req=max=1)
                // for the same logical tunnels.
                let upstreamRouter = findAncestorSwitch(of: uplink,
                                                        parentLookup: parentLookup)
                UpstreamLinkCard(
                    uplink: uplink,
                    tunnels: upstreamRouter.map { TopologyMapper.summariseTunnels(in: $0) } ?? []
                )
            }
            AdapterBreakdown(router: node,
                             title: depth == 0 ? "Built-in Adapters" : "Adapters",
                             onNavigate: onNavigate)
        }
    }

    /// Walk up the IOService tree to find the lane adapter feeding this router.
    /// On Apple Silicon the chain is `lane → peer port → switch`, so the
    /// upstream lane lives two parents up. We climb until we find a `port`
    /// whose Adapter Type description is "Thunderbolt Port".
    private func findUpstreamLane() -> TBNode? {
        var current: TBNode? = node
        for _ in 0..<8 {
            guard let c = current else { return nil }
            guard let parent = parentLookup(c.id) else { return nil }
            if parent.kind == .port,
               (parent.properties["Description"]?.asString == "Thunderbolt Port") {
                return parent
            }
            current = parent
        }
        return nil
    }

    private func shortFirmware(_ v: String?) -> String? {
        guard let v, !v.isEmpty else { return nil }
        if let range = v.range(of: "__") {
            return String(v[..<range.lowerBound])
        }
        return v
    }

    private func hex(_ v: UInt64?, width: Int) -> String {
        guard let v else { return "—" }
        return String(format: "0x%0\(width)llX", v)
    }

    private func tbVersionLabel(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        let major = (v >> 4) & 0xF
        let minor = v & 0xF
        return "Spec \(major).\(minor)"
    }
}

/// Categorised count of port adapters in a router.
private struct AdapterBreakdown: View {
    let router: TBNode
    let title: String
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let cats = categorise(router.children)
        SectionCard(title: title, symbol: "rectangle.grid.2x2") {
            VStack(spacing: 0) {
                ForEach(cats, id: \.0) { kind, ports in
                    AdapterCategoryRow(category: kind, ports: ports, onNavigate: onNavigate)
                    if cats.last?.0 != kind { Divider() }
                }
            }
        }
    }

    private func categorise(_ ports: [TBNode]) -> [(AdapterCategory, [TBNode])] {
        var buckets: [AdapterCategory: [TBNode]] = [:]
        for p in ports where p.kind == .port {
            let desc = p.properties["Description"]?.asString ?? ""
            let cat = AdapterCategory(description: desc)
            buckets[cat, default: []].append(p)
        }
        return AdapterCategory.allCases.compactMap { cat in
            guard let arr = buckets[cat], !arr.isEmpty else { return nil }
            return (cat, arr.sorted { ($0.properties["Port Number"]?.asUInt ?? 0) < ($1.properties["Port Number"]?.asUInt ?? 0) })
        }
    }
}

private enum AdapterCategory: String, CaseIterable, Hashable {
    case lane, hostInterface, displayPort, usb, pcie, inactive, other

    /// Categorise by the kernel's authoritative `Description` string.
    /// Adapter Type integer codes differ between Apple's controllers and
    /// third-party chips (e.g. Intel JHL9580), so we don't trust them.
    init(description: String) {
        switch description {
        case "Thunderbolt Port": self = .lane
        case "Port is inactive": self = .inactive
        case "Thunderbolt Native Host Interface Adapter": self = .hostInterface
        case "DP or HDMI Adapter": self = .displayPort
        case "USB Adapter", "USB Gen T Adapter": self = .usb
        case "PCIe Adapter": self = .pcie
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .lane: return "Thunderbolt Lane Adapters"
        case .hostInterface: return "Native Host Interface"
        case .displayPort: return "DisplayPort / HDMI Adapters"
        case .usb: return "USB Adapters"
        case .pcie: return "PCIe Adapters"
        case .inactive: return "Inactive Ports"
        case .other: return "Other Adapters"
        }
    }

    var symbol: String {
        switch self {
        case .lane: return "bolt.horizontal"
        case .hostInterface: return "cpu"
        case .displayPort: return "display"
        case .usb: return "cable.connector"
        case .pcie: return "square.stack.3d.up"
        case .inactive: return "circle.dashed"
        case .other: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .lane: return .blue
        case .hostInterface: return .indigo
        case .displayPort: return .pink
        case .usb: return .teal
        case .pcie: return .green
        case .inactive: return .secondary
        case .other: return .gray
        }
    }
}

private struct AdapterCategoryRow: View {
    let category: AdapterCategory
    let ports: [TBNode]
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: category.symbol)
                    .foregroundStyle(category.color)
                    .frame(width: 22)
                Text(category.title).font(.callout.weight(.medium))
                Text("\(ports.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(category.color.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
            }
            FlowChips {
                ForEach(ports, id: \.id) { p in
                    Button {
                        onNavigate(p.id)
                    } label: {
                        AdapterChip(port: p, color: category.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 30)
        }
        .padding(.vertical, 8)
    }
}

private struct AdapterChip: View {
    let port: TBNode
    let color: Color

    var body: some View {
        let n = port.properties["Port Number"]?.asUInt ?? 0
        let desc = port.properties["Description"]?.asString ?? ""
        let isLane = desc == "Thunderbolt Port"
        let isInactive = desc == "Port is inactive"
        let speed = port.properties["Current Link Speed"]?.asUInt ?? 0
        let required = port.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
        let maxAlloc = port.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
        let hopActive = hasActiveHopTable(port)
        // Lane link state needs more than Current Link Speed — empty
        // downstream lanes on device routers publish idle defaults
        // (CLS=8 / LBW=100) that would light the chip up as a live TB3
        // link. See `tbLaneLinkUp`.
        let laneUp = isLane && tbLaneLinkUp(props: port.properties,
                                            childCount: port.children.count)
        let highlight = isLane ? laneUp : (required > 0 || maxAlloc > 0 || hopActive)

        HStack(spacing: 5) {
            Text("Port \(n)").font(.caption2.monospacedDigit())
            if let trailing = trailingLabel(isLane: isLane,
                                            isInactive: isInactive,
                                            laneUp: laneUp,
                                            speed: speed,
                                            required: required,
                                            maxAlloc: maxAlloc,
                                            hopActive: hopActive) {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background((highlight ? color : .secondary).opacity(0.12))
        .overlay(
            Capsule().strokeBorder((highlight ? color : .secondary).opacity(0.35), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }

    /// True if the port's `Hop Table` has at least one entry — the kernel-
    /// authoritative signal that a tunnel is currently routed through this
    /// adapter, regardless of whatever bandwidth value it reports.
    private func hasActiveHopTable(_ port: TBNode) -> Bool {
        if case .array(let entries) = port.properties["Hop Table"], !entries.isEmpty {
            return true
        }
        return false
    }

    private func trailingLabel(isLane: Bool,
                               isInactive: Bool,
                               laneUp: Bool,
                               speed: UInt64,
                               required: UInt64,
                               maxAlloc: UInt64,
                               hopActive: Bool) -> String? {
        if isInactive { return nil }
        if isLane {
            return laneUp ? tbGenerationShortLabel(speed) : "Idle"
        }
        // Function adapter (DP / USB / PCIe). The kernel sometimes reports a
        // placeholder `Required Bandwidth Allocated = 1` (= 100 Mb/s) on an
        // active tunnel — DP streams in particular reserve almost nothing on
        // the TB link. Prefer the planned `Maximum Bandwidth Allocated` when
        // it's larger; fall back to "Active" when the tunnel is up but the
        // bandwidth fields are unreliable.
        let meaningful: UInt64 = 10 // ≥1 Gb/s = a real reservation, not a token
        let bestValue = max(required, maxAlloc)
        if bestValue >= meaningful {
            return tbBandwidthLabel(bestValue)
        }
        if hopActive || bestValue > 0 {
            return "Active"
        }
        return "Unused"
    }
}

// MARK: - Upstream link card

private struct UpstreamLinkCard: View {
    /// The upstream lane adapter on the host side feeding this router.
    let uplink: TBNode
    /// Tunnel summaries from the *upstream-side* router's function
    /// adapters — the kernel-authoritative reservation source. Summing the
    /// device router's own adapters instead reads placeholders (DP:
    /// req=max=1) and shows a live 34 Gb/s DP stream as "negligible".
    let tunnels: [PortTunnel]

    var body: some View {
        let bw = uplink.properties["Link Bandwidth"]?.asUInt ?? 0
        let currentSpeed = uplink.properties["Current Link Speed"]?.asUInt ?? 0
        let width = uplink.properties["Current Link Width"]?.asUInt ?? 0
        let reserved = tunnels.reduce(UInt64(0)) { $0 + $1.reservedBandwidth }
        let maxAlloc = tunnels.reduce(UInt64(0)) { $0 + $1.maxBandwidth }

        SectionCard(title: "Uplink to Host", symbol: "arrow.up.right.circle") {
            VStack(alignment: .leading, spacing: 12) {
                if currentSpeed > 0 {
                    HStack(spacing: 14) {
                        Label(tbLinkSpeedLabel(currentSpeed), systemImage: "antenna.radiowaves.left.and.right")
                        if width > 0 {
                            Label(tbCurrentLinkWidthLabel(width), systemImage: "arrow.left.and.right")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if bw > 0 {
                    BandwidthBar(linkBandwidth: bw,
                                 required: reserved,
                                 maximum: maxAlloc)
                }
                if !tunnels.isEmpty {
                    TunnelBreakdownList(tunnels: tunnels, linkBandwidth: bw)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Per-category breakdown (DP / USB / PCIe rows) below the aggregate
/// bandwidth bar — lets the user see which class of traffic is eating the
/// reservation. Renders nothing when no class has a real reservation.
///
/// `consumers` is the per-tunnel-class device attribution (displays
/// for DP, USB endpoints for USB, etc). The kernel doesn't expose a
/// per-device tunnel reservation, so consumers are listed beneath the
/// class with a name + lightweight subtitle rather than a hard wattage.
struct TunnelBreakdownList: View {
    let tunnels: [PortTunnel]
    let linkBandwidth: UInt64
    var consumers: [PortTunnel.Kind: [TunnelConsumer]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Link Members")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(tunnels, id: \.self) { t in
                VStack(alignment: .leading, spacing: 4) {
                    TunnelBreakdownRow(tunnel: t, linkBandwidth: linkBandwidth)
                    if let list = consumers[t.kind], !list.isEmpty {
                        ForEach(list) { c in
                            TunnelConsumerRow(consumer: c,
                                              kind: t.kind)
                        }
                    }
                }
            }
        }
    }
}

/// One device (or chassis-level placeholder) attributed to a tunnel class.
/// The kernel doesn't publish per-device tunnel reservations, so we just
/// surface the device's name + a one-line hint about what it is — enough
/// for the user to recognise which physical thing is using the dock link.
struct TunnelConsumer: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
}

private struct TunnelBreakdownRow: View {
    let tunnel: PortTunnel
    let linkBandwidth: UInt64

    var body: some View {
        let cat = tunnelCategoryColor(tunnel.kind)
        let real = max(tunnel.reservedBandwidth, tunnel.maxBandwidth) >= 10
        HStack(spacing: 10) {
            Image(systemName: tunnel.symbol)
                .foregroundStyle(cat)
                .frame(width: 18)
            Text(tunnel.label).font(.caption.weight(.medium))
            Text("× \(tunnel.adapterCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if real {
                Text("Reserved \(tbBandwidthLabel(tunnel.reservedBandwidth))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("· max \(tbBandwidthLabel(tunnel.maxBandwidth))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("Active (negligible reservation)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct TunnelConsumerRow: View {
    let consumer: TunnelConsumer
    let kind: PortTunnel.Kind

    var body: some View {
        HStack(spacing: 8) {
            // Indented past the tunnel-class icon column so the consumers
            // visually hang off the category row above.
            Rectangle().fill(Color.clear).frame(width: 18, height: 1)
            Image(systemName: consumerSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .font(.caption2)
            Text(consumer.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let s = consumer.subtitle, !s.isEmpty {
                Text("· \(s)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.leading, 4)
    }

    private var consumerSymbol: String {
        switch kind {
        case .displayPort: return "display"
        case .usb: return "cable.connector"
        case .pcie: return "square.stack.3d.up"
        }
    }
}

/// Build the per-tunnel-class consumer attribution for a physical port.
/// DP gets the displays attributed to the port; USB gets the top non-hub
/// devices under the port; PCIe is left empty unless we discover the dock
/// publishes PCIe descendants in IOKit (it usually doesn't on Apple Silicon,
/// since the dock's NVMe is hidden behind a vendor-bridged enclosure that
/// only enumerates over USB).
@MainActor
func tunnelConsumers(forPort port: PhysicalPort,
                     displays: [DisplayInfo]) -> [PortTunnel.Kind: [TunnelConsumer]] {
    var out: [PortTunnel.Kind: [TunnelConsumer]] = [:]

    // DisplayPort → displays attributed to this port. Adapter ID is unique
    // when the kernel exposes one; otherwise fall back to the display ID.
    if !displays.isEmpty {
        out[.displayPort] = displays.map { d in
            TunnelConsumer(id: "dp-\(d.id.raw)",
                           title: d.title,
                           subtitle: displaySubtitle(d))
        }
    }

    // USB → the meaningful endpoint devices on the port. Skip hubs (the
    // dock's internals) and per-interface entries; the user wants to see
    // "what's the storage / mouse / NIC eating the link", not the dock's
    // hub fabric. List every endpoint — no cap. The card scrolls with the
    // page; truncating to "… and N more" hides the device the user is
    // looking for in exactly the busy-dock case where they care most.
    let usbEndpoints = port.attachedUSBDevices
        .filter { $0.kind == .usbDevice }
        .filter { isMeaningfulUSBEndpoint($0) }
    if !usbEndpoints.isEmpty {
        out[.usb] = usbEndpoints.map { dev in
            TunnelConsumer(id: "usb-\(dev.id.raw)",
                           title: usbEndpointTitle(dev),
                           subtitle: usbEndpointSubtitle(dev))
        }
    }

    return out
}

private func displaySubtitle(_ d: DisplayInfo) -> String? {
    var parts: [String] = []
    if let w = d.widthPixels, let h = d.heightPixels, w > 0, h > 0 {
        parts.append("\(w) × \(h)")
    }
    // Prefer the refresh rate the panel is actually running at; the max
    // is a capability ceiling ("144 Hz" on a display driven at 120 Hz).
    if let hz = d.currentRefreshHz {
        parts.append("\(Int(hz.rounded())) Hz")
    } else if let mx = d.maxRefreshHz {
        parts.append("up to \(Int(mx.rounded())) Hz")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private func isMeaningfulUSBEndpoint(_ node: TBNode) -> Bool {
    // Filter out the dock's own internal USB controller / hub passthroughs
    // (BillBoard descriptors, the dock-internal "Anker Prime Docking Station"
    // hub entries published on the USB tree, Apple's HID composite bus, etc.).
    // Anything that's classified as a hub is already skipped at the call
    // site; here we drop a few specific endpoints that aren't real "things
    // plugged into the dock".
    let title = node.title.lowercased()
    if title.contains("billboard") { return false }
    if title == "usb hub" || title.hasSuffix(" hub") { return false }
    return true
}

private func usbEndpointTitle(_ node: TBNode) -> String {
    node.title
}

private func usbEndpointSubtitle(_ node: TBNode) -> String? {
    let speed = node.properties["Device Speed"]?.asUInt
        ?? node.properties["kUSBCurrentSpeed"]?.asUInt
    let bcdUSB = node.properties["bcdUSB"]?.asUInt
    let vendor = node.properties["kUSBVendorString"]?.asString
        ?? node.properties["USB Vendor Name"]?.asString
    var parts: [String] = []
    if let v = vendor, !v.isEmpty { parts.append(v) }
    // Show negotiated alongside the declared protocol version so a USB-3
    // device downgraded to the 2.0 bus doesn't read as "just a USB-2
    // device" — the user sees both and the ↓ marker telling them where to
    // look. The declared label is version-only (`usbDeclaredVersionLabel`)
    // because bcdUSB doesn't encode the Gen/lane ceiling.
    if let s = speed, s > 0 {
        if usbIsDowngraded(bcdUSB: bcdUSB, currentSpeed: speed),
           let declared = usbDeclaredVersionLabel(bcdUSB) {
            parts.append("\(usbSpeedShortLabel(s)) ↓ \(declared)")
        } else {
            parts.append(usbSpeedShortLabel(s))
        }
    } else if let declared = usbDeclaredVersionLabel(bcdUSB) {
        parts.append(declared)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

nonisolated private func tunnelCategoryColor(_ kind: PortTunnel.Kind) -> Color {
    switch kind {
    case .displayPort: return .pink
    case .usb: return .teal
    case .pcie: return .green
    }
}

// MARK: - Port

private struct PortView: View {
    let node: TBNode
    let parentLookup: (TBNodeID) -> TBNode?

    var body: some View {
        let description = node.properties["Description"]?.asString ?? "Port"
        if isFunctionAdapterDescription(description) {
            FunctionAdapterPortView(node: node, description: description)
        } else {
            laneAdapterContent(description: description)
        }
    }

    /// Lane-adapter / NHI / inactive-port view — the original PortView body.
    /// Function adapters route through `FunctionAdapterPortView` instead
    /// because Current Link Speed / Width / Link Negotiation are concepts
    /// that don't apply to a DP / USB / PCIe tunnel adapter.
    @ViewBuilder
    private func laneAdapterContent(description: String) -> some View {
        let currentSpeed = node.properties["Current Link Speed"]?.asUInt ?? 0
        let targetSpeed = node.properties["Target Link Speed"]?.asUInt ?? 0
        let supportedSpeed = node.properties["Supported Link Speed"]?.asUInt ?? 0
        let currentWidth = node.properties["Current Link Width"]?.asUInt ?? 0
        let targetWidth = node.properties["Target Link Width"]?.asUInt ?? 0
        let supportedWidth = node.properties["Supported Link Width"]?.asUInt ?? 0
        let bw = node.properties["Link Bandwidth"]?.asUInt ?? 0
        // Per-lane Required / Maximum is an outer-wrapper partial aggregate
        // that disagrees with the actual sum across the link's tunnels.
        // When this lane carries a downstream switch, sum the function
        // adapters of the *upstream-side* router (the lane's ancestor
        // switch — the host root for a host lane). That's the side where
        // the kernel publishes real reservations; the device-side router's
        // adapters carry placeholders (DP: req=max=1 on a live stream), so
        // summing there reads a 34 Gb/s DP reservation as 200 Mb/s. Same
        // source `TopologyMapper.makePort` uses for `bandwidthSummary`.
        // Fall back to the lane's published numbers when nothing is
        // connected (no switch underneath).
        let downstream = findDownstreamSwitch(under: node)
        let upstreamRouter = downstream != nil
            ? findAncestorSwitch(of: node, parentLookup: parentLookup)
            : nil
        let tunnels = upstreamRouter.map { TopologyMapper.summariseTunnels(in: $0) } ?? []
        let summedReserved = tunnels.reduce(UInt64(0)) { $0 + $1.reservedBandwidth }
        let summedMax = tunnels.reduce(UInt64(0)) { $0 + $1.maxBandwidth }
        let req = upstreamRouter != nil ? summedReserved
            : (node.properties["Required Bandwidth Allocated"]?.asUInt ?? 0)
        let maxAlloc = upstreamRouter != nil ? summedMax
            : (node.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0)

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Adapter", value: description,
                     symbol: iconFor(description: description)),
                Stat(label: "Port", value: node.properties["Port Number"]?.display ?? "—",
                     symbol: "number"),
                Stat(label: "Generation",
                     value: currentSpeed > 0 ? tbLinkSpeedLabel(currentSpeed) : "Inactive",
                     symbol: "antenna.radiowaves.left.and.right"),
                Stat(label: "Width",
                     value: currentWidth > 0 ? tbCurrentLinkWidthLabel(currentWidth) : "—",
                     symbol: "arrow.left.and.right"),
                Stat(label: "Negotiated Rate",
                     value: tbCurrentLinkRateLabel(speed: currentSpeed, width: currentWidth) ?? "—",
                     symbol: "speedometer"),
                Stat(label: "Lane",
                     value: node.properties["Lane"]?.display ?? "—",
                     symbol: "bolt"),
                Stat(label: "Bus Power",
                     value: node.properties["Bus Power"]?.display ?? "—",
                     symbol: "bolt.fill")
            ])

            // Bandwidth bar (only when link is up).
            if bw > 0 {
                SectionCard(title: "Bandwidth Allocation", symbol: "speedometer") {
                    VStack(alignment: .leading, spacing: 10) {
                        BandwidthBar(linkBandwidth: bw, required: req, maximum: maxAlloc)
                            .padding(.vertical, 4)
                        if !tunnels.isEmpty {
                            Divider()
                            TunnelBreakdownList(tunnels: tunnels, linkBandwidth: bw)
                        }
                    }
                }
            }

            // Negotiation card.
            SectionCard(title: "Link Negotiation", symbol: "waveform.path.ecg") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.trailing)
                        Text("Speed").foregroundStyle(.secondary).font(.caption)
                        Text("Width").foregroundStyle(.secondary).font(.caption)
                    }
                    Divider()
                    GridRow {
                        Text("Current").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(currentSpeed > 0 ? tbLinkSpeedLabel(currentSpeed) : "—")
                        Text(currentWidth > 0 ? tbCurrentLinkWidthLabel(currentWidth) : "—")
                    }
                    GridRow {
                        Text("Target").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        // Target fields use different encodings from Current.
                        // See `tbSupportedLinkSpeedLabel` / `tbTargetLinkWidthLabel`.
                        Text(targetSpeed > 0 ? tbSupportedLinkSpeedLabel(targetSpeed) : "—")
                        Text(targetWidth > 0 ? tbTargetLinkWidthLabel(targetWidth) : "—")
                    }
                    GridRow {
                        Text("Supported").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        // Supported is a bitmask of speed codes; Width
                        // uses the same encoding as Current.
                        Text(supportedSpeed > 0 ? tbSupportedLinkSpeedLabel(supportedSpeed) : "—")
                        Text(supportedWidth > 0 ? tbCurrentLinkWidthLabel(supportedWidth) : "—")
                    }
                }
                .font(.callout)
                .padding(.vertical, 4)
            }

            // Active paths (Hop Table) rendered cleanly.
            if let hops = node.properties["Hop Table"], case .array(let arr) = hops, !arr.isEmpty {
                SectionCard(title: "Active Tunnels (\(arr.count))", symbol: "arrow.triangle.swap") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(arr.enumerated()), id: \.offset) { idx, v in
                            if case .dictionary(let kv) = v {
                                let dict = Dictionary(kv, uniquingKeysWith: { a, _ in a })
                                HopRow(index: idx,
                                       hopID: dict["Hop ID"]?.asUInt,
                                       dstPort: dict["Dst Port"]?.asUInt,
                                       dstHop: dict["Dst Hop ID"]?.asUInt,
                                       counter: dict["Counter"]?.asUInt)
                                if idx < arr.count - 1 { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }
}

private func iconFor(description: String) -> String {
    switch description {
    case "Thunderbolt Port": return "bolt.horizontal"
    case "Port is inactive": return "circle.dashed"
    case "Thunderbolt Native Host Interface Adapter": return "cpu"
    case "DP or HDMI Adapter": return "display"
    case "USB Adapter", "USB Gen T Adapter": return "cable.connector"
    case "PCIe Adapter": return "square.stack.3d.up"
    default: return "questionmark.circle"
    }
}

/// Detail view for a TB function adapter (DP/HDMI, USB, PCIe). Function
/// adapters don't have a physical link — their meaningful state is the
/// hop table and whatever bandwidth the kernel reports allocated to the
/// tunnels routed through them. The original `PortView` layout (current/
/// target/supported link speed + width, full bandwidth bar) makes a live
/// DP output read as "Inactive · 100 Mb/s" which is the opposite of
/// what's happening.
private struct FunctionAdapterPortView: View {
    let node: TBNode
    let description: String

    var body: some View {
        let portNum = node.properties["Port Number"]?.asUInt
        let req = node.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
        let maxAlloc = node.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
        let linkBw = node.properties["Link Bandwidth"]?.asUInt ?? 0
        let hopTable: [IORegValue] = {
            if case let .array(arr) = node.properties["Hop Table"] { return arr }
            return []
        }()
        let bestAlloc = max(req, maxAlloc)
        // CLAUDE.md: DP adapters often publish Required=Max=1 (100 Mb/s)
        // on an active tunnel — that's a placeholder, not the real
        // allocation. Treat values <1 Gb/s as decorative.
        let hasRealReservation = bestAlloc >= 10
        let isActive = !hopTable.isEmpty

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Adapter",
                     value: description,
                     symbol: iconFor(description: description)),
                Stat(label: "Port",
                     value: portNum.map(String.init) ?? "—",
                     symbol: "number"),
                Stat(label: "Status",
                     value: isActive ? "Active" : "Idle",
                     symbol: isActive ? "checkmark.circle.fill" : "circle.dashed"),
                Stat(label: "Active Tunnels",
                     value: "\(hopTable.count)",
                     symbol: "arrow.triangle.swap"),
                Stat(label: "Link Capacity",
                     value: linkBw > 0 ? tbBandwidthLabel(linkBw) : "—",
                     symbol: "gauge.with.dots.needle.67percent"),
                Stat(label: "Reserved",
                     value: reservedBandwidthLabel(req: req,
                                                   maxAlloc: maxAlloc,
                                                   isActive: isActive),
                     symbol: "speedometer")
            ])

            // Only show the bandwidth bar when there's a real reservation
            // (≥1 Gb/s). The placeholder 100 Mb/s case is misleading —
            // function adapters don't statically reserve the link.
            if hasRealReservation && linkBw > 0 {
                SectionCard(title: "Bandwidth Allocation", symbol: "speedometer") {
                    BandwidthBar(linkBandwidth: linkBw,
                                 required: req,
                                 maximum: maxAlloc)
                        .padding(.vertical, 4)
                }
            }

            // Hop Table — the authoritative routing record. Each entry
            // describes a stream this adapter is forwarding: which hop
            // ID arrives here, which port + hop it goes to next.
            if !hopTable.isEmpty {
                SectionCard(title: "Active Tunnels (\(hopTable.count))",
                            symbol: "arrow.triangle.swap") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hopTable.enumerated()), id: \.offset) { idx, v in
                            if case .dictionary(let kv) = v {
                                let dict = Dictionary(kv, uniquingKeysWith: { a, _ in a })
                                HopRow(index: idx,
                                       hopID: dict["Hop ID"]?.asUInt,
                                       dstPort: dict["Dst Port"]?.asUInt,
                                       dstHop: dict["Dst Hop ID"]?.asUInt,
                                       counter: dict["Counter"]?.asUInt)
                                if idx < hopTable.count - 1 { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func reservedBandwidthLabel(req: UInt64, maxAlloc: UInt64, isActive: Bool) -> String {
        let best = max(req, maxAlloc)
        if best >= 10 { return tbBandwidthLabel(best) }
        if isActive { return "Negligible (no static reservation)" }
        return "—"
    }
}

private struct HopRow: View {
    let index: Int
    let hopID: UInt64?
    let dstPort: UInt64?
    let dstHop: UInt64?
    let counter: UInt64?

    var body: some View {
        HStack(spacing: 12) {
            Text("Tunnel \(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            HStack(spacing: 8) {
                Tag(label: "hop \(hopID.map(String.init) ?? "—")", color: .blue)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Tag(label: "port \(dstPort.map(String.init) ?? "—")", color: .orange)
                Tag(label: "hop \(dstHop.map(String.init) ?? "—")", color: .blue)
            }
            Spacer()
            if let c = counter {
                Text("counter \(c)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
    }
}

private struct Tag: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Local node & generic devices

private struct LocalNodeView: View {
    let node: TBNode
    var body: some View {
        StatGrid(stats: [
            Stat(label: "Domain UUID",
                 value: node.properties["Domain UUID"]?.asString ?? "—",
                 symbol: "number"),
            Stat(label: "This Mac",
                 value: "Local TB endpoint",
                 symbol: "macbook")
        ])
    }
}

private struct GenericDeviceView: View {
    let node: TBNode
    var body: some View {
        EmptyView()
    }
}

// MARK: - Bandwidth bar (shared)

struct BandwidthBar: View {
    let linkBandwidth: UInt64
    let required: UInt64
    let maximum: UInt64

    var body: some View {
        let total = Double(linkBandwidth)
        let req = Double(required)
        let maxD = Double(maximum)
        let reqFrac = total > 0 ? min(req / total, 1.0) : 0
        // "Max planned" is the per-adapter kernel `Maximum Bandwidth Allocated`
        // summed across all active function adapters. It's a worst-case
        // ceiling — the TB scheduler arbitrates so the link's tunnels never
        // all peak at once, and on docks the sum routinely exceeds link
        // capacity. We surface the ceiling as a marker, not as a parallel
        // fill, and we don't paint it as an error condition.
        let maxFrac = total > 0 ? min(maxD / total, 1.0) : 0
        let showPeakMarker = maximum > required && maximum > 0

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Link capacity")
                Spacer()
                Text(tbBandwidthLabel(linkBandwidth))
                    .font(.callout.bold().monospaced())
            }
            .font(.callout)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 22)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: geo.size.width * reqFrac)
                        if showPeakMarker {
                            // Slim marker at the "peak planned" position —
                            // readable against the orange + quaternary
                            // backdrop, distinct from the bar fill so the eye
                            // doesn't read it as additional usage. Clamp
                            // the offset so a tiny maxFrac (≈100 Mb/s on a
                            // 80 Gb/s link) doesn't push the marker off the
                            // left edge, and so the marker stays inside the
                            // capsule when maxFrac == 1.0.
                            let markerW: CGFloat = 2
                            let rawOffset = geo.size.width * maxFrac - markerW / 2
                            Rectangle()
                                .fill(Color.yellow.opacity(0.85))
                                .frame(width: markerW, height: 22)
                                .offset(x: min(max(0, rawOffset),
                                               geo.size.width - markerW))
                        }
                    }
                }
                .frame(height: 22)
            }

            HStack(spacing: 16) {
                BWLegend(color: .orange, label: "Reserved", value: tbBandwidthLabel(required))
                if showPeakMarker {
                    BWLegend(color: Color.yellow.opacity(0.85),
                             label: "Peak planned",
                             value: tbBandwidthLabel(maximum))
                }
                Spacer()
                Text(total > 0 ? String(format: "%.0f%% reserved", reqFrac * 100) : "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
    }
}

private struct BWLegend: View {
    let color: Color
    let label: String
    let value: String
    var tint: Color? = nil
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospaced().foregroundStyle(tint ?? .primary)
        }
    }
}

// MARK: - Developer details disclosure

private struct DeveloperDisclosure: View {
    let node: TBNode
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .frame(width: 12)
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.secondary)
                    Text("IO Registry Details")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                PropertyTableView(node: node)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Reusable building blocks

struct Stat: Hashable {
    let label: String
    let value: String
    let symbol: String
    var isSecret: Bool = false
}

struct StatGrid: View {
    let stats: [Stat]
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(stats, id: \.self) { s in
                StatCell(stat: s)
            }
        }
    }
}

private struct StatCell: View {
    let stat: Stat
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stat.symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(displayValue)
                        .font(.callout.monospaced(stat.isSecret))
                        .textSelection(.enabled)
                        // Reserve space for two lines on every cell so a
                        // single value that wraps (e.g. "TB3/USB4 Gen 2 —
                        // 20 Gb/s per lane") doesn't make its row taller
                        // than the surrounding rows. `LazyVGrid` only
                        // normalises height *within* a row, not across
                        // rows, so without the reservation the second
                        // row reads as visibly shorter than the first.
                        .lineLimit(2, reservesSpace: true)
                    if stat.isSecret && !hovering {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .help(stat.isSecret ? "Hover to reveal" : "")
    }

    private var displayValue: String {
        if !stat.isSecret || hovering { return stat.value }
        return mask(of: stat.value)
    }

    private func mask(of value: String) -> String {
        if value.hasPrefix("0x") {
            return "0x" + String(repeating: "\u{2022}", count: max(value.count - 2, 4))
        }
        if value == "—" { return value }
        return String(repeating: "\u{2022}", count: min(max(value.count, 4), 24))
    }
}

private extension Font {
    func monospaced(_ on: Bool) -> Font { on ? self.monospaced() : self }
}

struct SectionCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Util

private func walk(_ n: TBNode, _ visit: (TBNode) -> Void) {
    visit(n)
    for c in n.children { walk(c, visit) }
}

// MARK: - Flow layout for chips

struct FlowChips<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        FlowLayout(spacing: 6) { content() }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                totalWidth = max(totalWidth, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        totalWidth = max(totalWidth, x - spacing)
        return CGSize(width: totalWidth, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
