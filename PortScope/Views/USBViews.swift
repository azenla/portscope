//
//  USBViews.swift
//  PortScope
//
//  Kind-specific summary cards for USB host controllers, hubs, devices, and
//  interfaces. Cross-links into the Thunderbolt tree when a controller is
//  reached over a tunneled TB switch.
//

import SwiftUI

// MARK: - USB host controller

struct USBControllerView: View {
    let node: TBNode
    let tbContext: TBNodeID?
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let portCount = node.properties["Number of Ports"]?.asUInt
            ?? node.properties["NumberOfPorts"]?.asUInt
        let xhciVersion = node.properties["kUSBControllerVersion"]?.asUInt
        let pciVendor = node.properties["PCI Vendor ID"]?.asUInt
            ?? node.properties["idVendor"]?.asUInt
        let pciDevice = node.properties["PCI Device ID"]?.asUInt
            ?? node.properties["idProduct"]?.asUInt
        let attached = countDevices(under: node)

        let chip = chipFamily(from: node)
        let protoLabel = node.properties["UsbHostControllerProtocolRevision"]?.asString
            ?? xhciVersion.map(usbBcdVersion)
            ?? "—"

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Hardware",
                     value: chip,
                     symbol: "cpu"),
                Stat(label: "USB Spec",
                     value: protoLabel == "—" ? "—" : "xHCI \(protoLabel)",
                     symbol: "memorychip"),
                Stat(label: "Downstream Ports",
                     value: portCount.map(String.init) ?? "—",
                     symbol: "rectangle.3.group"),
                Stat(label: "Attached Devices",
                     value: "\(attached.devices)",
                     symbol: "cable.connector"),
                Stat(label: "PCI Vendor / Device",
                     value: pciVendor.map { String(format: "0x%04X", $0) }
                        .flatMap { v in pciDevice.map { "\(v):\(String(format: "0x%04X", $0))" } } ?? "—",
                     symbol: "barcode"),
                Stat(label: "Sleep Capable",
                     value: (node.properties["kUSBSleepSupported"]?.asBool ?? false) ? "Yes" : "No",
                     symbol: "moon.zzz")
            ])

            if let tb = tbContext {
                TBLinkCard(label: "This USB host controller is tunneled over Thunderbolt.",
                           tbSwitchID: tb,
                           onNavigate: onNavigate)
            }

            USBDeviceTreeCard(root: node, onNavigate: onNavigate)
        }
    }

    /// Translate IORegistry hints into a human chip-family label. Uses
    /// `IONameMatch` tokens ("usb-drd,t8142", "usb-auss,t6050") instead of
    /// raw class names so the user doesn't see "AppleT8142USBXHCI".
    private func chipFamily(from node: TBNode) -> String {
        let nameMatch = node.properties["IONameMatch"]?.asString
            ?? node.properties["IONameMatched"]?.asString
            ?? ""
        let kind: String
        if nameMatch.hasPrefix("usb-drd") {
            kind = "Thunderbolt-attached"
        } else if nameMatch.hasPrefix("usb-auss") {
            kind = "SoC-integrated"
        } else if nameMatch.hasPrefix("usb-host") {
            kind = "Host"
        } else {
            kind = "USB"
        }
        // Pull the silicon token (e.g. "t8142") if present.
        if let comma = nameMatch.firstIndex(of: ",") {
            let silicon = String(nameMatch[nameMatch.index(after: comma)...]).uppercased()
            if !silicon.isEmpty {
                return "\(kind) (\(silicon))"
            }
        }
        return kind == "USB" ? "USB Controller" : kind
    }
}

// MARK: - USB hub

