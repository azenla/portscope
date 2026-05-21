//
//  InternalHardwareViews.swift
//  PortScope
//
//  Detail views for the Internal Hardware sidebar section: I²C / SPI buses,
//  on-bus slave devices, the AppleSmartBattery, and the MagSafe 3 receptacle.
//

import SwiftUI

// MARK: - Battery

struct BatteryView: View {
    let node: TBNode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            let current = node.properties["CurrentCapacity"]?.asUInt ?? 0
            let maxCap = node.properties["MaxCapacity"]?.asUInt ?? 100
            let isCharging = node.properties["IsCharging"]?.asBool ?? false
            let external = node.properties["ExternalConnected"]?.asBool ?? false
            let voltage = node.properties["Voltage"]?.asUInt
            let amperage = node.properties["Amperage"]?.asInt
            let temperatureCK = node.properties["Temperature"]?.asUInt
            let cycleCount = node.properties["CycleCount"]?.asUInt ?? 0
            let designCapacity = node.properties["DesignCapacity"]?.asUInt ?? 0
            let appleRawCapacity = node.properties["AppleRawCurrentCapacity"]?.asUInt ?? 0
            let appleRawMaxCapacity = node.properties["AppleRawMaxCapacity"]?.asUInt ?? 0
            let timeRemaining = node.properties["TimeRemaining"]?.asUInt
            let avgTimeToEmpty = node.properties["AvgTimeToEmpty"]?.asUInt
            let avgTimeToFull = node.properties["AvgTimeToFull"]?.asUInt
            let serial = node.properties["Serial"]?.asString
            let device = node.properties["DeviceName"]?.asString
            let installed = node.properties["BatteryInstalled"]?.asBool ?? false

            BatteryHero(percent: current,
                        maxPercent: maxCap,
                        isCharging: isCharging,
                        external: external)

            StatGrid(stats: [
                Stat(label: "Charge",
                     value: "\(current)% / \(maxCap)%",
                     symbol: "battery.100"),
                Stat(label: "Power Source",
                     value: external ? (isCharging ? "AC (charging)" : "AC (not charging)") : "Battery",
                     symbol: external ? "powerplug.fill" : "battery.50percent"),
                Stat(label: "Voltage",
                     value: voltage.map { String(format: "%.2f V", Double($0) / 1000.0) } ?? "—",
                     symbol: "bolt"),
                Stat(label: "Current Draw",
                     value: amperageLabel(amperage),
                     symbol: "waveform.path"),
                Stat(label: "Temperature",
                     value: temperatureLabel(temperatureCK),
                     symbol: "thermometer.medium"),
                Stat(label: "Cycle Count",
                     value: "\(cycleCount)",
                     symbol: "arrow.triangle.2.circlepath"),
                Stat(label: "Time to Empty",
                     value: minuteLabel(timeRemainingValue(timeRemaining, avg: avgTimeToEmpty)),
                     symbol: "hourglass.bottomhalf.filled"),
                Stat(label: "Time to Full",
                     value: minuteLabel(timeRemainingValue(nil, avg: avgTimeToFull)),
                     symbol: "hourglass.tophalf.filled"),
                Stat(label: "Design Capacity",
                     value: designCapacity > 0 ? "\(designCapacity) mAh" : "—",
                     symbol: "battery.100"),
                Stat(label: "Raw Capacity",
                     value: appleRawCapacity > 0 ? "\(appleRawCapacity) / \(appleRawMaxCapacity) mAh" : "—",
                     symbol: "gauge.with.dots.needle.67percent"),
                Stat(label: "Device",
                     value: device ?? "—",
                     symbol: "memorychip"),
                Stat(label: "Serial",
                     value: serial ?? "—",
                     symbol: "barcode",
                     isSecret: true)
            ])

            if !installed {
                SectionCard(title: "Battery not installed", symbol: "exclamationmark.triangle") {
                    Text("AppleSmartBatteryManager reports BatteryInstalled = No. The kernel can see the manager IC but no pack is present.")
                        .foregroundStyle(.secondary)
                }
            }

