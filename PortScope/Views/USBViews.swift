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

        PropertyList {
            PropertyRowSpec("Hardware", chip)
            PropertyRowSpec("USB spec", protoLabel.map { "xHCI \($0)" })
            PropertyRowSpec("Downstream ports", portCount.map(String.init))
            PropertyRowSpec("Attached devices",
                            attached.devices > 0 ? "\(attached.devices)" : nil)
            PropertyRowSpec("PCI vendor / device", vidPidLabel(vid: pciVendor, pid: pciDevice), mono: true)
            PropertyRowSpec(forcing: "Sleep capable",
                            (node.properties["kUSBSleepSupported"]?.asBool ?? false) ? "Yes" : "No")
        }

        if let tb = tbContext {
            TBContextSection(text: "This USB host controller is tunneled over Thunderbolt.",
                             tbSwitchID: tb,
                             onNavigate: onNavigate)
        }
        USBChildrenSection(root: node, onNavigate: onNavigate)
    }

    private func chipFamily(from node: TBNode) -> String? {
        let nameMatch = node.properties["IONameMatch"]?.asString
            ?? node.properties["IONameMatched"]?.asString
            ?? ""
        guard !nameMatch.isEmpty else { return nil }
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
        if let comma = nameMatch.firstIndex(of: ",") {
            let silicon = String(nameMatch[nameMatch.index(after: comma)...]).uppercased()
            if !silicon.isEmpty { return "\(kind) (\(silicon))" }
        }
        return kind == "USB" ? "USB controller" : kind
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
        let power = USBDevicePower(properties: node.properties)
        let attached = countDevices(under: node)

        PropertyList {
            PropertyRowSpec("Vendor", NodeFormatter.usbVendorName(node.properties))
            PropertyRowSpec("Model", NodeFormatter.usbProductName(node.properties))
            PropertyRowSpec("USB spec", usbBcdVersion(node.properties["bcdUSB"]?.asUInt))
            PropertyRowSpec("Negotiated speed", usbSpeedLabel(speed))
            PropertyRowSpec("Downstream ports", portCount.map(String.init))
            PropertyRowSpec("Attached devices",
                            attached.devices > 0 ? "\(attached.devices)" : nil)
            PropertyRowSpec("Power output", power.allocationLabel.isNilOrEmpty ? nil : power.allocationLabel)
            PropertyRowSpec(forcing: "Built-in",
                            (node.properties["Built-In"]?.asBool ?? false) ? "Yes" : "No")
        }

        if power.hasData {
            USBSinkPowerSection(power: power)
        }
        if let tb = tbContext {
            TBContextSection(text: "Reached through a Thunderbolt-tunneled USB controller.",
                             tbSwitchID: tb,
                             onNavigate: onNavigate)
        }
        USBChildrenSection(root: node, onNavigate: onNavigate)
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

        PropertyList {
            PropertyRowSpec("Vendor", NodeFormatter.usbVendorName(node.properties))
            PropertyRowSpec("Product", NodeFormatter.usbProductName(node.properties))
            PropertyRowSpec("USB spec", usbBcdVersion(bcdUSB))
            PropertyRowSpec("Negotiated speed", usbSpeedLabel(speed))
            PropertyRowSpec("Device class", usbDeviceClassLabel(cls))
            PropertyRowSpec("VID : PID", formatVidPid(vid: vid, pid: pid), mono: true)
            PropertyRowSpec("Serial",
                            serial?.isEmpty == false ? serial : nil,
                            mono: true,
                            secret: true)
        }

        if power.hasData {
            USBSinkPowerSection(power: power)
        }
        if let tb = tbContext {
            TBContextSection(text: "Reached through a Thunderbolt-tunneled USB bus.",
                             tbSwitchID: tb,
                             onNavigate: onNavigate)
        }
        let ethernet = findUSBEthernetAdapters(in: [node])
        if !ethernet.isEmpty {
            USBEthernetSection(adapters: ethernet, onNavigate: onNavigate)
        }
        InterfacesSection(device: node, onNavigate: onNavigate)
    }

    private func formatVidPid(vid: UInt64?, pid: UInt64?) -> String? {
        guard let vid, let pid else { return nil }
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

        PropertyList {
            PropertyRowSpec("Interface #", num.map(String.init))
            PropertyRowSpec("Class", usbDeviceClassLabel(cls))
            PropertyRowSpec("Subclass",
                            sub.map { String(format: "0x%02X", $0) },
                            mono: true)
            PropertyRowSpec("Protocol",
                            proto.map { String(format: "0x%02X", $0) },
                            mono: true)
            PropertyRowSpec("Endpoints", endpoints.map(String.init))
        }
    }
}

