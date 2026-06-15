//
//  BuiltInPortViews.swift
//  PortScope
//
//  Curated detail pages for built-in non-USB-C/USB-A receptacles on the
//  chassis: the AC PSU on desktop Macs, the Ethernet jack, the HDMI jack,
//  and the SD Card slot. The unified `PhysicalPortDetailView` is built
//  around USB-C semantics (USB-PD profiles, alt-mode transports, cable
//  e-markers, plug orientation) — none of which apply to a plain RJ-45 or
//  a kettle-cord PSU. Each of these views focuses on what the port itself
//  actually represents (live wattage / link state / card-present), with a
//  Developer Details disclosure at the bottom that exposes the underlying
//  IOKit properties verbatim — that's the "jump to the hierarchy" affordance.
//

import SwiftUI

// MARK: - AC Power Input (desktop PSU)

/// Detail page for the AC power-input port on a desktop chassis. Pulls
/// the live wattage/voltage/current readings directly from the synthetic
/// USB-PD profile that `PowerInputScanner` builds from the kernel's
/// `PowerTelemetryData` dict.
struct ACPowerDetailView: View {
    let port: PhysicalPort
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: stats)
                telemetryCard
                developerDetails
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    // MARK: Hero

    private var hero: some View {
        let live = port.accessory?.usbPD?.winning
        let wattsLabel = live?.powerLabel ?? "—"
        let isLive = (live?.maxPowerMW ?? 0) > 0

        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill((isLive ? Color.yellow : .secondary).opacity(0.18))
                    .frame(width: 84, height: 84)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(isLive ? .yellow : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(port.cliTitle).font(.title2).bold()
                if let loc = port.locationLabel {
                    Text(loc).foregroundStyle(.secondary)
                }
                Text(isLive ? "Mac is drawing power from the wall" : "No telemetry reported")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(wattsLabel)
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isLive ? .yellow : .secondary)
                if let live, isLive {
                    Text("\(live.voltageLabel) · \(live.currentLabel)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Stats

    private var stats: [Stat] {
        let live = port.accessory?.usbPD?.winning
        let watts = live.map { String(format: "%.1f W", Double($0.maxPowerMW) / 1000.0) } ?? "—"
        let volts = live.map { String(format: "%.2f V", Double($0.voltageMV) / 1000.0) } ?? "—"
        let amps = live.map { String(format: "%.3f A", Double($0.maxCurrentMA) / 1000.0) } ?? "—"
        let spec = port.catalogCapability ?? "—"
        let externalConnected = port.accessory?.registryProperties["ExternalConnected"]?.asBool ?? false
        return [
            Stat(label: "Power", value: watts, symbol: "bolt.fill"),
            Stat(label: "Voltage", value: volts, symbol: "waveform.path"),
            Stat(label: "Current", value: amps, symbol: "wave.3.right"),
            Stat(label: "Power Source", value: externalConnected ? "AC" : "Unknown",
                 symbol: "powerplug.fill"),
            Stat(label: "PSU Spec", value: spec, symbol: "cpu"),
            Stat(label: "Port",
                 value: port.catalogLocation ?? "Built-in",
                 symbol: "rectangle.connected.to.line.below")
        ]
    }

    // MARK: Telemetry detail card

    @ViewBuilder
    private var telemetryCard: some View {
        // The `PowerTelemetryData` dict carries running totals + per-second
        // snapshots that don't fit cleanly into the headline stat row.
        // Surface a few of the more interesting ones; the rest are visible
        // in the Developer Details disclosure below.
        if let dict = telemetryDict {
            SectionCard(title: "Power Telemetry", symbol: "chart.line.uptrend.xyaxis") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    if let v = dict["SystemLoad"]?.asUInt {
                        telemetryRow("System Load",
                                     "\(String(format: "%.2f", Double(v) / 1000.0)) W",
                                     hint: "Power the SoC is currently consuming")
                    }
                    if let v = dict["AdapterEfficiencyLoss"]?.asUInt {
                        telemetryRow("Adapter Loss",
                                     "\(String(format: "%.2f", Double(v) / 1000.0)) W",
                                     hint: "Heat dissipated in the PSU itself")
                    }
                    if let wallTotal = dict["AccumulatedWallEnergyEstimate"]?.asUInt {
                        telemetryRow("Wall Energy (since boot)",
                                     formatEnergyMilliWattSeconds(wallTotal),
                                     hint: "Total energy drawn from the outlet since the Mac last started")
                    }
                    // `AccumulatedSystemEnergyConsumed` is intentionally
                    // NOT rendered as Wh — empirically its raw value
                    // runs 5+ orders of magnitude larger than
                    // `AccumulatedWallEnergyEstimate` on the same host,
                    // so feeding it through the mJ→Wh divisor produces
                    // physically impossible numbers (~63 GWh on a
                    // several-day boot). Its actual unit is not
                    // documented and not the same mJ as the Wall
                    // counter. The raw value remains visible in the
                    // Developer Details disclosure below.
                }
            }
        }
    }

    private var telemetryDict: [String: IORegValue]? {
        guard let raw = port.accessory?.registryProperties["PowerTelemetryData"],
              case let .dictionary(kv) = raw
        else { return nil }
        return Dictionary(kv, uniquingKeysWith: { a, _ in a })
    }

    private func telemetryRow(_ label: String, _ value: String, hint: String) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout)
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(value).font(.callout.monospacedDigit())
                .gridColumnAlignment(.trailing)
        }
    }

    /// `Accumulated*` totals are denominated in milliwatt-seconds (mJ).
    /// Convert to a familiar wall-energy unit. The numbers are big — past
    /// ~1 kWh we drop to Wh; past 1 MWh (improbable) we'd drop to kWh; but
    /// since this is per-boot, Wh is almost always plenty.
    private func formatEnergyMilliWattSeconds(_ raw: UInt64) -> String {
        // 1 Wh = 1000 W × 3600 s = 3_600_000 mJ → so mJ / 3_600_000.
        let wh = Double(raw) / 3_600_000.0
        if wh >= 1000 { return String(format: "%.2f kWh", wh / 1000.0) }
        if wh >= 1    { return String(format: "%.1f Wh", wh) }
        return String(format: "%.3f Wh", wh)
    }

    private var developerDetails: some View {
        BuiltInDeveloperDetails(accessory: port.accessory,
                                fallbackTitle: "Power Input",
                                fallbackClass: "AppleSmartBattery")
    }
}

