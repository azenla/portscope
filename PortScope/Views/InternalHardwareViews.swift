//
//  InternalHardwareViews.swift
//  PortScope
//
//  Detail views for the Internal Hardware sidebar section: the
//  AppleSmartBattery, I²C / SPI buses, on-bus slave devices, and the
//  MagSafe 3 receptacle.
//

import SwiftUI

// MARK: - Battery

struct BatteryView: View {
    let node: TBNode

    var body: some View {
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

        Hero(symbol: heroSymbol(percent: current, charging: isCharging),
             title: node.title,
             subtitle: heroSubtitle(percent: current, charging: isCharging, external: external),
             status: heroStatus(charging: isCharging, external: external))

        CapacityBar(
            title: "Charge",
            value: Double(current),
            secondaryValue: nil,
            capacity: 100,
            headlineValue: "\(current) %",
            legend: maxCap < 100 ? "Health max: \(maxCap) %" : nil,
            tint: chargeTint(percent: current, charging: isCharging)
        )

        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Live")
            PropertyList {
                PropertyRowSpec("Voltage",
                                voltage.map { String(format: "%.2f V", Double($0) / 1000.0) })
                PropertyRowSpec("Current", amperageLabel(amperage))
                PropertyRowSpec("Temperature", temperatureLabel(temperatureCK))
                PropertyRowSpec("Time to empty",
                                minuteLabel(timeRemainingValue(timeRemaining, avg: avgTimeToEmpty)))
                PropertyRowSpec("Time to full",
                                minuteLabel(timeRemainingValue(nil, avg: avgTimeToFull)))
            }
        }

        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Health & capacity")
            PropertyList {
                PropertyRowSpec("Cycle count", cycleCount > 0 ? "\(cycleCount)" : nil)
                PropertyRowSpec("Health maximum",
                                "\(maxCap) %",
                                valueColor: maxCap >= 80 ? PSColor.active
                                          : (maxCap >= 60 ? PSColor.warning : PSColor.error))
                PropertyRowSpec("Design capacity",
                                designCapacity > 0 ? "\(designCapacity) mAh" : nil)
                PropertyRowSpec("Raw capacity",
                                appleRawCapacity > 0
                                    ? "\(appleRawCapacity) / \(appleRawMaxCapacity) mAh"
                                    : nil)
                PropertyRowSpec("Device", device)
                PropertyRowSpec("Serial", serial, mono: true, secret: true)
            }
        }

        if !installed {
            EmptyStateNote(
                text: "AppleSmartBatteryManager reports BatteryInstalled = No. The kernel can see the manager IC but no pack is present."
            )
        }
    }

    private func heroSymbol(percent: UInt64, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        if percent >= 75 { return "battery.100" }
        if percent >= 50 { return "battery.75percent" }
        if percent >= 25 { return "battery.50percent" }
        if percent > 0 { return "battery.25percent" }
        return "battery.0percent"
    }

    private func heroSubtitle(percent: UInt64, charging: Bool, external: Bool) -> String {
        if charging { return "Charging" }
        if external { return "On AC · not charging" }
        return "On battery"
    }

    private func heroStatus(charging: Bool, external: Bool) -> PSStatus? {
        if charging { return .powerIn("Charging") }
        if external { return .builtIn }
        return .active
    }

    private func chargeTint(percent: UInt64, charging: Bool) -> Color {
        if charging { return PSColor.active }
        if percent <= 20 { return PSColor.error }
        if percent <= 40 { return PSColor.warning }
        return PSColor.active
    }

    private func amperageLabel(_ raw: Int64?) -> String? {
        guard let raw, raw != 0 else { return nil }
        let mA = raw
        let absMA = abs(mA)
        let amps = Double(absMA) / 1000.0
        let sign = mA < 0 ? "−" : "+"
        let direction = mA < 0 ? "draw" : "charge"
        return String(format: "%@%.2f A · %@", sign, amps, direction)
    }

    /// `Temperature` is centi-degrees Celsius (3060 = 30.60 °C).
    private func temperatureLabel(_ raw: UInt64?) -> String? {
        guard let raw, raw > 0 else { return nil }
        let celsius = Double(raw) / 100.0
        return String(format: "%.1f °C", celsius)
    }

    private func timeRemainingValue(_ primary: UInt64?, avg: UInt64?) -> UInt64? {
        if let p = primary, p > 0, p < 65535 { return p }
        if let a = avg, a > 0, a < 65535 { return a }
        return nil
    }

    private func minuteLabel(_ minutes: UInt64?) -> String? {
        guard let m = minutes else { return nil }
        let h = m / 60
        let mm = m % 60
        if h == 0 { return "\(mm) min" }
        return "\(h)h \(mm)m"
    }
}

// MARK: - I²C / SPI bus

struct BusView: View {
    let node: TBNode
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        let slaves = node.children

