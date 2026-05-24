//
//  PhysicalPortDetailView.swift
//  PortScope
//
//  Unified per-port view shown when the user selects a Physical Port row
//  (USB-C / USB-A / MagSafe / other). Pulls together TB mode + link state,
//  IOAccessoryManager runtime data (transports, USB-PD, plug orientation,
//  DP HPD, cable e-marker), and rolled-up TB tunnels / attached USB devices.
//
//  Built around USB-C semantics — the built-in non-USB-C receptacles
//  (AC PSU, Ethernet, HDMI, SD) get their own curated views in
//  `BuiltInPortViews.swift`.
//

import SwiftUI

struct PhysicalPortDetailView: View {
    let port: PhysicalPort
    /// External displays attributed to this port by `ContentView`.
    var displays: [DisplayInfo] = []
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let ethernet = findUSBEthernetAdapters(in: port.usbDeviceRoots)

        DetailContainer {
            Hero(
                symbol: port.mode.symbol,
                title: port.cliTitle,
                subtitle: heroSubtitle,
                status: heroStatus
            )

            connectionSection
            if let pd = port.accessory?.usbPD {
                powerInputSection(pd: pd)
            }
            if let sp = port.sourcePower, !sp.sinks.isEmpty {
                powerOutputSection(sp)
            }
            if shouldShowDisplaysCard {
                displaysSection
            }
            if !ethernet.isEmpty {
                USBEthernetSection(adapters: ethernet, onNavigate: onNavigate)
            }
            if !port.tunnels.isEmpty {
                tunnelsSection
            }
            if let dev = port.connectedDevice {
                connectedDeviceSection(dev)
            }
            relatedSection
        }
    }

    // MARK: - Hero subtitle / status

    /// Single subtitle line carries the rest of the story — connector,
    /// negotiated transport, charging wattage, DP — instead of stacking
    /// multiple pills next to the hero.
    private var heroSubtitle: String? {
        var parts: [String] = []
        // Lead with the connector capability when known.
        if let cap = port.catalogCapability { parts.append(cap) }
        else { parts.append(port.connector.label) }

        // The kernel's mode label, when it adds information.
        switch port.mode {
        case .empty:
            parts.append("Nothing connected")
        case .thunderbolt:
            let speed = port.laneAdapter.properties["Current Link Speed"]?.asUInt ?? 0
            let width = port.laneAdapter.properties["Current Link Width"]?.asUInt ?? 0
            if speed > 0 { parts.append(tbGenerationShortLabel(speed)) }
            if width > 0 { parts.append("×\(width) lanes") }
        case .usbOnly(let s):
            if let s, s > 0 { parts.append(usbSpeedShortLabel(s)) }
        case .displayOnly:
            parts.append("Display")
        case .charging(let w):
            if let w, w > 0 { parts.append("\(w) W in") }
            else { parts.append("Charging") }
        case .unknown:
            parts.append("Link up")
        }

        if let acc = port.accessory {
            if acc.carriesDisplay, port.mode != .displayOnly { parts.append("+ DP") }
            if acc.activeCable { parts.append("Active cable") }
        }
        if let watts = port.accessory?.usbPD?.winning?.powerLabel,
           !isChargingMode {
            parts.append("\(watts) in")
        }

        return parts.joined(separator: " · ")
    }

    private var isChargingMode: Bool {
        if case .charging = port.mode { return true }
        return false
    }

    private var heroStatus: PSStatus? {
        switch port.mode {
        case .empty:
            // Treat charging-only as Power-In (accessory connected, no data).
            if port.accessory?.connectionActive == true,
               let watts = port.accessory?.usbPD?.winning?.powerLabel {
                return .powerIn(watts)
            }
            return .empty
        case .thunderbolt, .usbOnly, .displayOnly, .unknown:
            return .active
        case .charging(let w):
            return .powerIn(w.map { "\($0) W" } ?? "Charging")
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        let acc = port.accessory
        let lane = port.bandwidthLane
        let speed = lane.properties["Current Link Speed"]?.asUInt
            ?? port.laneAdapter.properties["Current Link Speed"]?.asUInt
            ?? 0
        let width = lane.properties["Current Link Width"]?.asUInt
            ?? port.laneAdapter.properties["Current Link Width"]?.asUInt
            ?? 0
        let bw = speed > 0 ? (lane.properties["Link Bandwidth"]?.asUInt ?? 0) : 0
        let cableType: String? = {
            guard let acc, acc.connectionActive else { return nil }
            if acc.opticalCable { return "Optical" }
            if acc.activeCable { return "Active (powered e-marker)" }
            return "Passive"
        }()
        let connectionLabel: String? = {
            guard let acc else { return nil }
            if acc.connection.isConnected { return acc.connection.label }
            return acc.connectionActive ? "Power only" : nil
        }()

        return VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Connection")
            PropertyList {
                PropertyRowSpec("Connector",
                                acc?.connector.label ?? port.connector.label)
                PropertyRowSpec("Role", connectionLabel)
                PropertyRowSpec("Active transports", activeTransportsLabel)
                PropertyRowSpec("Cable", cableType)
                PropertyRowSpec("Cable e-marker", acc?.cableLabel)
                PropertyRowSpec("Plug orientation",
                                acc?.plugOrientation.label == "Unknown"
                                    ? nil
                                    : acc?.plugOrientation.label)
                PropertyRowSpec("Link generation",
                                speed > 0 ? tbLinkSpeedLabel(speed) : nil)
                PropertyRowSpec("Lane width",
                                width > 0 ? "\(width) lanes" : nil)
                PropertyRowSpec("Link capacity",
                                bw > 0 ? tbBandwidthLabel(bw) : nil)
                PropertyRowSpec("Plug events (since boot)",
                                (acc?.plugEventCount ?? 0) > 0
                                    ? "\(acc!.plugEventCount)" : nil)
                PropertyRowSpec("Overcurrent events",
                                (acc?.overcurrentCount ?? 0) > 0
                                    ? "\(acc!.overcurrentCount)" : nil,
                                valueColor: PSColor.error)
            }

            // Bandwidth bar when there's a live TB link.
            if case .thunderbolt = port.mode, bw > 0 {
                let req = lane.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
                let maxBw = lane.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
                CapacityBar(
                    title: "Bandwidth",
                    value: Double(req),
                    secondaryValue: maxBw > req ? Double(maxBw) : nil,
                    capacity: Double(bw),
                    headlineValue: "\(tbBandwidthLabel(req)) of \(tbBandwidthLabel(bw))",
                    legend: maxBw > req ? "\(tbBandwidthLabel(maxBw)) max planned" : nil,
                    tint: PSColor.active
                )
            }
        }
    }

    private var activeTransportsLabel: String? {
        guard let acc = port.accessory, !acc.activeTransports.isEmpty else { return nil }
        return acc.activeTransports
            .map { $0.label }
            .sorted()
            .joined(separator: " · ")
    }

    // MARK: - Power input

    @ViewBuilder
    private func powerInputSection(pd: USBPDProfile) -> some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Power input")
            if let win = pd.winning {
                let advertisedW = Double(pd.offered.map(\.maxPowerMW).max() ?? win.maxPowerMW) / 1000.0
                let currentW = Double(win.maxPowerMW) / 1000.0
                CapacityBar(
                    title: nil,
                    value: currentW,
                    secondaryValue: nil,
                    capacity: max(advertisedW, currentW),
                    headlineValue: "\(win.powerLabel) · \(win.voltageLabel) · \(win.currentLabel)",
                    legend: advertisedW > currentW + 0.1
                        ? "Negotiated \(win.powerLabel) of \(String(format: "%.0f W", advertisedW)) advertised"
                        : "Negotiated contract",
                    tint: PSColor.powerIn
                )
            } else {
                EmptyStateNote(text: "No active power profile negotiated.")
            }
            if !pd.offered.isEmpty {
                DisclosureCard("Offered PDOs (\(pd.offered.count))",
                               icon: "list.bullet.rectangle") {
                    PDOTableView(profile: pd)
                }
            }
            if let brick = pd.brickID {
                PropertyList {
                    PropertyRowSpec(forcing: "Apple brick ID",
                                    "\(brick.voltageLabel) · \(brick.currentLabel)",
                                    mono: true)
                }
            }
        }
    }

    // MARK: - Power output (Mac sourcing power to attached devices)

    @ViewBuilder
    private func powerOutputSection(_ sp: PortSourcePower) -> some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Power output (Mac sourcing)")
            if sp.totalAllocatedMA > 0 {
                let totalW = Double(sp.totalAllocatedMA) / 1000.0 * 5.0
                let cap = sp.wakeLimitMA.map { Double($0) / 1000.0 * 5.0 } ?? max(15, totalW)
                CapacityBar(
                    title: nil,
                    value: totalW,
                    secondaryValue: nil,
                    capacity: cap,
                    headlineValue: String(format: "%.1f W at 5 V · %.2f A",
                                          totalW, Double(sp.totalAllocatedMA) / 1000.0),
                    legend: sp.wakeLimitMA != nil
                        ? "Port source limit: \(String(format: "%.0f W", cap))"
                        : nil,
                    tint: PSColor.powerOut
                )
            }
            if !sp.sinks.isEmpty {
                PropertyList(rows: sp.sinks.compactMap { sink -> PropertyRowSpec? in
                    let watts = Double(sink.allocatedMA) / 1000.0 * 5.0
                    return PropertyRowSpec(
                        sink.name,
                        String(format: "%d mA · %.1f W", sink.allocatedMA, watts)
                    )
                })
            }
            Text("Wattage assumes USB-C default 5 V. PD-fast-charge devices may pull more than shown.")
                .font(PSFont.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Displays

    private var shouldShowDisplaysCard: Bool {
        if port.accessory?.carriesDisplay == true { return true }
        if !displays.isEmpty { return true }
        return false
    }

    private var displaysSection: some View {
        let acc = port.accessory
        let dpTunnel = port.tunnels.first { $0.kind == .displayPort }
        let title = displays.count <= 1 ? "Display" : "Displays (\(displays.count))"

        return VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader(title)
            if displays.isEmpty {
                EmptyStateNote(text: "This port has a DisplayPort path active but no lit display surface was found. The framebuffer engine may still be coming up.")
            } else {
                VStack(spacing: 0) {
                    ForEach(displays) { d in
                        if d.id != displays.first?.id {
                            Rectangle()
                                .fill(PSColor.divider.opacity(0.7))
                                .frame(height: 0.5)
                        }
                        AttachedDisplayRow(display: d, onNavigate: onNavigate)
                    }
                }
            }
            if let acc, acc.carriesDisplay {
                PropertyList {
                    PropertyRowSpec(forcing: "Hot-plug detect",
                                    acc.hpdAsserted ? "Asserted" : "Idle",
                                    valueColor: acc.hpdAsserted ? PSColor.active : nil)
                    PropertyRowSpec("Pin assignment",
                                    displayPortPinAssignmentLabel(acc.displayPortPinAssignment))
                }
            }
            if let dp = dpTunnel {
                dpTunnelRow(tunnel: dp)
            }
        }
    }

    @ViewBuilder
    private func dpTunnelRow(tunnel: PortTunnel) -> some View {
        let bw = port.bandwidthLane.properties["Link Bandwidth"]?.asUInt
        let reserved = tunnel.reservedBandwidth
        let maxBw = tunnel.maxBandwidth
        let hasRealReservation = max(reserved, maxBw) >= 10
        if hasRealReservation, let bw, bw > 0 {
            CapacityBar(
                title: "DisplayPort tunnel",
                value: Double(reserved),
                secondaryValue: maxBw > reserved ? Double(maxBw) : nil,
                capacity: Double(bw),
                headlineValue: "\(tbBandwidthLabel(reserved)) of \(tbBandwidthLabel(bw))",
                legend: nil,
                tint: PSColor.powerOut
            )
        } else {
            PropertyList {
                PropertyRowSpec(forcing: "DisplayPort tunnel",
                                "Active · \(tunnel.adapterCount) adapter\(tunnel.adapterCount == 1 ? "" : "s")")
            }
        }
    }

    // MARK: - Tunnels

    private var tunnelsSection: some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Active TB tunnels (\(port.tunnels.count))")
            PropertyList {
                for t in port.tunnels {
                    PropertyRowSpec(forcing: t.label,
                                    "Reserved \(tbBandwidthLabel(t.reservedBandwidth)) · max \(tbBandwidthLabel(t.maxBandwidth))",
                                    mono: false)
                }
            }
        }
    }

    private func connectedDeviceSection(_ device: ConnectedDevice) -> some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Connected Thunderbolt device")
            Button { onNavigate(device.id) } label: {
                HStack(spacing: PSSpacing.s + 4) {
                    Image(systemName: "shippingbox")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.title)
                            .font(PSFont.bodyEmph)
                            .foregroundStyle(.primary)
                        if let s = device.subtitle {
                            Text(s)
                                .font(PSFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(PSFont.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, PSSpacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: PSSpacing.s) {
            SectionHeader("Jump to")
            HStack(spacing: PSSpacing.s) {
                if hasRealLaneAdapter {
                    Button { onNavigate(port.laneAdapter.id) } label: {
                        Label("Lane adapter", systemImage: "bolt.horizontal")
                    }
                }
                Button { onNavigate(port.controller.id) } label: {
                    Label("Host controller", systemImage: "cpu")
                }
                Spacer()
            }
        }
    }

    private var hasRealLaneAdapter: Bool {
        !port.laneAdapter.className.isEmpty
    }
}

// MARK: - Attached display row

private struct AttachedDisplayRow: View {
    let display: DisplayInfo
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        Button { onNavigate(display.id) } label: {
            HStack(alignment: .center, spacing: PSSpacing.s + 4) {
                Image(systemName: display.iconSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.title).font(PSFont.bodyEmph)
                    if let s = subtitle {
                        Text(s).font(PSFont.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(PSFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, PSSpacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let w = display.widthPixels, let h = display.heightPixels, w > 0, h > 0 {
            parts.append("\(w) × \(h)")
        }
        if let mx = display.maxRefreshHz {
            parts.append("\(Int(mx.rounded())) Hz")
        }
        if let d = display.colorBitDepth { parts.append("\(d)-bit") }
        if display.supportsHDR { parts.append("HDR") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
