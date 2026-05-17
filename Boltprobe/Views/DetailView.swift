//
//  DetailView.swift
//  Boltprobe
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
        case .port: PortView(node: node)
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
            let speed = node.properties["Current Link Speed"]?.asUInt ?? 0
            if speed == 0 { return ("Inactive", .secondary) }
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

// MARK: - Controller

private struct ControllerView: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Find the controller's root router (depth 0) to show port summary.
            let rootRouter = node.children.compactMap { findRoot($0) }.first

            StatGrid(stats: [
                Stat(label: "Generation",
                     value: node.properties["Generation"]?.display ?? "—",
                     symbol: "cpu"),
                Stat(label: "User Client API",
                     value: "v\(node.properties["User Client Version"]?.display ?? "—")",
                     symbol: "gearshape"),
                Stat(label: "Time Sync (TMU)",
                     value: tmuLabel(node.properties["TMU Mode"]?.asUInt),
                     symbol: "clock"),
                Stat(label: "Bus Power",
                     value: (node.properties["Using Bus Power"]?.asBool ?? false) ? "Active" : "Idle",
                     symbol: "bolt"),
                Stat(label: "Total Adapters",
                     value: rootRouter.map { "\($0.children.count)" } ?? "—",
                     symbol: "rectangle.connected.to.line.below"),
                Stat(label: "Connected Routers",
                     value: "\(countExternalRouters(in: node))",
                     symbol: "link")
            ])

            if let root = rootRouter {
                AdapterBreakdown(router: root,
                                 title: "Built-in Router Adapters",
                                 onNavigate: onNavigate)
            }
        }
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
                Stat(label: "Thunderbolt Generation",
                     value: tbVersionLabel(node.properties["Thunderbolt Version"]?.asUInt),
                     symbol: "bolt.horizontal.circle"),
                Stat(label: "Depth in Chain",
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
                UpstreamLinkCard(uplink: uplink)
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
        let highlight = isLane ? (speed > 0) : (required > 0)

        HStack(spacing: 5) {
            Text("Port \(n)").font(.caption2.monospacedDigit())
            if let trailing = trailingLabel(isLane: isLane,
                                            isInactive: isInactive,
                                            speed: speed,
                                            required: required) {
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

    private func trailingLabel(isLane: Bool,
                               isInactive: Bool,
                               speed: UInt64,
                               required: UInt64) -> String? {
        if isInactive { return nil }
        if isLane {
            return speed > 0 ? tbGenerationShortLabel(speed) : "Idle"
        }
        // Function adapter (DP / USB / PCIe). Show reserved bandwidth if any.
        if required > 0 {
            return tbBandwidthLabel(required)
        }
        return "Unused"
    }
}

// MARK: - Upstream link card

private struct UpstreamLinkCard: View {
    /// The upstream lane adapter on the host side feeding this router.
    let uplink: TBNode

    var body: some View {
        let bw = uplink.properties["Link Bandwidth"]?.asUInt ?? 0
        let req = uplink.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
        let maxAlloc = uplink.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
        let currentSpeed = uplink.properties["Current Link Speed"]?.asUInt ?? 0
        let width = uplink.properties["Current Link Width"]?.asUInt ?? 0

        SectionCard(title: "Uplink to Host", symbol: "arrow.up.right.circle") {
            VStack(alignment: .leading, spacing: 12) {
                if currentSpeed > 0 {
                    HStack(spacing: 14) {
                        Label(tbLinkSpeedLabel(currentSpeed), systemImage: "antenna.radiowaves.left.and.right")
                        if width > 0 {
                            Label("\(width) lanes", systemImage: "arrow.left.and.right")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if bw > 0 {
                    BandwidthBar(linkBandwidth: bw, required: req, maximum: maxAlloc)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Port

private struct PortView: View {
    let node: TBNode

    var body: some View {
        let description = node.properties["Description"]?.asString ?? "Port"
        let currentSpeed = node.properties["Current Link Speed"]?.asUInt ?? 0
        let targetSpeed = node.properties["Target Link Speed"]?.asUInt ?? 0
        let supportedSpeed = node.properties["Supported Link Speed"]?.asUInt ?? 0
        let currentWidth = node.properties["Current Link Width"]?.asUInt ?? 0
        let targetWidth = node.properties["Target Link Width"]?.asUInt ?? 0
        let supportedWidth = node.properties["Supported Link Width"]?.asUInt ?? 0
        let bw = node.properties["Link Bandwidth"]?.asUInt ?? 0
        let req = node.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
        let maxAlloc = node.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Adapter", value: description,
                     symbol: iconFor(description: description)),
                Stat(label: "Port", value: node.properties["Port Number"]?.display ?? "—",
                     symbol: "number"),
                Stat(label: "Active Generation",
                     value: currentSpeed > 0 ? tbLinkSpeedLabel(currentSpeed) : "Inactive",
                     symbol: "antenna.radiowaves.left.and.right"),
                Stat(label: "Active Width",
                     value: currentWidth > 0 ? "\(currentWidth) lanes" : "—",
                     symbol: "arrow.left.and.right"),
                Stat(label: "Lane",
                     value: node.properties["Lane"]?.display ?? "—",
                     symbol: "bolt"),
                Stat(label: "Bus Power Drawn",
                     value: node.properties["Bus Power"]?.display ?? "—",
                     symbol: "bolt.fill")
            ])

            // Bandwidth bar (only when link is up).
            if bw > 0 {
                SectionCard(title: "Bandwidth Allocation", symbol: "speedometer") {
                    BandwidthBar(linkBandwidth: bw, required: req, maximum: maxAlloc)
                        .padding(.vertical, 4)
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
                        Text(currentWidth > 0 ? "\(currentWidth) lanes" : "—")
                    }
                    GridRow {
                        Text("Target").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(targetSpeed > 0 ? tbLinkSpeedLabel(targetSpeed) : "—")
                        Text(targetWidth > 0 ? "\(targetWidth) lanes" : "—")
                    }
                    GridRow {
                        Text("Supported").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(supportedSpeed > 0 ? tbLinkSpeedLabel(supportedSpeed) : "—")
                        Text(supportedWidth > 0 ? "\(supportedWidth) lanes" : "—")
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
        Text("Connected device. Open Developer details below for the raw IORegistry entry.")
            .foregroundStyle(.secondary)
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
        let maxFrac = total > 0 ? min(maxD / total, 1.0) : 0
        let overage = maximum > linkBandwidth
        let overFrac = overage ? Double(maximum - linkBandwidth) / Double(maximum) : 0

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
                            .fill(Color.yellow.opacity(0.55))
                            .frame(width: geo.size.width * maxFrac)
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: geo.size.width * reqFrac)
                        if overage {
                            // Hatched red overlay on the right edge to indicate the
                            // planned ceiling exceeds capacity.
                            Capsule()
                                .stroke(Color.red, lineWidth: 1.5)
                                .frame(width: max(geo.size.width * overFrac, 16))
                                .offset(x: geo.size.width - max(geo.size.width * overFrac, 16))
                        }
                    }
                }
                .frame(height: 22)
            }

            HStack(spacing: 16) {
                BWLegend(color: .orange, label: "Reserved", value: tbBandwidthLabel(required))
                BWLegend(color: Color.yellow.opacity(0.55), label: "Max planned",
                         value: tbBandwidthLabel(maximum),
                         tint: overage ? .red : nil)
                Spacer()
                Text(total > 0 ? String(format: "%.0f%% reserved", reqFrac * 100) : "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)

            if overage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Planned bandwidth (\(tbBandwidthLabel(maximum))) exceeds link capacity by \(tbBandwidthLabel(maximum - linkBandwidth)).")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
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
                    Text("Developer details (raw IORegistry)")
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
                        .lineLimit(2)
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
