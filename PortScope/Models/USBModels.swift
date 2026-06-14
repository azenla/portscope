//
//  USBModels.swift
//  PortScope
//
//  USB-specific formatters, enums, and snapshot type.
//

import Foundation
import SwiftUI

/// Negotiated USB device speed. Values come from `kUSBCurrentSpeed` /
/// `Device Speed` properties in the IOKit registry.
nonisolated enum USBSpeed: Int {
    case low = 0
    case full = 1
    case high = 2
    case `super` = 3
    case superPlus = 4
    case superPlusBy2 = 5

    var rateMbps: Double {
        switch self {
        case .low: return 1.5
        case .full: return 12
        case .high: return 480
        case .super: return 5_000
        case .superPlus: return 10_000
        case .superPlusBy2: return 20_000
        }
    }

    var label: String {
        switch self {
        case .low: return "USB 1.0 Low Speed"
        case .full: return "USB 1.1 Full Speed"
        case .high: return "USB 2.0 High Speed"
        case .super: return "USB 3.0 SuperSpeed"
        case .superPlus: return "USB 3.1 SuperSpeed+"
        case .superPlusBy2: return "USB 3.2 SuperSpeed+ 2×"
        }
    }

    var shortLabel: String {
        switch self {
        case .low: return "USB 1.0"
        case .full: return "USB 1.1"
        case .high: return "USB 2.0"
        case .super: return "USB 3.0"
        case .superPlus: return "USB 3.1"
        case .superPlusBy2: return "USB 3.2×2"
        }
    }

    var rateLabel: String {
        if rateMbps >= 1_000 {
            return String(format: "%.0f Gb/s", rateMbps / 1_000)
        } else if rateMbps >= 1 {
            return String(format: "%.0f Mb/s", rateMbps)
        } else {
            return String(format: "%.1f Mb/s", rateMbps)
        }
    }

    var accentColor: Color {
        switch self {
        case .low, .full: return .gray
        case .high: return .yellow
        case .super: return .blue
        case .superPlus: return .indigo
        case .superPlusBy2: return .purple
        }
    }
}

/// USB-IF base class codes from the device descriptor (`bDeviceClass`).
nonisolated enum USBDeviceClass: UInt64, Hashable {
    case perInterface = 0x00
    case audio = 0x01
    case cdcComm = 0x02
    case hid = 0x03
    case physical = 0x05
    case image = 0x06
    case printer = 0x07
    case massStorage = 0x08
    case hub = 0x09
    case cdcData = 0x0a
    case smartCard = 0x0b
    case contentSecurity = 0x0d
    case video = 0x0e
    case personalHealthcare = 0x0f
    case audioVideo = 0x10
    case billboard = 0x11
    case typeCBridge = 0x12
    case diagnostic = 0xdc
    case wireless = 0xe0
    case miscellaneous = 0xef
    case applicationSpecific = 0xfe
    case vendorSpecific = 0xff

    var label: String {
        switch self {
        case .perInterface: return "Per-Interface"
        case .audio: return "Audio"
        case .cdcComm: return "Communications"
        case .hid: return "Human Interface (HID)"
        case .physical: return "Physical"
        case .image: return "Image"
        case .printer: return "Printer"
        case .massStorage: return "Mass Storage"
        case .hub: return "USB Hub"
        case .cdcData: return "CDC Data"
        case .smartCard: return "Smart Card"
        case .contentSecurity: return "Content Security"
        case .video: return "Video"
        case .personalHealthcare: return "Personal Healthcare"
        case .audioVideo: return "Audio / Video"
        case .billboard: return "Billboard"
        case .typeCBridge: return "USB-C Bridge"
        case .diagnostic: return "Diagnostic"
        case .wireless: return "Wireless Controller"
        case .miscellaneous: return "Miscellaneous"
        case .applicationSpecific: return "Application-Specific"
        case .vendorSpecific: return "Vendor-Specific"
        }
    }

    var symbol: String {
        switch self {
        case .audio: return "speaker.wave.2"
        case .hid: return "keyboard"
        case .image: return "camera"
        case .printer: return "printer"
        case .massStorage: return "externaldrive"
        case .hub: return "rectangle.3.group"
        case .video: return "video"
        case .audioVideo: return "av.remote"
        case .billboard: return "rectangle.on.rectangle"
        case .typeCBridge: return "cable.connector"
        case .wireless: return "wifi"
        case .cdcComm, .cdcData: return "antenna.radiowaves.left.and.right"
        case .vendorSpecific: return "gearshape"
        default: return "cable.connector"
        }
    }
}