            // Health = MaxCapacity (%) reported by the gauge IC. Show a brief
            // explanation so users understand it's a percentage of design.
            SectionCard(title: "Health", symbol: "heart.text.square") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Battery Health Maximum")
                        Spacer()
                        Text("\(maxCap)%")
                            .monospaced()
                            .foregroundStyle(maxCap >= 80 ? .green : (maxCap >= 60 ? .orange : .red))
                    }
                    .font(.callout)
                    Text("MaxCapacity is the gauge IC's current best-available charge as a percentage of design (\(designCapacity) mAh). Apple's UI typically calls this \"Maximum Capacity\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func amperageLabel(_ raw: Int64?) -> String {
        guard let raw else { return "—" }
        // The gauge IC reports current in mA as a signed value, but IOKit may
        // surface it as an unsigned 64-bit number for negative readings (a
        // very large UInt64 → Int64 bit-pattern = small negative). Normalise.
        let mA = raw
        let absMA = abs(mA)
        let amps = Double(absMA) / 1000.0
        let sign = mA < 0 ? "−" : (mA > 0 ? "+" : "")
        return String(format: "%@%.2f A", sign, amps)
    }

    /// Battery temperature is reported in centi-Kelvin (3060 = 30.60 K above 0 °C).
    /// Wait — actually it's in 0.01 °C above 0, i.e. 3060 = 30.60 °C. Confirmed
    /// against macOS battery readings: 30 °C in a warm room matches 3060.
    private func temperatureLabel(_ raw: UInt64?) -> String {
        guard let raw, raw > 0 else { return "—" }
        let celsius = Double(raw) / 100.0
        let fahrenheit = celsius * 9.0 / 5.0 + 32.0
        return String(format: "%.1f °C  (%.0f °F)", celsius, fahrenheit)
    }

    /// Battery reports two minute counters: TimeRemaining (when discharging)
    /// and AvgTimeToEmpty / AvgTimeToFull. 65535 = invalid.
    private func timeRemainingValue(_ primary: UInt64?, avg: UInt64?) -> UInt64? {
        if let p = primary, p > 0, p < 65535 { return p }
        if let a = avg, a > 0, a < 65535 { return a }
        return nil
    }

    private func minuteLabel(_ minutes: UInt64?) -> String {
        guard let m = minutes else { return "—" }
        let h = m / 60
        let mm = m % 60
        if h == 0 { return "\(mm) min" }
        return "\(h)h \(mm)m"
    }
}

private struct BatteryHero: View {
    let percent: UInt64
    let maxPercent: UInt64
    let isCharging: Bool
    let external: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 84, height: 84)
                VStack(spacing: 0) {
                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(color)
                    }
                    Text("\(percent)%")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(statusText).font(.title3).bold()
                Text(maxText).foregroundStyle(.secondary).font(.callout)
                ProgressView(value: Double(percent) / Double(max(maxPercent, 1)))
                    .progressViewStyle(.linear)
                    .tint(color)
                    .frame(maxWidth: 320)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        if isCharging { return "Charging" }
        if external { return "Plugged In · Not Charging" }
        return "On Battery"
    }

    private var maxText: String {
        "Cap relative to design · \(maxPercent)% available"
    }

    private var color: Color {
        if isCharging { return .green }
        if percent <= 20 { return .red }
        if percent <= 40 { return .orange }
        return .green
    }
}

// MARK: - I²C / SPI bus

