//
//  DiagramView.swift
//  Boltprobe
//
//  Visual topology diagram. Shows Mac → physical TB ports → connected
//  routers and their internal adapters, with active tunnels overlaid as
//  coloured paths derived from the hop tables.
//

import SwiftUI

// MARK: - Anchor preference for measuring nodes

private struct NodeAnchorKey: PreferenceKey {
    static var defaultValue: [TBNodeID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TBNodeID: Anchor<CGRect>],
                       nextValue: () -> [TBNodeID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func diagramAnchor(_ id: TBNodeID) -> some View {
        anchorPreference(key: NodeAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

// MARK: - Tunnel model

/// One tunnel rendered on the diagram. The tunnel's intermediate hops aren't
/// fully traced — we show its entry into the connected router by category.
private struct DiagramTunnel: Identifiable, Hashable {
    let id = UUID()
    let category: AdapterCategory
    let portID: TBNodeID
    let routerID: TBNodeID
    let bandwidth: UInt64    // raw 100 Mb/s units
    let label: String
}

private enum AdapterCategory: String, Hashable {
    case lane, dp, usb, pcie, other

    init(description: String) {
        switch description {
        case "DP or HDMI Adapter": self = .dp
        case "USB Adapter", "USB Gen T Adapter": self = .usb
        case "PCIe Adapter": self = .pcie
        case "Thunderbolt Port": self = .lane
        default: self = .other
        }
    }

    var color: Color {
        switch self {
        case .lane: return .blue
        case .dp: return .pink
        case .usb: return .teal
        case .pcie: return .green
        case .other: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .lane: return "bolt.horizontal"
        case .dp: return "display"
        case .usb: return "cable.connector"
        case .pcie: return "square.stack.3d.up"
        case .other: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .lane: return "Lane"
        case .dp: return "DisplayPort / HDMI"
        case .usb: return "USB"
        case .pcie: return "PCIe"
        case .other: return "Other"
        }
    }
}

// MARK: - DiagramView

struct DiagramView: View {
    let snapshot: TBSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var highlight: AdapterCategory? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView([.horizontal, .vertical]) {
                topology
                    .padding(60)
                    .frame(minWidth: 1100, minHeight: 600, alignment: .top)
            }
            .background(Color.black.opacity(0.05))
            Divider()
            footer
        }
        .frame(minWidth: 1200, minHeight: 720)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Thunderbolt Topology").font(.title2.bold())
                Text("Hover a legend tag to highlight its tunnels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 14) {
            ForEach([AdapterCategory.lane, .dp, .usb, .pcie], id: \.self) { cat in
                LegendChip(category: cat,
                           highlighted: highlight == cat)
                    .onHover { highlight = $0 ? cat : nil }
            }
            Spacer()
            Text("Active tunnels are drawn as paths from the host port into the router's adapter groups.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private var topology: some View {
        let ports = TopologyMapper.physicalPorts(from: snapshot)
        let tunnels = collectTunnels(from: ports)

        VStack(spacing: 60) {
            MacBlock()

            HStack(alignment: .top, spacing: 60) {
                ForEach(ports, id: \.id) { port in
                    PortColumn(port: port, allTunnels: tunnels, highlight: highlight)
                }
            }
        }
        .backgroundPreferenceValue(NodeAnchorKey.self) { anchors in
            GeometryReader { geo in
                ZStack {
                    // Mac → each port short connector
                    ForEach(ports, id: \.id) { port in
                        if let a = anchors[Self.macAnchorID], let b = anchors[port.id] {
                            ConnectorLine(start: geo[a], end: geo[b],
                                          color: port.connectedDevice == nil ? .gray.opacity(0.4) : .blue,
                                          dashed: port.connectedDevice == nil)
                        }
                    }
                    // Tunnels host port → adapter group
                    ForEach(tunnels) { t in
                        if let from = anchors[t.portID], let to = anchors[CategoryAnchorID(routerID: t.routerID, category: t.category).key] {
                            TunnelPath(start: geo[from], end: geo[to],
                                       color: t.category.color,
                                       muted: highlight != nil && highlight != t.category,
                                       label: t.label)
                        }
                    }
                }
            }
        }
    }

    // Sentinel ID used to anchor the Mac block in the diagram.
    static let macAnchorID = TBNodeID(raw: 0xDEAD_BEEF_DEAD_BEEF)

    /// Build a list of tunnels — one per function adapter that has bandwidth
    /// reserved on the connected router. Lets us draw a path per active link.
    private func collectTunnels(from ports: [PhysicalPort]) -> [DiagramTunnel] {
        var out: [DiagramTunnel] = []
        for port in ports {
            guard let device = port.connectedDevice else { continue }
            let router = device.routerNode
            // Aggregate reserved bandwidth per category.
            var perCategory: [AdapterCategory: UInt64] = [:]
            for child in router.children where child.kind == .port {
                let desc = child.properties["Description"]?.asString ?? ""
                let cat = AdapterCategory(description: desc)
                guard cat != .lane && cat != .other else { continue }
                let bw = child.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
                if bw > 0 {
                    perCategory[cat, default: 0] += bw
                }
            }
            for (cat, bw) in perCategory {
                out.append(DiagramTunnel(
                    category: cat,
                    portID: port.id,
                    routerID: router.id,
                    bandwidth: bw,
                    label: tbBandwidthLabel(bw)
                ))
            }
        }
        return out
    }
}

// Anchor wrapper for an adapter group inside a router, since multiple
// such anchors share the same router but differ by category.
private struct CategoryAnchorID: Hashable {
    let routerID: TBNodeID
    let category: AdapterCategory
    var key: TBNodeID {
        // Pack the category into a derived synthetic ID for the anchor map.
        let salt: UInt64
        switch category {
        case .lane: salt = 1
        case .dp: salt = 2
        case .usb: salt = 3
        case .pcie: salt = 4
        case .other: salt = 5
        }
        return TBNodeID(raw: routerID.raw &+ (salt << 56))
    }
}

// MARK: - Mac block

private struct MacBlock: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "macbook")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text("This Mac").font(.headline)
            Text("Thunderbolt Host").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12).padding(.horizontal, 22)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.blue.opacity(0.4), lineWidth: 1)
        )
        .diagramAnchor(DiagramView.macAnchorID)
    }
}

