//
//  SensorScanner.swift
//  PortScope
//
//  Walk every sensor-bearing IORegistry class and return a flat list of
//  `HardwareSensor` rows for the Hardware Sensors panel. The kernel
//  exposes sensors through several different IOService families on Apple
//  Silicon; we mine each one and merge the results.
//
//  Live values are harder than discovery — most thermal / power readings
//  on Apple Silicon are only readable through the HID Event System
//  (`IOHIDEventSystemClient`, private API) or through `powermetrics`.
//  Values that the kernel DOES publish as IORegistry properties — the
//  battery / charger telemetry — get pulled in directly so the panel
//  isn't a pure discovery view.
//

import Foundation
import IOKit

nonisolated enum SensorScanner {
    /// Build a snapshot of *readable* sensors. Discovery rows (sensors
    /// the kernel exposes but doesn't publish live values for) are
    /// dropped — the user asked for a tight, value-bearing view rather
    /// than a wall of "Live read needs HID" tags. The combined data
    /// path:
    ///
    /// 1. Mine IOKit for every sensor-bearing service class, collecting
    ///    identification (Product, LocationID = SMC key, registry id).
    /// 2. Open an `IOHIDEventSystemClient` session and read every
    ///    available temperature / power / ambient-light event in one
    ///    pass, keyed by registry id.
    /// 3. Merge the two: a discovery row is kept iff (a) its registry
    ///    id appears in the HID readings, or (b) we synthesised the
    ///    value from a regular IORegistry property (battery /
    ///    AC-PSU telemetry).
    static func scan() -> HardwareSensorsSnapshot {
        let liveReadings = HIDSensorReader.readAll()
        var out: [HardwareSensor] = []
        out.append(contentsOf: scanPMUTempSensors(live: liveReadings))
        out.append(contentsOf: scanPMUPowerSensors(live: liveReadings))
        out.append(contentsOf: scanALSSensors(live: liveReadings))
        out.append(contentsOf: scanNVMeTempSensors(live: liveReadings))
        out.append(contentsOf: scanBatterySensors())
        out.append(contentsOf: scanPSUSensors())
        return HardwareSensorsSnapshot(capturedAt: Date(), sensors: out)
    }

    // MARK: - PMU thermal

    private static func scanPMUTempSensors(live: [UInt64: HIDSensorReader.Reading]) -> [HardwareSensor] {
        return mineHID(class: "AppleARMPMUTempSensor",
                       category: .temperature,
                       live: live)
    }

    // MARK: - PMU power rails

    private static func scanPMUPowerSensors(live: [UInt64: HIDSensorReader.Reading]) -> [HardwareSensor] {
        return mineHID(class: "AppleARMPMUPowerSensor",
                       category: .power,
                       live: live)
    }

    // MARK: - Ambient light + color

    private static func scanALSSensors(live: [UInt64: HIDSensorReader.Reading]) -> [HardwareSensor] {
        // `AppleSPUVD6286` is the ambient-light / colour-temperature
        // sensor on the AOP I²C bus on M-series laptops (in front of the
        // FaceTime camera). Sometimes paired with `AppleSPUALSColorDriver`.
        return mineHID(class: "AppleSPUVD6286",
                       category: .light,
                       live: live)
    }

    // MARK: - NVMe storage thermal

    private static func scanNVMeTempSensors(live: [UInt64: HIDSensorReader.Reading]) -> [HardwareSensor] {
        return mineHID(class: "AppleEmbeddedNVMeTemperatureSensor",
                       category: .temperature,
                       live: live)
    }

    // MARK: - Battery & charger telemetry (LIVE values via IOKit)

    /// Battery emits voltage / current / temperature directly into
    /// IORegistry; surface those as live sensor rows rather than just
    /// discovery markers.
    private static func scanBatterySensors() -> [HardwareSensor] {
        var out: [HardwareSensor] = []
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return out }
        defer { IOObjectRelease(svc) }

        let installed = (IORegistryEntryCreateCFProperty(
            svc, "BatteryInstalled" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool) ?? false
        // On desktops the AppleSmartBattery service exists with
        // BatteryInstalled = NO — used as a PSU telemetry endpoint, not
        // a pack-present marker. Skip the per-cell sensors there.
        if installed {
            if let tempCentiC = number(svc, "Temperature") {
                out.append(HardwareSensor(
                    name: "Battery Pack",
                    subtitle: "AppleSmartBattery · Temperature",
                    category: .temperature,
                    value: Double(tempCentiC) / 100.0,
                    unit: "°C",
                    locationID: nil,
                    kernelClass: "AppleSmartBattery"
                ))
            }
            if let mV = number(svc, "Voltage") {
                out.append(HardwareSensor(
                    name: "Battery Voltage",
                    subtitle: "AppleSmartBattery · Voltage",
                    category: .voltage,
                    value: Double(mV) / 1000.0,
                    unit: "V",
                    locationID: nil,
                    kernelClass: "AppleSmartBattery"
                ))
            }
            if let mA = signedNumber(svc, "Amperage") {
                out.append(HardwareSensor(
                    name: "Battery Current",
                    subtitle: mA >= 0 ? "Charging" : "Discharging",
                    category: .current,
                    value: Double(mA) / 1000.0,
                    unit: "A",
                    locationID: nil,
                    kernelClass: "AppleSmartBattery"
                ))
            }
        }
        return out
    }

    /// AC-PSU telemetry exposed through `AppleSmartBattery.PowerTelemetryData`
    /// on Apple Silicon Macs (laptops and desktops). The kernel publishes a
    /// dictionary with input / system / adapter energy counters. We surface
    /// the live wall-input power as a sensor row.
    private static func scanPSUSensors() -> [HardwareSensor] {
        var out: [HardwareSensor] = []
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return out }
        defer { IOObjectRelease(svc) }
        guard let telemetry = IORegistryEntryCreateCFProperty(
            svc, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any] else { return out }

        if let mw = telemetry["SystemPowerIn"] as? UInt64 {
            out.append(HardwareSensor(
                name: "Wall Power Input",
                subtitle: "AppleSmartBattery · PowerTelemetryData · SystemPowerIn",
                category: .power,
                value: Double(mw) / 1000.0,
                unit: "W",
                locationID: nil,
                kernelClass: "AppleSmartBattery"
            ))
        }
        if let mw = telemetry["SystemEnergyConsumed"] as? UInt64 {
            out.append(HardwareSensor(
                name: "System Energy (since boot)",
                subtitle: "AppleSmartBattery · AccumulatedSystemEnergyConsumed",
                category: .energy,
                value: Double(mw) / 3_600_000.0,
                unit: "Wh",
                locationID: nil,
                kernelClass: "AppleSmartBattery"
            ))
        }
        if let mv = telemetry["AdapterVoltage"] as? UInt64, mv > 0 {
            out.append(HardwareSensor(
                name: "Adapter Voltage",
                subtitle: "AppleSmartBattery · PowerTelemetryData",
                category: .voltage,
                value: Double(mv) / 1000.0,
                unit: "V",
                locationID: nil,
                kernelClass: "AppleSmartBattery"
            ))
        }
        return out
    }

    // MARK: - HID-sensor enumeration helper

    /// Walk every service matching `class`, emit a `HardwareSensor`
    /// row *only* for the ones that have a live HID reading. Discovery-
    /// only rows are dropped per the user's "tight value-bearing view"
    /// requirement — the wall of "Live read needs HID" tags went away
    /// when we wired the HID Event System reader.
    ///
    /// `LocationID` is the SMC 4-char ASCII key on PMU sensors; we use
    /// it to synthesise a friendly name. Live readings come from
    /// `HIDSensorReader.readAll()` keyed by registry entry id, which
    /// matches `IORegBridge.entryID(of:)`.
    private static func mineHID(class cls: String,
                                category: SensorCategory,
                                live: [UInt64: HIDSensorReader.Reading]) -> [HardwareSensor] {
        var out: [HardwareSensor] = []
        for svc in IORegBridge.services(matchingClass: cls) {
            defer { IOObjectRelease(svc) }
            guard let regID = IORegBridge.entryID(of: svc) else { continue }
            guard let reading = live[regID] else { continue }
            let product = string(svc, "Product")
            let location: UInt32? = {
                if let n = number(svc, "LocationID") { return UInt32(truncatingIfNeeded: n) }
                return nil
            }()
            let key = location.flatMap(decodeSMCKey)
            let friendly = synthesiseName(product: product, smcKey: key, category: category)
            var subtitleParts: [String] = []
            if let p = product, !p.isEmpty { subtitleParts.append(p) }
            if let k = key, !k.isEmpty { subtitleParts.append("key \(k)") }
            let subtitle = subtitleParts.isEmpty ? nil
                : subtitleParts.joined(separator: " · ")
            out.append(HardwareSensor(
                name: friendly,
                subtitle: subtitle,
                category: category,
                value: reading.value,
                unit: reading.unit,
                locationID: location,
                kernelClass: cls
            ))
        }
        return out
    }

    /// Decode a 32-bit SMC key encoded as 4 ASCII characters. The kernel
    /// publishes it as the big-endian integer, so we shift / mask down
    /// to four bytes and reverse to get human-readable order.
    private static func decodeSMCKey(_ raw: UInt32) -> String? {
        let b0 = UInt8((raw >> 24) & 0xFF)
        let b1 = UInt8((raw >> 16) & 0xFF)
        let b2 = UInt8((raw >> 8) & 0xFF)
        let b3 = UInt8(raw & 0xFF)
        let bytes = [b0, b1, b2, b3]
        guard bytes.allSatisfy({ ($0 >= 0x20 && $0 < 0x7F) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Best-effort friendly-name synthesis from the kernel `Product`
    /// string + SMC key. The kernel names are terse but consistent
    /// across generations; we map a handful of well-known SMC key
    /// prefixes to user-recognisable labels and fall back to the raw
    /// product string. New / unknown keys still get a readable row
    /// (`<Product>` or `<class> sensor`) rather than going silent.
    private static func synthesiseName(product: String?,
                                       smcKey: String?,
                                       category: SensorCategory) -> String {
        if let key = smcKey {
            // SMC key prefixes: T = thermal, V = voltage, I = current,
            // P = power. The second char often disambiguates the rail
            // (CPU / GPU / NAND / battery / wall).
            switch key.prefix(1) {
            case "T":
                if let mapped = thermalKeyLabel(key) { return mapped }
            case "V":
                return "Voltage Rail \(key)"
            case "I":
                return "Current Sensor \(key)"
            case "P":
                if let mapped = powerKeyLabel(key) { return mapped }
                return "Power Rail \(key)"
            default: break
            }
        }
        if let p = product, !p.isEmpty {
            return p
        }
        return "\(category.title) Sensor"
    }

    private static func thermalKeyLabel(_ key: String) -> String? {
        // Apple uses 4-character SMC keys throughout — Tp01 / Tg05 / etc.
        // The common families are well-known from iStat-Menus-style apps.
        switch key {
        case "TCAS", "Tcal": return "PMU Calibration Reference"
        case "TANS": return "Storage Controller"
        case "TBAT": return "Battery Pack"
        case "TCHP": return "Charge Controller"
        case "TSOC": return "SoC Average"
        case "TPMU": return "PMU Junction"
        default: break
        }
        if key.hasPrefix("Tp") { return "Performance Core \(key.suffix(2))" }
        if key.hasPrefix("Te") { return "Efficiency Core \(key.suffix(2))" }
        if key.hasPrefix("Tg") { return "GPU Cluster \(key.suffix(2))" }
        if key.hasPrefix("TaP") { return "Air Inlet \(key.suffix(1))" }
        return nil
    }

    private static func powerKeyLabel(_ key: String) -> String? {
        switch key {
        case "PCPU", "Pcpu": return "CPU Power"
        case "PGPU", "Pgpu": return "GPU Power"
        case "PDTR": return "DRAM Power"
        case "PSTR": return "Storage Power"
        case "PSYS": return "System Total Power"
        default: return nil
        }
    }

    // MARK: - IOKit property helpers

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        return IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }

    private static func number(_ entry: io_registry_entry_t, _ key: String) -> UInt64? {
        let v = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        if let n = v as? UInt64 { return n }
        if let n = v as? Int64, n >= 0 { return UInt64(n) }
        if let n = v as? NSNumber { return n.uint64Value }
        return nil
    }

    private static func signedNumber(_ entry: io_registry_entry_t, _ key: String) -> Int64? {
        let v = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        if let n = v as? Int64 { return n }
        if let n = v as? NSNumber { return n.int64Value }
        return nil
    }
}