struct USBHubView: View {
    let node: TBNode
    let tbContext: TBNodeID?
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let portCount = node.properties["Number of Ports"]?.asUInt
        let speed = node.properties["Device Speed"]?.asUInt
            ?? node.properties["kUSBCurrentSpeed"]?.asUInt
        let bcdUSB = node.properties["bcdUSB"]?.asUInt
        let power = USBDevicePower(properties: node.properties)
        let attached = countDevices(under: node)

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Vendor",
                     value: NodeFormatter.usbVendorName(node.properties) ?? "—",
                     symbol: "building.2"),
                Stat(label: "Model",
                     value: NodeFormatter.usbProductName(node.properties) ?? "—",
                     symbol: "shippingbox"),
                Stat(label: "Capability",
                     value: usbCapabilityLabel(bcdUSB: bcdUSB),
                     symbol: "arrow.up.forward"),
                Stat(label: "Negotiated Speed",
                     value: usbSpeedLabel(speed),
                     symbol: "antenna.radiowaves.left.and.right"),
                Stat(label: "Downstream Ports",
                     value: portCount.map(String.init) ?? "—",
                     symbol: "rectangle.3.group"),
                Stat(label: "Attached Devices",
                     value: "\(attached.devices)",
                     symbol: "cable.connector"),
                Stat(label: "Power Output",
                     value: power.allocationLabel,
                     symbol: "bolt"),
                Stat(label: "Firmware",
                     value: usbBcdVersion(node.properties["bcdDevice"]?.asUInt),
                     symbol: "memorychip"),
                Stat(label: "Built-In",
                     value: (node.properties["Built-In"]?.asBool ?? false) ? "Yes" : "No",
                     symbol: "macbook")
            ])

            if speed != nil || bcdUSB != nil {
                USBLinkRateCard(currentSpeed: speed, bcdUSB: bcdUSB,
                                deviceClass: node.properties["bDeviceClass"]?.asUInt)
            }
            if power.hasData {
                USBSinkPowerCard(power: power)
            }
            if let tb = tbContext {
                TBLinkCard(label: "Reached through a Thunderbolt-tunneled USB controller.",
                           tbSwitchID: tb,
                           onNavigate: onNavigate)
            }
            USBDeviceTreeCard(root: node, onNavigate: onNavigate)
        }
    }
}

// MARK: - USB device

struct USBDeviceView: View {
    let node: TBNode
    let tbContext: TBNodeID?
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let speed = node.properties["Device Speed"]?.asUInt
            ?? node.properties["kUSBCurrentSpeed"]?.asUInt
        let bcdUSB = node.properties["bcdUSB"]?.asUInt
        let power = USBDevicePower(properties: node.properties)
        let vid = node.properties["idVendor"]?.asUInt
        let pid = node.properties["idProduct"]?.asUInt
        let cls = node.properties["bDeviceClass"]?.asUInt
        let serial = node.properties["kUSBSerialNumberString"]?.asString

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Vendor",
                     value: NodeFormatter.usbVendorName(node.properties) ?? "—",
                     symbol: "building.2"),
                Stat(label: "Product",
                     value: NodeFormatter.usbProductName(node.properties) ?? "—",
                     symbol: "shippingbox"),
                Stat(label: "Capability",
                     value: usbCapabilityLabel(bcdUSB: bcdUSB),
                     symbol: "arrow.up.forward"),
                Stat(label: "Negotiated Speed",
                     value: usbSpeedLabel(speed),
                     symbol: "antenna.radiowaves.left.and.right"),
                Stat(label: "Device Class",
                     value: usbDeviceClassLabel(cls),
                     symbol: deviceClassSymbol(cls)),
                Stat(label: "VID : PID",
                     value: formatVidPid(vid: vid, pid: pid),
                     symbol: "barcode"),
                // `bcdDevice` is the device-specific firmware revision
                // string the kernel exposes alongside the USB protocol
                // version. Most peripherals publish it (USB spec
                // requires the field in the device descriptor); leaving
                // it in Developer details hides a useful identification
                // signal for triaging "is my firmware up to date?"
                Stat(label: "Firmware",
                     value: usbBcdVersion(node.properties["bcdDevice"]?.asUInt),
                     symbol: "memorychip"),
                Stat(label: "Power Output",
                     value: power.allocationLabel,
                     symbol: "bolt"),
                Stat(label: "Serial Number",
                     value: serial?.isEmpty == false ? serial! : "—",
                     symbol: "number",
                     isSecret: serial?.isEmpty == false)
            ])

            if speed != nil || bcdUSB != nil {
                USBLinkRateCard(currentSpeed: speed, bcdUSB: bcdUSB,
                                deviceClass: cls)
            }
            if power.hasData {
                USBSinkPowerCard(power: power)
            }
            if let tb = tbContext {
                TBLinkCard(label: "Reached through a Thunderbolt-tunneled USB bus.",
                           tbSwitchID: tb,
                           onNavigate: onNavigate)
            }
            // USB-Ethernet adapters publish their BSD interface several
            // levels below the IOUSBHostDevice. Surface a synthesized
            // ethernet card here so the user doesn't have to dig down to
            // the driver kext to see the MAC, link state, and link speed.
            let ethernet = findUSBEthernetAdapters(in: [node])
            if !ethernet.isEmpty {
                USBEthernetCard(adapters: ethernet, onNavigate: onNavigate)
            }
            InterfacesCard(device: node, onNavigate: onNavigate)
        }
    }

    private func deviceClassSymbol(_ raw: UInt64?) -> String {
        guard let raw, let cls = USBDeviceClass(rawValue: raw) else { return "cable.connector" }
        return cls.symbol
    }

    private func formatVidPid(vid: UInt64?, pid: UInt64?) -> String {
        guard let vid, let pid else { return "—" }
        return String(format: "0x%04X : 0x%04X", vid, pid)
    }
}

