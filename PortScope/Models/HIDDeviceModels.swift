//
//  HIDDeviceModels.swift
//  PortScope
//
//  Model for the HID Devices sidebar section. The HID Event System
//  exposes every keyboard, trackpad, sensor, magic accessory, and
//  USB-PD partner as an `IOHIDDevice` (or one of the kernel's HID-
//  event-driver subclasses) tagged with a `PrimaryUsagePage` /
//  `PrimaryUsage` pair. Bucketing by usage page is what lets the
//  sidebar group ALS / trackpad / keyboard / button / sensor entries
//  separately instead of running them all together.
//

import Foundation

nonisolated struct HIDDeviceInfo: Hashable, Identifiable {
    var id: UInt64 { registryID }

    /// IORegistry entry id — used to join against
    /// `HIDSensorReader.readAll()` so the live sensor value can be
    /// surfaced inline when the device is the source of one.
    let registryID: UInt64
    /// Friendly product string ("Magic Trackpad", "PMU tcal", etc.).
    let product: String?
    /// Manufacturer string when published ("Apple Inc.").
    let manufacturer: String?
    /// IOKit class hierarchy leaf (`AppleARMPMUTempSensor`,
    /// `AppleHIDKeyboardEventDriverV2`, …). Surfaced as the tertiary
    /// line so power users can drill back into ioreg.
    let kernelClass: String
    /// USB / vendor id when the device is on a real bus.
    let vendorID: UInt64?
    let productID: UInt64?
    /// HID usage page / usage. Together they decide which Apple
    /// driver matched the device.
    let usagePage: UInt64?
    let usage: UInt64?
    /// True when `Built-In` is set on the IOKit node (every Apple-
    /// silicon-resident sensor is built-in; external HID keyboards /
    /// mice connected over USB / Bluetooth are not).
    let builtIn: Bool
    /// Bucket this device falls into for sidebar grouping.
    let category: HIDDeviceCategory

    /// Convenience: short, scannable subtitle for the sidebar row.
    var subtitle: String? {
        var parts: [String] = []
        if let p = product { parts.append(p) }
        if let m = manufacturer, !m.isEmpty, m != product { parts.append(m) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

nonisolated enum HIDDeviceCategory: String, CaseIterable, Hashable {
    case temperatureSensor
    case powerSensor
    case ambientLight
    case keyboard
    case trackpad
    case button
    case biometric
    case audio
    case multitouch
    case generic

    var title: String {
        switch self {
        case .temperatureSensor: return "Temperature Sensors"
        case .powerSensor:       return "Power Sensors"
        case .ambientLight:      return "Ambient Light"
        case .keyboard:          return "Keyboards"
        case .trackpad:          return "Trackpads"
        case .button:            return "Chassis Buttons"
        case .biometric:         return "Biometric Sensors"
        case .audio:             return "Audio Devices (HID)"
        case .multitouch:        return "Multitouch Devices"
        case .generic:           return "Other HID"
        }
    }

    var symbol: String {
        switch self {
        case .temperatureSensor: return "thermometer.medium"
        case .powerSensor:       return "bolt.fill"
        case .ambientLight:      return "sun.max"
        case .keyboard:          return "keyboard"
        case .trackpad:          return "hand.point.up.left.fill"
        case .button:            return "button.programmable"
        case .biometric:         return "touchid"
        case .audio:             return "speaker.wave.2"
        case .multitouch:        return "hand.tap"
        case .generic:           return "dot.radiowaves.left.and.right"
        }
    }

    var sortOrder: Int {
        switch self {
        case .keyboard:          return 0
        case .trackpad:          return 1
        case .multitouch:        return 2
        case .button:            return 3
        case .biometric:         return 4
        case .ambientLight:      return 5
        case .temperatureSensor: return 6
        case .powerSensor:       return 7
        case .audio:             return 8
        case .generic:           return 9
        }
    }
}

nonisolated struct HIDDevicesSnapshot: Hashable {
    let devices: [HIDDeviceInfo]

    static let empty = HIDDevicesSnapshot(devices: [])

    /// Group by category in display order.
    var grouped: [(category: HIDDeviceCategory, devices: [HIDDeviceInfo])] {
        let buckets = Dictionary(grouping: devices, by: \.category)
        return HIDDeviceCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { cat in
                guard let list = buckets[cat], !list.isEmpty else { return nil }
                return (cat, list.sorted { ($0.product ?? "") < ($1.product ?? "") })
            }
    }
}
