//
//  TBModels.swift
//  PortScope
//
//  Domain model for Thunderbolt controllers, routers, ports, and downstream
//  PCIe / USB devices. Everything that lives in the navigation tree is a
//  `TBNode`.
//

import Foundation
import SwiftUI

/// Stable identifier across refreshes. Matches the IORegistry entry ID.
nonisolated struct TBNodeID: Hashable {
    let raw: UInt64
}

/// Categories used for icon/colour assignment in the UI.
nonisolated enum TBNodeKind: String {
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
    case i2cBus        // AppleARMIODevice with `device_type = i2c` (i2c1..i2c8)
    case spiBus        // AppleARMIODevice with `device_type = spi/qspi`
    case busDevice     // AppleARMIICDevice / AppleARMSPIDevice — an on-bus slave
    case batteryManager // AppleSmartBatteryManager
    case battery       // AppleSmartBattery
    case socCoprocessor // AppleARMIODevice for a named SoC block (sep / aop / ane / isp / dcp / ans / smc / wlan / bluetooth / …)
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
        case .i2cBus: return "point.3.connected.trianglepath.dotted"
        case .spiBus: return "waveform.path.ecg"
        case .busDevice: return "circuit.cubic"
        case .batteryManager: return "battery.100.bolt"
        case .battery: return "battery.100"
        case .socCoprocessor: return "cpu.fill"
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
        case .i2cBus: return .orange
        case .spiBus: return .pink
        case .busDevice: return .gray
        case .batteryManager: return .green
        case .battery: return .green
        case .socCoprocessor: return .indigo
        case .other: return .gray
        }
    }
}

/// Adapter types observed on `IOThunderboltPort.Adapter Type`.
///
/// The low values (0, 1, 2) are stable across every TB controller family we
/// support: 0 = inactive, 1 = lane adapter, 2 = native host interface. The
/// higher "function adapter" codes (0xE0001, 0x100001, 0x200001, etc.) are
/// **NOT** portable — different controller generations / vendors permute
/// them. For example, Apple's Type7 controllers use `0x100001 = DP/HDMI`,
/// but Type5 controllers (M1 / M2 family, T6000) use `0x100001 = PCIe`.
/// Intel's `IOThunderboltSwitchIntelJHL95xx` adds its own permutation.
///
/// Surfacing those swapped codes as fixed labels was actively misleading on
/// every host except the one the labels were authored for, so we no longer
/// try. The authoritative identity of a function adapter is the kernel's
/// `Description` string (`"PCIe Adapter"`, `"USB Adapter"`, `"DP or HDMI
/// Adapter"`, etc.) — read that, not the raw `Adapter Type` integer. Lane
/// detection (raw == 1) is still safe because every encoding agrees on it.
nonisolated enum TBAdapterType: Hashable {
    case inactive
    case lane(index: Int)              // 1 = lane adapter (both lanes)
    case nhi                           // 2 = native host interface
    case unknown(UInt64)               // function adapter — see `Description`

    init(rawValue: UInt64) {
        switch rawValue {
        case 0: self = .inactive
        case 1: self = .lane(index: 1)
        case 2: self = .nhi
        default: self = .unknown(rawValue)
        }
    }

    var label: String {
        switch self {
        case .inactive: return "Inactive"
        case .lane(let i): return "Lane Adapter \(i)"
        case .nhi: return "Native Host Interface"
        case .unknown(let v): return String(format: "Function Adapter (0x%X)", v)
        }
    }

    var icon: String {
        switch self {
        case .inactive: return "circle.dashed"
        case .lane: return "bolt.horizontal"
        case .nhi: return "cpu"
        case .unknown: return "rectangle.connected.to.line.below"
        }
    }
}