// MARK: - USBDevicePower

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

    var primaryCurrentMA: UInt64? {
        allocationMA ?? configurationCurrentMA ?? legacyBusCurrentMA ?? capabilityMA
    }

    var estimatedPowerW: Double? {
        guard let mA = primaryCurrentMA, mA > 0 else { return nil }
        return Double(mA) / 1000.0 * 5.0
    }

    var hasData: Bool {
        primaryCurrentMA != nil || capabilityMA != nil
    }

    var allocationLabel: String? {
        guard let mA = primaryCurrentMA, mA > 0 else { return nil }
        return "\(mA) mA"
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        guard let s = self else { return true }
        return s.isEmpty
    }
}

/// Power section for a USB device. Highlights the Apple sink-allocation
/// numbers that drive USB-C charging on Apple Silicon, plus the estimated
/// wattage at 5 V.
struct USBSinkPowerSection: View {
    let power: USBDevicePower

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Power output (Mac sourcing this device)")
            if let mA = power.primaryCurrentMA, mA > 0, let watts = power.estimatedPowerW {
                CapacityBar(
                    title: nil,
                    value: watts,
                    secondaryValue: nil,
                    capacity: max(15, watts),
                    headlineValue: String(format: "%.1f W at 5 V · %d mA", watts, mA),
                    legend: "Apple Silicon doesn't publish source-side PD profiles. A PD-fast-charge device may pull more than shown.",
                    tint: PSColor.powerOut
                )
            }
            PropertyList {
                PropertyRowSpec("Negotiated allowance",
                                power.allocationMA.map { "\($0) mA" })
                PropertyRowSpec("Peak capability",
                                power.capabilityMA.map { "\($0) mA" })
                PropertyRowSpec("Active config override",
                                power.configurationCurrentMA.map { "\($0) mA" })
                PropertyRowSpec("Bus current (legacy)",
                                power.legacyBusCurrentMA.map { "\($0) mA" })
            }
        }
    }
}

// MARK: - Cross-link to TB context

struct TBContextSection: View {
    let text: String
    let tbSwitchID: TBNodeID
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.s) {
            SectionHeader("Thunderbolt context")
            HStack(spacing: PSSpacing.s) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text(text).font(PSFont.body).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onNavigate(tbSwitchID)
                } label: {
                    Label("Show in Thunderbolt", systemImage: "arrow.up.right.square")
                        .font(PSFont.body)
                }
            }
        }
    }
}

// MARK: - Attached devices