// MARK: - USB interface

struct USBInterfaceView: View {
    let node: TBNode

    var body: some View {
        let cls = node.properties["bInterfaceClass"]?.asUInt
        let sub = node.properties["bInterfaceSubClass"]?.asUInt
        let proto = node.properties["bInterfaceProtocol"]?.asUInt
        let num = node.properties["bInterfaceNumber"]?.asUInt
        let endpoints = node.properties["bNumEndpoints"]?.asUInt

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Interface #",
                     value: num.map(String.init) ?? "—",
                     symbol: "number"),
                Stat(label: "Class",
                     value: usbDeviceClassLabel(cls),
                     symbol: "puzzlepiece.extension"),
                Stat(label: "Subclass",
                     value: sub.map { String(format: "0x%02X", $0) } ?? "—",
                     symbol: "tag"),
                Stat(label: "Protocol",
                     value: proto.map { String(format: "0x%02X", $0) } ?? "—",
                     symbol: "shippingbox"),
                Stat(label: "Endpoints",
                     value: endpoints.map(String.init) ?? "—",
                     symbol: "arrow.left.arrow.right")
            ])
        }
    }
}

// MARK: - USB device power

/// Power-sourcing summary for a USB device, derived from the Apple-specific
/// IORegistry properties the kernel publishes on each `IOUSBHostDevice` when
/// the Mac is the USB-PD source on a USB-C receptacle.
///
/// * `UsbPowerSinkAllocation` — current (mA) the Mac has *granted* the sink.
/// * `UsbPowerSinkCapability` — peak (mA) the sink is willing to accept.
/// * `kUSBConfigurationCurrentOverride` — per-active-config override that
///   replaces the legacy `bMaxPower` field from the configuration descriptor.
/// * `Bus Current` / `Operating Bus Current (mA)` — legacy bus-current fields
///   present on USB-A / hub-attached devices (no PD negotiation).
struct USBDevicePower {
    let allocationMA: UInt64?
    let capabilityMA: UInt64?
    let configurationCurrentMA: UInt64?
    let legacyBusCurrentMA: UInt64?

    init(properties: [String: IORegValue]) {
        self.allocationMA = properties["UsbPowerSinkAllocation"]?.asUInt
        self.capabilityMA = properties["UsbPowerSinkCapability"]?.asUInt
        self.configurationCurrentMA = properties["kUSBConfigurationCurrentOverride"]?.asUInt
        self.legacyBusCurrentMA = properties["Bus Current"]?.asUInt
            ?? properties["Operating Bus Current (mA)"]?.asUInt
    }

    /// Best single-number "current the device is set up to draw" — used in
    /// the stat grid. Prefers the PD-negotiated allocation, falls back to
    /// the config override, then the legacy bus-current field, then the
    /// raw capability.
    var primaryCurrentMA: UInt64? {
        allocationMA ?? configurationCurrentMA ?? legacyBusCurrentMA ?? capabilityMA
    }

