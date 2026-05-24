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
            .filter { $0.connector == .usbC || $0.connector == .magsafe }
            .sorted { $0.number < $1.number }

        VStack(spacing: 24) {
            MacBlock(controllerCount: snapshot.tb.controllers.count)
            if ports.isEmpty {
                Text("No Thunderbolt-capable ports on this Mac.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 40)
            } else {
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
        let speed = port.laneAdapter.properties["Current Link Speed"]?.asUInt ?? 0
        let width = port.laneAdapter.properties["Current Link Width"]?.asUInt ?? 0
        let gen = speed > 0 ? tbGenerationShortLabel(speed) : nil

        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: connected
                      ? "bolt.horizontal.circle.fill"
                      : "bolt.horizontal.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(connected ? Color.blue : .secondary)
                Text(port.cliTitle).font(.subheadline.bold())
            }
            if let loc = port.catalogLocation {
                Text(loc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if connected, let gen {
                HStack(spacing: 4) {
                    Text(gen).font(.caption2.bold())
                    if width > 0 {
                        Text("×\(width)").font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.blue.opacity(0.10))
                .clipShape(Capsule())
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

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                    Text(s.hasLink ? tbBandwidthLabel(s.linkBandwidth) + " link" : "Link state unknown")
                        .font(.caption.monospacedDigit().weight(.medium))
                    Spacer()
                    if s.planExceedsCapacity {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .help("Planned bandwidth exceeds link capacity. The scheduler relies on tunnels not peaking simultaneously.")
                    }
                }
                if s.hasLink {
                    MiniBandwidthBar(summary: s)
                    HStack(spacing: 8) {
                        Text("Reserved \(tbBandwidthLabel(s.reserved))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                        Text("Max \(tbBandwidthLabel(s.max))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", s.reservedFraction * 100))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(8)
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

/// Compact 3-layer bar: free (background), max planned (yellow), reserved
/// (orange). Mirrors `BandwidthBar` but at footprint suited for the topology
/// inline.
private struct MiniBandwidthBar: View {
    let summary: PortBandwidthSummary

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.20))
                Capsule()
                    .fill(Color.yellow.opacity(0.55))
                    .frame(width: w * summary.maxFraction)
                Capsule()
                    .fill(Color.orange)
                    .frame(width: w * summary.reservedFraction)
                if summary.planExceedsCapacity {
                    Capsule()
                        .strokeBorder(Color.red, lineWidth: 1)
                }
            }
        }
        .frame(height: 8)
    }
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
            if let sub = device.subtitle {
                Text(sub).font(.caption2).foregroundStyle(.secondary)
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

/// Single tunnel-class row inside the device card. Renders the reserved
/// figure inline with a mini bar showing usage against the link capacity.
/// DP often publishes placeholder reservations (req=max=1, < 1 Gb/s); when
/// that happens we say "Active" instead of stamping "0.1 Gb/s" everywhere.
private struct TunnelRowMini: View {
    let tunnel: PortTunnel
    let linkBandwidth: UInt64

    var body: some View {
        let real = max(tunnel.reservedBandwidth, tunnel.maxBandwidth) >= 10
        let category = TunnelCategory(kind: tunnel.kind)

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
                if real {
                    Text(tbBandwidthLabel(tunnel.reservedBandwidth))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(category.color)
                } else {
                    Text("Active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(category.color)
                }
            }
            if real && linkBandwidth > 0 {
                GeometryReader { geo in
                    let w = geo.size.width
                    let reqFrac = min(Double(tunnel.reservedBandwidth) / Double(linkBandwidth), 1.0)
                    let maxFrac = min(Double(tunnel.maxBandwidth) / Double(linkBandwidth), 1.0)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.18))
                        Capsule()
                            .fill(category.color.opacity(0.30))
                            .frame(width: w * maxFrac)
                        Capsule()
                            .fill(category.color)
                            .frame(width: w * reqFrac)
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
