//
//  AccessoryModels.swift
//  PortScope
//
//  Domain types for the per-physical-port state Apple's IOAccessoryManager
//  exposes through `AppleHPMInterfaceType10`. One instance exists for every
//  physical USB-C / MagSafe receptacle on the host; it carries runtime info
//  (active transports, USB-PD power, plug orientation, cable e-marker, etc.)
//  that's invisible to the Thunderbolt and USB IOKit families.
//

import Foundation
import SwiftUI

/// Receptacle type reported by `PortTypeDescription`. Apple's
/// `IOAccessoryManager` publishes one of these strings on every chassis
/// receptacle it manages (USB-C on Apple Silicon, USB-A on desktops that
/// ship with rear A-jacks, MagSafe 3 on the relevant laptops).
nonisolated enum PortConnectorType: Hashable {
    case usbC
    case usbA
    case magsafe
    case hdmi
    case sdCard
    /// Built-in AC power input on desktop Macs (Mac mini, iMac, Mac Studio,
    /// Mac Pro). Measured wattage comes from `AppleSmartBattery`'s
    /// `PowerTelemetryData` — the same telemetry source the kernel uses to
    /// drive battery-less power reporting.
    case acPower
    /// Built-in RJ-45 Ethernet jack. Link state + speed come from the
    /// `IOEthernetController` driver class (e.g. `BCM5701Enet` on Apple
    /// Silicon, AppleAVE2 on M2/M3 internal). Excludes USB / TB-tunneled
    /// adapters — those show up under their connecting USB-C port.
    case ethernet
    case other(String)

    init(_ description: String?) {
        switch description {
        case "USB-C": self = .usbC
        case "USB-A": self = .usbA
        case "MagSafe 3": self = .magsafe
        case "HDMI": self = .hdmi
        case "SD", "SD Card", "SDXC": self = .sdCard
        case "AC Power", "Power": self = .acPower
        case "Ethernet", "RJ-45": self = .ethernet
        case let .some(d): self = .other(d)
        case .none: self = .other("Unknown")
        }
    }

    var label: String {
        switch self {
        case .usbC: return "USB-C"
        case .usbA: return "USB-A"
        case .magsafe: return "MagSafe 3"
        case .hdmi: return "HDMI"
        case .sdCard: return "SD Card"
        case .acPower: return "AC Power"
        case .ethernet: return "Ethernet"
        case .other(let s): return s
        }
    }

    var symbol: String {
        switch self {
        case .usbC: return "cable.connector"
        case .usbA: return "cable.connector.horizontal"
        case .magsafe: return "powerplug.fill"
        case .hdmi: return "tv"
        case .sdCard: return "sdcard"
        case .acPower: return "bolt.fill"
        case .ethernet: return "cable.coaxial"
        case .other: return "questionmark.circle"
        }
    }
}

/// What's plugged into the port, in plain language. Mapped from
/// `IOAccessoryUSBConnectString`.
nonisolated enum AccessoryConnection: Hashable {
    case none
    case device
    case host
    case audioAdapter
    case debug
    case other(String)

    init(_ raw: String?) {
        switch raw {
        case "None", nil: self = .none
        case "Device": self = .device
        case "Host": self = .host
        case "Audio Adapter": self = .audioAdapter
        case "Debug": self = .debug
        case .some(let v): self = .other(v)
        }
    }

    var label: String {
        switch self {
        case .none: return "Nothing connected"
        case .device: return "Device connected"
        case .host: return "Host connected"
        case .audioAdapter: return "Audio adapter"
        case .debug: return "Debug accessory"
        case .other(let s): return s
        }
    }

    var isConnected: Bool {
        if case .none = self { return false }
        return true
    }
}

