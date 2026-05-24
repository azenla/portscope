//
//  BluetoothViews.swift
//  PortScope
//
//  Detail pages for the Bluetooth section. Controller card shows the HCI /
//  chipset summary; per-device cards expand each paired / connected device
//  with the metadata SPBluetoothDataType exposes (RSSI, batteries, etc.).
//

import SwiftUI

// MARK: - Controller

struct BluetoothControllerView: View {
    let controller: BluetoothController
    let snapshot: BluetoothSnapshot
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        DetailContainer { content }
    }

    @ViewBuilder
    private var content: some View {
        Hero(
            symbol: "dot.radiowaves.left.and.right",
            title: "Bluetooth",
            subtitle: controller.displayChipset,
            status: controller.isOn ? .active : .idle
        )

        PropertyList {
            PropertyRowSpec("Address", controller.address, mono: true)
            PropertyRowSpec("Chipset", controller.displayChipset)
            PropertyRowSpec("Firmware", controller.firmwareVersion, mono: true)
            PropertyRowSpec("Transport", controller.transport)
            PropertyRowSpec("Vendor ID", controller.vendorID, mono: true)
            PropertyRowSpec("Product ID", controller.productID, mono: true)
            PropertyRowSpec(forcing: "State", controller.isOn ? "On" : "Off")
            PropertyRowSpec(forcing: "Discoverable", controller.isDiscoverable ? "Yes" : "No")
        }

        if !controller.supportedServices.isEmpty {
            VStack(alignment: .leading, spacing: PSSpacing.s) {
                SectionHeader("Supported profiles")
                Text(controller.supportedServices.joined(separator: " · "))
                    .font(PSFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !snapshot.connected.isEmpty {
            BluetoothDeviceListSection(
                title: "Connected (\(snapshot.connected.count))",
                devices: snapshot.connected,
                onNavigate: onNavigate
            )
        }
        if !snapshot.paired.isEmpty {
            BluetoothDeviceListSection(
                title: "Paired (\(snapshot.paired.count))",
                devices: snapshot.paired,
                onNavigate: onNavigate
            )
        }
    }
}

private struct BluetoothDeviceListSection: View {
    let title: String
    let devices: [BluetoothDevice]
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader(title)
            VStack(spacing: 0) {
                ForEach(devices) { dev in
                    if dev.id != devices.first?.id {
                        Rectangle()
                            .fill(PSColor.divider.opacity(0.7))
                            .frame(height: 0.5)
                    }
                    Button {
                        onNavigate(BluetoothSelector.id(for: dev))
                    } label: {
                        BluetoothDeviceListRow(device: dev)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BluetoothDeviceListRow: View {
    let device: BluetoothDevice

    var body: some View {
        HStack(spacing: PSSpacing.s + 4) {
            Image(systemName: device.category.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(PSFont.body)
                if let s = subtitle, !s.isEmpty {
                    Text(s)
                        .font(PSFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if device.isConnected {
                StatusDot(status: .active)
            }
            Image(systemName: "chevron.right")
                .font(PSFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, PSSpacing.s)
        .contentShape(Rectangle())
    }

    private var subtitle: String? {
        var bits: [String] = []
        if let m = device.minorType, !m.isEmpty { bits.append(m) }
        if let addr = device.address { bits.append(addr) }
        if let rssi = device.rssi { bits.append("\(rssi) dBm") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}

// MARK: - Device detail

struct BluetoothDeviceView: View {
    let device: BluetoothDevice

    var body: some View {
        DetailContainer { content }
    }

    @ViewBuilder
    private var content: some View {
        Hero(
            symbol: device.category.symbol,
            title: device.name,
            subtitle: deviceSubtitle,
            status: device.isConnected ? .active : .idle
        )

        PropertyList {
            PropertyRowSpec("Address", device.address, mono: true)
            PropertyRowSpec("Type", device.minorType)
            PropertyRowSpec(forcing: "Connection",
                            device.isConnected ? "Connected" : "Paired")
            PropertyRowSpec("Vendor ID", device.vendorID, mono: true)
            PropertyRowSpec("Product ID", device.productID, mono: true)
            PropertyRowSpec("Firmware", device.firmwareVersion, mono: true)
            PropertyRowSpec("RSSI", device.rssi.map { "\($0) dBm" })
            PropertyRowSpec("Serial", device.serialNumber, mono: true, secret: true)
            PropertyRowSpec("Case firmware", device.caseVersion, mono: true)
        }

        let batteries = batteryRows()
        if !batteries.isEmpty {
            VStack(alignment: .leading, spacing: PSSpacing.m) {
                SectionHeader("Battery")
                VStack(alignment: .leading, spacing: PSSpacing.m) {
                    ForEach(batteries, id: \.label) { row in
                        if let pct = row.percent {
                            CapacityBar(
                                title: row.label,
                                value: pct * 100,
                                secondaryValue: nil,
                                capacity: 100,
                                headlineValue: row.value,
                                legend: nil,
                                tint: pct < 0.20 ? PSColor.error
                                    : (pct < 0.40 ? PSColor.warning : PSColor.active)
                            )
                        }
                    }
                }
            }
        }

        let services = device.services
        if !services.isEmpty {
            DisclosureCard("Advertised services (\(services.count))",
                           icon: "tray.full") {
                Text(services.joined(separator: " · "))
                    .font(PSFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deviceSubtitle: String? {
        var bits: [String] = []
        if let m = device.minorType { bits.append(m) }
        if let v = device.vendorID, let p = device.productID { bits.append("\(v) / \(p)") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private struct BatteryEntry { let label: String; let value: String; let percent: Double? }

    private func batteryRows() -> [BatteryEntry] {
        var rows: [BatteryEntry] = []
        if let level = device.batteryLevel {
            rows.append(BatteryEntry(label: "Device", value: level, percent: percent(of: level)))
        }
        if let left = device.batteryLevelLeft {
            rows.append(BatteryEntry(label: "Left earbud", value: left, percent: percent(of: left)))
        }
        if let right = device.batteryLevelRight {
            rows.append(BatteryEntry(label: "Right earbud", value: right, percent: percent(of: right)))
        }
        if let caseBat = device.batteryLevelCase {
            rows.append(BatteryEntry(label: "Case", value: caseBat, percent: percent(of: caseBat)))
        }
        return rows
    }

    private func percent(of raw: String) -> Double? {
        let digits = raw.filter { $0.isNumber }
        guard let n = Double(digits) else { return nil }
        return min(max(n / 100.0, 0), 1)
    }
}
