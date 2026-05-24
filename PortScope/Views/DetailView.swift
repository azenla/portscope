//
//  DetailView.swift
//  PortScope
//
//  Curated, human-readable presentation of a TB / USB / SoC entity. Each
//  detail view is composed from the design-system primitives — Hero,
//  PropertyList, CapacityBar, TileGrid, DisclosureCard. No bespoke heroes,
//  no per-kind tile grids of icon-and-value cells.
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
        DetailContainer {
            BreadcrumbBar(ancestors: ancestors, onNavigate: onNavigate)
            Hero(symbol: node.kind.sfSymbol,
                 title: node.title,
                 subtitle: heroSubtitle,
                 status: heroStatus)
            summary(for: node)
            DisclosureCard("Developer details (raw IORegistry)",
                           icon: "wrench.and.screwdriver") {
                PropertyTableView(node: node)
            }
        }
    }

    private var heroSubtitle: String? {
        node.subtitle?.isEmpty == false ? node.subtitle : nil
    }

    /// Pill alongside the hero title. Derived from the node's kind and a
    /// couple of key properties; only present for entities that genuinely
    /// have a status (port / router / controller). USB devices / generic
    /// nodes drop the pill and rely on their subtitle text.
    private var heroStatus: PSStatus? {
        switch node.kind {
        case .port:
            let desc = node.properties["Description"]?.asString ?? ""
            if isFunctionAdapterDescription(desc) {
                return hasActiveHopTable(node) ? .active : .idle
            }
            if desc == "Port is inactive" { return .disabled }
            let speed = node.properties["Current Link Speed"]?.asUInt ?? 0
            return speed > 0 ? .active : .idle
        case .switch:
            let depth = node.properties["Depth"]?.asUInt ?? 0
            return depth == 0 ? .builtIn : .active
        case .controller:
            return .active
        default:
            return nil
        }
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
        case .battery:
            BatteryView(node: node)
        case .batteryManager:
            if let battery = node.children.first(where: { $0.kind == .battery }) {
                BatteryView(node: battery)
            } else {
                GenericDeviceView(node: node)
            }
        case .i2cBus, .spiBus:
            BusView(node: node, onNavigate: onNavigate)
        case .busDevice:
            BusSlaveView(node: node)
        case .socCoprocessor:
            SoCCoprocessorView(node: node)
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

/// True when the kernel's adapter description points at a TB *function*
/// adapter (carries a tunnel — DP/HDMI, USB, PCIe) rather than a lane
/// adapter (the bidirectional TB link itself) or the NHI host interface.
nonisolated func isFunctionAdapterDescription(_ desc: String) -> Bool {
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
nonisolated func hasActiveHopTable(_ node: TBNode) -> Bool {
    if case .array(let entries) = node.properties["Hop Table"], !entries.isEmpty {
        return true
    }
    return false
}

// MARK: - TB controller

private struct ControllerView: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let rootRouter = node.children.compactMap { findRoot($0) }.first
        let externalDevice = firstExternalDeviceName(in: node)
        let externalCount = countExternalRouters(in: node)

        PropertyList {
            PropertyRowSpec("Connected device", externalDevice)
            PropertyRowSpec("Time sync (TMU)", tmuLabel(node.properties["TMU Mode"]?.asUInt))
            PropertyRowSpec("Bus power",
                            (node.properties["Using Bus Power"]?.asBool ?? false) ? "Active" : "Idle")
            PropertyRowSpec("Total adapters", rootRouter.map { "\($0.children.count)" })
            PropertyRowSpec("Routers in chain", externalCount > 0 ? "\(externalCount)" : nil)
            PropertyRowSpec("Domain UUID", domainUUID(), mono: true)
        }

        if let root = rootRouter {
            VStack(alignment: .leading, spacing: PSSpacing.m) {
                SectionHeader("Built-in router adapters")
                AdapterBreakdown(router: root, onNavigate: onNavigate)
            }
        }
    }

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

    private func tmuLabel(_ v: UInt64?) -> String? {
        switch v {
        case 0: return "Disabled"
        case 1: return "Low resolution"
        case 2: return "High res, unidirectional"
        case 3: return "High res, bidirectional"
        default: return v.map(String.init)
        }
    }
}

