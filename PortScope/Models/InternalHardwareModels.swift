//
//  InternalHardwareModels.swift
//  PortScope
//
//  Models for the "Internal Hardware" sidebar section — non-removable buses
//  and devices that live on the SoC fabric: I²C, SPI/QSPI controllers, the
//  internal Smart Battery, and the MagSafe 3 receptacle. The MagSafe slot is
//  a peer to the USB-C receptacles in IOAccessory plane (HPM Type11 vs
//  Type10) but it doesn't carry data — it lives here because it's part of
//  the laptop chassis, not an expansion port.
//

import Foundation

/// Static snapshot of the internal-fabric hardware. Built once per rescan by
/// `InternalHardwareScanner`. Anything the user can't unplug lives here.
nonisolated struct InternalHardwareSnapshot {
    /// Chassis-wide "About this Mac" overview (chip, cores, RAM, internal
    /// SSD, OS / firmware versions). Populated by `SystemInfoScanner` —
    /// the data combines `sysctl`, `IOPlatformExpertDevice`, and a handful
    /// of `system_profiler` calls. Always present (with mostly-nil fields)
    /// even on the empty snapshot so the view code can render it
    /// unconditionally.
    let systemInfo: SystemInfoSnapshot
    /// I²C controllers (one per physical bus). Children are the slaves on the
    /// bus and their attached drivers.
    let i2cBuses: [TBNode]
    /// SPI and QSPI controllers.
    let spiBuses: [TBNode]
    /// AppleSmartBatteryManager subtree (battery manager + battery node).
    /// Nil on desktop hardware without a battery.
    let batteryManager: TBNode?
    /// MagSafe 3 receptacle accessory state (AppleHPMInterfaceType11).
    /// Nil on chassis without a MagSafe port. The `PortAccessoryInfo` carries
    /// the live charging / cable info when plugged in.
    let magsafe: PortAccessoryInfo?
    /// Named SoC blocks pulled out of the `AppleARMIODevice` haystack —
    /// Secure Enclave, Always-On Processor, Apple Neural Engine, display /
    /// video / image-signal coprocessors, NAND controller, SMC, etc.
    /// Grouped by function so the sidebar can render them as small,
    /// thematic subsections rather than one long alphabetical list.
    let coprocessorGroups: [SoCCoprocessorGroup]

    /// Flat view across all groups, in display order. Lookup helper used
    /// when resolving sidebar selections to nodes.
    var socCoprocessors: [TBNode] {
        coprocessorGroups.flatMap(\.coprocessors)
    }

    static let empty = InternalHardwareSnapshot(
        systemInfo: .empty,
        i2cBuses: [], spiBuses: [], batteryManager: nil, magsafe: nil,
        coprocessorGroups: []
    )
}

/// A thematic bucket of SoC coprocessors. The grouping mirrors how a user
/// would naturally reason about the silicon: display engines together,
/// media codecs together, security blocks together, etc.
nonisolated struct SoCCoprocessorGroup: Hashable, Identifiable {
    var id: SoCCoprocessorCategory { category }
    let category: SoCCoprocessorCategory
    let coprocessors: [TBNode]
}

nonisolated enum SoCCoprocessorCategory: String, CaseIterable, Hashable {
    case displayAndGraphics
    case mediaImage
    case mediaVideo
    case storageMemory
    case securityPower
    case radios
    case other

    var title: String {
        switch self {
        case .displayAndGraphics: return "Display & Graphics"
        case .mediaImage:         return "Image / ML"
        case .mediaVideo:         return "Video Codecs"
        case .storageMemory:      return "Storage & Memory"
        case .securityPower:      return "Security & Power"
        case .radios:             return "Radios"
        case .other:              return "Other Coprocessors"
        }
    }

    /// Promoted section name now that these render as top-level sidebar
    /// sections, not subgroups under a single "Internal Hardware" wrapper.
    /// The thematic groupings carry the same intent but the labels lose the
    /// "subgroup of internals" framing so they read like first-class
    /// sections (`Graphics`, `Image & ML`, `Codecs`, `Coprocessors`).
    var topLevelTitle: String {
        switch self {
        case .displayAndGraphics: return "Graphics"
        case .mediaImage:         return "Image & ML"
        case .mediaVideo:         return "Codecs"
        case .storageMemory:      return "Storage Controllers"
        case .securityPower:      return "Security & Power"
        case .radios:             return "Radio Coprocessors"
        case .other:              return "Coprocessors"
        }
    }

    var symbol: String {
        switch self {
        case .displayAndGraphics: return "rectangle.on.rectangle"
        case .mediaImage:         return "photo.stack"
        case .mediaVideo:         return "film"
        case .storageMemory:      return "internaldrive"
        case .securityPower:      return "lock.shield"
        case .radios:             return "antenna.radiowaves.left.and.right"
        case .other:              return "cpu"
        }
    }
}
