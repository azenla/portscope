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
        let busCurrent = node.properties["Bus Current"]?.asUInt
            ?? node.properties["Operating Bus Current (mA)"]?.asUInt
        let attached = countDevices(under: node)

        VStack(alignment: .leading, spacing: 16) {
            StatGrid(stats: [
                Stat(label: "Vendor",
                     value: NodeFormatter.usbVendorName(node.properties) ?? "—",
                     symbol: "building.2"),
                Stat(label: "Model",
                     value: NodeFormatter.usbProductName(node.properties) ?? "—",
                     symbol: "shippingbox"),
                Stat(label: "USB Spec",
                     value: usbBcdVersion(node.properties["bcdUSB"]?.asUInt),
                     symbol: "doc.text"),
                Stat(label: "Negotiated Speed",
                     value: usbSpeedLabel(speed),
                     symbol: "antenna.radiowaves.left.and.right"),
                Stat(label: "Downstream Ports",
                     value: portCount.map(String.init) ?? "—",
                     symbol: "rectangle.3.group"),
                Stat(label: "Attached Devices",
                     value: "\(attached.devices)",
                     symbol: "cable.connector"),
                Stat(label: "Bus Current",
                     value: busCurrent.map { "\($0) mA" } ?? "—",
                     symbol: "bolt"),
                Stat(label: "Built-In",
                     value: (node.properties["Built-In"]?.asBool ?? false) ? "Yes" : "No",
                     symbol: "macbook")
            ])

            if let speedVal = speed {
                USBLinkRateCard(speed: speedVal)
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
        let busCurrent = node.properties["Bus Current"]?.asUInt
            ?? node.properties["Operating Bus Current (mA)"]?.asUInt
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
                Stat(label: "USB Spec",
                     value: usbBcdVersion(bcdUSB),
                     symbol: "doc.text"),
                Stat(label: "Negotiated Speed",
                     value: usbSpeedLabel(speed),
                     symbol: "antenna.radiowaves.left.and.right"),
                Stat(label: "Device Class",
                     value: usbDeviceClassLabel(cls),
                     symbol: deviceClassSymbol(cls)),
                Stat(label: "VID : PID",
                     value: formatVidPid(vid: vid, pid: pid),
                     symbol: "barcode"),
                Stat(label: "Bus Current",
                     value: busCurrent.map { "\($0) mA" } ?? "—",
                     symbol: "bolt"),
                Stat(label: "Serial Number",
                     value: serial?.isEmpty == false ? serial! : "—",
                     symbol: "number",
                     isSecret: serial?.isEmpty == false)
            ])

            if let speedVal = speed {
                USBLinkRateCard(speed: speedVal)
            }
            if let tb = tbContext {
                TBLinkCard(label: "Reached through a Thunderbolt-tunneled USB bus.",
                           tbSwitchID: tb,
                           onNavigate: onNavigate)
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

// MARK: - Shared building blocks

/// Visual indicator of the USB link rate for the negotiated speed.
struct USBLinkRateCard: View {
    let speed: UInt64

    var body: some View {
        if let s = USBSpeed(rawValue: Int(speed)) {
            SectionCard(title: "Link Rate", symbol: "speedometer") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(s.shortLabel).font(.callout.weight(.medium))
                        Spacer()
                        Text(s.rateLabel).font(.callout.bold().monospaced())
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 14)
                            Capsule()
                                .fill(s.accentColor)
                                .frame(width: geo.size.width * rateFraction(s), height: 14)
                        }
                    }
                    .frame(height: 14)
                    HStack(spacing: 12) {
                        ForEach(USBSpeed.allRates, id: \.label) { name, rate in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(rate == s.rateMbps ? s.accentColor : Color.secondary.opacity(0.3))
                                    .frame(width: 6, height: 6)
                                Text(name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Logarithmic fraction so 1.5 Mb/s isn't invisible against 20 Gb/s.
    private func rateFraction(_ s: USBSpeed) -> Double {
        let log = log10(s.rateMbps + 1)
        let logMax = log10(USBSpeed.superPlusBy2.rateMbps + 1)
        return min(max(log / logMax, 0.04), 1.0)
    }
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
        let cls = node.properties["bDeviceClass"]?.asUInt
        let symbol = USBDeviceClass(rawValue: cls ?? 0)?.symbol ?? "cable.connector"

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