// MARK: - TB router (switch)

private struct RouterView: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void
    let parentLookup: (TBNodeID) -> TBNode?

    var body: some View {
        let depth = node.properties["Depth"]?.asUInt ?? 0
        let firmware = shortFirmware(node.properties["Firmware Version"]?.asString)

        PropertyList {
            PropertyRowSpec("Vendor", node.properties["Device Vendor Name"]?.asString)
            PropertyRowSpec("Model", node.properties["Device Model Name"]?.asString)
            PropertyRowSpec("Thunderbolt",
                            tbVersionLabel(node.properties["Thunderbolt Version"]?.asUInt))
            PropertyRowSpec("Depth", depth == 0 ? "Built-in" : "\(depth)")
            PropertyRowSpec("Firmware", firmware)
            PropertyRowSpec("Unique ID",
                            hex(node.properties["UID"]?.asUInt, width: 16),
                            mono: true,
                            secret: true)
        }

        if depth > 0, let uplink = findUpstreamLane() {
            UpstreamLinkSection(uplink: uplink)
        }

        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader(depth == 0 ? "Built-in adapters" : "Adapters")
            AdapterBreakdown(router: node, onNavigate: onNavigate)
        }
    }

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

    private func hex(_ v: UInt64?, width: Int) -> String? {
        guard let v else { return nil }
        return String(format: "0x%0\(width)llX", v)
    }

    private func tbVersionLabel(_ v: UInt64?) -> String? {
        guard let v else { return nil }
        let major = (v >> 4) & 0xF
        let minor = v & 0xF
        return "Spec \(major).\(minor)"
    }
}

// MARK: - Upstream link

private struct UpstreamLinkSection: View {
    let uplink: TBNode

    var body: some View {
        let bw = uplink.properties["Link Bandwidth"]?.asUInt ?? 0
        let req = uplink.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
        let maxAlloc = uplink.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
        let currentSpeed = uplink.properties["Current Link Speed"]?.asUInt ?? 0
        let width = uplink.properties["Current Link Width"]?.asUInt ?? 0

        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Uplink to host")

            PropertyList {
                PropertyRowSpec("Generation",
                                currentSpeed > 0 ? tbLinkSpeedLabel(currentSpeed) : nil)
                PropertyRowSpec("Width", width > 0 ? "\(width) lanes" : nil)
                PropertyRowSpec("Link capacity",
                                bw > 0 ? tbBandwidthLabel(bw) : nil)
            }

            if bw > 0 {
                let primaryUsage = Double(req)
                let secondaryUsage = Double(maxAlloc)
                CapacityBar(
                    title: "Bandwidth",
                    value: primaryUsage,
                    secondaryValue: secondaryUsage > primaryUsage ? secondaryUsage : nil,
                    capacity: Double(bw),
                    headlineValue: "\(tbBandwidthLabel(req)) of \(tbBandwidthLabel(bw))",
                    legend: legend(req: req, maxAlloc: maxAlloc, bw: bw),
                    tint: PSColor.active
                )
            }
        }
    }

    private func legend(req: UInt64, maxAlloc: UInt64, bw: UInt64) -> String {
        var parts: [String] = []
        if req > 0 { parts.append("\(tbBandwidthLabel(req)) reserved") }
        if maxAlloc > req {
            parts.append("\(tbBandwidthLabel(maxAlloc)) max planned")
        }
        if maxAlloc > bw {
            parts.append("exceeds link by \(tbBandwidthLabel(maxAlloc - bw))")
        }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }
}

// MARK: - Adapter breakdown