/// Cable orientation, derived from `PlugOrientation`. Tells you whether the
/// cable is inserted "right-side up" or flipped — useful for matching kernel
/// state against the visible cable.
nonisolated enum PlugOrientation: Hashable {
    case unflipped     // 1
    case flipped       // 2
    case unattached    // 0
    case unknown(UInt64)

    init(_ raw: UInt64?) {
        switch raw {
        case 0, .none: self = .unattached
        case 1: self = .unflipped
        case 2: self = .flipped
        case .some(let v): self = .unknown(v)
        }
    }

    var label: String {
        switch self {
        case .unattached: return "—"
        case .unflipped: return "Normal"
        case .flipped: return "Reversed"
        case .unknown: return "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .unattached: return "circle.dashed"
        case .unflipped: return "arrow.up"
        case .flipped: return "arrow.down"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// One of the signals the kernel can route over a USB-C connector. Values
/// observed in `TransportsSupported / Provisioned / Active` arrays.
nonisolated enum USBCTransport: Hashable, CaseIterable {
    case cc              // CC = USB-PD configuration channel
    case usb2            // USB 2.0 D+/D− pair
    case usb3            // USB 3 SuperSpeed pair
    case cio             // "Cooperative I/O" — the bundle that carries Thunderbolt/USB4
    case displayPort     // DisplayPort alt-mode
    case other(String)

    static var allCases: [USBCTransport] {
        [.cc, .usb2, .usb3, .cio, .displayPort]
    }

    init(_ raw: String) {
        switch raw {
        case "CC": self = .cc
        case "USB2": self = .usb2
        case "USB3": self = .usb3
        case "CIO": self = .cio
        case "DisplayPort": self = .displayPort
        default: self = .other(raw)
        }
    }

    var label: String {
        switch self {
        case .cc: return "USB-PD"
        case .usb2: return "USB 2.0"
        case .usb3: return "USB 3"
        case .cio: return "Thunderbolt / USB4"
        case .displayPort: return "DisplayPort"
        case .other(let s): return s
        }
    }

    var detail: String {
        switch self {
        case .cc: return "Configuration channel for power & alt-mode negotiation"
        case .usb2: return "Legacy 480 Mb/s USB pair, always available"
        case .usb3: return "SuperSpeed USB lane (≥5 Gb/s)"
        case .cio: return "High-speed lane carrying Thunderbolt / USB4 / DisplayPort tunnels"
        case .displayPort: return "DisplayPort alt-mode signal pair"
        case .other: return "Vendor-defined transport"
        }
    }

    var symbol: String {
        switch self {
        case .cc: return "bolt.circle"
        case .usb2: return "cable.connector"
        case .usb3: return "cable.connector.horizontal"
        case .cio: return "bolt.horizontal.circle.fill"
        case .displayPort: return "display"
        case .other: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .cc: return .yellow
        case .usb2: return .gray
        case .usb3: return .teal
        case .cio: return .blue
        case .displayPort: return .pink
        case .other: return .secondary
        }
    }
}

/// One USB-PD Power Data Object (fixed voltage). Mapped from each
/// `PowerSourceOptions` entry under the "USB-PD" feature.
nonisolated struct USBPDOption: Hashable, Identifiable {
    let id: UUID
    let voltageMV: UInt64
    let maxCurrentMA: UInt64
    let maxPowerMW: UInt64

    init(voltageMV: UInt64, maxCurrentMA: UInt64, maxPowerMW: UInt64, id: UUID = UUID()) {
        self.voltageMV = voltageMV
        self.maxCurrentMA = maxCurrentMA
        self.maxPowerMW = maxPowerMW
        self.id = id
    }

    var voltageLabel: String { String(format: "%.0f V", Double(voltageMV) / 1000.0) }
    var currentLabel: String { String(format: "%.2g A", Double(maxCurrentMA) / 1000.0) }
    var powerLabel: String {
        let w = Double(maxPowerMW) / 1000.0
        return w >= 10 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }
}

/// Aggregated USB-PD info for a single physical port.
nonisolated struct USBPDProfile: Hashable {
    /// The PDO the source and sink agreed on (active power draw).
    let winning: USBPDOption?
    /// All PDOs the source advertised.
    let offered: [USBPDOption]
    /// Apple's "Brick ID" PDO, present when an Apple charger is identifying itself.
    let brickID: USBPDOption?
}

/// Snapshot of the runtime state on one physical receptacle.
nonisolated struct PortAccessoryInfo: Identifiable, Hashable {
    /// IORegistry entry ID of the `AppleHPMInterfaceType10` instance.
    let id: TBNodeID
    /// `PortNumber` field — the canonical physical port label (1, 2, 3 …).
    let portNumber: Int
    let connector: PortConnectorType
    /// Plain-English connection state (Device / Host / Audio adapter / None).
    let connection: AccessoryConnection
    /// True iff the port has a load currently driving it.
    let connectionActive: Bool
    /// True iff the kernel can see something physically present.
    let detected: Bool
    let plugOrientation: PlugOrientation
    /// Which transports the connector + cable + remote partner could in
    /// theory carry. A superset of `provisioned` and `active`.
    let supportedTransports: Set<USBCTransport>
    /// Transports the kernel has set up routing for after negotiation.
    let provisionedTransports: Set<USBCTransport>
    /// Transports actually carrying data right now.
    let activeTransports: Set<USBCTransport>
    /// DisplayPort hot-plug-detect line — true when a display is attached.
    let hpdAsserted: Bool
    /// Pin assignment for DP alt-mode (0 = none; 1..6 = A..F).
    let displayPortPinAssignment: UInt64
    let activeCable: Bool
    let opticalCable: Bool
    /// Number of cable insertions seen since boot.
    let connectionCount: UInt64
    /// Total plug events (insert + remove).
    let plugEventCount: UInt64
    /// Number of overcurrent events on this port.
    let overcurrentCount: UInt64
    /// Vendor ID returned by the cable e-marker (USB-PD SOP).
    let cableVendorID: UInt64?
    /// Product ID returned by the cable e-marker.
    let cableProductID: UInt64?
    /// Cable manufacturer string (often the e-marker silicon vendor).
    let cableManufacturer: String?
    /// Structured decode of the cable's near-end e-marker (SOP'), when one
    /// is present. Carries the cable speed class, current rating, max
    /// VBUS, EPR capability, active vs passive, optical vs copper,
    /// retimer vs redriver, and any spec-violation tells. Decoded from
    /// the `Metadata.VDOs` array the kernel publishes on the
    /// `IOPortTransportComponentCCUSBPDSOP*` services. See
    /// `USBPDVDOModels.swift` (decoder adapted from WhatCable, MIT,
    /// Copyright (c) 2026 Darryl Morley).
    let cableEmarker: CableEmarkerInfo?
    /// Negotiated USB 3 generation read from the per-port
    /// `IOPortTransportStateUSB3` service, when one exists. Provides a
    /// port-side view distinct from device-side `bcdUSB` /
    /// `kUSBCurrentSpeed`. Decoder adapted from WhatCable
    /// (Sources/WhatCableCore/USB3Transport.swift, MIT, Copyright (c)
    /// 2026 Darryl Morley).
    let usb3State: USB3TransportState?
    /// Thunderbolt controller's own cable assessment, read from
    /// `IOPortTransportStateCIO`. Independent of, and sometimes
    /// contradicts, the cable e-marker. Decoder adapted from WhatCable
    /// (Sources/WhatCableCore/CIOCableCapability.swift, MIT, Copyright
    /// (c) 2026 Darryl Morley).
    let cioState: CIOCableState?
    /// Per-lane PHY state — `AppleT*TypeCPhy` services publish per-port
    /// dictionaries with each lane's transport assignment (CIO / DP /
    /// USB3 / idle). Authoritative source for "this port is running
    /// CIO on 2 lanes and DP on the other 2," which the HPM
    /// `TransportsActive` array can't disambiguate. Decoder adapted from
    /// WhatCable (Sources/WhatCableCore/AppleTypeCPhy.swift, MIT,
    /// Copyright (c) 2026 Darryl Morley).
    let phyState: PhyState?
    let usbPD: USBPDProfile?
    /// Raw IORegistry properties of the `AppleHPMInterfaceType10` entry, kept
    /// for the Developer details disclosure.
    let registryProperties: [String: IORegValue]
    /// IOService-plane registry path of the accessory entry (e.g.
    /// `"IOService:/AppleARMPE/port-usb-a-1/Port-USB-A@1"`). The xHCI port
    /// wrappers below external USB controllers carry a `UsbIOPort` property
    /// whose string value matches this path — that's how we attribute USB
    /// devices to a USB-A receptacle. Nil only if `IORegistryEntryGetPath`
    /// failed (shouldn't happen in practice).
    let registryPath: String?

    /// Whether this port is currently carrying Thunderbolt / USB4 (CIO transport).
    var carriesThunderbolt: Bool { activeTransports.contains(.cio) }
    /// Whether this port is actively driving a display via USB-C alt-mode.
    /// Requires both the connection to be live *and* a real DP signal:
    ///   * DisplayPort in `activeTransports` (kernel's authoritative "DP is
    ///     running on this connector" flag), or
    ///   * a non-zero `DisplayPortPinAssignment` (DP alt-mode pin layout
    ///     successfully negotiated on the connector's CC lines).
    ///
    /// `HPDAsserted` alone is not sufficient — the kernel raises HPD for
    /// non-display partners too (e.g. a Linux/PC peer in Thunderbolt-
    /// networking mode reads `HPDAsserted = true` while no DP is provisioned
    /// or active), and HPD also lingers after a display is unplugged.
    ///
    /// Per-PHY `dpLinks` / `dpTunnels` aren't connector-level signals —
    /// they report DP traffic flowing through the PHY's CIO lanes (e.g. the
    /// internal panel routed through atc0's DP-IN adapter), so they fire on
    /// the controller hosting the internal display even when no monitor is
    /// plugged into that USB-C connector. Display-tunneled (dock-attached)
    /// panels are surfaced via `portCarriesAnyDisplay`'s tunnels branch
    /// instead.
    var carriesDisplay: Bool {
        guard connectionActive else { return false }
        if activeTransports.contains(.displayPort) { return true }
        if displayPortPinAssignment > 0 { return true }
        return false
    }

    /// Vendor & product label, e.g. `"Infineon (VID 0x291A · PID 0x83B5)"`.
    var cableLabel: String? {
        let parts: [String] = [
            cableManufacturer,
            cableVendorID.map { String(format: "VID 0x%04X", $0) },
            cableProductID.map { String(format: "PID 0x%04X", $0) }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// DisplayPort pin assignment label.
///
/// The kernel's `DisplayPortPinAssignment` integer is NOT the raw USB-IF
/// Type-C alt-mode spec value — Apple publishes a smaller Apple-specific
/// encoding that only covers the pin assignments modern hardware actually
/// negotiates (USB-IF Pin Assignments A and B are deprecated). Encoding
/// adopted from WhatCable (Sources/WhatCableCore/DisplayPortLaneConfig.swift,
/// MIT, Copyright (c) 2026 Darryl Morley), where it was confirmed
/// empirically on Apple Silicon Macs:
///
///   0 = no DP alt mode active
///   1 = Pin Assignment C (4-lane DP, no USB 3)
///   2 = Pin Assignment D (2-lane DP + USB 3)
///   3 = Pin Assignment E (4-lane DP, flipped orientation)
///   4 = Pin Assignment F (2-lane DP + USB 3, flipped)
///
/// PortScope previously used the USB-IF spec values directly (1=A...6=F)
/// which didn't match what Apple's kernel publishes. The new encoding
/// makes "4-lane vs 2-lane" reads correct.
nonisolated func displayPortPinAssignmentLabel(_ raw: UInt64) -> String {
    switch raw {
    case 0: return "None"
    case 1: return "C — 4-lane DP (no USB 3)"
    case 2: return "D — 2-lane DP + USB 3"
    case 3: return "E — 4-lane DP (flipped)"
    case 4: return "F — 2-lane DP + USB 3 (flipped)"
    default: return "Assignment \(raw)"
    }
}

/// Decoded DP lane count from `DisplayPortPinAssignment`. Returns 4
/// (Pin Assignments C / E), 2 (D / F), or nil (no DP / unknown).
/// Encoding per WhatCable DisplayPortLaneConfig.swift:23-37 (MIT,
/// Copyright (c) 2026 Darryl Morley).
nonisolated func displayPortLaneCount(_ raw: UInt64) -> Int? {
    switch raw {
    case 1, 3: return 4
    case 2, 4: return 2
    default: return nil
    }
}