/// Lookup a USB device's class label using its `bDeviceClass` property.
nonisolated func usbDeviceClassLabel(_ raw: UInt64?) -> String {
    guard let raw, let cls = USBDeviceClass(rawValue: raw) else {
        if let raw { return String(format: "Class 0x%02X", raw) }
        return "Unknown"
    }
    return cls.label
}

nonisolated func usbSpeedLabel(_ raw: UInt64?) -> String {
    guard let raw, let s = USBSpeed(rawValue: Int(raw)) else { return "—" }
    return s.label
}

nonisolated func usbSpeedShortLabel(_ raw: UInt64?) -> String {
    guard let raw, let s = USBSpeed(rawValue: Int(raw)) else { return "—" }
    return s.shortLabel
}

/// Format a `bcdUSB`-style version (e.g. 0x0320 → "3.2.0").
nonisolated func usbBcdVersion(_ raw: UInt64?) -> String {
    guard let raw else { return "—" }
    let major = (raw >> 8) & 0xFF
    let minor = (raw >> 4) & 0xF
    let sub = raw & 0xF
    if sub == 0 {
        return "\(major).\(minor)"
    }
    return "\(major).\(minor).\(sub)"
}

/// Map a device's declared `bcdUSB` protocol version to a *guaranteed
/// floor* speed class — not a ceiling. `bcdUSB` encodes spec-revision
/// compliance, not the Gen/lane tier: nearly every USB 3.2 Gen 1 *and*
/// Gen 2 device ships `bcdUSB = 0x0320` (a Samsung T7 declares 3.2 and
/// tops out at 10 Gb/s — that's its hardware max, not a downgrade), so
/// the true ceiling of a 3.x device is not derivable from this field.
/// All 3.x values therefore map to `.super` — the SuperSpeed minimum a
/// 3.x device must support. Callers must not render ceiling claims
/// ("×2", "up to N Gb/s") for 3.x devices; show the version-only label
/// from `usbDeclaredVersionLabel` instead.
nonisolated func usbCapabilityFromBCD(_ bcdUSB: UInt64?) -> USBSpeed? {
    guard let v = bcdUSB else { return nil }
    switch (v >> 8) & 0xFF {
    case 1: return .full   // USB 1.x — Full Speed (12 Mb/s)
    case 2: return .high   // USB 2.x — High Speed (480 Mb/s)
    case 3: return .super  // USB 3.x — SuperSpeed floor; Gen tier unknown
    default: return nil
    }
}

/// Version-only label for a declared `bcdUSB` ("USB 3.2"). This is the
/// only honest capability string for 3.x devices, where the Gen/lane
/// ceiling isn't encoded — see `usbCapabilityFromBCD`.
nonisolated func usbDeclaredVersionLabel(_ bcdUSB: UInt64?) -> String? {
    guard let v = bcdUSB else { return nil }
    let major = (v >> 8) & 0xFF
    let minor = (v >> 4) & 0xF
    guard (1...3).contains(major) else { return nil }
    return "USB \(major).\(minor)"
}

/// True when a USB 3.x device (`bcdUSB >= 0x0300`) negotiated below
/// SuperSpeed — i.e. it fell back to the High/Full/Low-Speed bus, the
/// real "USB 2.0 hub or cable in the path" failure. A 3.x device running
/// at SuperSpeed 5 Gb/s is *not* downgraded even when bcdUSB says 3.2:
/// Gen 1 hardware declares 0x0320 too. 2.x devices are never downgraded —
/// a 480-capable device at Full Speed is a device choice (HID endpoints),
/// not a path problem.
nonisolated func usbIsDowngraded(bcdUSB: UInt64?, currentSpeed: UInt64?) -> Bool {
    guard let v = bcdUSB, v >= 0x0300,
          let raw = currentSpeed,
          let negotiated = USBSpeed(rawValue: Int(raw))
    else { return false }
    return negotiated.rateMbps < USBSpeed.`super`.rateMbps
}

/// Per-physical-port summary of the power the Mac is sourcing on a USB-C
/// receptacle. Pulled together from two IOKit sources:
///
/// * The xHCI port wrapper (`AppleUSB30XHCIARMPort` / `AppleUSB20XHCIARMPort`)
///   carries the *port-level* current ceiling — `kUSBWakePortCurrentLimit` and
///   `kUSBSleepPortCurrentLimit` — i.e. how much current the silicon is
///   willing to push at 5 V regardless of which device is plugged in.
/// * Each attached USB device exposes its *negotiated* allowance through
///   `UsbPowerSinkAllocation` (granted to the sink) and
///   `UsbPowerSinkCapability` (peak the sink could request).
///
/// USB-PD source PDOs (the per-voltage profiles the Mac advertises) aren't
/// exposed in IORegistry on Apple Silicon today — `IOPortFeaturePowerOut`
/// has no children — so the wattage shown here is computed at 5 V from the
/// negotiated current. When Apple starts publishing source PDOs we can plug
/// them in via `outputProfile`.
nonisolated struct PortSourcePower: Hashable {
    let wakeLimitMA: UInt64?
    let sleepLimitMA: UInt64?
    let sinks: [PortSinkConsumer]
    /// Forward-looking. Currently always nil on Apple Silicon.
    let outputProfile: USBPDProfile?

    var isInteresting: Bool {
        wakeLimitMA != nil || sleepLimitMA != nil || !sinks.isEmpty || outputProfile != nil
    }

    /// Total current the Mac is currently sourcing across all attached USB
    /// devices on this port (sum of `allocatedMA`). Useful for the headline
    /// wattage figure on the port view.
    var totalAllocatedMA: UInt64 {
        sinks.reduce(0) { $0 + $1.allocatedMA }
    }
}