/// Generic node used in the tree-shaped UI.
nonisolated struct TBNode: Identifiable, Hashable {
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

    /// Equality compares both the IORegistry entry id AND the current
    /// `properties` dict. This is load-bearing for SwiftUI's view diffing:
    /// the periodic power refresh produces a new `TBNode` with the same
    /// id but updated properties (e.g. a refreshed battery `CurrentCapacity`),
    /// and SwiftUI will skip re-evaluating a child view's body when its
    /// inputs compare equal. Without the property check, a `BatteryView`
    /// bound to the battery node would freeze on the values from the snapshot
    /// it was first rendered with, while the sidebar row continues to update
    /// because its enclosing List re-renders for other reasons.
    /// `children` are intentionally excluded — including them would recurse
    /// the entire IOKit tree on every diff, and SwiftUI compares child views
    /// on their own merits when iterating, so per-node properties are enough.
    static func == (lhs: TBNode, rhs: TBNode) -> Bool {
        lhs.id == rhs.id && lhs.properties == rhs.properties
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id.raw) }
}

nonisolated extension TBNode {
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
        case "Current Link Speed":
            if let v = value.asUInt { return tbLinkSpeedLabel(v) }
        case "Target Link Speed", "Supported Link Speed":
            // Bitmask form of the same encoding — see tbSupportedLinkSpeedLabel.
            if let v = value.asUInt { return tbSupportedLinkSpeedLabel(v) }
        case "Current Link Width", "Supported Link Width":
            if let v = value.asUInt { return tbCurrentLinkWidthLabel(v) }
        case "Target Link Width":
            // Different encoding: 0x1 = single, 0x3 = dual. NOT bitmask.
            if let v = value.asUInt { return tbTargetLinkWidthLabel(v) }
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
        case "UsbPowerSinkAllocation", "UsbPowerSinkCapability",
             "kUSBConfigurationCurrentOverride",
             "kUSBWakePortCurrentLimit", "kUSBSleepPortCurrentLimit",
             "Bus Current", "Operating Bus Current (mA)":
            if let v = value.asUInt {
                let watts = Double(v) / 1000.0 * 5.0
                return String(format: "%llu mA  (~%.1f W @ 5 V)", v, watts)
            }
        case "compatible", "IONameMatch", "IONameMatched":
            // These come back as arrays of device-tree match strings. The
            // first entry is the primary match (`jpeg,t8110jpeg`), the
            // remainder are legacy/older-silicon aliases the kext also
            // binds against. Show the array contents joined with " · " so
            // the user gets the bus name + family at a glance instead of
            // a tuple-syntax `("jpeg,t8110jpeg","s5l8920x")`.
            return prettyCompatibleString(value)
        default: break
        }
        return value.display
    }
}

/// Render a `compatible` / `IONameMatch` array as a friendly inline list.
/// Handles three forms: a plain string, an array of strings, and a data
/// blob (some device-tree entries serialise the value as a NUL-separated
/// byte string instead of a CFArray).
nonisolated func prettyCompatibleString(_ value: IORegValue) -> String {
    switch value {
    case .string(let s):
        return s
    case .array(let arr):
        let strs: [String] = arr.compactMap {
            if case let .string(s) = $0 { return s }
            return nil
        }
        if strs.isEmpty { return value.display }
        return strs.joined(separator: " · ")
    case .data(let d):
        // The kernel sometimes serialises a NUL-separated device-tree
        // string array as raw bytes. Split on NUL and reconstitute.
        let pieces = d
            .split(separator: 0)
            .compactMap { String(data: Data($0), encoding: .utf8) }
            .filter { !$0.isEmpty }
        if pieces.isEmpty { return value.display }
        return pieces.joined(separator: " · ")
    default:
        return value.display
    }
}

