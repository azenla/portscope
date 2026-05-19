//
//  PCIModels.swift
//  PortScope
//
//  Domain model for the PCIe subsystem. On Apple Silicon laptops the root
//  complex has a handful of dedicated host bridges (`apcie-bridge` /
//  `ApplePCIEHostBridge`) feeding fixed-function endpoints — Wi-Fi,
//  Bluetooth, SD card reader, the three Thunderbolt downstream slots — plus
//  the internal NAND controller which sits on its own bus. The same data
//  on Intel Macs is decorated with vendor names from the kernel's PCI
//  database; on Apple Silicon we fall back to a small built-in lookup.
//

import Foundation
import SwiftUI

nonisolated struct PCISnapshot {
    /// Root host bridges + their downstream tree. Empty on Macs without
    /// PCIe (e.g. Intel-virtualized hosts).
    let roots: [PCINode]

    static let empty = PCISnapshot(roots: [])

    /// Flat count of non-bridge devices in the tree.
    var endpointCount: Int {
        var c = 0
        for r in roots { c += countEndpoints(in: r) }
        return c
    }

    private func countEndpoints(in n: PCINode) -> Int {
        let self_ = n.kind == .endpoint ? 1 : 0
        return self_ + n.children.reduce(0) { $0 + countEndpoints(in: $1) }
    }
}

nonisolated struct PCINode: Hashable, Identifiable {
    var id: TBNodeID { backingID }

    /// IORegistry entry ID — used to resolve back to the raw TBNode for the
    /// Developer-details disclosure.
    let backingID: TBNodeID
    let node: TBNode

    let kind: PCIKind
    /// Friendly name, e.g. "Wi-Fi (Broadcom BCM4387)", "SD Card Reader",
    /// "Thunderbolt Bridge 0".
    let title: String
    let subtitle: String?

    /// PCI vendor / device numeric IDs from the IORegistry property dict.
    let vendorID: UInt16?
    let deviceID: UInt16?
    let subsystemVendorID: UInt16?
    let subsystemDeviceID: UInt16?

    /// Decoded class/subclass/programming-interface from `class-code`.
    let classCode: UInt8?
    let subclassCode: UInt8?
    let progIF: UInt8?

    /// Negotiated link speed (1=2.5GT/s, 2=5GT/s, 3=8GT/s, 4=16GT/s, 5=32GT/s
    /// for PCIe 1.0/2.0/3.0/4.0/5.0). Optional — bridges may not report it.
    let linkSpeed: UInt64?
    /// Negotiated link width (×1, ×2, ×4, ×8).
    let linkWidth: UInt64?
    /// Maximum link speed the slot supports.
    let maxLinkSpeed: UInt64?
    /// Maximum link width the slot supports.
    let maxLinkWidth: UInt64?

    /// PCI BDF (bus:device:function) from `pcidebug`.
    let bdf: String?
    /// Slot label from `AAPL,slot-name`, when present.
    let slotName: String?

    /// True for an Apple-internal device (the bus is on the SoC fabric).
    let isBuiltIn: Bool

    let children: [PCINode]
}

nonisolated enum PCIKind: String {
    case rootBridge   // pci-bridge0 at depth 0
    case bridge       // pci-bridge / pcic*-bridge children
    case endpoint     // leaf device (wlan, sdreader, NVMe, …)

    var symbol: String {
        switch self {
        case .rootBridge: return "rectangle.connected.to.line.below"
        case .bridge:     return "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .endpoint:   return "square.stack.3d.up.fill"
        }
    }

    var color: Color {
        switch self {
        case .rootBridge: return .blue
        case .bridge:     return .indigo
        case .endpoint:   return .green
        }
    }
}

/// Format a PCIe link speed code into a human-readable rate.
nonisolated func pciLinkSpeedLabel(_ speed: UInt64) -> String {
    switch speed {
    case 1: return "PCIe 1.0 (2.5 GT/s)"
    case 2: return "PCIe 2.0 (5 GT/s)"
    case 3: return "PCIe 3.0 (8 GT/s)"
    case 4: return "PCIe 4.0 (16 GT/s)"
    case 5: return "PCIe 5.0 (32 GT/s)"
    case 6: return "PCIe 6.0 (64 GT/s)"
    default: return "Gen \(speed)"
    }
}

/// Short label for tight spaces.
nonisolated func pciLinkSpeedShortLabel(_ speed: UInt64) -> String {
    switch speed {
    case 1: return "Gen 1"
    case 2: return "Gen 2"
    case 3: return "Gen 3"
    case 4: return "Gen 4"
    case 5: return "Gen 5"
    case 6: return "Gen 6"
    default: return "Gen \(speed)"
    }
}
