//
//  SensorModels.swift
//  PortScope
//
//  Data model for the Hardware Sensors panel — a modal view (sibling of
//  the Thunderbolt Topology sheet) that surveys every sensor exposed
//  through IOKit on the host and shows what each one is + (where
//  possible) its current reading.
//
//  Apple Silicon Macs expose sensors through a few different IOService
//  classes: `AppleARMPMUTempSensor` (CPU / SoC thermal probes via the
//  Power Management Unit), `AppleARMPMUPowerSensor` (per-rail power
//  rails monitored by the PMU), `AppleSPUVD6286` (ambient-light /
//  colour sensor on the Always-On Processor's I²C bus),
//  `AppleEmbeddedNVMeTemperatureSensor` (storage thermal), `AppleMesaShim`
//  (Touch ID), `AppleM68Buttons` (chassis buttons), and the
//  multitouch trackpad / keyboard drivers. The raw `LocationID` on each
//  PMU sensor is a 4-character ASCII code (the SMC-style sensor key —
//  e.g. `TPMU` = thermal/PMU); we decode it for the display name.
//

import Foundation

/// One sensor discovered on the host. Identification fields are always
/// populated from IORegistry; `value` / `unit` are populated for sensors
/// whose live reading is exposed as a kernel property (battery
/// temperature / voltage / current, accumulated PSU energy, etc.). HID
/// sensors that publish through `IOHIDEventSystem` only show up here
/// as discovery rows without a live number — the right way to read
/// them requires opening an HID event subscription, which we defer.
nonisolated struct HardwareSensor: Hashable, Identifiable {
    /// Includes the kernel registry entry ID so same-category sensors
    /// without a `LocationID` and with identical product strings still
    /// get distinct `Identifiable` IDs (the sensors panel refreshes a
    /// `ForEach` every 2 s — duplicate IDs scramble its diffing).
    var id: String { "\(category.rawValue)#\(registryID)#\(locationID ?? 0)#\(name)" }

    /// Kernel IORegistry entry ID of the backing service. Synthetic rows
    /// (battery / PSU telemetry read off `AppleSmartBattery` properties)
    /// use small fixed tokens instead — real registry IDs are large, so
    /// the namespaces can't collide.
    let registryID: UInt64
    /// Human-friendly name. Synthesised from the kernel `Product` string
    /// and / or the decoded `LocationID` SMC key.
    let name: String
    /// Short subtitle showing the raw kernel-side identifier so power
    /// users can correlate with `ioreg`. E.g. `PMU tcal · key TPMU`.
    let subtitle: String?
    /// Sensor category (Temperature / Power / Light / Motion / …) for
    /// grouping in the panel.
    let category: SensorCategory
    /// Live reading, when the kernel exposes one through a regular
    /// IORegistry property. Nil when we'd need an HID event subscription
    /// to read it.
    let value: Double?
    /// Unit string for the value (e.g. "°C", "V", "mA", "lux"). Nil when
    /// `value` is nil.
    let unit: String?
    /// Raw IORegistry `LocationID` — a 4-character SMC key encoded as
    /// 32-bit ASCII for PMU sensors. Decoded for display when readable.
    let locationID: UInt32?
    /// Kernel class name (`AppleARMPMUTempSensor`, `AppleSPUVD6286`, …).
    /// Surfaced as a tertiary line so power users can drill into ioreg.
    let kernelClass: String
}

nonisolated enum SensorCategory: String, CaseIterable, Hashable {
    case temperature
    case power
    case voltage
    case current
    case energy
    case light
    case motion
    case biometric
    case button
    case touch
    case other

    var title: String {
        switch self {
        case .temperature: return "Temperature"
        case .power:       return "Power Sensors"
        case .voltage:     return "Voltage"
        case .current:     return "Current"
        case .energy:      return "Energy Counters"
        case .light:       return "Ambient Light"
        case .motion:      return "Motion"
        case .biometric:   return "Biometric"
        case .button:      return "Buttons"
        case .touch:       return "Touch / Trackpad"
        case .other:       return "Other Sensors"
        }
    }

    var symbol: String {
        switch self {
        case .temperature: return "thermometer.medium"
        case .power:       return "bolt.fill"
        case .voltage:     return "bolt"
        case .current:     return "waveform.path"
        case .energy:      return "battery.100"
        case .light:       return "sun.max"
        case .motion:      return "move.3d"
        case .biometric:   return "touchid"
        case .button:      return "button.programmable"
        case .touch:       return "hand.point.up.left.fill"
        case .other:       return "dot.radiowaves.left.and.right"
        }
    }

    /// Display order in the panel — hot / actionable sensors first
    /// (temperature, power, light), discovery rows later.
    var sortOrder: Int {
        switch self {
        case .temperature: return 0
        case .power:       return 1
        case .voltage:     return 2
        case .current:     return 3
        case .energy:      return 4
        case .light:       return 5
        case .motion:      return 6
        case .biometric:   return 7
        case .touch:       return 8
        case .button:      return 9
        case .other:       return 10
        }
    }
}

nonisolated struct HardwareSensorsSnapshot: Hashable {
    let capturedAt: Date
    let sensors: [HardwareSensor]

    var grouped: [(category: SensorCategory, sensors: [HardwareSensor])] {
        let buckets = Dictionary(grouping: sensors, by: \.category)
        return SensorCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { cat in
                guard let list = buckets[cat], !list.isEmpty else { return nil }
                return (cat, list.sorted { $0.name < $1.name })
            }
    }

    static let empty = HardwareSensorsSnapshot(capturedAt: .distantPast, sensors: [])
}