/// Map the `Current Link Speed` field to a TB generation label.
///
/// Encoding (single value, NOT a bitmask on the Current field):
///   `0` = inactive
///   `0x8` = TB3 (10 Gb/s/lane)
///   `0x4` = USB4 / TB4 (20 Gb/s/lane)
///   `0x2` = TB5 / USB4 v2 (40 Gb/s/lane)
///
/// Mapping adapted from WhatCable
/// (Sources/WhatCableCore/IOThunderboltLink.swift:13-65, MIT, Copyright
/// (c) 2026 Darryl Morley). Anchored against Linux's
/// `drivers/thunderbolt/tb_regs.h`. Confirmed empirically on this host:
/// an active TB5 link reports `Current Link Speed = 2`, `Current Link
/// Width = 2` (dual lane), `Link Bandwidth = 800` → 80 Gb/s = 2 lanes ×
/// 40 Gb/s/lane (and the cable e-marker decodes to 80 Gb/s class too —
/// see `CableEmarkerInfo`).
///
/// PortScope's earlier mapping (`2 = TB3 Gen 2 20 Gb/s/lane`,
/// `8 = TB5 80 Gb/s/lane`) was empirically wrong — that combination
/// would imply 40 Gb/s total on the active link, but the kernel
/// reports 80.
nonisolated func tbLinkSpeedLabel(_ raw: UInt64) -> String {
    switch raw {
    case 0: return "Inactive"
    case 0x2: return "TB5 / USB4 v2 — 40 Gb/s per lane"
    case 0x4: return "TB4 / USB4 v1 — 20 Gb/s per lane"
    case 0x8: return "TB3 — 10 Gb/s per lane"
    default:
        // `Supported Link Speed` / `Target Link Speed` are bitmasks of
        // the above three values OR'd together (e.g. 14 = 0x8|0x4|0x2 =
        // "TB3 + TB4 + TB5 supported"). Decode any non-single value as
        // the bitmask form.
        return tbSupportedLinkSpeedLabel(raw)
    }
}

/// Per-lane Gb/s for a `Current Link Speed` raw value, or nil for
/// inactive / unknown. Useful when combining with `Current Link Width`
/// to derive total link bandwidth. Encoding per WhatCable
/// IOThunderboltLink.swift:32-39 (MIT, Copyright (c) 2026 Darryl Morley).
nonisolated func tbPerLaneGbps(speed raw: UInt64) -> Int? {
    switch raw {
    case 0x2: return 40
    case 0x4: return 20
    case 0x8: return 10
    default: return nil
    }
}

/// Decode `Supported Link Speed` / `Target Link Speed` as a bitmask of
/// the same single-value codes used by `Current Link Speed`. Bit `0x8` =
/// TB3, `0x4` = TB4, `0x2` = TB5. A value of 14 = `0x8|0x4|0x2` means
/// "supports all three" — the typical TB5 host advertisement. Per
/// WhatCable IOThunderboltLink.swift:68-97 (MIT, Copyright (c) 2026
/// Darryl Morley).
nonisolated func tbSupportedLinkSpeedLabel(_ raw: UInt64) -> String {
    if raw == 0 { return "—" }
    var parts: [String] = []
    if raw & 0x2 != 0 { parts.append("TB5") }
    if raw & 0x4 != 0 { parts.append("TB4") }
    if raw & 0x8 != 0 { parts.append("TB3") }
    if parts.isEmpty { return "Raw 0x\(String(raw, radix: 16))" }
    return parts.joined(separator: " · ")
}

/// Short link generation label used in sidebars and dense rows.
///
/// Same single-value encoding as `tbLinkSpeedLabel`. Mapping per
/// WhatCable IOThunderboltLink.swift:13-65 (MIT, Copyright (c) 2026
/// Darryl Morley).
nonisolated func tbGenerationShortLabel(_ raw: UInt64) -> String {
    switch raw {
    case 0: return "Inactive"
    case 0x2: return "TB5"
    case 0x4: return "TB4"
    case 0x8: return "TB3"
    default: return tbSupportedLinkSpeedLabel(raw)
    }
}

