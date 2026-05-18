//
//  BluetoothViews.swift
//  PortScope
//
//  Detail cards for the Bluetooth section. The controller card shows the
//  HCI / chipset summary; per-device cards expand each paired or connected
//  device with the metadata that SPBluetoothDataType exposes (RSSI, battery
//  levels, firmware version, etc.).
//

import SwiftUI

// MARK: - Controller

struct BluetoothControllerView: View {
    let controller: BluetoothController
    let snapshot: BluetoothSnapshot
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BluetoothHero(controller: controller, snapshot: snapshot)

            StatGrid(stats: [
                Stat(label: "Address",
                     value: controller.address ?? "—",
                     symbol: "barcode"),
                Stat(label: "Chipset",
                     value: controller.displayChipset,
                     symbol: "memorychip"),
                Stat(label: "Firmware",
                     value: controller.firmwareVersion ?? "—",
                     symbol: "tag"),
                Stat(label: "Transport",
                     value: controller.transport ?? "—",
                     symbol: "cable.connector"),
                Stat(label: "Vendor ID",
                     value: controller.vendorID ?? "—",
                     symbol: "number"),
                Stat(label: "Product ID",
                     value: controller.productID ?? "—",
                     symbol: "number"),
                Stat(label: "State",
                     value: controller.isOn ? "On" : "Off",
                     symbol: controller.isOn ? "checkmark.circle.fill" : "circle.slash"),
                Stat(label: "Discoverable",
                     value: controller.isDiscoverable ? "Yes" : "No",
                     symbol: "eye")
            ])

            let services = controller.supportedServices
            if !services.isEmpty {
                SectionCard(title: "Supported Profiles", symbol: "tray.full") {
                    FlowChips {
                        ForEach(services, id: \.self) { svc in
                            Text(svc)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.purple.opacity(0.12))
                                .foregroundStyle(.purple)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if !snapshot.connected.isEmpty {
                SectionCard(title: "Connected (\(snapshot.connected.count))", symbol: "link") {
                    deviceList(snapshot.connected)
                }
            }
            if !snapshot.paired.isEmpty {
                SectionCard(title: "Paired (\(snapshot.paired.count))", symbol: "person.crop.circle.badge.checkmark") {
                    deviceList(snapshot.paired)
                }
            }
        }
    }

    @ViewBuilder
    private func deviceList(_ devices: [BluetoothDevice]) -> some View {
        VStack(spacing: 0) {
            ForEach(devices) { dev in
                Button {
                    onNavigate(BluetoothSelector.id(for: dev))
                } label: {
                    DeviceListRow(device: dev)
                }
                .buttonStyle(.plain)
                if devices.last?.id != dev.id { Divider() }
            }
        }
    }
}

private struct BluetoothHero: View {
    let controller: BluetoothController
    let snapshot: BluetoothSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill((controller.isOn ? Color.blue : .secondary).opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(controller.isOn ? .blue : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Bluetooth").font(.title2).bold()
                Text(controller.displayChipset)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label("\(snapshot.connected.count) connected", systemImage: "link")
                    Label("\(snapshot.paired.count) paired", systemImage: "person.crop.circle.badge.checkmark")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct DeviceListRow: View {
    let device: BluetoothDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.category.symbol)
                .foregroundStyle(device.category.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.callout)
                    if device.isConnected {
                        Text("connected")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                if let sub = subtitleParts.first.map({ _ in subtitleParts.joined(separator: " · ") }) {
                    Text(sub).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var subtitleParts: [String] {
        var bits: [String] = []
        if let m = device.minorType, !m.isEmpty { bits.append(m) }
        if let addr = device.address { bits.append(addr) }
        if let rssi = device.rssi { bits.append("\(rssi) dBm") }
        return bits
    }
}

// MARK: - Device detail

struct BluetoothDeviceView: View {
    let device: BluetoothDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BluetoothDeviceHero(device: device)

            StatGrid(stats: statRows())

            // Battery levels — AirPods/Beats etc.
            let batteries = batteryRows()
            if !batteries.isEmpty {
                SectionCard(title: "Battery", symbol: "battery.100") {
                    VStack(spacing: 0) {
                        ForEach(batteries, id: \.label) { row in
                            BatteryRow(label: row.label, value: row.value, percent: row.percent)
                            if batteries.last?.label != row.label { Divider() }
                        }
                    }
                }
            }

            let services = device.services
            if !services.isEmpty {
                SectionCard(title: "Advertised Services", symbol: "tray.full") {
                    FlowChips {
                        ForEach(services, id: \.self) { svc in
                            Text(svc)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(device.category.color.opacity(0.12))
                                .foregroundStyle(device.category.color)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    private func statRows() -> [Stat] {
        var stats: [Stat] = [
            Stat(label: "Address",
                 value: device.address ?? "—",
                 symbol: "barcode"),
            Stat(label: "Type",
                 value: device.minorType ?? "—",
                 symbol: device.category.symbol),
            Stat(label: "Connection",
                 value: device.isConnected ? "Connected" : "Paired",
                 symbol: device.isConnected ? "link" : "person.crop.circle.badge.checkmark"),
            Stat(label: "Vendor ID",
                 value: device.vendorID ?? "—",
                 symbol: "number"),
            Stat(label: "Product ID",
                 value: device.productID ?? "—",
                 symbol: "number"),
            Stat(label: "Firmware",
                 value: device.firmwareVersion ?? "—",
                 symbol: "tag")
        ]
        if let rssi = device.rssi {
            stats.append(Stat(label: "RSSI",
                              value: "\(rssi) dBm",
                              symbol: "wave.3.left.circle"))
        }
        if let serial = device.serialNumber {
            stats.append(Stat(label: "Serial",
                              value: serial,
                              symbol: "barcode.viewfinder",
                              isSecret: true))
        }
        if let caseVersion = device.caseVersion {
            stats.append(Stat(label: "Case FW",
                              value: caseVersion,
                              symbol: "shippingbox"))
        }
        return stats
    }

    private struct BatteryEntry { let label: String; let value: String; let percent: Double? }

    private func batteryRows() -> [BatteryEntry] {
        var rows: [BatteryEntry] = []
        if let level = device.batteryLevel {
            rows.append(BatteryEntry(label: "Device", value: level, percent: percent(of: level)))
        }
        if let left = device.batteryLevelLeft {
            rows.append(BatteryEntry(label: "Left", value: left, percent: percent(of: left)))
        }
        if let right = device.batteryLevelRight {
            rows.append(BatteryEntry(label: "Right", value: right, percent: percent(of: right)))
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

private struct BluetoothDeviceHero: View {
    let device: BluetoothDevice

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(device.category.color.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: device.category.symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(device.category.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.title2).bold().textSelection(.enabled)
                Text(subtitle).foregroundStyle(.secondary)
                if device.isConnected {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Connected").font(.caption.weight(.medium)).foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            Spacer()
        }
    }

    private var subtitle: String {
        var bits: [String] = []
        if let m = device.minorType { bits.append(m) }
        if let v = device.vendorID, let p = device.productID { bits.append("\(v) / \(p)") }
        return bits.joined(separator: " · ")
    }
}

private struct BatteryRow: View {
    let label: String
    let value: String
    let percent: Double?

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .frame(width: 80, alignment: .leading)
            if let percent {
                ProgressView(value: percent)
                    .progressViewStyle(.linear)
                    .tint(percent < 0.20 ? .red : (percent < 0.40 ? .orange : .green))
                    .frame(maxWidth: 240)
            }
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
    }
}