// MARK: - Ethernet

/// Detail page for a built-in RJ-45 jack. The headline is the link state
/// and negotiated speed; vendor / driver / MAC / firmware sit in the stats
/// grid, and the raw IOKit properties remain accessible via the Developer
/// Details disclosure for spelunkers.
struct EthernetDetailView: View {
    let port: PhysicalPort
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: stats)
                developerDetails
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var props: [String: IORegValue] { port.accessory?.registryProperties ?? [:] }
    private var linkActive: Bool {
        port.accessory?.connectionActive
            ?? (props["LinkActive"]?.asBool ?? false)
    }
    private var linkSpeedMbps: UInt64? {
        if let v = props["LinkSpeedMbps"]?.asUInt, v > 0 { return v }
        return nil
    }

    private var hero: some View {
        let color: Color = linkActive ? .green : .secondary
        let symbol = linkActive ? "cable.coaxial" : "cable.coaxial.slash"
        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(port.cliTitle).font(.title2).bold()
                if let loc = port.locationLabel {
                    Text(loc).foregroundStyle(.secondary)
                }
                Text(headlineSubtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let mbps = linkSpeedMbps {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ethernetSpeedLabel(mbps))
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.green)
                    Text("Negotiated")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var headlineSubtitle: String {
        if linkActive {
            if let mbps = linkSpeedMbps { return "Linked · \(ethernetSpeedLabel(mbps))" }
            return "Linked"
        }
        return "Cable unplugged"
    }

    private var stats: [Stat] {
        let mac = props["IOMACAddress"]?.asString.map(prettifyMAC) ?? "—"
        let bsdName = props["BSD Name"]?.asString ?? "—"
        let vendor = props["IOVendor"]?.asString ?? "—"
        let model = props["IOModel"]?.asString ?? "—"
        let driverVer = props["Driver_Version"]?.asString ?? "—"
        let fwVer = props["FirmwareVersionString"]?.asString ?? "—"
        let mtu = props["IOMaxTransferUnit"]?.asUInt.map { "\($0) bytes" } ?? "—"
        let jumbo = props["IOMaxPacketSize"]?.asUInt
            .map { $0 > 1500 ? "Jumbo capable (\($0) bytes)" : "Standard" } ?? "—"
        return [
            Stat(label: "BSD Name", value: bsdName, symbol: "terminal"),
            Stat(label: "MAC Address", value: mac, symbol: "barcode", isSecret: true),
            Stat(label: "Controller",
                 value: vendor == "—" && model == "—" ? "—" : "\(vendor) \(model)",
                 symbol: "cpu"),
            Stat(label: "Driver", value: driverVer, symbol: "puzzlepiece.extension"),
            Stat(label: "Firmware", value: fwVer, symbol: "memorychip"),
            // Duplex decoded from the high half of the `IOActiveMedium`
            // IFM_* word — half-duplex on a modern jack is almost always
            // a misconfigured switch or a degraded cable. Surface it so
            // the user can spot it without parsing the hex blob.
            Stat(label: "Duplex",
                 value: duplexLabel,
                 symbol: "arrow.left.arrow.right"),
            Stat(label: "MTU", value: mtu, symbol: "tray.full"),
            Stat(label: "Jumbo Frames", value: jumbo, symbol: "shippingbox"),
            Stat(label: "PHY Spec",
                 value: port.catalogCapability ?? "—",
                 symbol: "rectangle.connected.to.line.below")
        ]
    }

    /// Decode `IOActiveMedium`'s IFM_FDX bit (0x00100000) into a friendly
    /// label. Returns "—" when the link is down or the field is missing.
    private var duplexLabel: String {
        guard linkActive else { return "—" }
        if case .unsigned(let u)? = props["IOActiveMedium"] {
            return (u & 0x00100000) != 0 ? "Full" : "Half"
        }
        if var s = props["IOActiveMedium"]?.asString {
            if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
            if let raw = UInt64(s, radix: 16) {
                return (raw & 0x00100000) != 0 ? "Full" : "Half"
            }
        }
        return "—"
    }

    /// `IOMACAddress` arrives as a string like "0x00c5850fbdcb"; turn it
    /// into the conventional colon-separated lowercase form.
    private func prettifyMAC(_ raw: String) -> String {
        var hex = raw
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        guard hex.count == 12 else { return raw }
        let lower = Array(hex.lowercased())
        var parts: [String] = []
        parts.reserveCapacity(6)
        for i in stride(from: 0, to: lower.count, by: 2) {
            parts.append(String(lower[i..<i + 2]))
        }
        return parts.joined(separator: ":")
    }

    private var developerDetails: some View {
        BuiltInDeveloperDetails(accessory: port.accessory,
                                fallbackTitle: "Ethernet Interface",
                                fallbackClass: "IOEthernetInterface")
    }
}