private struct AdapterBreakdown: View {
    let router: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let cats = categorise(router.children)
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            ForEach(cats, id: \.0) { kind, ports in
                AdapterCategoryRow(category: kind, ports: ports, onNavigate: onNavigate)
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
            return (cat, arr.sorted { ($0.properties["Port Number"]?.asUInt ?? 0)
                                       < ($1.properties["Port Number"]?.asUInt ?? 0) })
        }
    }
}

private enum AdapterCategory: String, CaseIterable, Hashable {
    case lane, hostInterface, displayPort, usb, pcie, inactive, other

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
        case .lane:          return "Thunderbolt lane adapters"
        case .hostInterface: return "Native host interface"
        case .displayPort:   return "DisplayPort / HDMI adapters"
        case .usb:           return "USB adapters"
        case .pcie:          return "PCIe adapters"
        case .inactive:      return "Inactive ports"
        case .other:         return "Other adapters"
        }
    }

    var symbol: String {
        switch self {
        case .lane:          return "bolt.horizontal"
        case .hostInterface: return "cpu"
        case .displayPort:   return "display"
        case .usb:           return "cable.connector"
        case .pcie:          return "square.stack.3d.up"
        case .inactive:      return "circle.dashed"
        case .other:         return "questionmark.circle"
        }
    }
}