// MARK: - Port column

private struct PortColumn: View {
    let port: PhysicalPort
    let allTunnels: [DiagramTunnel]
    let highlight: AdapterCategory?

    var body: some View {
        VStack(spacing: 28) {
            PortBox(port: port)
            if let device = port.connectedDevice {
                LinkBadge(uplink: port.laneAdapter)
                RouterBox(device: device, highlight: highlight)
            }
        }
    }
}

private struct PortBox: View {
    let port: PhysicalPort

    var body: some View {
        let connected = port.connectedDevice != nil
        VStack(spacing: 4) {
            Image(systemName: connected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .font(.system(size: 22))
                .foregroundStyle(connected ? Color.blue : .secondary)
            Text("TB Port \(port.number)").font(.subheadline.bold())
            Text(connected ? "Connected" : "Empty")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10).padding(.horizontal, 18)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder((connected ? Color.blue : .gray).opacity(0.35), lineWidth: 1)
        )
        .diagramAnchor(port.id)
    }
}

private struct LinkBadge: View {
    let uplink: TBNode

    var body: some View {
        let speed = uplink.properties["Current Link Speed"]?.asUInt ?? 0
        let width = uplink.properties["Current Link Width"]?.asUInt ?? 0
        let bw = uplink.properties["Link Bandwidth"]?.asUInt ?? 0
        let maxP = uplink.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
        let overage = maxP > bw && bw > 0

        VStack(spacing: 2) {
            HStack(spacing: 4) {
                if speed > 0 {
                    Text(tbGenerationShortLabel(speed)).font(.caption.bold())
                }
                if width > 0 {
                    Text("×\(width)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Text(tbBandwidthLabel(bw))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if overage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption2)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.thinMaterial)
        .clipShape(Capsule())
    }
}

// MARK: - Router box

private struct RouterBox: View {
    let device: ConnectedDevice
    let highlight: AdapterCategory?

    var body: some View {
        let router = device.routerNode
        let counts = adapterCounts(in: router)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.purple)
                Text(device.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
            }
            if let sub = device.subtitle {
                Text(sub).font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            ForEach([AdapterCategory.dp, .usb, .pcie, .lane], id: \.self) { cat in
                AdapterGroupRow(category: cat,
                                count: counts[cat]?.count ?? 0,
                                reserved: counts[cat]?.reserved ?? 0,
                                muted: highlight != nil && highlight != cat,
                                anchorID: CategoryAnchorID(routerID: router.id, category: cat).key)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.purple.opacity(0.4), lineWidth: 1)
        )
        .diagramAnchor(router.id)
    }

    private func adapterCounts(in router: TBNode) -> [AdapterCategory: (count: Int, reserved: UInt64)] {
        var out: [AdapterCategory: (count: Int, reserved: UInt64)] = [:]
        for child in router.children where child.kind == .port {
            let desc = child.properties["Description"]?.asString ?? ""
            if desc == "Port is inactive" { continue }
            let cat = AdapterCategory(description: desc)
            let bw = child.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
            let entry = out[cat] ?? (count: 0, reserved: 0)
            out[cat] = (count: entry.count + 1, reserved: entry.reserved + bw)
        }
        return out
    }
}

private struct AdapterGroupRow: View {
    let category: AdapterCategory
    let count: Int
    let reserved: UInt64
    let muted: Bool
    let anchorID: TBNodeID

    var body: some View {
        let active = reserved > 0
        HStack(spacing: 8) {
            Image(systemName: category.symbol)
                .foregroundStyle(category.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(category.label).font(.caption.weight(.medium))
                    Text("× \(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(active ? "Reserved \(tbBandwidthLabel(reserved))" : "No active tunnels")
                    .font(.caption2)
                    .foregroundStyle(active ? .secondary : .tertiary)
            }
            Spacer()
            if active {
                Circle()
                    .fill(category.color)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(active ? category.color.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(muted ? 0.35 : 1)
        .diagramAnchor(anchorID)
    }
}

// MARK: - Connection drawing

private struct ConnectorLine: View {
    let start: CGRect
    let end: CGRect
    let color: Color
    var dashed: Bool = false

    var body: some View {
        Path { p in
            let from = CGPoint(x: start.midX, y: start.maxY)
            let to = CGPoint(x: end.midX, y: end.minY)
            p.move(to: from)
            let midY = (from.y + to.y) / 2
            p.addCurve(to: to,
                       control1: CGPoint(x: from.x, y: midY),
                       control2: CGPoint(x: to.x, y: midY))
        }
        .stroke(color,
                style: StrokeStyle(lineWidth: 1.5,
                                   lineCap: .round,
                                   dash: dashed ? [4, 4] : []))
    }
}

private struct TunnelPath: View {
    let start: CGRect
    let end: CGRect
    let color: Color
    let muted: Bool
    let label: String

    var body: some View {
        Path { p in
            let from = CGPoint(x: start.midX, y: start.maxY)
            let to = CGPoint(x: end.minX, y: end.midY)
            p.move(to: from)
            p.addCurve(
                to: to,
                control1: CGPoint(x: from.x, y: (from.y + to.y) / 2),
                control2: CGPoint(x: to.x - 60, y: to.y)
            )
        }
        .stroke(muted ? color.opacity(0.15) : color.opacity(0.85),
                style: StrokeStyle(lineWidth: muted ? 1.2 : 2.4,
                                   lineCap: .round))
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(muted ? 0.05 : 0.12))
                .foregroundStyle(muted ? Color.secondary : color)
                .clipShape(Capsule())
                .position(midpoint(start: start, end: end))
                .allowsHitTesting(false)
        }
    }

    private func midpoint(start: CGRect, end: CGRect) -> CGPoint {
        let mx = (start.midX + end.minX) / 2
        let my = (start.maxY + end.midY) / 2
        return CGPoint(x: mx, y: my)
    }
}

// MARK: - Legend chip

private struct LegendChip: View {
    let category: AdapterCategory
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(category.color).frame(width: 8, height: 8)
            Text(category.label).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(category.color.opacity(highlighted ? 0.2 : 0.08))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(category.color.opacity(highlighted ? 0.6 : 0.2), lineWidth: 1)
        )
    }
}
