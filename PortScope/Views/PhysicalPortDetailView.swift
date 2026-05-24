//
//  PhysicalPortDetailView.swift
//  PortScope
//
//  Unified per-port view shown when the user selects a Physical Port row.
//  Pulls together TB mode + link state, IOAccessoryManager runtime state
//  (active transports, USB-PD, plug orientation, displayport HPD, cable
//  e-marker), and a rolled-up view of TB tunnels and attached USB devices.
//

import SwiftUI

struct PhysicalPortDetailView: View {
    let port: PhysicalPort
    /// External displays attributed to this port by `ContentView`. Attribution
    /// is heuristic (the IOService plane doesn't expose a clean port→display
    /// link), but accurate enough when there's only one DP-active port or
    /// when DP-active ports and external displays come in matching counts.
    var displays: [DisplayInfo] = []
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let ethernet = findUSBEthernetAdapters(in: port.usbDeviceRoots)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stats
                modeCard
                if port.accessory != nil {
                    transportsCard
                    connectorCableCard
                }
                if let pd = port.accessory?.usbPD {
                    powerInputCard(pd: pd)
                }
                if let sp = port.sourcePower, !sp.sinks.isEmpty {
                    powerOutputCard(sp)
                }
                if shouldShowDisplaysCard {
                    displaysCard
                }
                if !ethernet.isEmpty {
                    ethernetCard(adapters: ethernet)
                }
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