// MARK: - HDMI

/// Detail page for the built-in HDMI jack. The kernel tells us whether a
/// cable is seated (`HDMI_HPD`), whether a sink has finished negotiating
/// (`ConnectionActive`), and what alt-mode-style transports are active
/// (DisplayPort over the HDMI port, on Apple Silicon). We surface those
/// directly and skip the USB-C transport-chip grid — there's no USB on a
/// classic HDMI jack.
struct HDMIDetailView: View {
    let port: PhysicalPort
    /// External displays attributed to this port by `ContentView` (same
    /// `displaysAttributed` heuristic the unified USB-C view uses) — the
    /// sidebar nests the monitor under the HDMI port, so the detail page
    /// should show it too.
    var displays: [DisplayInfo] = []
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: stats)
                if !displays.isEmpty {
                    displaysCard
                }
                developerDetails
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var displaysCard: some View {
        SectionCard(title: displays.count == 1 ? "Display" : "Displays (\(displays.count))",
                    symbol: "display") {
            VStack(spacing: 0) {
                ForEach(displays) { d in
                    HDMIDisplayRow(display: d, onNavigate: onNavigate)
                    if d.id != displays.last?.id { Divider() }
                }
            }
        }
    }

    private var props: [String: IORegValue] { port.accessory?.registryProperties ?? [:] }
    private var hpd: Bool {
        props["HDMI_HPD"]?.asBool ?? port.accessory?.hpdAsserted ?? false
    }
    private var connectionActive: Bool {
        port.accessory?.connectionActive ?? false
    }
    private var dpAlt: Bool { port.accessory?.activeTransports.contains(.displayPort) ?? false }

    private var hero: some View {
        let attached = hpd || connectionActive || dpAlt
        let color: Color = attached ? .pink : .secondary
        let symbol = attached ? "display" : "tv.slash"
        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(port.cliTitle).font(.title2).bold()
                if let loc = port.locationLabel {
                    Text(loc).foregroundStyle(.secondary)
                }
                Text(headlineSubtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var headlineSubtitle: String {
        if connectionActive { return "Display attached and negotiated" }
        if hpd { return "Cable seated · waiting on link" }
        if dpAlt { return "Carrying DisplayPort" }
        return "No cable detected"
    }

    private var stats: [Stat] {
        let plugCount = props["ConnectionCount"]?.asUInt.map(String.init) ?? "0"
        let active = (props["TransportsActive"]?.asArray ?? []).joined(separator: ", ")
        return [
            Stat(label: "Cable", value: hpd ? "Seated" : "Unplugged",
                 symbol: hpd ? "checkmark.circle.fill" : "circle.dashed"),
            Stat(label: "Sink Negotiated",
                 value: connectionActive ? "Yes" : "No",
                 symbol: "checkmark.seal"),
            Stat(label: "Active Transports",
                 value: active.isEmpty ? "—" : active,
                 symbol: "waveform.path"),
            Stat(label: "HDMI Spec",
                 value: port.catalogCapability ?? "—",
                 symbol: "rectangle.connected.to.line.below"),
            Stat(label: "Location",
                 value: port.catalogLocation ?? "Built-in",
                 symbol: "viewfinder"),
            Stat(label: "Plug Events (since boot)",
                 value: plugCount,
                 symbol: "arrow.up.arrow.down.circle")
        ]
    }

    private var developerDetails: some View {
        BuiltInDeveloperDetails(accessory: port.accessory,
                                fallbackTitle: "HDMI Port",
                                fallbackClass: "IODPHDMIPort")
    }
}

/// One attributed external display under the HDMI port — icon, title,
/// resolution/refresh subtitle, and a chevron that jumps to the display's
/// own detail page. Mirrors the unified port view's display rows.
private struct HDMIDisplayRow: View {
    let display: DisplayInfo
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        Button {
            onNavigate(display.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: display.iconSymbol)
                    .foregroundStyle(.pink)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.title).font(.callout.weight(.medium))
                    if let s = display.subtitle, !s.isEmpty {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SD Card

/// Detail page for the built-in SD card reader. The receptacle is always
/// rendered when the chassis ships one; the live signal is "is there a
/// card mounted right now" — the storage stack publishes `IOMedia` nodes
/// downstream when a card is usable, and `SDCardScanner` translates that
/// into `connectionActive`.
struct SDCardDetailView: View {
    let port: PhysicalPort
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: stats)
                developerDetails
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var inserted: Bool { port.accessory?.connectionActive ?? false }

    private var hero: some View {
        let color: Color = inserted ? .teal : .secondary
        let symbol = inserted ? "sdcard.fill" : "sdcard"
        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(port.cliTitle).font(.title2).bold()
                if let loc = port.locationLabel {
                    Text(loc).foregroundStyle(.secondary)
                }
                Text(inserted ? "Card inserted and mounted" : "Slot empty")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var stats: [Stat] {
        return [
            Stat(label: "Card",
                 value: inserted ? "Inserted" : "Empty",
                 symbol: inserted ? "checkmark.circle.fill" : "circle.dashed"),
            Stat(label: "Reader Spec",
                 value: port.catalogCapability ?? "—",
                 symbol: "rectangle.connected.to.line.below"),
            Stat(label: "Location",
                 value: port.catalogLocation ?? "Built-in",
                 symbol: "viewfinder")
        ]
    }

    private var developerDetails: some View {
        BuiltInDeveloperDetails(accessory: port.accessory,
                                fallbackTitle: "SD Card Reader",
                                fallbackClass: "pcie-sdreader")
    }
}

// MARK: - Shared developer-details disclosure

/// Inline disclosure that surfaces the underlying IOKit properties for a
/// port accessory verbatim. The accessory's `registryProperties` dict and
/// `registryPath` are wrapped in a synthetic `TBNode` so we can re-use
/// `PropertyTableView` (which is the same widget the bus-tree detail
/// views use for their Developer Details section). Clicking the chevron
/// reveals the full property dump — that's the "jump to the hierarchy"
/// affordance for the built-in port pages.
private struct BuiltInDeveloperDetails: View {
    let accessory: PortAccessoryInfo?
    let fallbackTitle: String
    let fallbackClass: String

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

            if open, let node = syntheticNode {
                PropertyTableView(node: node).padding(.top, 8)
            } else if open {
                Text("No IOKit properties were captured for this port.")
                    .foregroundStyle(.secondary).font(.callout)
                    .padding(.top, 8)
            }
        }
    }

    private var syntheticNode: TBNode? {
        guard let accessory else { return nil }
        let props = accessory.registryProperties
        // Stable display order: alphabetical. The scanners don't preserve a
        // canonical order for these dicts, so anything else would be
        // arbitrary.
        let order = props.keys.sorted()
        return TBNode(
            id: accessory.id,
            kind: .other,
            title: fallbackTitle,
            subtitle: nil,
            className: fallbackClass,
            properties: props,
            propertyOrder: order,
            children: [],
            registryPath: accessory.registryPath
        )
    }
}

// MARK: - Small IORegValue convenience

private extension IORegValue {
    /// String-array view of an `.array(...)` of `.string(...)` entries.
    /// Used for the HDMI `TransportsActive` field, which the kernel
    /// publishes as `("DisplayPort")` and friends.
    var asArray: [String]? {
        guard case .array(let arr) = self else { return nil }
        let strings = arr.compactMap { $0.asString }
        return strings.count == arr.count ? strings : nil
    }
}
