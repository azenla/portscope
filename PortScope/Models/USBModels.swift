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
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .empty: return .secondary
        case .thunderbolt: return .blue
        case .usbOnly: return .teal
        case .displayOnly: return .pink
        case .unknown: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .empty: return "circle.dashed"
        case .thunderbolt: return "bolt.horizontal.circle.fill"
        case .usbOnly: return "cable.connector"
        case .displayOnly: return "display"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Snapshot of the entire system across TB + USB + connector-level state.
nonisolated struct SystemSnapshot {
    let tb: TBSnapshot
    let usb: USBSnapshot
    /// Per-physical-port runtime state from `IOAccessoryManager`. Includes
    /// both USB-C (HPM Type10) and MagSafe (HPM Type11) receptacles — the
    /// `connector` field distinguishes them. Empty on Macs that don't expose
    /// HPM interfaces (e.g. Intel hosts).
    let accessories: [PortAccessoryInfo]
    /// Internal-fabric buses and devices: I²C, SPI, smart battery, MagSafe.
    let internalHardware: InternalHardwareSnapshot
    /// Bluetooth controller + paired/connected devices, from SPBluetoothDataType.
    let bluetooth: BluetoothSnapshot
    /// Built-in + external displays. Empty on Intel hosts.
    let displays: DisplaySnapshot
    /// PCIe topology rooted at host bridges. Empty on Macs without a
    /// visible PCIe complex (rare; even Apple Silicon laptops have one).
    let pcie: PCISnapshot
    let capturedAt: Date

    static let empty = SystemSnapshot(tb: .empty,
                                      usb: .empty,
                                      accessories: [],
                                      internalHardware: .empty,
                                      bluetooth: .empty,
                                      displays: .empty,
                                      pcie: .empty,
                                      capturedAt: .distantPast)
}
