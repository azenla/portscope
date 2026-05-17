//
//  PhysicalPortDetailView.swift
//  Boltprobe
//
//  Unified per-port view shown when the user selects a Physical Port row.
//  Aggregates Thunderbolt mode, link state, tunnels, and attached USB devices.
//

import SwiftUI

struct PhysicalPortDetailView: View {
    let port: PhysicalPort
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stats
                modeCard
                if !port.tunnels.isEmpty {
                    tunnelsCard
                }
                if !port.attachedUSBDevices.isEmpty {
                    usbCard
                }
                if let dev = port.connectedDevice {
                    connectedDeviceCard(dev)
                }
                relatedCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(port.mode.color.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: port.mode.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(port.mode.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("USB-C Port \(port.number)").font(.title2).bold()
                if let dev = port.connectedDevice {
                    Text(dev.title).foregroundStyle(.secondary)
                } else {
                    Text(port.mode == .empty ? "No device connected" : "Connected")
                        .foregroundStyle(.secondary)
                }
                ModeBadge(mode: port.mode)
            }
            Spacer()
        }
    }

    private var stats: some View {
        let lane = port.laneAdapter
        let speed = lane.properties["Current Link Speed"]?.asUInt ?? 0
        let width = lane.properties["Current Link Width"]?.asUInt ?? 0
        let bw = lane.properties["Link Bandwidth"]?.asUInt ?? 0

        return StatGrid(stats: [
            Stat(label: "Operating Mode",
                 value: port.mode.label,
                 symbol: port.mode.symbol),
            Stat(label: "Link Speed",
                 value: speed > 0 ? tbLinkSpeedLabel(speed) : "Inactive",
                 symbol: "antenna.radiowaves.left.and.right"),
            Stat(label: "Lane Width",
                 value: width > 0 ? "\(width) lanes" : "—",
                 symbol: "arrow.left.and.right"),
            Stat(label: "Link Capacity",
                 value: bw > 0 ? tbBandwidthLabel(bw) : "—",
                 symbol: "gauge.with.dots.needle.67percent"),
            Stat(label: "TB Devices",
                 value: port.connectedDevice == nil ? "0" : "\(countRouters(port.connectedDevice!))",
                 symbol: "shippingbox"),
            Stat(label: "USB Devices",
                 value: "\(port.attachedUSBDevices.count)",
                 symbol: "cable.connector")
        ])
    }

    @ViewBuilder
    private var modeCard: some View {
        SectionCard(title: "What's happening on this port", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                Text(explanation(for: port.mode))
                    .foregroundStyle(.secondary)
                    .font(.callout)
                if case .thunderbolt = port.mode {
                    let bw = port.laneAdapter.properties["Link Bandwidth"]?.asUInt ?? 0
                    let req = port.laneAdapter.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
                    let maxBw = port.laneAdapter.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
                    if bw > 0 {
                        BandwidthBar(linkBandwidth: bw, required: req, maximum: maxBw)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func explanation(for mode: PhysicalPortMode) -> String {
        switch mode {
        case .empty:
            return "Nothing detected on this port. Plug in a Thunderbolt or USB-C device to bring up the link."
        case .thunderbolt(let speed):
            return "A Thunderbolt device is connected and negotiated at \(tbLinkSpeedLabel(speed))."
        case .usbOnly(let s):
            if let s, s > 0 {
                return "A USB-C device is connected without Thunderbolt; it negotiated \(usbSpeedLabel(s))."
            }
            return "A USB-C device is connected without Thunderbolt."
        case .displayOnly:
            return "Only a DisplayPort signal is active on this port."
        case .unknown:
            return "Link is up but no device is reachable through the registry. Connection may still be negotiating."
        }
    }

    private var tunnelsCard: some View {
        SectionCard(title: "Active Tunnels", symbol: "arrow.triangle.swap") {
            VStack(spacing: 0) {
                ForEach(port.tunnels, id: \.self) { t in
                    TunnelRow(tunnel: t)
                    if t != port.tunnels.last { Divider() }
                }
            }
        }
    }

    private var usbCard: some View {
        SectionCard(title: "USB Devices via This Port (\(port.attachedUSBDevices.count))",
                    symbol: "cable.connector") {
            VStack(spacing: 0) {
                ForEach(port.attachedUSBDevices.prefix(20), id: \.id) { dev in
                    USBDeviceRow(node: dev, onNavigate: onNavigate)
                    if dev.id != port.attachedUSBDevices.prefix(20).last?.id {
                        Divider()
                    }
                }
                if port.attachedUSBDevices.count > 20 {
                    Text("… and \(port.attachedUSBDevices.count - 20) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func connectedDeviceCard(_ device: ConnectedDevice) -> some View {
        SectionCard(title: "Connected Thunderbolt Device", symbol: "shippingbox.fill") {
            Button {
                onNavigate(device.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.purple)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.title).foregroundStyle(.primary)
                        if let s = device.subtitle {
                            Text(s).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var relatedCard: some View {
        SectionCard(title: "Jump to", symbol: "arrow.up.right.square") {
            HStack(spacing: 8) {
                Button {
                    onNavigate(port.laneAdapter.id)
                } label: {
                    Label("Lane adapter", systemImage: "bolt.horizontal")
                }
                Button {
                    onNavigate(port.controller.id)
                } label: {
                    Label("Host controller", systemImage: "cpu")
                }
                Spacer()
            }
        }
    }

    private func countRouters(_ device: ConnectedDevice) -> Int {
        return 1 + device.daisyChained.reduce(0) { $0 + countRouters($1) }
    }
}

private struct ModeBadge: View {
    let mode: PhysicalPortMode
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(mode.color).frame(width: 8, height: 8)
            Text(mode.label).font(.caption.weight(.medium))
                .foregroundStyle(mode.color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(mode.color.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct TunnelRow: View {
    let tunnel: PortTunnel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tunnel.symbol)
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.label).font(.callout.weight(.medium))
                Text("\(tunnel.adapterCount) adapter\(tunnel.adapterCount == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Reserved \(tbBandwidthLabel(tunnel.reservedBandwidth))")
                    .font(.caption.monospacedDigit())
                Text("Max \(tbBandwidthLabel(tunnel.maxBandwidth))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
    }
}
