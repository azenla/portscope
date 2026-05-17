//
//  TBModels.swift
//  Boltprobe
//
//  Domain model for Thunderbolt controllers, routers, ports, and downstream
//  PCIe / USB devices. Everything that lives in the navigation tree is a
//  `TBNode`.
//

import Foundation
import SwiftUI

/// Stable identifier across refreshes. Matches the IORegistry entry ID.
struct TBNodeID: Hashable {
    let raw: UInt64
}

/// Categories used for icon/colour assignment in the UI.
enum TBNodeKind: String {
    case domain        // Thunderbolt domain (machine root)
    case controller    // IOThunderboltController*
    case localNode     // IOThunderboltLocalNode
    case `switch`      // IOThunderboltSwitch* (router)
    case port          // IOThunderboltPort (lane / DP / USB / PCIe adapter)
    case usbBus        // AppleThunderboltUSB*Adapter (TB-side USB adapter)
    case usbController // IOUSBHostController / AppleUSBXHCI
    case usbHub        // IOUSBHostDevice that's also a hub (bDeviceClass == 0x09)
    case usbInterface  // IOUSBHostInterface (a single function of a USB device)
    case pcieBridge    // IOPCIBridge sitting downstream
    case pcieDevice    // IOPCIDevice
    case usbDevice     // IOUSBHostDevice
    case networkIf     // IOEthernetInterface (TBnet, USB-Ethernet)
    case appleFabric   // AppleFabricController / AppleFabricEndpoint
    case other

    var sfSymbol: String {
        switch self {
        case .domain: return "globe"
        case .controller: return "cpu"
        case .localNode: return "house.circle"
        case .switch: return "rectangle.connected.to.line.below"
        case .port: return "bolt.horizontal.circle"
        case .usbBus: return "cable.connector.horizontal"
        case .usbController: return "cpu.fill"
        case .usbHub: return "rectangle.3.group"
        case .usbInterface: return "puzzlepiece.extension"
        case .pcieBridge: return "square.stack.3d.up"
        case .pcieDevice: return "square.stack.3d.up.fill"
        case .usbDevice: return "cable.connector"
        case .networkIf: return "network"
        case .appleFabric: return "fibrechannel"
        case .other: return "questionmark.circle"
        }
    }

    var accentColor: Color {
        switch self {
        case .domain: return .blue
        case .controller: return .blue
        case .localNode: return .indigo
        case .switch: return .purple
        case .port: return .orange
        case .usbBus: return .teal
        case .usbController: return .teal
        case .usbHub: return .cyan
        case .usbInterface: return .mint
        case .pcieBridge, .pcieDevice: return .green
        case .usbDevice: return .teal
        case .networkIf: return .mint
        case .appleFabric: return .brown
        case .other: return .gray
        }
    }
}

/// Adapter types observed on `IOThunderboltPort.Adapter Type`.
/// Encoded as `(category << 16) | (direction)` historically.
enum TBAdapterType: Hashable {
    case inactive
    case lane(index: Int)              // 0 / 1
    case nhi                           // 2 = native host interface
    case dpHdmiIn
    case dpHdmiOut
    case usb3Up
    case usb3Down
    case usbGenTUp
    case usbGenTDown
    case pcieUp
    case pcieDown
    case unknown(UInt64)

    init(rawValue: UInt64) {
        switch rawValue {
        case 0: self = .inactive
        case 1: self = .lane(index: 1)
        case 2: self = .nhi
        case 0x0E0001: self = .pcieUp
        case 0x0E0002: self = .pcieDown
        case 0x100001: self = .dpHdmiIn
        case 0x100002: self = .dpHdmiOut
        case 0x200001: self = .usb3Up
        case 0x200002: self = .usb3Down
        case 0x210001: self = .usbGenTUp
        case 0x210002: self = .usbGenTDown
        default: self = .unknown(rawValue)
        }
    }

    var label: String {
        switch self {
        case .inactive: return "Inactive"
        case .lane(let i): return "Lane Adapter \(i)"
        case .nhi: return "Native Host Interface"
        case .dpHdmiIn: return "DisplayPort/HDMI In"
        case .dpHdmiOut: return "DisplayPort/HDMI Out"
        case .usb3Up: return "USB 3 Upstream"
        case .usb3Down: return "USB 3 Downstream"
        case .usbGenTUp: return "USB Gen-T Upstream"
        case .usbGenTDown: return "USB Gen-T Downstream"
        case .pcieUp: return "PCIe Upstream"
        case .pcieDown: return "PCIe Downstream"
        case .unknown(let v): return String(format: "Unknown (0x%X)", v)
        }
    }

