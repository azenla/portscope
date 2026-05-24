//
//  DiagramView.swift
//  PortScope
//
//  Topology view: the Mac at the top, every physical Thunderbolt-capable
//  receptacle in a row beneath it, and (per port) the link to the attached
//  device with reserved-bandwidth bars per tunnel class.
//
//  Numbers come from `PhysicalPort.bandwidthSummary` — link capacity from
//  whichever lane endpoint actually publishes it, reservation totals from
//  the host-side function adapters on the controller's root switch.
//

import SwiftUI

// MARK: - Top-level view

struct DiagramView: View {
    let snapshot: SystemSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView([.horizontal, .vertical]) {
                topology
                    .padding(28)
                    .frame(minWidth: 1000, alignment: .top)
            }
            .background(Color.black.opacity(0.04))
            Divider()
            footer
        }
        .frame(minWidth: 1100, minHeight: 720)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Thunderbolt Topology").font(.title2.bold())
                Text("Each TB-capable port, the negotiated link to its attached device, and the bandwidth reserved by active tunnels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 18) {
            BWLegendDot(color: .orange,
                        label: "Reserved",
                        hint: "Committed by active tunnels")
            BWLegendDot(color: Color.yellow.opacity(0.55),
                        label: "Max planned",
                        hint: "Peak the scheduler has budgeted")
            BWLegendDot(color: Color.gray.opacity(0.25),
                        label: "Free",
                        hint: "Headroom on the negotiated link")
            Spacer()
            Text("Reservation sums come from the controller's host-side function adapters — the dock-side endpoints publish placeholder values on TB5.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .trailing)
        }
        .padding(14)
    }

    @ViewBuilder
    private var topology: some View {
        let ports = TopologyMapper.physicalPorts(from: snapshot)
            .filter { $0.connector == .usbC }
            .sorted { $0.number < $1.number }

        VStack(spacing: 0) {
            MacBlock(controllerCount: snapshot.tb.controllers.count)
            if ports.isEmpty {
                Text("No Thunderbolt-capable ports on this Mac.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 40)
            } else {
                // Trunk descender from the Mac block.
                Rectangle()
                    .fill(Color.blue.opacity(0.45))
                    .frame(width: 2, height: 14)
                // Horizontal bus spanning the centres of the port columns
                // below. Drawn as a thin background line behind a row of
                // spacers sized identically to the columns, so the line
                // endpoints land exactly on the first and last column
                // centres regardless of port count.
                ZStack {
                    HStack(spacing: 32) {
                        ForEach(0..<ports.count, id: \.self) { _ in
                            Color.clear.frame(width: 300, height: 2)
                        }
                    }
                    GeometryReader { geo in
                        let columnW: CGFloat = 300
                        let gap: CGFloat = 32
                        let totalW = CGFloat(ports.count) * columnW
                                   + CGFloat(max(ports.count - 1, 0)) * gap
                        let startX = (geo.size.width - totalW) / 2 + columnW / 2
                        let endX = startX + CGFloat(max(ports.count - 1, 0)) * (columnW + gap)
                        Path { p in
                            p.move(to: CGPoint(x: startX, y: 1))
                            p.addLine(to: CGPoint(x: endX, y: 1))
                        }
                        .stroke(Color.blue.opacity(0.45), lineWidth: 2)
                    }
                }
                .frame(height: 2)
                HStack(alignment: .top, spacing: 32) {
                    ForEach(ports, id: \.id) { port in
                        PortColumn(port: port)
                    }
                }
            }
        }
    }
}

// MARK: - Mac block