struct BusView: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let slaves = node.children
        VStack(alignment: .leading, spacing: 18) {
            StatGrid(stats: [
                Stat(label: "Bus", value: node.title, symbol: node.kind.sfSymbol),
                Stat(label: "Slaves", value: "\(slaves.count) device\(slaves.count == 1 ? "" : "s")",
                     symbol: "rectangle.connected.to.line.below"),
                Stat(label: "Controller",
                     value: extractControllerName() ?? "—",
                     symbol: "cpu"),
                Stat(label: "MMIO",
                     value: node.subtitle ?? "—",
                     symbol: "memorychip")
            ])

            SectionCard(title: "Attached Devices", symbol: "rectangle.grid.2x2") {
                if slaves.isEmpty {
                    Text("No slaves matched. The bus is wired but no driver currently attaches.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    VStack(spacing: 0) {
                        ForEach(slaves, id: \.id) { slave in
                            Button { onNavigate(slave.id) } label: {
                                SlaveRow(slave: slave)
                            }
                            .buttonStyle(.plain)
                            if slaves.last?.id != slave.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    /// Originally the controller wrapper was at `node.children[0]`. The
    /// scanner promoted its grandchildren up, but the bus's IORegistry
    /// `compatible` array still tells us which controller kext drives the
    /// bus. Falls back to the bus's own `compatible` first entry.
    private func extractControllerName() -> String? {
        if case let .array(arr) = node.properties["compatible"], let first = arr.first {
            if case let .string(s) = first { return s }
        }
        return nil
    }
}

private struct SlaveRow: View {
    let slave: TBNode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: slave.kind.sfSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(slave.title).font(.callout)
                if let s = slave.subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary)
                }
                if let driver = slave.children.first(where: { $0.kind == .other }) {
                    Text("Driver: \(driver.className)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Bus slave detail

struct BusSlaveView: View {
    let node: TBNode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatGrid(stats: [
                Stat(label: "Function", value: node.title, symbol: "tag"),
                Stat(label: "Bus Address", value: addressLabel, symbol: "number"),
                Stat(label: "Class", value: node.className, symbol: "doc.text"),
                Stat(label: "Driver",
                     value: driverClass ?? "—",
                     symbol: "puzzlepiece.extension")
            ])
        }
    }

    private var addressLabel: String {
        // Extract `@hex` suffix from the entry name, when present.
        let raw = node.properties["IOName"]?.asString
            ?? node.subtitle
            ?? ""
        if let range = raw.range(of: "0x", options: .caseInsensitive) {
            return String(raw[range.lowerBound...])
        }
        return "—"
    }

    private var driverClass: String? {
        node.children.first(where: { $0.kind == .other })?.className
    }
}

// MARK: - MagSafe

struct MagSafeView: View {
    let accessory: PortAccessoryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MagSafeHero(accessory: accessory)

            StatGrid(stats: [
                Stat(label: "Receptacle",
                     value: accessory.connector.label,
                     symbol: "powerplug.fill"),
                Stat(label: "Plug State",
                     value: plugStateLabel,
                     symbol: accessory.connectionActive ? "powerplug.fill" : "powerplug"),
                Stat(label: "Lifetime Plug Events",
                     value: "\(accessory.plugEventCount)",
                     symbol: "number"),
                Stat(label: "Overcurrent Events",
                     value: "\(accessory.overcurrentCount)",
                     symbol: "exclamationmark.triangle"),
                Stat(label: "Orientation",
                     value: accessory.plugOrientation.label,
                     symbol: accessory.plugOrientation.symbol),
                Stat(label: "Active Cable",
                     value: accessory.activeCable ? "Yes" : "No",
                     symbol: "cable.connector.video")
            ])

            // USB-PD profile, only meaningful when a charger is attached.
            if let pd = accessory.usbPD, accessory.connectionActive {
                SectionCard(title: "Power Input", symbol: "bolt.batteryblock") {
                    USBPDCard(profile: pd)
                }
            } else {
                SectionCard(title: "Power Input", symbol: "bolt.batteryblock") {
                    Text("Plug in a MagSafe charger to see negotiated wattage and the full PDO list. PortScope reads this live from the USB-PD subsystem.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Cable e-marker, when present.
            if accessory.cableLabel != nil || accessory.cableVendorID != nil {
                SectionCard(title: "Cable", symbol: "cable.coaxial") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let label = accessory.cableLabel {
                            Text(label).font(.callout).monospaced()
                        } else {
                            Text("No e-marker information").foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }
            }

            // Firmware version is published in the HPM controller's props.
            if let fw = magSafeFirmware {
                SectionCard(title: "HPM Controller", symbol: "memorychip") {
                    Text("Firmware: \(fw)").font(.callout).monospaced()
                }
            }
        }
    }

    private var plugStateLabel: String {
        if accessory.connectionActive { return "Connected" }
        if accessory.detected { return "Cable detected" }
        return "Empty"
    }

    /// `FW Version` is a 4-byte little-endian blob (e.g. `<00872000>` =
    /// 0x00208700 ≈ 2.08.7.0). We surface it as a dot-separated string.
    private var magSafeFirmware: String? {
        if case .data(let d) = accessory.registryProperties["FW Version"], d.count >= 4 {
            return "\(d[3]).\(d[2]).\(d[1]).\(d[0])"
        }
        return nil
    }
}

private struct MagSafeHero: View {
    let accessory: PortAccessoryInfo

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill((accessory.connectionActive ? Color.green : .secondary).opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(accessory.connectionActive ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("MagSafe 3 Port").font(.title2).bold()
                Text(subtitle).foregroundStyle(.secondary)
                if accessory.connectionActive, let win = accessory.usbPD?.winning {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").foregroundStyle(.green)
                        Text(win.powerLabel).font(.title3.bold().monospaced())
                            .foregroundStyle(.green)
                        Text("(\(win.voltageLabel) · \(win.currentLabel))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    private var subtitle: String {
        accessory.connectionActive
            ? "Charger attached"
            : "Idle — \(accessory.plugEventCount) plug event\(accessory.plugEventCount == 1 ? "" : "s") since boot"
    }
}

/// Compact PDO table reused across views. Highlights the winning PDO.
private struct USBPDCard: View {
    let profile: USBPDProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let win = profile.winning {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.yellow)
                    Text("Active Contract").font(.callout.bold())
                    Text(win.powerLabel).monospaced().foregroundStyle(.green)
                    Text("\(win.voltageLabel) · \(win.currentLabel)")
                        .foregroundStyle(.secondary)
                }
            }
            if !profile.offered.isEmpty {
                Divider()
                Text("Offered PDOs").font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("Voltage").foregroundStyle(.secondary).font(.caption)
                        Text("Current").foregroundStyle(.secondary).font(.caption)
                        Text("Power").foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(profile.offered) { pdo in
                        GridRow {
                            Text(pdo.voltageLabel).monospaced()
                            Text(pdo.currentLabel).monospaced()
                            Text(pdo.powerLabel).monospaced()
                        }
                    }
                }
                .font(.callout)
            }
            if let brick = profile.brickID {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                    Text("Apple Brick ID:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(brick.powerLabel).monospaced()
                }
            }
        }
    }
}