private struct AdapterCategoryRow: View {
    let category: AdapterCategory
    let ports: [TBNode]
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.s) {
            HStack(spacing: PSSpacing.s) {
                Image(systemName: category.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(category.title)
                    .font(PSFont.bodyEmph)
                Text("\(ports.count)")
                    .font(PSFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ChipFlow {
                ForEach(ports, id: \.id) { p in
                    Button {
                        onNavigate(p.id)
                    } label: {
                        AdapterChip(port: p)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 26)
        }
    }
}

private struct AdapterChip: View {
    let port: TBNode

    var body: some View {
        let n = port.properties["Port Number"]?.asUInt ?? 0
        let desc = port.properties["Description"]?.asString ?? ""
        let isLane = desc == "Thunderbolt Port"
        let isInactive = desc == "Port is inactive"
        let speed = port.properties["Current Link Speed"]?.asUInt ?? 0
        let required = port.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
        let maxAlloc = port.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
        let hopActive = hasActiveHopTable(port)
        let active = isLane ? (speed > 0) : (required > 0 || maxAlloc > 0 || hopActive)

        Chip(
            label: chipLabel(port: n,
                             isLane: isLane,
                             isInactive: isInactive,
                             speed: speed,
                             required: required,
                             maxAlloc: maxAlloc,
                             hopActive: hopActive),
            tint: active ? PSColor.active : Color(NSColor.tertiaryLabelColor),
            emphasized: active,
            monospaced: true
        )
    }

    private func chipLabel(port: UInt64,
                           isLane: Bool,
                           isInactive: Bool,
                           speed: UInt64,
                           required: UInt64,
                           maxAlloc: UInt64,
                           hopActive: Bool) -> String {
        let head = "Port \(port)"
        if isInactive { return head }
        if isLane {
            return speed > 0 ? "\(head) · \(tbGenerationShortLabel(speed))" : "\(head) · Idle"
        }
        let best = max(required, maxAlloc)
        if best >= 10 { return "\(head) · \(tbBandwidthLabel(best))" }
        if hopActive || best > 0 { return "\(head) · Active" }
        return "\(head) · Unused"
    }
}

// MARK: - TB port (lane / NHI / function adapter)

private struct PortView: View {
    let node: TBNode

    var body: some View {
        let description = node.properties["Description"]?.asString ?? "Port"
        if isFunctionAdapterDescription(description) {
            FunctionAdapterPortView(node: node, description: description)
        } else {
            LaneAdapterPortView(node: node, description: description)
        }
    }
}

private struct LaneAdapterPortView: View {
    let node: TBNode
    let description: String

    var body: some View {
        let currentSpeed = node.properties["Current Link Speed"]?.asUInt ?? 0
        let currentWidth = node.properties["Current Link Width"]?.asUInt ?? 0
        let bw = currentSpeed > 0 ? (node.properties["Link Bandwidth"]?.asUInt ?? 0) : 0
        let req = node.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
        let maxAlloc = node.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0

        PropertyList {
            PropertyRowSpec("Adapter", description)
            PropertyRowSpec("Port", node.properties["Port Number"]?.display)
            PropertyRowSpec("Generation",
                            currentSpeed > 0 ? tbLinkSpeedLabel(currentSpeed) : nil)
            PropertyRowSpec("Width",
                            currentWidth > 0 ? "\(currentWidth) lanes" : nil)
            PropertyRowSpec("Lane", node.properties["Lane"]?.display)
            PropertyRowSpec("Bus power drawn", node.properties["Bus Power"]?.display)
        }

        if bw > 0 {
            CapacityBar(
                title: "Bandwidth",
                value: Double(req),
                secondaryValue: maxAlloc > req ? Double(maxAlloc) : nil,
                capacity: Double(bw),
                headlineValue: "\(tbBandwidthLabel(req)) of \(tbBandwidthLabel(bw))",
                legend: maxAlloc > req ? "\(tbBandwidthLabel(maxAlloc)) max planned" : nil,
                tint: PSColor.active
            )
        }

        if let hops = node.properties["Hop Table"], case .array(let arr) = hops, !arr.isEmpty {
            HopTableSection(hops: arr)
        }
    }
}

private struct FunctionAdapterPortView: View {
    let node: TBNode
    let description: String

    var body: some View {
        let portNum = node.properties["Port Number"]?.asUInt
        let req = node.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
        let maxAlloc = node.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
        let hopTable: [IORegValue] = {
            if case let .array(arr) = node.properties["Hop Table"] { return arr }
            return []
        }()
        let best = max(req, maxAlloc)
        let hasRealReservation = best >= 10
        let isActive = !hopTable.isEmpty

        PropertyList {
            PropertyRowSpec("Adapter", description)
            PropertyRowSpec("Port", portNum.map(String.init))
            PropertyRowSpec(forcing: "Status", isActive ? "Active" : "Idle")
            PropertyRowSpec(forcing: "Active tunnels", "\(hopTable.count)")
            PropertyRowSpec("Reservation",
                            hasRealReservation
                                ? tbBandwidthLabel(best)
                                : (isActive ? "Negligible (no static reservation)" : nil))
        }

        if !hopTable.isEmpty {
            HopTableSection(hops: hopTable)
        } else {
            EmptyStateNote(text: "No active tunnels — nothing is currently routed through this adapter.")
        }
    }
}

// MARK: - Hop table table

private struct HopTableSection: View {
    let hops: [IORegValue]

    private struct Row: Identifiable {
        let id: Int
        let tunnel: Int
        let hopID: String
        let dstPort: String
        let dstHop: String
        let counter: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Active tunnels (\(hops.count))")
            Table(of: Row.self) {
                TableColumn("Tunnel") { Text("\($0.tunnel)").monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Hop in") { Text($0.hopID).monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("→ Port") { Text($0.dstPort).monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("→ Hop") { Text($0.dstHop).monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Counter") { Text($0.counter).monospacedDigit() }
                    .width(min: 80, ideal: 100)
            } rows: {
                ForEach(rows) { row in
                    TableRow(row)
                }
            }
            .frame(minHeight: CGFloat(min(hops.count + 1, 8)) * 26)
        }
    }

    private var rows: [Row] {
        hops.enumerated().compactMap { idx, v in
            guard case let .dictionary(kv) = v else { return nil }
            let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
            return Row(
                id: idx,
                tunnel: idx + 1,
                hopID: d["Hop ID"]?.asUInt.map(String.init) ?? "—",
                dstPort: d["Dst Port"]?.asUInt.map(String.init) ?? "—",
                dstHop: d["Dst Hop ID"]?.asUInt.map(String.init) ?? "—",
                counter: d["Counter"]?.asUInt.map { "\($0)" } ?? "—"
            )
        }
    }
}

// MARK: - Local node / generic / SoC

private struct LocalNodeView: View {
    let node: TBNode
    var body: some View {
        PropertyList {
            PropertyRowSpec("Domain UUID",
                            node.properties["Domain UUID"]?.asString,
                            mono: true)
            PropertyRowSpec(forcing: "Role", "Local TB endpoint")
        }
    }
}

struct GenericDeviceView: View {
    let node: TBNode
    var body: some View {
        EmptyStateNote(text: "Connected device. Open Developer details below for the raw IORegistry entry.")
    }
}

struct SoCCoprocessorView: View {
    let node: TBNode

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            Text(description)
                .font(PSFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PropertyList {
                PropertyRowSpec("MMIO base", mmio, mono: true)
                PropertyRowSpec("Provider", node.properties["IOProviderClass"]?.asString)
                PropertyRowSpec("Compatible", compatibleString)
            }
        }
    }

    private var description: String {
        let name = stringValue(node.properties["name"]) ?? node.title
        switch name {
        case "sep":        return "Secure Enclave processor — handles biometrics, key wrapping, sealed storage."
        case "aop":        return "Always-On Processor — runs sensor fusion and audio while the main cores sleep."
        case "pmp":        return "Power Management Processor — runs the SoC's PMU firmware."
        case "smc":        return "System Management Controller — battery, charging, thermals, fans, hardware buttons."
        case "ans":        return "NAND storage controller for the internal SSD."
        case "wlan":       return "Wi-Fi subsystem (Broadcom/Apple-designed radio)."
        case "bluetooth":  return "Bluetooth subsystem."
        case "ane0":       return "Apple Neural Engine — runs Core ML / vision workloads."
        case "isp0":       return "Image Signal Processor — drives the FaceTime camera pipeline."
        case "dcp":        return "Display Coprocessor — built-in display pipeline (Apple-designed firmware)."
        case "gfx-asc":    return "GPU coprocessor that fronts the Apple GPU command stream."
        case "mcc":        return "Memory cache controller for the unified-memory fabric."
        case "avd0":       return "Hardware video decoder (H.264 / H.265 / ProRes)."
        case "pmgr":       return "SoC clock + power-gate manager."
        case "aic":        return "Apple Interrupt Controller — fans out hardware IRQs to the CPU complex."
        default:
            if name.hasPrefix("dcpext") {
                return "External-display coprocessor pipeline (one per external display engine)."
            }
            if name.hasPrefix("ave") { return "Hardware video encoder." }
            if name.hasPrefix("jpeg") { return "Hardware JPEG encoder/decoder." }
            if name.hasPrefix("scaler") { return "Image scaler / colour-space converter." }
            if name.hasPrefix("disp") || name.hasPrefix("dispext") {
                return "Display engine — pixel pump feeding the DCP / external display."
            }
            return "SoC coprocessor block. Open Developer details below for the raw IORegistry entry."
        }
    }

    private var mmio: String? {
        guard case let .array(arr) = node.properties["IODeviceMemory"], let first = arr.first else { return nil }
        if case let .array(inner) = first, let dict = inner.first, case let .dictionary(kv) = dict {
            for (k, v) in kv where k == "address" {
                if let addr = v.asUInt { return String(format: "0x%llX", addr) }
            }
        }
        if case let .dictionary(kv) = first {
            for (k, v) in kv where k == "address" {
                if let addr = v.asUInt { return String(format: "0x%llX", addr) }
            }
        }
        return nil
    }

    private var compatibleString: String? {
        if let val = node.properties["compatible"] {
            return prettyCompatibleString(val)
        }
        return nil
    }

    private func stringValue(_ value: IORegValue?) -> String? {
        guard let value else { return nil }
        if case let .string(s) = value { return s }
        if case let .data(d) = value {
            if let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !s.isEmpty {
                return s
            }
        }
        return nil
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