    var icon: String {
        switch self {
        case .inactive: return "circle.dashed"
        case .lane: return "bolt.horizontal"
        case .nhi: return "cpu"
        case .dpHdmiIn, .dpHdmiOut: return "display"
        case .usb3Up, .usb3Down, .usbGenTUp, .usbGenTDown: return "cable.connector"
        case .pcieUp, .pcieDown: return "square.stack.3d.up"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Generic node used in the tree-shaped UI.
struct TBNode: Identifiable, Hashable {
    let id: TBNodeID
    let kind: TBNodeKind
    /// Short title shown in the sidebar list.
    let title: String
    /// Subtitle shown beneath the title.
    let subtitle: String?
    /// IORegistry class for this entry (e.g. "IOThunderboltPort").
    let className: String
    /// Raw IORegistry properties of this entry.
    let properties: [String: IORegValue]
    /// Ordered keys for stable display.
    let propertyOrder: [String]
    /// Direct children in the visualisation.
    let children: [TBNode]
    /// IORegistry path for copy & debugging.
    let registryPath: String?

    static func == (lhs: TBNode, rhs: TBNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id.raw) }
}

extension TBNode {
    /// Pretty-format a property value with TB-specific knowledge.
    static func formatValue(_ key: String, _ value: IORegValue) -> String {
        switch key {
        case "Vendor ID":
            if let v = value.asUInt { return String(format: "0x%04X (%d)", v, v) }
        case "Device ID":
            if let v = value.asUInt { return String(format: "0x%04X (%d)", v, v) }
        case "UID":
            if let v = value.asUInt { return String(format: "0x%016llX", v) }
        case "Route String":
            if let v = value.asUInt { return String(format: "0x%016llX", v) }
        case "Adapter Type":
            if let v = value.asUInt {
                return "\(TBAdapterType(rawValue: v).label) (0x\(String(v, radix: 16, uppercase: true)))"
            }
        case "Thunderbolt Version":
            if let v = value.asUInt {
                let major = (v >> 4) & 0xF
                let minor = v & 0xF
                return "\(major).\(minor) (0x\(String(v, radix: 16, uppercase: true)))"
            }
        case "Link Bandwidth", "Maximum Bandwidth Allocated", "Required Bandwidth Allocated":
            if let v = value.asUInt {
                let gbps = Double(v) / 100.0
                return "\(v) (\(String(format: "%.1f", gbps)) Gb/s)"
            }
        case "Current Link Speed", "Target Link Speed", "Supported Link Speed":
            if let v = value.asUInt { return tbLinkSpeedLabel(v) }
        case "Current Link Width", "Target Link Width", "Supported Link Width":
            if let v = value.asUInt { return "\(v)× lanes" }
        case "Device Speed", "kUSBCurrentSpeed":
            if let v = value.asUInt { return usbSpeedLabel(v) }
        case "bcdUSB", "bcdDevice":
            if let v = value.asUInt { return "\(usbBcdVersion(v)) (0x\(String(v, radix: 16, uppercase: true)))" }
        case "bDeviceClass":
            if let v = value.asUInt {
                return "\(usbDeviceClassLabel(v)) (0x\(String(format: "%02X", v)))"
            }
        case "idVendor", "idProduct":
            if let v = value.asUInt { return String(format: "0x%04X (%d)", v, v) }
        default: break
        }
        return value.display
    }
}

/// Map the `Current Link Speed` field to a TB generation label.
/// Observed: 0 = inactive, 2 = TB3/USB4 Gen 2 (20 Gbit/lane), 8 = TB5 Gen 3 (40 Gbit/lane bidirectional), etc.
func tbLinkSpeedLabel(_ raw: UInt64) -> String {
    switch raw {
    case 0: return "Inactive"
    case 1: return "TB3/USB4 Gen 1 — 10 Gb/s per lane"
    case 2: return "TB3/USB4 Gen 2 — 20 Gb/s per lane"
    case 4: return "TB4 Gen 3 — 40 Gb/s per lane"
    case 8: return "TB5 Gen 4 — 80 Gb/s per lane"
    case 14: return "TB5 asymmetric — 120 Gb/s tx / 40 Gb/s rx"
    default: return "Raw value \(raw)"
    }
}

/// Short link generation label used in sidebars and dense rows.
func tbGenerationShortLabel(_ raw: UInt64) -> String {
    switch raw {
    case 0: return "Inactive"
    case 1: return "TB3 Gen 1"
    case 2: return "TB3 Gen 2"
    case 4: return "TB4"
    case 8: return "TB5"
    case 14: return "TB5 async"
    default: return "Speed \(raw)"
    }
}

/// Format a "Link Bandwidth" raw value as a human bandwidth string. Field is
/// in 100 Mb/s units. Anything below 1 Gb/s is rendered in Mb/s — "100 Mb/s"
/// reads better than "0.1 Gb/s".
func tbBandwidthLabel(_ raw: UInt64) -> String {
    if raw == 0 { return "0 Gb/s" }
    if raw < 10 {
        return "\(raw * 100) Mb/s"
    }
    let gbps = Double(raw) / 10.0
    return String(format: "%.0f Gb/s", gbps)
}

/// Snapshot of the entire Thunderbolt subsystem captured at scan time.
struct TBSnapshot {
    let capturedAt: Date
    let controllers: [TBNode]
    let pcieDevicesOverTB: [TBNode]
    let usbDevicesOverTB: [TBNode]

    static let empty = TBSnapshot(capturedAt: .distantPast, controllers: [], pcieDevicesOverTB: [], usbDevicesOverTB: [])
}