struct USBChildrenSection: View {
    let root: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let kids = root.children.filter { $0.kind == .usbDevice || $0.kind == .usbHub }
        if !kids.isEmpty {
            VStack(alignment: .leading, spacing: PSSpacing.m) {
                SectionHeader("Attached USB devices")
                VStack(spacing: 0) {
                    ForEach(kids, id: \.id) { kid in
                        if kid.id != kids.first?.id {
                            Rectangle()
                                .fill(PSColor.divider.opacity(0.7))
                                .frame(height: 0.5)
                        }
                        USBDeviceRow(node: kid, onNavigate: onNavigate)
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
        let hasChildren = !node.children.filter({ $0.kind == .usbDevice || $0.kind == .usbHub }).isEmpty

        Button {
            onNavigate(node.id)
        } label: {
            HStack(spacing: PSSpacing.s + 4) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(PSFont.body).lineLimit(1)
                    HStack(spacing: 6) {
                        if let s = speed, s > 0 {
                            Text(usbSpeedShortLabel(s))
                                .font(PSFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let cls {
                            Text(usbDeviceClassLabel(cls))
                                .font(PSFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if hasChildren {
                    Image(systemName: "chevron.right")
                        .font(PSFont.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, PSSpacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct InterfacesSection: View {
    let device: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let interfaces = device.children.filter { $0.kind == .usbInterface }
        if !interfaces.isEmpty {
            VStack(alignment: .leading, spacing: PSSpacing.m) {
                SectionHeader("USB interfaces (\(interfaces.count))")
                VStack(spacing: 0) {
                    ForEach(interfaces, id: \.id) { iface in
                        if iface.id != interfaces.first?.id {
                            Rectangle()
                                .fill(PSColor.divider.opacity(0.7))
                                .frame(height: 0.5)
                        }
                        Button { onNavigate(iface.id) } label: {
                            HStack(spacing: PSSpacing.s + 4) {
                                Image(systemName: "puzzlepiece.extension")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(iface.title).font(PSFont.body).lineLimit(1)
                                    if let s = iface.subtitle {
                                        Text(s).font(PSFont.caption).foregroundStyle(.secondary)
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
            }
        }
    }
}

// MARK: - USB-Ethernet adapter

struct USBEthernetSection: View {
    let adapters: [USBEthernetAdapterInfo]
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader(adapters.count == 1 ? "Ethernet" : "Ethernet (\(adapters.count))")
            VStack(spacing: 0) {
                ForEach(adapters, id: \.interfaceID) { info in
                    if info.interfaceID != adapters.first?.interfaceID {
                        Rectangle()
                            .fill(PSColor.divider.opacity(0.7))
                            .frame(height: 0.5)
                    }
                    USBEthernetRow(info: info, onNavigate: onNavigate)
                }
            }
        }
    }
}

private struct USBEthernetRow: View {
    let info: USBEthernetAdapterInfo
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        Button { onNavigate(info.interfaceID) } label: {
            HStack(alignment: .top, spacing: PSSpacing.s + 4) {
                Image(systemName: "network")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: PSSpacing.s) {
                        Text(info.bsdName ?? "Network interface")
                            .font(PSFont.bodyEmph.monospaced())
                        if info.linkActive {
                            StatusPill(status: .active)
                        } else {
                            StatusPill(status: .idle)
                        }
                        if let mbps = info.linkSpeedMbps {
                            Chip(label: ethernetSpeedLabel(mbps),
                                 symbol: "speedometer",
                                 tint: PSColor.powerOut,
                                 emphasized: true,
                                 monospaced: true)
                        }
                    }
                    if !rows.isEmpty {
                        PropertyList {
                            for r in rows {
                                PropertyRowSpec(r.label, r.value, mono: r.mono)
                            }
                        }
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

    private struct Row { let label: String; let value: String; let mono: Bool }

    private var rows: [Row] {
        var out: [Row] = []
        if let mac = info.macAddress {
            out.append(Row(label: "MAC address", value: mac.uppercased(), mono: true))
        }
        if let speed = info.linkSpeedMbps {
            out.append(Row(label: "Negotiated speed", value: ethernetSpeedLabel(speed), mono: false))
        }
        if let ctrl = info.controllerClassName, !ctrl.isEmpty {
            out.append(Row(label: "Driver", value: ctrl, mono: true))
        }
        return out
    }
}

// MARK: - Helpers

private func vidPidLabel(vid: UInt64?, pid: UInt64?) -> String? {
    guard let v = vid, let p = pid else { return nil }
    return String(format: "0x%04X : 0x%04X", v, p)
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