    /// Estimated wattage at the USB-C default voltage (5 V). When the Mac
    /// negotiates a higher PD voltage with the device the actual figure is
    /// higher, but that source-side info isn't exposed in IORegistry today,
    /// so the card always says "@ 5 V" to keep the number honest.
    var estimatedPowerW: Double? {
        guard let mA = primaryCurrentMA, mA > 0 else { return nil }
        return Double(mA) / 1000.0 * 5.0
    }

    var hasData: Bool {
        primaryCurrentMA != nil || capabilityMA != nil
    }

    var allocationLabel: String {
        guard let mA = primaryCurrentMA, mA > 0 else { return "—" }
        return "\(mA) mA"
    }
}

/// Power card on a USB device. Surfaces the Apple sink-allocation and
/// capability fields that drive USB-C charging on Apple Silicon, along with
/// an estimated wattage at 5 V.
struct USBSinkPowerCard: View {
    let power: USBDevicePower

    var body: some View {
        // Title is Mac-centric: from the host's POV this is power *output* —
        // the Mac sources current to this attached USB device. The card shows
        // the per-device sink-allocation properties published in IORegistry.
        SectionCard(title: "Power Output", symbol: "bolt.fill") {
            VStack(alignment: .leading, spacing: 10) {
                if let mA = power.primaryCurrentMA, mA > 0, let watts = power.estimatedPowerW {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(format: "%.1f W", watts))
                            .font(.system(size: 30, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.yellow)
                        Text("at 5 V · \(mA) mA")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    if let alloc = power.allocationMA {
                        GridRow {
                            Text("Negotiated allowance").foregroundStyle(.secondary)
                            Text("\(alloc) mA").monospacedDigit()
                        }
                    }
                    if let cap = power.capabilityMA {
                        GridRow {
                            Text("Peak Capability").foregroundStyle(.secondary)
                            Text("\(cap) mA").monospacedDigit()
                        }
                    }
                    if let cfg = power.configurationCurrentMA, cfg != power.allocationMA {
                        GridRow {
                            Text("Active config override").foregroundStyle(.secondary)
                            Text("\(cfg) mA").monospacedDigit()
                        }
                    }
                    if let bus = power.legacyBusCurrentMA, bus != power.allocationMA {
                        GridRow {
                            Text("Bus current (legacy)").foregroundStyle(.secondary)
                            Text("\(bus) mA").monospacedDigit()
                        }
                    }
                }
                .font(.callout)
            }
        }
    }
}

// MARK: - Shared building blocks

/// Visual indicator of the USB link rate for the negotiated speed.
struct USBLinkRateCard: View {
    let currentSpeed: UInt64?
    let bcdUSB: UInt64?
    let deviceClass: UInt64?

    private var negotiated: USBSpeed? {
        currentSpeed.flatMap { USBSpeed(rawValue: Int($0)) }
    }
    private var capability: USBSpeed? {
        usbCapabilityFromBCD(bcdUSB)
    }
    private var isDowngraded: Bool {
        guard let n = negotiated, let c = capability else { return false }
        return c.rateMbps > n.rateMbps
    }