    // MARK: - Hero header

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
                Text(portTitle).font(.title2).bold()
                Text(subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ModeBadge(mode: port.mode)
                    if let acc = port.accessory {
                        AccessoryBadges(acc: acc, suppressDisplay: port.mode == .displayOnly)
                    }
                }
            }
            Spacer()
            if let watts = port.accessory?.usbPD?.winning?.powerLabel {
                PowerCallout(watts: watts)
            }
        }
    }

    private var portTitle: String {
        port.cliTitle
    }

    private var subheadline: String {
        if let dev = port.connectedDevice { return dev.title }
        if let acc = port.accessory {
            if acc.connection.isConnected { return acc.connection.label }
        }
        switch port.mode {
        case .empty: return "No device connected"
        case .displayOnly: return "Display only"
        case .usbOnly: return "USB device"
        case .thunderbolt: return "Thunderbolt device"
        case .charging: return "Charger connected"
        case .unknown: return "Link up"
        }
    }

    // MARK: - Stats grid

    private var stats: some View {
        StatGrid(stats: buildStats())
    }

    private func buildStats() -> [Stat] {
        // Speed / width are negotiated link parameters published on both
        // endpoints. Capacity comes from whichever endpoint actually
        // publishes a non-zero `Link Bandwidth` (TB5 host-side on Apple
        // Silicon). `bandwidthSummary` already picked the right lane.
        let lane = port.bandwidthLane
        let speed = lane.properties["Current Link Speed"]?.asUInt
            ?? port.laneAdapter.properties["Current Link Speed"]?.asUInt
            ?? 0
        let width = lane.properties["Current Link Width"]?.asUInt
            ?? port.laneAdapter.properties["Current Link Width"]?.asUInt
            ?? 0
        let bw = port.bandwidthSummary.linkBandwidth
        let acc = port.accessory

        var stats: [Stat] = [
            Stat(label: "Operating Mode",
                 value: port.mode.label,
                 symbol: port.mode.symbol)
        ]
        // Lane / link stats only make sense when a Thunderbolt lane adapter
        // is backing this port. USB-A jacks (no TB lane) get a different mix.
        if hasRealLaneAdapter {
            stats.append(contentsOf: [
                Stat(label: "Link Speed",
                     value: speed > 0 ? tbLinkSpeedLabel(speed) : "Inactive",
                     symbol: "antenna.radiowaves.left.and.right"),
                Stat(label: "Lane Width",
                     value: width > 0 ? "\(width) lanes" : "—",
                     symbol: "arrow.left.and.right"),
                Stat(label: "Link Capacity",
                     value: bw > 0 ? tbBandwidthLabel(bw) : "—",
                     symbol: "gauge.with.dots.needle.67percent")
            ])
        }
        // Power In and Plug Orientation come from USB-PD / HPM — neither is
        // published for USB-A IOPort accessories.
        if port.connector != .usbA {
            stats.append(contentsOf: [
                Stat(label: "Power Input",
                     value: acc?.usbPD?.winning?.powerLabel ?? "—",
                     symbol: "bolt.fill"),
                Stat(label: "Plug Orientation",
                     value: acc?.plugOrientation.label ?? "—",
                     symbol: acc?.plugOrientation.symbol ?? "arrow.up.arrow.down"),
                Stat(label: "TB Devices",
                     value: port.connectedDevice == nil ? "0" : "\(countRouters(port.connectedDevice!))",
                     symbol: "shippingbox")
            ])
        }
        stats.append(Stat(label: "USB Devices",
                          value: "\(port.attachedUSBDevices.count)",
                          symbol: "cable.connector"))
        return stats
    }

    // MARK: - "What's happening on this port" card

    @ViewBuilder
    private var modeCard: some View {
        SectionCard(title: "What's happening on this port", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation(for: port.mode, accessory: port.accessory))
                    .foregroundStyle(.secondary)
                    .font(.callout)
                if case .thunderbolt = port.mode {
                    // Link capacity comes from the lane, but the kernel's
                    // outer-wrapper aggregate on the lane is unreliable
                    // (publishes a partial view that disagrees with the
                    // function-adapter sums). Read reserved/max from the
                    // connected router's function adapters instead — that's
                    // what `bandwidthSummary` does.
                    let s = port.bandwidthSummary
                    if s.hasLink {
                        BandwidthBar(linkBandwidth: s.linkBandwidth,
                                     required: s.reserved,
                                     maximum: s.max)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func explanation(for mode: PhysicalPortMode, accessory acc: PortAccessoryInfo?) -> String {
        switch mode {
        case .empty:
            if let acc, acc.detected {
                return "A connector is inserted but no transport has been negotiated yet."
            }
            return "Nothing detected on this port. Plug in a Thunderbolt or USB-C device to bring up the link."
        case .thunderbolt(let speed):
            let speedPart = speed > 0
                ? " and negotiated at \(tbLinkSpeedLabel(speed))"
                : ""
            return "A Thunderbolt / USB4 device is connected\(speedPart)."
        case .usbOnly(let s):
            let connectorName = port.connector.label
            if let s, s > 0 {
                if port.connector == .usbA {
                    return "A \(connectorName) device is connected at \(usbSpeedLabel(s))."
                }
                return "A \(connectorName) device is connected without Thunderbolt; it negotiated \(usbSpeedLabel(s))."
            }
            if port.connector == .usbA {
                return "A \(connectorName) device is connected."
            }
            return "A \(connectorName) device is connected without Thunderbolt."
        case .displayOnly:
            return "DisplayPort is the only active alt-mode on this port — typically a passive HDMI / DP adapter or a monitor connected without USB hub functionality."
        case .charging(let w):
            if let w, w > 0 {
                return "A USB-PD power source is connected and negotiated a \(w) W contract. No data transports are active — this is a power-only sink (e.g. a wall charger)."
            }
            return "A USB-PD power source is connected. No data transports are active — this is a power-only sink (e.g. a wall charger)."
        case .unknown:
            return "Link is up but no device is reachable through the registry. Connection may still be negotiating."
        }
    }

    // MARK: - Active transports

    private var transportsCard: some View {
        SectionCard(title: "Active Transports", symbol: "waveform.path") {
            VStack(alignment: .leading, spacing: 10) {
                TransportChipsRow(accessory: port.accessory!)
                Text(transportsLegend(port.accessory!))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func transportsLegend(_ acc: PortAccessoryInfo) -> String {
        let active = acc.activeTransports.count
        let prov = acc.provisionedTransports.count
        let supp = acc.supportedTransports.count
        return "\(active) active · \(prov) provisioned · \(supp) supported by the cable & partner."
    }

    // MARK: - Connector & Cable card

    private var connectorCableCard: some View {
        let acc = port.accessory!
        // `connection` (IOAccessoryUSBConnectString) reports the USB role only
        // — a power-only charger reads "None" even when something is plugged
        // in. Use `connectionActive` for the attached-vs-empty visual, and
        // substitute a clearer label when the port is live but has no USB role.
        let connectionLabel: String = {
            if acc.connection.isConnected { return acc.connection.label }
            return acc.connectionActive ? "Power only" : acc.connection.label
        }()
        var rows: [InfoRow] = [
            InfoRow(label: "Connector",
                    value: acc.connector.label,
                    symbol: acc.connector.symbol),
            InfoRow(label: "Connection",
                    value: connectionLabel,
                    symbol: acc.connectionActive ? "checkmark.circle.fill" : "circle.dashed",
                    tint: acc.connectionActive ? .green : .secondary)
        ]
        // Cable e-marker / plug-event / overcurrent counters are USB-PD
        // bookkeeping — only USB-C / MagSafe HPM accessories publish them.
        if port.connector != .usbA {
            rows.append(contentsOf: [
                InfoRow(label: "Cable Type",
                        value: cableTypeLabel(acc),
                        symbol: "cable.connector"),
                InfoRow(label: "Cable E-Marker",
                        value: acc.cableLabel ?? "Not reported",
                        symbol: "barcode"),
                InfoRow(label: "Plug Events (since boot)",
                        value: "\(acc.plugEventCount)",
                        symbol: "arrow.up.arrow.down.circle"),
                InfoRow(label: "Overcurrent Events",
                        value: "\(acc.overcurrentCount)",
                        symbol: "exclamationmark.triangle",
                        tint: acc.overcurrentCount > 0 ? .red : .secondary)
            ])
        }
        return SectionCard(title: "Connector & Cable", symbol: "cable.connector") {
            InfoRowsView(rows: rows)
        }
    }

    private func cableTypeLabel(_ acc: PortAccessoryInfo) -> String {
        if acc.opticalCable { return "Optical" }
        if acc.activeCable { return "Active (powered e-marker)" }
        if acc.connectionActive { return "Passive" }
        return "—"
    }

    // MARK: - Power Input (Mac is sinking — a charger is supplying us)

    private func powerInputCard(pd: USBPDProfile) -> some View {
        SectionCard(title: "Power Input", symbol: "bolt.fill") {
            VStack(alignment: .leading, spacing: 12) {
                if let win = pd.winning {
                    WinningPDO(option: win, brickID: pd.brickID)
                } else {
                    Text("No active power profile negotiated.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                if !pd.offered.isEmpty {
                    Divider()
                    Text("Profiles offered by the source")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    PDOTable(options: pd.offered, winning: pd.winning)
                }
            }
        }
    }

    // MARK: - USB-C Power Output (Mac is sourcing power to the attached device)

    private func powerOutputCard(_ sp: PortSourcePower) -> some View {
        // 5 V is the USB-C default. Source-side PDOs aren't published in
        // IORegistry on Apple Silicon today, so we can't pretend to know a
        // higher negotiated voltage. The card says so explicitly.
        let totalMA = sp.totalAllocatedMA
        let totalW = Double(totalMA) / 1000.0 * 5.0
        let wakeA = sp.wakeLimitMA.map { Double($0) / 1000.0 }
        let sleepA = sp.sleepLimitMA.map { Double($0) / 1000.0 }
        let portLimitW = sp.wakeLimitMA.map { Double($0) / 1000.0 * 5.0 }

        return SectionCard(title: "Power Output", symbol: "bolt.batteryblock") {
            VStack(alignment: .leading, spacing: 12) {
                if totalMA > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(format: "%.1f W", totalW))
                            .font(.system(size: 30, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.green)
                        Text(String(format: "5 V · %.2f A", Double(totalMA) / 1000.0))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let cap = portLimitW {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "of %.0f W", cap))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                ProgressView(value: min(totalW / max(cap, 0.1), 1.0))
                                    .progressViewStyle(.linear)
                                    .frame(width: 120)
                                    .tint(.green)
                            }
                        }
                    }
                } else {
                    Text("No USB device is currently drawing power on this port.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !sp.sinks.isEmpty {
                    Divider()
                    Text("Per-device allocation")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("Device").gridColumnAlignment(.leading)
                            Text("Allocated").gridColumnAlignment(.trailing)
                            Text("Capability").gridColumnAlignment(.trailing)
                            Text("≈ Power").gridColumnAlignment(.trailing)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        ForEach(sp.sinks) { sink in
                            let watts = Double(sink.allocatedMA) / 1000.0 * 5.0
                            GridRow {
                                Text(sink.name).lineLimit(1)
                                Text("\(sink.allocatedMA) mA").gridColumnAlignment(.trailing).monospacedDigit()
                                Text(sink.capabilityMA.map { "\($0) mA" } ?? "—")
                                    .gridColumnAlignment(.trailing)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.1f W", watts))
                                    .gridColumnAlignment(.trailing)
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }

                if wakeA != nil || sleepA != nil {
                    Divider()
                    Text("Port source limit")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        if let a = wakeA {
                            limitChip(label: "Awake",
                                      value: String(format: "%.1f A", a),
                                      icon: "sun.max")
                        }
                        if let a = sleepA {
                            limitChip(label: "Asleep",
                                      value: String(format: "%.1f A", a),
                                      icon: "moon.zzz")
                        }
                        Spacer()
                    }
                }

                Text("Estimated wattage assumes the USB-C default 5 V. Apple Silicon doesn't expose source-side USB-PD profiles, so PD-fast-charge devices may pull more than this number.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func limitChip(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10))
        .clipShape(Capsule())
    }

    // MARK: - Displays

    /// We show the card when either (a) DP alt-mode is asserted on the
    /// USB-C connector itself or (b) `ContentView` has attributed at least
    /// one display to this port (covers the TB-tunneled-display case where
    /// the connector reports no DP transport but the dock's TB lane carries
    /// a DisplayPort tunnel). When neither holds, displays aren't on this
    /// port and the card stays hidden.
    private var shouldShowDisplaysCard: Bool {
        if port.accessory?.carriesDisplay == true { return true }
        if !displays.isEmpty { return true }
        return false
    }

    /// Display section: lists each external display attributed to this port
    /// (resolution, refresh, color depth, HDR support) and folds the
    /// DisplayPort alt-mode pin assignment + the DP tunnel's reserved
    /// bandwidth in as inline rows. Attribution comes from `ContentView`
    /// so the view doesn't reason about which display goes where.
    private var displaysCard: some View {
        let acc = port.accessory
        let dpTunnel = port.tunnels.first { $0.kind == .displayPort }
        return SectionCard(title: displaysCardTitle, symbol: "display") {
            VStack(alignment: .leading, spacing: 14) {
                if displays.isEmpty {
                    Text("This port has a DisplayPort path active but no lit display surface was found. The framebuffer engine may still be coming up, or the panel may be in standby.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displays) { d in
                        DisplayRowCompact(display: d, onNavigate: onNavigate)
                        if d.id != displays.last?.id { Divider() }
                    }
                }
                // Alt-mode pin / HPD lines only make sense when the
                // connector itself is driving the display — TB-tunneled
                // displays don't touch USB-C alt-mode at all.
                if let acc, acc.carriesDisplay {
                    Divider()
                    let altRows: [InfoRow] = [
                        InfoRow(label: "Hot-Plug Detect",
                                value: acc.hpdAsserted ? "Asserted — display attached" : "Idle",
                                symbol: "dot.radiowaves.up.forward",
                                tint: acc.hpdAsserted ? .pink : .secondary),
                        InfoRow(label: "Pin Assignment",
                                value: displayPortPinAssignmentLabel(acc.displayPortPinAssignment),
                                symbol: "rectangle.connected.to.line.below")
                    ]
                    InfoRowsView(rows: altRows)
                }
                if let dp = dpTunnel {
                    Divider()
                    DPBandwidthRow(tunnel: dp,
                                   linkBandwidth: port.bandwidthSummary.linkBandwidth)
                }
            }
        }
    }

    private var displaysCardTitle: String {
        if displays.isEmpty { return "Display" }
        if displays.count == 1 { return "Display" }
        return "Displays (\(displays.count))"
    }

    // MARK: - Ethernet (synthesised from USB-Ethernet adapters attached to the port)

    private func ethernetCard(adapters: [USBEthernetAdapterInfo]) -> some View {
        SectionCard(title: ethernetCardTitle(count: adapters.count), symbol: "network") {
            VStack(spacing: 0) {
                ForEach(adapters, id: \.interfaceID) { info in
                    EthernetAdapterRow(info: info, onNavigate: onNavigate)
                    if info.interfaceID != adapters.last?.interfaceID { Divider() }
                }
            }
        }
    }

    private func ethernetCardTitle(count: Int) -> String {
        count == 1 ? "Ethernet" : "Ethernet (\(count))"
    }

    // MARK: - Existing cards (tunnels / USB / connected device / related)

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
                if hasRealLaneAdapter {
                    Button {
                        onNavigate(port.laneAdapter.id)
                    } label: {
                        Label("Lane adapter", systemImage: "bolt.horizontal")
                    }
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

    /// True iff `laneAdapter` is a real IORegistry node rather than a synthetic
    /// stub (USB-A ports and HPM-only fallbacks don't have a Thunderbolt lane
    /// to jump to, so the button would dead-end in the empty state).
    private var hasRealLaneAdapter: Bool {
        !port.laneAdapter.className.isEmpty
    }

    private func countRouters(_ device: ConnectedDevice) -> Int {
        return 1 + device.daisyChained.reduce(0) { $0 + countRouters($1) }
    }
}

// MARK: - Badges

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

private struct AccessoryBadges: View {
    let acc: PortAccessoryInfo
    /// True when the mode badge already conveys "Display" — skip the
    /// accessory-side display badge to avoid two adjacent identical chips.
    let suppressDisplay: Bool

    var body: some View {
        HStack(spacing: 6) {
            if acc.carriesDisplay && !suppressDisplay {
                badge("Display", icon: "display", color: .pink)
            }
            if acc.activeCable {
                badge("Active cable", icon: "bolt.circle", color: .yellow)
            }
            if acc.opticalCable {
                badge("Optical", icon: "fibrechannel", color: .indigo)
            }
            if acc.connectionCount > 0 {
                badge("\(acc.connectionCount) plug\(acc.connectionCount == 1 ? "" : "s")",
                      icon: "arrow.up.arrow.down.circle",
                      color: .secondary)
            }
        }
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Power callout (top-right of hero header)

private struct PowerCallout: View {
    let watts: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                Text(watts).font(.title2.weight(.semibold).monospacedDigit())
            }
            Text("Power Input").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Transport chips row

private struct TransportChipsRow: View {
    let accessory: PortAccessoryInfo

    var body: some View {
        FlowChips {
            ForEach(USBCTransport.allCases, id: \.self) { t in
                TransportChip(transport: t,
                              state: state(for: t))
            }
            // Render any vendor / unknown transports the kernel published.
            ForEach(Array(otherTransports), id: \.self) { t in
                TransportChip(transport: t, state: state(for: t))
            }
        }
    }

    private var otherTransports: Set<USBCTransport> {
        let known = Set(USBCTransport.allCases)
        let all = accessory.supportedTransports
            .union(accessory.provisionedTransports)
            .union(accessory.activeTransports)
        return all.subtracting(known)
    }

    private func state(for t: USBCTransport) -> TransportChip.State {
        if accessory.activeTransports.contains(t) { return .active }
        if accessory.provisionedTransports.contains(t) { return .provisioned }
        if accessory.supportedTransports.contains(t) { return .supported }
        return .unavailable
    }
}

private struct TransportChip: View {
    let transport: USBCTransport

    enum State { case active, provisioned, supported, unavailable }
    let state: State

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: transport.symbol)
                .font(.caption2)
            Text(transport.label).font(.caption.weight(.medium))
            if let badge = stateBadge {
                Text(badge).font(.caption2)
                    .opacity(0.7)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(background)
        .overlay(
            Capsule().strokeBorder(border, lineWidth: 0.5)
        )
        .clipShape(Capsule())
        .help(helpText)
    }

    private var stateBadge: String? {
        switch state {
        case .active: return "· live"
        case .provisioned: return "· ready"
        case .supported, .unavailable: return nil
        }
    }

    private var foreground: Color {
        switch state {
        case .active: return transport.color
        case .provisioned: return transport.color.opacity(0.85)
        case .supported: return .secondary
        case .unavailable: return Color.secondary.opacity(0.55)
        }
    }

    private var background: Color {
        switch state {
        case .active: return transport.color.opacity(0.18)
        case .provisioned: return transport.color.opacity(0.10)
        case .supported, .unavailable: return Color.secondary.opacity(0.07)
        }
    }

    private var border: Color {
        switch state {
        case .active: return transport.color.opacity(0.5)
        case .provisioned: return transport.color.opacity(0.3)
        case .supported, .unavailable: return Color.secondary.opacity(0.2)
        }
    }

    private var helpText: String {
        switch state {
        case .active: return "\(transport.label) — active. \(transport.detail)"
        case .provisioned: return "\(transport.label) — provisioned but not currently carrying data."
        case .supported: return "\(transport.label) — supported by the cable & partner, not in use."
        case .unavailable: return "\(transport.label) — not available on this connection."
        }
    }
}

// MARK: - USB-PD displays

private struct WinningPDO: View {
    let option: USBPDOption
    let brickID: USBPDOption?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.powerLabel)
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.yellow)
                Text("\(option.voltageLabel)  ·  \(option.currentLabel)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let brick = brickID {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Brick ID")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(brick.voltageLabel) · \(brick.currentLabel)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PDOTable: View {
    let options: [USBPDOption]
    let winning: USBPDOption?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.center)
                Text("Voltage").gridColumnAlignment(.trailing)
                Text("Current").gridColumnAlignment(.trailing)
                Text("Power").gridColumnAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(options) { opt in
                let isWinner = matchesWinner(opt)
                GridRow {
                    Image(systemName: isWinner ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isWinner ? Color.yellow : Color.secondary.opacity(0.5))
                        .font(.caption)
                    Text(opt.voltageLabel)
                        .gridColumnAlignment(.trailing)
                        .monospacedDigit()
                    Text(opt.currentLabel)
                        .gridColumnAlignment(.trailing)
                        .monospacedDigit()
                    Text(opt.powerLabel)
                        .gridColumnAlignment(.trailing)
                        .monospacedDigit()
                        .foregroundStyle(isWinner ? .primary : .secondary)
                }
                .font(.callout)
            }
        }
    }

    private func matchesWinner(_ opt: USBPDOption) -> Bool {
        guard let w = winning else { return false }
        return w.voltageMV == opt.voltageMV
            && w.maxCurrentMA == opt.maxCurrentMA
            && w.maxPowerMW == opt.maxPowerMW
    }
}

// MARK: - Information rows (re-usable for Connector & Cable / Display alt-mode)

private struct InfoRow: Hashable {
    let label: String
    let value: String
    let symbol: String
    var tint: Color? = nil
}

private struct InfoRowsView: View {
    let rows: [InfoRow]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.self) { r in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: r.symbol)
                        .foregroundStyle(r.tint ?? .secondary)
                        .frame(width: 22)
                    Text(r.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(r.value)
                        .font(.callout)
                        .foregroundStyle(r.tint ?? .primary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 6)
                if r != rows.last { Divider() }
            }
        }
    }
}

// MARK: - Tunnel row

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

// MARK: - Display row (compact)

/// One external display in the port's Displays card. Resolution + refresh
/// dominate the row; HDR / bit depth ride along as secondary chips. Clicking
/// the row jumps to the full `DisplayDetailView`.
private struct DisplayRowCompact: View {
    let display: DisplayInfo
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        Button { onNavigate(display.id) } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: display.iconSymbol)
                    .foregroundStyle(.pink)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.title).font(.callout.weight(.medium))
                    if let s = subtitleLine, !s.isEmpty {
                        Text(s).font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if !badges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(badges, id: \.self) { b in
                                Text(b)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.10))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitleLine: String? {
        var parts: [String] = []
        if let w = display.widthPixels, let h = display.heightPixels, w > 0, h > 0 {
            parts.append("\(w) × \(h)")
        }
        if let mx = display.maxRefreshHz {
            if let mn = display.minRefreshHz, abs(mx - mn) > 1 {
                parts.append("\(Int(mn.rounded()))–\(Int(mx.rounded())) Hz")
            } else {
                parts.append("\(Int(mx.rounded())) Hz")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var badges: [String] {
        var out: [String] = []
        if let d = display.colorBitDepth { out.append("\(d)-bit color") }
        if display.supportsHDR { out.append("HDR") }
        if let acc = display.colorAccuracyIndex { out.append("Accuracy index \(acc)") }
        return out
    }
}

// MARK: - DisplayPort bandwidth row

/// Inline row used inside the Displays card: surfaces the DP tunnel's
/// reservation against the link's capacity. Reads as "Bandwidth Reserved
/// 25.6 Gb/s of 80 Gb/s" with a small progress bar — the user asked for
/// reserved/consumed bandwidth to show up where they can see what's eating
/// the link.
///
/// DP function adapters often publish `Required = Maximum = 1` (100 Mb/s)
/// even on a live tunnel — that's a placeholder, not the real allocation
/// (CLAUDE.md "Things that bit me"). When we see that, the row degrades
/// to "Carried over Thunderbolt" without a misleading number.
private struct DPBandwidthRow: View {
    let tunnel: PortTunnel
    let linkBandwidth: UInt64?

    private var hasRealReservation: Bool {
        max(tunnel.reservedBandwidth, tunnel.maxBandwidth) >= 10
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasRealReservation ? "DisplayPort Bandwidth" : "DisplayPort Tunnel")
                    .font(.callout.weight(.medium))
                Text(detailLine).font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasRealReservation, let bw = linkBandwidth, bw > 0 {
                ProgressView(value: progress(linkBandwidth: bw))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .tint(.blue)
            }
        }
        .padding(.vertical, 6)
    }

    private var detailLine: String {
        if !hasRealReservation {
            // DP adapters don't statically reserve TB bandwidth; the link
            // capacity is the only meaningful number to show here.
            var parts: [String] = ["Active · \(tunnel.adapterCount) adapter\(tunnel.adapterCount == 1 ? "" : "s")"]
            if let bw = linkBandwidth, bw > 0 {
                parts.append("\(tbBandwidthLabel(bw)) link")
            }
            return parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if tunnel.reservedBandwidth >= 10 {
            parts.append("Reserved \(tbBandwidthLabel(tunnel.reservedBandwidth))")
        }
        if tunnel.maxBandwidth >= 10 {
            parts.append("Max \(tbBandwidthLabel(tunnel.maxBandwidth))")
        }
        if let bw = linkBandwidth, bw > 0 {
            parts.append("of \(tbBandwidthLabel(bw)) link")
        }
        return parts.joined(separator: " · ")
    }

    private func progress(linkBandwidth: UInt64) -> Double {
        let used = max(tunnel.reservedBandwidth, tunnel.maxBandwidth)
        guard linkBandwidth > 0, used > 0 else { return 0 }
        return min(Double(used) / Double(linkBandwidth), 1.0)
    }
}

// MARK: - USB-Ethernet row

private struct EthernetAdapterRow: View {
    let info: USBEthernetAdapterInfo
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        Button { onNavigate(info.interfaceID) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "network")
                    .foregroundStyle(info.linkActive ? .green : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(adapterTitle).font(.callout.weight(.medium))
                    if let s = adapterSubtitle, !s.isEmpty {
                        Text(s).font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    let chips = statusChips
                    if !chips.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(chips, id: \.label) { chip in
                                HStack(spacing: 3) {
                                    Image(systemName: chip.symbol).font(.caption2)
                                    Text(chip.label).font(.caption2)
                                }
                                .foregroundStyle(chip.color)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(chip.color.opacity(0.12))
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var adapterTitle: String {
        info.productName ?? info.usbDeviceTitle ?? "USB Ethernet Adapter"
    }

    private var adapterSubtitle: String? {
        var parts: [String] = []
        if let v = info.usbVendorName, !v.isEmpty { parts.append(v) }
        if let bsd = info.bsdName { parts.append("Interface \(bsd)") }
        if let mac = info.macAddress { parts.append(mac.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private struct Chip { let symbol: String; let label: String; let color: Color }

    private var statusChips: [Chip] {
        var out: [Chip] = []
        if info.linkActive {
            out.append(Chip(symbol: "checkmark.circle.fill", label: "Link up", color: .green))
        } else {
            out.append(Chip(symbol: "minus.circle", label: "Link down", color: .secondary))
        }
        if let mbps = info.linkSpeedMbps {
            out.append(Chip(symbol: "speedometer", label: ethernetSpeedLabel(mbps), color: .blue))
        }
        return out
    }
}
