//
//  BluetoothModels.swift
//  PortScope
//
//  Domain model for the Bluetooth subsystem. Sourced from
//  `system_profiler -xml SPBluetoothDataType` rather than IOKit — the
//  IOBluetoothHCIController node only carries transport/connected booleans;
//  the chipset name, firmware version, paired-device list, RSSIs, and
//  battery levels all live behind SPBluetoothDataType.
//

import Foundation
import SwiftUI

struct BluetoothSnapshot {
    /// Controller. Nil on hosts without a Bluetooth radio (rare; SP returns
    /// the dict on every Mac with the daemon enabled).
    let controller: BluetoothController?
    /// Currently connected paired devices (ACL link up).
    let connected: [BluetoothDevice]
    /// Paired but not currently connected.
    let paired: [BluetoothDevice]

    static let empty = BluetoothSnapshot(controller: nil, connected: [], paired: [])

    /// Convenience: total device count (connected + paired).
    var totalDeviceCount: Int { connected.count + paired.count }
}

/// Bluetooth host controller info. Built from `controller_properties`.
struct BluetoothController: Hashable {
    let address: String?
    let chipset: String?
    let firmwareVersion: String?
    let productID: String?
    let vendorID: String?
    let transport: String?     // "PCIe" on Apple Silicon, "USB" on Intel
    let isOn: Bool
    let isDiscoverable: Bool
    let supportedServicesRaw: String?

    /// Friendly chipset → "Apple Designed (BCM_4388)" style.
    var displayChipset: String {
        guard let c = chipset, !c.isEmpty else { return "Unknown" }
        return c
    }

    /// Parsed supported-services flag list: "HFP AVRCP A2DP HID …" from the
    /// raw string `"0x392039 < HFP AVRCP A2DP HID Braille LEA AACP GATT SerialPort >"`.
    var supportedServices: [String] {
        guard let raw = supportedServicesRaw,
              let lhs = raw.firstIndex(of: "<"),
              let rhs = raw.lastIndex(of: ">"),
              lhs < rhs else { return [] }
        let inside = raw[raw.index(after: lhs)..<rhs]
        return inside
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }
}

/// A single Bluetooth device (connected or paired).
struct BluetoothDevice: Hashable, Identifiable {
    /// Stable id from the BD_ADDR (e.g. "70:F9:4A:93:C4:BE"). Falls back to
    /// `name` when address is missing, which shouldn't happen.
    var id: String { address ?? name }

    let name: String
    let address: String?
    let vendorID: String?
    let productID: String?
    let firmwareVersion: String?
    let minorType: String?
    let rssi: String?
    let serialNumber: String?
    let servicesRaw: String?
    let batteryLevel: String?
    let batteryLevelLeft: String?
    let batteryLevelRight: String?
    let batteryLevelCase: String?
    let caseVersion: String?
    let isConnected: Bool

    /// Best-effort device category for icon + sort priority.
    var category: BluetoothDeviceCategory {
        // Lean on the SP `device_minorType` (Headphones, Magic Trackpad,
        // Gamepad, etc.). When absent fall back to vendor heuristics.
        let mt = (minorType ?? "").lowercased()
        if mt.contains("headphone") || mt.contains("airpods") || mt.contains("speaker") {
            return .audio
        }
        if mt.contains("keyboard") { return .keyboard }
        if mt.contains("mouse") || mt.contains("trackpad") { return .pointer }
        if mt.contains("gamepad") || mt.contains("controller") { return .gamepad }
        if mt.contains("phone") { return .phone }
        if mt.contains("tablet") || mt.contains("ipad") { return .tablet }
        if mt.contains("computer") || mt.contains("laptop") { return .computer }
        if mt.contains("watch") { return .watch }
        if mt.contains("tv") || mt.contains("display") { return .display }
        return .other
    }

    /// Services advertised by this device, parsed from the SP "0x… < … >" form.
    var services: [String] {
        guard let raw = servicesRaw,
              let lhs = raw.firstIndex(of: "<"),
              let rhs = raw.lastIndex(of: ">"),
              lhs < rhs else { return [] }
        let inside = raw[raw.index(after: lhs)..<rhs]
        return inside
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }
}

enum BluetoothDeviceCategory: String {
    case audio, keyboard, pointer, gamepad, phone, tablet, computer, watch, display, other

    var symbol: String {
        switch self {
        case .audio:    return "headphones"
        case .keyboard: return "keyboard"
        case .pointer:  return "computermouse"
        case .gamepad:  return "gamecontroller"
        case .phone:    return "iphone"
        case .tablet:   return "ipad"
        case .computer: return "laptopcomputer"
        case .watch:    return "applewatch"
        case .display:  return "tv"
        case .other:    return "dot.radiowaves.left.and.right"
        }
    }

    var color: Color {
        switch self {
        case .audio:    return .purple
        case .keyboard: return .blue
        case .pointer:  return .cyan
        case .gamepad:  return .pink
        case .phone:    return .green
        case .tablet:   return .indigo
        case .computer: return .gray
        case .watch:    return .orange
        case .display:  return .teal
        case .other:    return .secondary
        }
    }
}