    var body: some View {
        SectionCard(title: "Link Rate", symbol: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                headline
                rateBar
                legend
            }
            .padding(.vertical, 4)
        }
    }

    /// The negotiated line is the headline (it's what's happening right
    /// now); the device's declared capability sits next to it so the user
    /// can see the gap at a glance. Both labels use the long-form name
    /// ("USB 3.0 SuperSpeed") so the card reads even without the bar.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Negotiated").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let n = negotiated {
                    Text(n.shortLabel).font(.callout.weight(.medium))
                    Text(n.rateLabel)
                        .font(.callout.bold().monospaced())
                        .foregroundStyle(n.accentColor)
                } else {
                    Text("Unknown").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let c = capability {
                HStack {
                    Text("Capability").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("up to \(c.shortLabel)").font(.callout)
                        .foregroundStyle(.secondary)
                    Text(c.rateLabel).font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Single bar with two fills: the device's capability ceiling as a
    /// translucent backdrop, the negotiated rate on top in the speed's
    /// accent colour. When they match, only the accent fill is visible.
    /// Log-scaled so 12 Mb/s is still readable against 20 Gb/s.
    private var rateBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 14)
                if let c = capability {
                    Capsule()
                        .fill(c.accentColor.opacity(0.25))
                        .frame(width: geo.size.width * rateFraction(c), height: 14)
                }
                if let n = negotiated {
                    Capsule()
                        .fill(n.accentColor)
                        .frame(width: geo.size.width * rateFraction(n), height: 14)
                }
            }
        }
        .frame(height: 14)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(USBSpeed.allRates, id: \.label) { name, rate in
                HStack(spacing: 4) {
                    Circle()
                        .fill(legendColor(forRate: rate))
                        .frame(width: 6, height: 6)
                    Text(name).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legendColor(forRate rate: Double) -> Color {
        if let n = negotiated, rate == n.rateMbps { return n.accentColor }
        if let c = capability, rate == c.rateMbps { return c.accentColor.opacity(0.55) }
        return Color.secondary.opacity(0.3)
    }

    /// Logarithmic fraction so 1.5 Mb/s isn't invisible against 20 Gb/s.
    private func rateFraction(_ s: USBSpeed) -> Double {
        let log = log10(s.rateMbps + 1)
        let logMax = log10(USBSpeed.superPlusBy2.rateMbps + 1)
        return min(max(log / logMax, 0.04), 1.0)
    }
}

/// Human-readable label for the device's declared protocol capability,
/// used in the device/hub stat grid. Falls through to `"—"` so empty
/// `bcdUSB` doesn't poison the row.
nonisolated func usbCapabilityLabel(bcdUSB: UInt64?) -> String {
    guard let cap = usbCapabilityFromBCD(bcdUSB) else { return "—" }
    return "\(cap.shortLabel) · up to \(cap.rateLabel)"
}

private extension USBSpeed {
    static let allRates: [(label: String, rate: Double)] = [
        ("USB 2.0", 480),
        ("USB 3.0", 5_000),
        ("USB 3.1", 10_000),
        ("USB 3.2×2", 20_000)
    ]
}

/// Card that cross-links to a TB switch entry.
struct TBLinkCard: View {
    let label: String
    let tbSwitchID: TBNodeID
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        SectionCard(title: "Thunderbolt Context", symbol: "bolt.horizontal.circle") {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .foregroundStyle(.blue)
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onNavigate(tbSwitchID)
                } label: {
                    Label("Show in Thunderbolt", systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
            }
        }
    }
}