private struct MacBlock: View {
    let controllerCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "macbook")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac").font(.headline)
                Text("\(controllerCount) Thunderbolt controller\(controllerCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 22)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.blue.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Port column

private struct PortColumn: View {
    let port: PhysicalPort

    var body: some View {
        VStack(spacing: 0) {
            // A small descender so the visual link from the Mac block above
            // lands cleanly on the port box.
            Capsule()
                .fill(port.connectedDevice == nil
                      ? Color.gray.opacity(0.35)
                      : Color.blue.opacity(0.55))
                .frame(width: 2, height: 18)

            PortBox(port: port)

            if let device = port.connectedDevice {
                LinkSegment(port: port)
                ConnectedDeviceCard(port: port, device: device)
            } else {
                Spacer().frame(height: 8)
                Text(emptyLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 300)
    }

    private var emptyLabel: String {
        if let acc = port.accessory, acc.connectionActive { return "Power only" }
        return "No device"
    }
}

private struct PortBox: View {
    let port: PhysicalPort

    var body: some View {
        let connected = port.connectedDevice != nil
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: connected
                      ? "bolt.horizontal.circle.fill"
                      : "bolt.horizontal.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(connected ? Color.blue : .secondary)
                Text(port.cliTitle).font(.subheadline.bold())
            }
            if let cap = port.catalogCapability {
                Text(cap)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let loc = port.catalogLocation {
                Text(loc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder((connected ? Color.blue : .gray).opacity(0.35),
                              lineWidth: 1)
        )
    }
}

// MARK: - Link segment (the cable between port and device)

/// The visual representation of "the cable" between a USB-C port and its
/// attached TB device. Shows the negotiated capacity, the current reserved
/// figure as a mini bar, and the over-budget flag when the planned ceiling
/// exceeds capacity.
private struct LinkSegment: View {
    let port: PhysicalPort

    var body: some View {
        let s = port.bandwidthSummary
        VStack(spacing: 4) {
            Capsule()
                .fill(Color.blue.opacity(0.55))
                .frame(width: 2, height: 14)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                    if s.hasLink {
                        Text(tbBandwidthLabel(s.linkBandwidth))
                            .font(.callout.monospacedDigit().bold())
                        Text("negotiated link")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Link state unknown")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(linkSpeedDescriptor(port: port))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if s.hasLink {
                    MiniBandwidthBar(summary: s)
                    HStack(spacing: 10) {
                        // Reserved is the only number that reflects actual
                        // commitment; surface it as the headline.
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text("Reserved \(tbBandwidthLabel(s.reserved))")
                                .font(.caption2.monospacedDigit().weight(.medium))
                        }
                        Text("(\(String(format: "%.0f%%", s.reservedFraction * 100)) of link)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if s.planExceedsCapacity {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                Text("Plan \(tbBandwidthLabel(s.max)) overbooks by \(tbBandwidthLabel(s.max - s.linkBandwidth))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                            .help("TB tunnels are budgeted on peak, but the scheduler relies on them not peaking at once. This is informational, not an error.")
                        } else {
                            HStack(spacing: 4) {
                                Circle().fill(Color.yellow.opacity(0.55)).frame(width: 6, height: 6)
                                Text("Max planned \(tbBandwidthLabel(s.max))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.blue.opacity(0.20), lineWidth: 0.5)
            )

            Capsule()
                .fill(Color.blue.opacity(0.55))
                .frame(width: 2, height: 14)
        }
    }
}

/// Compact, *non-overlapping* segmented bar: reserved (orange), additional
/// planned headroom (yellow), free (gray). When the planned ceiling exceeds
/// link capacity, the bar still tops out at 100% — the overbooked figure is
/// surfaced separately in the row's text so the visual stays honest about
/// utilization. Painting yellow up to the clamped max-fraction would make
/// every overbooked link look 100% full when in reality only `reserved`
/// is committed.
private struct MiniBandwidthBar: View {
    let summary: PortBandwidthSummary

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let reqW = w * summary.reservedFraction
            // Yellow ("max planned") only extends past reserved up to the
            // link cap. Beyond that there is no honest pixel to give it.
            let yellowW = max(0, w * summary.maxFraction - reqW)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: reqW)
                Rectangle()
                    .fill(Color.yellow.opacity(0.55))
                    .frame(width: yellowW)
                Rectangle()
                    .fill(Color.gray.opacity(0.20))
            }
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    summary.planExceedsCapacity ? Color.red.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
            )
        }
        .frame(height: 8)
    }
}

/// Short descriptor for the negotiated link state — used in the LinkSegment
/// header as a tertiary hint. Falls back gracefully when the kernel reports
/// values that don't map cleanly to a marketing TB generation.
nonisolated private func linkSpeedDescriptor(port: PhysicalPort) -> String {
    let width = port.laneAdapter.properties["Current Link Width"]?.asUInt ?? 0
    if width == 0 { return "" }
    return "\(width) lanes"
}

// MARK: - Device card

/// The card representing the attached TB device. Shows vendor/model, the
/// per-tunnel-class bandwidth breakdown, and the chained-device count
/// (if any). Tunnel rows draw a mini bar against the link capacity so the
/// user can see at a glance which class is eating bandwidth.
private struct ConnectedDeviceCard: View {
    let port: PhysicalPort
    let device: ConnectedDevice

    var body: some View {
        let s = port.bandwidthSummary
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.purple)
                Text(device.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
            }
            // The kernel's `Thunderbolt Version` encoding ("Spec 4.0") is
            // misleading on TB5 hardware (Apple maps the high nibble loosely),
            // and the dock's marketing name in `device.title` already carries
            // the generation. Show only the depth when meaningful.
            if let depth = device.routerNode.properties["Depth"]?.asUInt, depth > 0 {
                Text(depth == 1 ? "Directly attached" : "Daisy-chained · hop \(depth)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if s.perTunnel.isEmpty {
                Text("No active tunnels on this device.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Divider()
                ForEach(s.perTunnel, id: \.self) { t in
                    TunnelRowMini(tunnel: t, linkBandwidth: s.linkBandwidth)
                }
            }

            if !device.daisyChained.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "link.circle")
                        .foregroundStyle(.purple)
                    Text("Daisy-chained: \(device.daisyChained.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.purple.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Single tunnel-class row inside the device card.
///
/// Two distinct cases the kernel asks us to handle differently:
///
/// 1. **DP**: publishes a real `Required` (e.g. 31.2 Gb/s for two streams)
///    and a `Maximum` slightly higher than that. Both numbers mean what
///    they say.
/// 2. **USB / PCIe**: publishes `Required = 1` (= 100 Mb/s, a placeholder)
///    even on active tunnels. The meaningful number is `Maximum` (e.g.
///    20 Gb/s peak budget). Reading the placeholder as "100 Mb/s reserved"
///    would let the user think USB is barely doing anything when in fact
///    20 Gb/s of headroom is held for it.
///
/// Headline picks whichever is meaningful; mini-bar fills the same way so
/// the visual matches the number.
private struct TunnelRowMini: View {
    let tunnel: PortTunnel
    let linkBandwidth: UInt64

    var body: some View {
        let category = TunnelCategory(kind: tunnel.kind)
        let reservedReal = tunnel.reservedBandwidth >= 10
        let maxReal = tunnel.maxBandwidth >= 10
        let anyReal = reservedReal || maxReal
        // For the headline / bar: prefer the reserved figure when it's a
        // real reservation, otherwise fall back to the planned maximum
        // (so USB/PCIe show "20 Gb/s planned" instead of "100 Mb/s").
        let headlineValue: UInt64 = reservedReal
            ? tunnel.reservedBandwidth
            : tunnel.maxBandwidth
        let headlineLabel: String = reservedReal ? "Reserved" : "Planned"

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: tunnel.symbol)
                    .foregroundStyle(category.color)
                    .frame(width: 18)
                Text(tunnel.label).font(.caption.weight(.medium))
                Text("× \(tunnel.adapterCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if anyReal {
                    Text("\(headlineLabel) ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    + Text(tbBandwidthLabel(headlineValue))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(category.color)
                } else {
                    Text("Active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(category.color)
                }
            }
            if anyReal && linkBandwidth > 0 {
                GeometryReader { geo in
                    let w = geo.size.width
                    let headlineFrac = min(Double(headlineValue) / Double(linkBandwidth), 1.0)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.18))
                        Capsule()
                            .fill(category.color)
                            .frame(width: w * headlineFrac)
                    }
                }
                .frame(height: 5)
                .padding(.leading, 26)
            }
        }
    }
}

private struct TunnelCategory {
    let color: Color
    init(kind: PortTunnel.Kind) {
        switch kind {
        case .displayPort: color = .pink
        case .usb: color = .teal
        case .pcie: color = .green
        }
    }
}

// MARK: - Legend

private struct BWLegendDot: View {
    let color: Color
    let label: String
    let hint: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption.weight(.medium))
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