        PropertyList {
            PropertyRowSpec("Bus", node.title)
            PropertyRowSpec("Slaves",
                            "\(slaves.count) device\(slaves.count == 1 ? "" : "s")")
            PropertyRowSpec("Controller", extractControllerName())
            PropertyRowSpec("MMIO", node.subtitle, mono: true)
        }

        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Attached devices")
            if slaves.isEmpty {
                EmptyStateNote(text: "No slaves matched. The bus is wired but no driver currently attaches.")
            } else {
                VStack(spacing: 0) {
                    ForEach(slaves, id: \.id) { slave in
                        if slave.id != slaves.first?.id {
                            Rectangle()
                                .fill(PSColor.divider.opacity(0.7))
                                .frame(height: 0.5)
                        }
                        Button { onNavigate(slave.id) } label: {
                            SlaveRow(slave: slave)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

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
        HStack(spacing: PSSpacing.s + 4) {
            Image(systemName: slave.kind.sfSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(slave.title).font(PSFont.body)
                if let s = slave.subtitle, !s.isEmpty {
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
}

// MARK: - Bus slave detail

struct BusSlaveView: View {
    let node: TBNode

    var body: some View {
        PropertyList {
            PropertyRowSpec("Function", node.title)
            PropertyRowSpec("Bus address", addressLabel, mono: true)
            PropertyRowSpec("Class", node.className, mono: true)
            PropertyRowSpec("Driver", driverClass, mono: true)
        }
    }

    private var addressLabel: String? {
        let raw = node.properties["IOName"]?.asString
            ?? node.subtitle
            ?? ""
        if let range = raw.range(of: "0x", options: .caseInsensitive) {
            return String(raw[range.lowerBound...])
        }
        return nil
    }

    private var driverClass: String? {
        node.children.first(where: { $0.kind == .other })?.className
    }
}

// MARK: - MagSafe

struct MagSafeView: View {
    let accessory: PortAccessoryInfo

    var body: some View {
        DetailContainer {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        Hero(
            symbol: "powerplug",
            title: "MagSafe 3 Port",
            subtitle: heroSubtitle,
            status: heroStatus
        )

        PropertyList {
            PropertyRowSpec("Receptacle", accessory.connector.label)
            PropertyRowSpec("Plug state", plugStateLabel)
            PropertyRowSpec("Lifetime plug events",
                            accessory.plugEventCount > 0 ? "\(accessory.plugEventCount)" : nil)
            PropertyRowSpec("Overcurrent events",
                            accessory.overcurrentCount > 0
                                ? "\(accessory.overcurrentCount)"
                                : nil,
                            valueColor: accessory.overcurrentCount > 0 ? PSColor.error : nil)
            PropertyRowSpec("Plug orientation", accessory.plugOrientation.label)
            PropertyRowSpec(forcing: "Cable",
                            accessory.activeCable
                                ? "Active (powered e-marker)"
                                : (accessory.opticalCable ? "Optical" : "Passive"))
        }

        if let pd = accessory.usbPD, accessory.connectionActive {
            VStack(alignment: .leading, spacing: PSSpacing.m) {
                SectionHeader("Power input")
                if let win = pd.winning {
                    PropertyList {
                        PropertyRowSpec(forcing: "Power", win.powerLabel,
                                        valueColor: PSColor.powerIn)
                        PropertyRowSpec(forcing: "Voltage", win.voltageLabel)
                        PropertyRowSpec(forcing: "Current", win.currentLabel)
                    }
                }
                if !pd.offered.isEmpty {
                    DisclosureCard("Offered PDOs", icon: "list.bullet.rectangle") {
                        PDOTableView(profile: pd)
                    }
                }
            }
        }

        if accessory.cableLabel != nil {
            PropertyList {
                PropertyRowSpec("Cable e-marker", accessory.cableLabel, mono: true)
            }
        }

        if let fw = magSafeFirmware {
            PropertyList {
                PropertyRowSpec("HPM firmware", fw, mono: true)
            }
        }
    }

    private var heroSubtitle: String? {
        if accessory.connectionActive {
            if let win = accessory.usbPD?.winning {
                return "Charger attached · \(win.powerLabel)"
            }
            return "Charger attached"
        }
        return "Idle"
    }

    private var heroStatus: PSStatus? {
        if accessory.connectionActive {
            if let win = accessory.usbPD?.winning, win.maxPowerMW > 0 {
                return .powerIn(win.powerLabel)
            }
            return .active
        }
        return .empty
    }

    private var plugStateLabel: String {
        if accessory.connectionActive { return "Connected" }
        if accessory.detected { return "Cable detected" }
        return "Empty"
    }

    /// `FW Version` is a 4-byte little-endian blob (e.g. `<00872000>` =
    /// 0x00208700 ≈ 2.08.7.0).
    private var magSafeFirmware: String? {
        if case .data(let d) = accessory.registryProperties["FW Version"], d.count >= 4 {
            return "\(d[3]).\(d[2]).\(d[1]).\(d[0])"
        }
        return nil
    }
}

/// PDO list rendered as a Table. Reused by MagSafe and the physical-port
/// detail view's Power Input card.
struct PDOTableView: View {
    let profile: USBPDProfile

    private struct Row: Identifiable {
        let id: UUID
        let winning: Bool
        let voltage: String
        let current: String
        let power: String
    }

    var body: some View {
        Table(of: Row.self) {
            TableColumn("") { row in
                Image(systemName: row.winning ? "checkmark.seal.fill" : "circle")
                    .foregroundStyle(row.winning ? PSColor.powerIn : Color(NSColor.tertiaryLabelColor))
                    .font(.system(size: 11))
            }
            .width(20)
            TableColumn("Voltage") { Text($0.voltage).monospacedDigit() }
            TableColumn("Current") { Text($0.current).monospacedDigit() }
            TableColumn("Power") { Text($0.power).monospacedDigit() }
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
            }
        }
        .frame(minHeight: CGFloat(min(profile.offered.count + 1, 6)) * 26)
    }

    private var rows: [Row] {
        profile.offered.map { pdo in
            Row(
                id: UUID(),
                winning: matchesWinner(pdo),
                voltage: pdo.voltageLabel,
                current: pdo.currentLabel,
                power: pdo.powerLabel
            )
        }
    }

    private func matchesWinner(_ opt: USBPDOption) -> Bool {
        guard let w = profile.winning else { return false }
        return w.voltageMV == opt.voltageMV
            && w.maxCurrentMA == opt.maxCurrentMA
            && w.maxPowerMW == opt.maxPowerMW
    }
}