/// Decode `Current Link Width` as a bitmask. Per WhatCable
/// IOThunderboltLink.swift:99-138 (MIT, Copyright (c) 2026 Darryl
/// Morley):
///   `0x1` = single lane
///   `0x2` = dual lane (the symmetric case)
///   `0x4` = asymmetric TX (3 TX / 1 RX) — TB5 only
///   `0x8` = asymmetric RX (1 TX / 3 RX) — TB5 only
///
/// Note: this is NOT the same encoding as `Target Link Width`, which
/// uses `0x1` = single, `0x3` = dual (no asymmetric values). See
/// `tbTargetLinkWidthLabel`.
nonisolated func tbCurrentLinkWidthLabel(_ raw: UInt64) -> String {
    if raw == 0 { return "Inactive" }
    let (tx, rx) = tbCurrentLinkLanes(raw)
    if tx == rx { return "\(tx)× \(tx == 1 ? "lane" : "lanes")" }
    return "\(tx) TX / \(rx) RX (asymmetric)"
}

/// Number of active TX and RX lanes for a `Current Link Width` value.
nonisolated func tbCurrentLinkLanes(_ raw: UInt64) -> (tx: Int, rx: Int) {
    let asymTx = raw & 0x4 != 0
    let asymRx = raw & 0x8 != 0
    let dual = raw & 0x2 != 0
    let single = raw & 0x1 != 0
    let tx: Int
    let rx: Int
    if asymTx { tx = 3; rx = 1 }
    else if asymRx { tx = 1; rx = 3 }
    else if dual { tx = 2; rx = 2 }
    else if single { tx = 1; rx = 1 }
    else { tx = 0; rx = 0 }
    return (tx, rx)
}

/// Decode `Target Link Width`. Per WhatCable IOThunderboltLink.swift:140-156
/// (MIT, Copyright (c) 2026 Darryl Morley) — the spec uses a DIFFERENT
/// encoding here: `0x1` = single, `0x3` = dual. So a value of `0x3`
/// here means "negotiated dual lane," NOT "asymmetric."
nonisolated func tbTargetLinkWidthLabel(_ raw: UInt64) -> String {
    switch raw {
    case 0: return "—"
    case 0x1: return "Single lane"
    case 0x3: return "Dual lane"
    default: return "Raw 0x\(String(raw, radix: 16))"
    }
}

/// Combine `Current Link Speed` + `Current Link Width` into a single
/// negotiated-rate label like `"Up to 40 Gb/s × 2 lanes (80 Gb/s)"`.
/// Returns nil when either field is inactive. Useful for rendering the
/// active TB lane adapter row in a compact form.
nonisolated func tbCurrentLinkRateLabel(speed: UInt64, width: UInt64) -> String? {
    guard speed != 0, width != 0 else { return nil }
    guard let perLane = tbPerLaneGbps(speed: speed) else { return nil }
    let (tx, rx) = tbCurrentLinkLanes(width)
    let symmetric = (tx == rx)
    if symmetric {
        let total = perLane * tx
        return "Up to \(perLane) Gb/s × \(tx) \(tx == 1 ? "lane" : "lanes") (\(total) Gb/s)"
    }
    let txTotal = perLane * tx
    let rxTotal = perLane * rx
    return "Up to \(perLane) Gb/s × asymmetric (\(txTotal) Gb/s TX, \(rxTotal) Gb/s RX)"
}

/// Format a "Link Bandwidth" raw value as a human bandwidth string. Field is
/// in 100 Mb/s units. Anything below 1 Gb/s is rendered in Mb/s — "100 Mb/s"
/// reads better than "0.1 Gb/s".
nonisolated func tbBandwidthLabel(_ raw: UInt64) -> String {
    if raw == 0 { return "0 Gb/s" }
    if raw < 10 {
        return "\(raw * 100) Mb/s"
    }
    let gbps = Double(raw) / 10.0
    return String(format: "%.0f Gb/s", gbps)
}

/// Snapshot of the entire Thunderbolt subsystem captured at scan time.
nonisolated struct TBSnapshot {
    let capturedAt: Date
    let controllers: [TBNode]
    let pcieDevicesOverTB: [TBNode]
    let usbDevicesOverTB: [TBNode]

    static let empty = TBSnapshot(capturedAt: .distantPast, controllers: [], pcieDevicesOverTB: [], usbDevicesOverTB: [])
}