/// One USB device the Mac is sourcing power to on a given port.
nonisolated struct PortSinkConsumer: Hashable, Identifiable {
    let id: TBNodeID
    let name: String
    let allocatedMA: UInt64
    let capabilityMA: UInt64?
    let configCurrentMA: UInt64?
}

/// Snapshot of the USB subsystem at scan time.
nonisolated struct USBSnapshot {
    let capturedAt: Date
    /// Top-level USB host controllers (xHCI / eHCI / etc.) as TBNode trees.
    let controllers: [TBNode]
    /// Maps a USB controller's TBNodeID to its ancestor TB switch's TBNodeID
    /// when the controller is tunneled over Thunderbolt. Lets the detail view
    /// cross-link USB devices to their TB context.
    let tbContext: [TBNodeID: TBNodeID]

    static let empty = USBSnapshot(capturedAt: .distantPast,
                                   controllers: [],
                                   tbContext: [:])
}

/// What's a USB-C / USB-A port currently operating as.
nonisolated enum PhysicalPortMode: Hashable {
    case empty
    case thunderbolt(linkSpeed: UInt64)
    case usbOnly(speed: UInt64?)
    case displayOnly
    /// Power-only sink: a USB-PD partner is supplying the Mac with no data
    /// transports active (e.g. a wall charger). `watts` is the negotiated
    /// contract rounded to whole watts when known.
    case charging(watts: UInt64?)
    case unknown

    var label: String {
        switch self {
        case .empty: return "Empty"
        case .thunderbolt(let s):
            return s > 0 ? tbGenerationShortLabel(s) : "Thunderbolt"
        case .usbOnly(let s):
            if let s, s > 0 { return usbSpeedShortLabel(s) }
            return "USB"
        case .displayOnly: return "Display"
        case .charging(let w):
            if let w, w > 0 { return "Charging · \(w) W" }
            return "Charging"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .empty: return .secondary
        case .thunderbolt: return .blue
        case .usbOnly: return .teal
        case .displayOnly: return .pink
        case .charging: return .green
        case .unknown: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .empty: return "circle.dashed"
        case .thunderbolt: return "bolt.horizontal.circle.fill"
        case .usbOnly: return "cable.connector"
        case .displayOnly: return "display"
        case .charging: return "bolt.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Snapshot of the entire system across TB + USB + connector-level state.
nonisolated struct SystemSnapshot {
    // Fields are `var` so the streaming rescan in `PortScopeViewModel`
    // can update one slice at a time as each scanner completes — the
    // sidebar populates progressively (TB ports first, then PCIe, then
    // Displays trickling in) instead of waiting on the slowest scanner
    // to publish anything. Value semantics keep this safe: each
    // MainActor.run block copies the struct, sets one field, assigns
    // back; the runs are serialised by the actor.
    var tb: TBSnapshot
    var usb: USBSnapshot
    /// Per-physical-port runtime state from `IOAccessoryManager`. Includes
    /// both USB-C (HPM Type10) and MagSafe (HPM Type11) receptacles — the
    /// `connector` field distinguishes them. Empty on Macs that don't expose
    /// HPM interfaces (e.g. Intel hosts).
    var accessories: [PortAccessoryInfo]
    /// Chassis power hardware: smart battery and MagSafe.
    var internalHardware: InternalHardwareSnapshot
    /// Built-in + external displays. Empty on Intel hosts.
    var displays: DisplaySnapshot
    /// PCIe topology rooted at host bridges. Empty on Macs without a
    /// visible PCIe complex (rare; even Apple Silicon laptops have one).
    var pcie: PCISnapshot
    var capturedAt: Date

    static let empty = SystemSnapshot(tb: .empty,
                                      usb: .empty,
                                      accessories: [],
                                      internalHardware: .empty,
                                      displays: .empty,
                                      pcie: .empty,
                                      capturedAt: .distantPast)
}
