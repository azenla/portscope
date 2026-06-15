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
            let nominalChargeCapacity = node.properties["NominalChargeCapacity"]?.asUInt ?? 0
            // `MaxCapacity` is gas-gauge-normalized (always 100 on Apple
            // Silicon) — it's only good as the charge-bar denominator.
            // Real health is the full-charge capacity in mAh against the
            // pack's design capacity.
            let healthPct = healthPercent(rawMax: appleRawMaxCapacity > 0 ? appleRawMaxCapacity : nominalChargeCapacity,
                                          design: designCapacity)
            let timeRemaining = node.properties["TimeRemaining"]?.asUInt
            let avgTimeToEmpty = node.properties["AvgTimeToEmpty"]?.asUInt
            let avgTimeToFull = node.properties["AvgTimeToFull"]?.asUInt
            let serial = node.properties["Serial"]?.asString
            let device = node.properties["DeviceName"]?.asString
            let installed = node.properties["BatteryInstalled"]?.asBool ?? false

            BatteryHero(percent: current,
                        maxPercent: maxCap,
                        healthPercent: healthPct,
                        isCharging: isCharging,
                        external: external)

            StatGrid(stats: [
                Stat(label: "Charge",
                     value: "\(current)%",
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
                     value: cycleCountValue(cycleCount: cycleCount,
                                            designLife: node.properties["DesignCycleCount9C"]?.asUInt
                                                ?? node.properties["DesignCycleCount"]?.asUInt),
                     symbol: "arrow.triangle.2.circlepath"),
                Stat(label: "Time to Empty",
                     value: minuteLabel(timeRemainingValue(isCharging ? nil : timeRemaining,
                                                           avg: avgTimeToEmpty)),
                     symbol: "hourglass.bottomhalf.filled"),
                Stat(label: "Time to Full",
                     value: minuteLabel(timeRemainingValue(isCharging ? timeRemaining : nil,
                                                           avg: avgTimeToFull)),
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
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Battery not installed").font(.callout.weight(.medium))
                }
            }

            // Wall input telemetry from `AppleSmartBattery.PowerTelemetryData`.
            // Mirrors the desktop AC PSU detail view (ACPowerDetailView)
            // for parity — laptops have the same kernel-side telemetry,
            // it just lives behind the battery node instead of a
            // synthesised accessory. See `design/IOService-Updates.md`
            // "Wall Power Input on Internal Battery page".
            wallPowerInputCard(props: node.properties)

            // Charger state from AppleSmartBattery.ChargerData. The kernel
            // publishes a nested dict on every Apple Silicon Mac (laptops + the
            // desktop telemetry endpoint). Surfacing this gives the user a
            // direct, kernel-side view of why charging is or isn't happening.
            //
            // Field discovery adapted from WhatCable
            // (Sources/WhatCableCore/AppleSmartBattery.swift:178-210 and
            // Sources/WhatCableDarwinBackend/AppleSmartBatteryReader.swift:106-107,
            // MIT, Copyright (c) 2026 Darryl Morley).
            chargerDataCard(props: node.properties)

            SectionCard(title: "Health", symbol: "heart.text.square") {
                HStack {
                    Text("Full-Charge Capacity vs Design")
                    Spacer()
                    if let healthPct {
                        Text("\(healthPct)%")
                            .monospaced()
                            .foregroundStyle(healthPct >= 80 ? .green : (healthPct >= 60 ? .orange : .red))
                    } else {
                        Text("—").monospaced().foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
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

    /// `TimeRemaining` follows kIOPMPSTimeRemaining semantics — minutes to
    /// full while charging, minutes to empty while discharging — so callers
    /// pass it as `primary` only for the stat matching the charge state.
    /// AvgTimeToEmpty / AvgTimeToFull are the per-stat fallbacks.
    /// 65535 = invalid.
    private func timeRemainingValue(_ primary: UInt64?, avg: UInt64?) -> UInt64? {
        if let p = primary, p > 0, p < 65535 { return p }
        if let a = avg, a > 0, a < 65535 { return a }
        return nil
    }

    /// Health = full-charge capacity (mAh, from the gauge IC) ÷ design
    /// capacity (mAh). Both must be present and non-zero; desktops'
    /// telemetry-only `AppleSmartBattery` publishes neither.
    private func healthPercent(rawMax: UInt64, design: UInt64) -> Int? {
        guard rawMax > 0, design > 0 else { return nil }
        return Int((Double(rawMax) / Double(design) * 100).rounded())
    }

    private func minuteLabel(_ minutes: UInt64?) -> String {
        guard let m = minutes else { return "—" }
        let h = m / 60
        let mm = m % 60
        if h == 0 { return "\(mm) min" }
        return "\(h)h \(mm)m"
    }

    /// Cycle count rendered with a "% of design life" suffix when the
    /// gauge IC publishes a design cycle target (typically 1000 for
    /// Apple Silicon batteries — Apple considers the pack serviceable
    /// down to about 80% health). Without a design number, falls back
    /// to the raw count so we don't pretend to know the threshold.
    private func cycleCountValue(cycleCount: UInt64, designLife: UInt64?) -> String {
        guard let designLife, designLife > 0 else { return "\(cycleCount)" }
        let pct = Int((Double(cycleCount) / Double(designLife) * 100).rounded())
        return "\(cycleCount) · \(pct)% of \(designLife)"
    }

    /// Render the wall-input telemetry pulled from
    /// `AppleSmartBattery.PowerTelemetryData`. Same dict that the
    /// desktop AC PSU detail view (`ACPowerDetailView`) consumes; on
    /// laptops it carries live AC power / voltage / current and the
    /// since-boot wall energy estimate. Only renders when the kernel
    /// publishes the dict and at least one wall-input field is present
    /// — keeps the card from showing on hosts running purely on
    /// battery with no charger attached.
    ///
    /// CLAUDE.md guidance: `AccumulatedWallEnergyEstimate` is in
    /// milliwatt-seconds (mJ). `SystemPowerIn` is the instantaneous
    /// wall draw in mW. Don't try to render
    /// `AccumulatedSystemEnergyConsumed` as energy — its unit isn't
    /// documented and the values are ~5 orders of magnitude larger
    /// than `AccumulatedWallEnergyEstimate` (treating it as mJ would
    /// render absurd GWh figures).
    @ViewBuilder
    private func wallPowerInputCard(props: [String: IORegValue]) -> some View {
        if case let .dictionary(kv) = props["PowerTelemetryData"] {
            let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
            let powerMW = d["SystemPowerIn"]?.asUInt ?? 0
            let voltageMV = d["SystemVoltageIn"]?.asUInt ?? 0
            let currentMA = d["SystemCurrentIn"]?.asUInt ?? 0
            let energyMJ = d["AccumulatedWallEnergyEstimate"]?.asUInt ?? 0
            // The kernel zeroes these out when no charger is attached.
            // Suppress the card entirely in that case rather than
            // rendering "0 W · 0 V · 0 A", which would be misleading.
            if powerMW > 0 || voltageMV > 0 || currentMA > 0 || energyMJ > 0 {
                SectionCard(title: "Wall Power Input",
                            symbol: "powerplug.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        if powerMW > 0 {
                            HStack {
                                Text("Drawing now").foregroundStyle(.secondary)
                                Spacer()
                                Text(wattLabel(milliwatts: powerMW))
                                    .font(.callout.bold().monospaced())
                                    .foregroundStyle(.green)
                            }
                        }
                        if voltageMV > 0 || currentMA > 0 {
                            HStack {
                                Text("Source").foregroundStyle(.secondary)
                                Spacer()
                                Text(sourceLabel(voltageMV: voltageMV,
                                                 currentMA: currentMA))
                                    .monospaced()
                            }
                            .font(.callout)
                        }
                        if energyMJ > 0 {
                            HStack {
                                Text("Energy since boot").foregroundStyle(.secondary)
                                Spacer()
                                Text(energyLabel(milliJoules: energyMJ))
                                    .monospaced()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func wattLabel(milliwatts: UInt64) -> String {
        let w = Double(milliwatts) / 1000.0
        return w >= 10 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }

    private func sourceLabel(voltageMV: UInt64, currentMA: UInt64) -> String {
        let v = Double(voltageMV) / 1000.0
        let a = Double(currentMA) / 1000.0
        return String(format: "%.2f V · %.2f A", v, a)
    }

    private func energyLabel(milliJoules: UInt64) -> String {
        // mJ → Wh: divide by 3.6 million. CLAUDE.md notes this is the
        // only Accumulated* counter we can safely render as energy.
        let wh = Double(milliJoules) / 3_600_000.0
        if wh >= 1000 {
            return String(format: "%.1f kWh", wh / 1000.0)
        }
        if wh >= 1 {
            return String(format: "%.1f Wh", wh)
        }
        return String(format: "%.0f mWh", wh * 1000.0)
    }

    /// Render `AppleSmartBattery.ChargerData` when present. The nested dict
    /// carries the gauge IC's own view of charging state: what voltage and
    /// current it's pushing into the cell right now, plus bitfields that
    /// non-zero out when the IC is blocking charge for some reason
    /// (thermal limit, full battery, fault, etc.). PortScope shows them as
    /// raw values — bit decoders for these fields aren't public — but a
    /// non-zero value is itself the diagnostic signal ("the kernel knows
    /// something is wrong / rate-limited").
    @ViewBuilder
    private func chargerDataCard(props: [String: IORegValue]) -> some View {
        if case let .dictionary(kv) = props["ChargerData"] {
            let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
            let chargingMV = d["ChargingVoltage"]?.asUInt ?? 0
            let chargingMA = d["ChargingCurrent"]?.asUInt ?? 0
            let slowCharging = d["SlowChargingReason"]?.asUInt ?? 0
            let thermallyLimited = d["TimeChargingThermallyLimited"]?.asUInt ?? 0
            let vacLimit = d["VacVoltageLimit"]?.asUInt ?? 0

            if chargingMV > 0 || chargingMA > 0 || slowCharging != 0 || thermallyLimited > 0 || vacLimit > 0 {
                SectionCard(title: "Charger State", symbol: "bolt.car") {
                    VStack(alignment: .leading, spacing: 8) {
                        if chargingMV > 0 || chargingMA > 0 {
                            HStack {
                                Text("Delivering to cell").foregroundStyle(.secondary)
                                Spacer()
                                Text(chargerDeliveryLabel(mV: chargingMV, mA: chargingMA))
                                    .monospaced()
                            }
                            .font(.callout)
                        }
                        if slowCharging != 0 {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Slow-charging reason").foregroundStyle(.secondary)
                                Spacer()
                                Text(reasonLabel(slowCharging))
                                    .monospaced()
                                    .foregroundStyle(.orange)
                            }
                            .font(.callout)
                        }
                        if thermallyLimited > 0 {
                            HStack {
                                Text("Time thermally limited").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(thermallyLimited) s")
                                    .monospaced()
                            }
                            .font(.callout)
                        }
                        if vacLimit > 0 {
                            HStack {
                                Text("VAC voltage limit").foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.2f V", Double(vacLimit) / 1000.0))
                                    .monospaced()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func chargerDeliveryLabel(mV: UInt64, mA: UInt64) -> String {
        let v = Double(mV) / 1000.0
        let a = Double(mA) / 1000.0
        let w = v * a
        return String(format: "%.2f V · %.2f A  (~%.1f W)", v, a, w)
    }

    /// Render a bitfield reason as decimal + hex so an engineer can look up
    /// the bits without needing a decoder built in (Apple doesn't publish one).
    private func reasonLabel(_ raw: UInt64) -> String {
        String(format: "%llu (0x%llX)", raw, raw)
    }
}

private struct BatteryHero: View {
    let percent: UInt64
    /// Gas-gauge-normalized charge ceiling (`MaxCapacity`) — charge-bar
    /// denominator only, not a health figure.
    let maxPercent: UInt64
    /// Full-charge capacity ÷ design capacity, when the gauge publishes both.
    let healthPercent: Int?
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
                if let health = healthPercent {
                    Text("Health \(health)% of design capacity")
                        .foregroundStyle(.secondary).font(.callout)
                }
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

    private var color: Color {
        if isCharging { return .green }
        if percent <= 20 { return .red }
        if percent <= 40 { return .orange }
        return .green
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

    /// `FW Version` is a 4-byte little-endian blob; render it
    /// most-significant byte first, each byte as two-digit hex (the live
    /// blob `<00023100>` is 0x00310200 → "00.31.02.00").
    private var magSafeFirmware: String? {
        if case .data(let d) = accessory.registryProperties["FW Version"], d.count >= 4 {
            let b = [UInt8](d.prefix(4))
            return String(format: "%02x.%02x.%02x.%02x", b[3], b[2], b[1], b[0])
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