/// Section listing the immediate USB-device children below a hub/controller.
struct USBDeviceTreeCard: View {
    let root: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let kids = root.children.filter { $0.kind == .usbDevice || $0.kind == .usbHub }
        if !kids.isEmpty {
            SectionCard(title: "Attached USB Devices", symbol: "cable.connector") {
                VStack(spacing: 0) {
                    ForEach(kids, id: \.id) { kid in
                        USBDeviceRow(node: kid, onNavigate: onNavigate)
                        if kid.id != kids.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

struct USBDeviceRow: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let speed = node.properties["Device Speed"]?.asUInt
            ?? node.properties["kUSBCurrentSpeed"]?.asUInt
        let bcdUSB = node.properties["bcdUSB"]?.asUInt
        let cls = node.properties["bDeviceClass"]?.asUInt
        let symbol = USBDeviceClass(rawValue: cls ?? 0)?.symbol ?? "cable.connector"
        let downgraded = usbIsDowngraded(bcdUSB: bcdUSB, currentSpeed: speed)
        let capability = usbCapabilityFromBCD(bcdUSB)

        Button {
            onNavigate(node.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(node.kind.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title).lineLimit(1)
                    HStack(spacing: 6) {
                        if let s = speed, s > 0 {
                            Text(usbSpeedShortLabel(s))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        // Show the gap inline so the user doesn't have to
                        // open the device to spot a downgraded link. The
                        // pill uses a stable color (orange) since it's a
                        // diagnostic hint, not a property of the device's
                        // own speed class.
                        if downgraded, let cap = capability {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down.right")
                                    .font(.system(size: 9, weight: .bold))
                                Text("vs \(cap.shortLabel)")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        if let cls {
                            Text(usbDeviceClassLabel(cls))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if !node.children.filter({ $0.kind == .usbDevice || $0.kind == .usbHub }).isEmpty {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct InterfacesCard: View {
    let device: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let interfaces = device.children.filter { $0.kind == .usbInterface }
        if !interfaces.isEmpty {
            SectionCard(title: "USB Interfaces (\(interfaces.count))",
                        symbol: "puzzlepiece.extension") {
                VStack(spacing: 0) {
                    ForEach(interfaces, id: \.id) { iface in
                        Button { onNavigate(iface.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundStyle(.mint)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(iface.title).font(.callout).lineLimit(1)
                                    if let s = iface.subtitle {
                                        Text(s).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if iface.id != interfaces.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

/// Rich Ethernet card shown on the `USBDeviceView` for USB-Ethernet adapters.
/// Pulled out of the surrounding stat grid because BSD name / MAC / link
/// status / negotiated speed are the *operating state* of the adapter and
/// deserve a focused section instead of getting buried among VID / PID /
/// power numbers. Each adapter renders as a card row that navigates to the
/// IOEthernetInterface entry when clicked (matches the InterfacesCard
/// pattern), so the user can still drill down into raw IORegistry.
struct USBEthernetCard: View {
    let adapters: [USBEthernetAdapterInfo]
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        SectionCard(title: title, symbol: "network") {
            VStack(spacing: 0) {
                ForEach(adapters, id: \.interfaceID) { info in
                    AdapterDetailRow(info: info, onNavigate: onNavigate)
                    if info.interfaceID != adapters.last?.interfaceID { Divider() }
                }
            }
        }
    }

    private var title: String {
        adapters.count == 1 ? "Ethernet" : "Ethernet (\(adapters.count))"
    }

    private struct AdapterDetailRow: View {
        let info: USBEthernetAdapterInfo
        let onNavigate: (TBNodeID) -> Void

        var body: some View {
            Button { onNavigate(info.interfaceID) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: info.linkActive ? "network" : "network.slash")
                        .foregroundStyle(info.linkActive ? .green : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 6) {
                        // Headline: BSD name + link state, with negotiated
                        // speed as a chip on the right.
                        HStack(spacing: 8) {
                            Text(info.bsdName ?? "Network Interface")
                                .font(.callout.weight(.semibold).monospaced())
                            statusChip
                            if let mbps = info.linkSpeedMbps {
                                speedChip(mbps: mbps)
                            }
                        }
                        // Property grid: MAC, controller, source.
                        if !rows.isEmpty {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                                ForEach(rows, id: \.label) { row in
                                    GridRow {
                                        Text(row.label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .gridColumnAlignment(.leading)
                                        Text(row.value)
                                            .font(.caption.monospacedDigit())
                                            .textSelection(.enabled)
                                            .gridColumnAlignment(.leading)
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private var statusChip: some View {
            HStack(spacing: 4) {
                Circle()
                    .fill(info.linkActive ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(info.linkActive ? "Link Up" : "Link Down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(info.linkActive ? .green : .secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((info.linkActive ? Color.green : Color.secondary).opacity(0.12))
            .clipShape(Capsule())
        }

        private func speedChip(mbps: UInt64) -> some View {
            HStack(spacing: 4) {
                Image(systemName: "speedometer").font(.caption2)
                Text(ethernetSpeedLabel(mbps)).font(.caption.weight(.medium))
            }
            .foregroundStyle(.blue)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.blue.opacity(0.12))
            .clipShape(Capsule())
        }

        private struct Row { let label: String; let value: String }

        private var rows: [Row] {
            var out: [Row] = []
            if let mac = info.macAddress {
                out.append(Row(label: "MAC Address", value: mac.uppercased()))
            }
            if let speed = info.linkSpeedMbps {
                out.append(Row(label: "Negotiated Speed", value: ethernetSpeedLabel(speed)))
            }
            if let ctrl = info.controllerClassName, !ctrl.isEmpty {
                out.append(Row(label: "Driver", value: ctrl))
            }
            return out
        }
    }
}

private func countDevices(under node: TBNode) -> (devices: Int, hubs: Int) {
    var devices = 0, hubs = 0
    var stack = node.children
    while !stack.isEmpty {
        let n = stack.removeFirst()
        if n.kind == .usbDevice { devices += 1 }
        if n.kind == .usbHub { hubs += 1; devices += 1 }
        stack.append(contentsOf: n.children)
    }
    return (devices, hubs)
}
