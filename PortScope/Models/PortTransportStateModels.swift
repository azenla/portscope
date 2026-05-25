//
//  PortTransportStateModels.swift
//  PortScope
//
//  Dynamic per-port transport-state services published by IOKit. These
//  services appear when a device is connected on a USB-C receptacle and
//  disappear on unplug:
//
//   - `IOPortTransportStateUSB3` — precise USB 3 generation (Gen 1
//     5 Gb/s vs Gen 2 10 Gb/s) negotiated on the port, distinct from
//     the device-side `bcdUSB` / `kUSBCurrentSpeed` readings.
//   - `IOPortTransportStateCIO`  — the Thunderbolt controller's own
//     assessment of the connected cable: TB3/4/5 capability,
//     asymmetric-mode advertisement. Independent of, and sometimes
//     contradicts, the cable's USB-PD e-marker.
//
//  Both join back to a `PortAccessoryInfo` via
//  `"<parentPortType>/<parentPortNumber>"` — the `portKey` shape
//  WhatCable uses across its watchers
//  (Sources/WhatCableCore/PowerSource.swift:71-82,
//  Sources/WhatCableDarwinBackend/USB3TransportWatcher.swift:96-102,
//  TRMTransportWatcher.swift:195-203; MIT, Copyright (c) 2026 Darryl
//  Morley).
//
//  Model shapes (field names, sentinel handling, label formatting) adapted
//  from WhatCable Sources/WhatCableCore/USB3Transport.swift and
//  CIOCableCapability.swift (MIT, Copyright (c) 2026 Darryl Morley).
//

import Foundation

/// USB 3 SuperSpeed link state read from `IOPortTransportStateUSB3`.
/// The kernel publishes one such service per active USB 3 link on a
/// USB-C port. Tunneled-over-TB USB 3 produces a transport service whose
/// signaling reads as 0 ("None" sentinel) — see `speedLabel` for the
/// rationale.
nonisolated struct USB3TransportState: Hashable {
    /// Raw `SuperSpeedSignaling` value. 0 = None sentinel (no negotiated
    /// SuperSpeed link), 1 = Gen 1 (5 Gb/s), 2 = Gen 2 (10 Gb/s).
    let signaling: Int
    /// Description string the kernel publishes alongside the integer,
    /// e.g. `"Gen 1"` / `"Gen 2"` / `"None"`.
    let signalingDescription: String?
    /// `DataRole` / `PortDataRole` value, when published. Typical values:
    /// `"host"`, `"device"`.
    let dataRole: String?

    /// User-facing label for the negotiated USB 3 speed, or `nil` if no
    /// live SuperSpeed link is present. Mirrors WhatCable's USB3Transport
    /// sentinel handling at Sources/WhatCableCore/USB3Transport.swift:51-59:
    /// `signaling == 0` means "no live USB 3 signaling" (common on
    /// CIO-tunneled USB 3 and idle USB-C ports that expose a transport
    /// service but never negotiated SuperSpeed).
    var speedLabel: String? {
        switch signaling {
        case 0: return nil
        case 1: return "USB 3.2 Gen 1 (5 Gb/s)"
        case 2: return "USB 3.2 Gen 2 (10 Gb/s)"
        default: return "USB 3.2 Gen \(signaling)"
        }
    }

    var hasLiveLink: Bool { signaling > 0 }
}

/// Thunderbolt controller's view of the cable, read from
/// `IOPortTransportStateCIO`. This is a separate, complementary signal to
/// the USB-PD e-marker — the CIO controller can correctly identify
/// some active TB4 cables that mis-self-report as "passive" in the
/// e-marker (the CalDigit 2 m case documented in WhatCable
/// CIOCableCapability.swift:8-19).
nonisolated struct CIOCableState: Hashable {
    /// Cable speed capability per CIO. Confirmed encoding (from real
    /// probes across TB3/4/5 — WhatCable CIOCableCapability.swift:78-93):
    ///
    ///   2 → 20 Gb/s (TB3 class)
    ///   3 → 40 Gb/s (TB4 class)
    ///   4 → 80 Gb/s (TB5 class)
    ///
    /// Other values are surfaced raw because the encoding is not fully
    /// documented; do not derive a generation label from unknown codes.
    let cableSpeed: Int?
    /// Raw CIO `CableGeneration` / `Generation` fields. WhatCable's
    /// research explicitly warns these do NOT track the Thunderbolt
    /// generation (they vary per port on the same machine), so PortScope
    /// stores them raw without deriving a label. See
    /// CIOCableCapability.swift:25-39.
    let cableGenerationRaw: Int?
    let generationRaw: Int?
    /// `AsymmetricModeSupported` flag. WhatCable
    /// CIOCableCapability.swift:40-48 documents that this is a static
    /// port-capability advertisement (`PORT_CS_18.CSA` in the Linux
    /// thunderbolt driver), NOT a runtime "will negotiate asymmetric"
    /// signal. Apple Silicon sets it across the family including Type5
    /// hosts that can't run Gen 4 — so it should be surfaced as
    /// "port advertises asymmetric capability," not "host supports
    /// asymmetric mode."
    let asymmetricModeSupported: Bool?
    /// Raw CIO `LegacyAdapter` / `LinkTrainingMode` values. Meaning TBD;
    /// stored raw.
    let legacyAdapter: Bool?
    let linkTrainingMode: Int?

    /// Human-readable label for a confirmed `cableSpeed` value, or `nil`
    /// when the code is unknown. Mirrors WhatCable
    /// CIOCableCapability.swift:78-93.
    var cableSpeedLabel: String? {
        guard let cs = cableSpeed else { return nil }
        switch cs {
        case 2: return "20 Gb/s (TB3 class)"
        case 3: return "40 Gb/s (TB4 class)"
        case 4: return "80 Gb/s (TB5 class)"
        default: return nil
        }
    }
}

/// Per-port PHY state read from `AppleT*TypeCPhy` services. The PHY
/// publishes per-lane transport assignment ("Lane 0 carries CIO, Lane 1
/// carries DisplayPort") — the authoritative answer for 2-lane vs
/// 4-lane DP-Alt on a USB-C port simultaneously running CIO and DP.
/// `HPM.TransportsActive` only tells you *which* transports are running,
/// not how many lanes each consumes.
///
/// Field shapes (per-lane sub-dict layout with `Transport` / `Power Level`
/// / `Client` keys, plus the dedicated USB2 and DisplayPort sub-dicts)
/// adapted from WhatCable
/// (Sources/WhatCableCore/AppleTypeCPhy.swift, MIT, Copyright (c) 2026
/// Darryl Morley). The candidate-class list is extended with
/// `AppleT6050TypeCPhy` (M4 Pro) which is not present in WhatCable's
/// upstream — confirmed empirically on this hardware to publish the
/// identical schema.
nonisolated struct PhyLaneState: Hashable {
    let index: Int
    /// `Transport` value the PHY publishes. Observed values: `"CIO"`,
    /// `"DisplayPort"`, `"USB3"`, empty string for idle. Stored raw so
    /// new transports added in future kernels don't get dropped.
    let transport: String
    /// `Power Level` value. Observed: `"on"`, empty for off.
    let powerLevel: String
    /// `Client` string — the driver name the lane is bound to. Useful
    /// for identifying which TB controller (NHIType7 vs Type5 etc.) or
    /// DP adapter is consuming the lane.
    let client: String

    var isLive: Bool { !transport.isEmpty && powerLevel == "on" }
}

nonisolated struct PhyDPLink: Hashable {
    /// `Link Rate` string as published by the kernel (e.g.
    /// `"5.40Gbps/lane (HBR2)"`).
    let linkRate: String
    /// Client driver name attached to this link, when published. Lets
    /// the UI say "this DP tunnel feeds AppleATCDPINAdapterPort(atc0-dpin0)."
    let client: String?
}

nonisolated struct PhyState: Hashable {
    /// `AppleTypeCPhyID` — port index 0..N-1. PortScope's HPM
    /// `PortNumber` is 1..N, so `portNumber == id + 1` on every
    /// machine observed to date (Mac mini M4 Pro, MacBook Pro M3+ per
    /// WhatCable's research).
    let id: Int
    /// Per-lane assignments. Typically 2 lanes (Lane 0, Lane 1); some
    /// silicon may publish more.
    let lanes: [PhyLaneState]
    /// USB 2.0 transport row when present.
    let usb2Transport: String?
    let usb2Client: String?
    /// Active DP link rate(s). Some kernels publish a flat
    /// `Link Rate` directly; others publish a sub-dict
    /// (`PCLK 1 → {Link Rate, Clients}`, `PCLK 2 → …`) — both layouts
    /// observed on Apple Silicon; the scanner flattens to this list.
    let dpLinks: [PhyDPLink]
    /// Active DP tunnels (DP-over-TB). Same dict-or-flat shape as DP
    /// pclk; flattened to this list.
    let dpTunnels: [PhyDPLink]

    var hasCIO: Bool { lanes.contains { $0.transport == "CIO" } }
    var hasDisplayPort: Bool { lanes.contains { $0.transport == "DisplayPort" } }
    var hasUSB3: Bool { lanes.contains { $0.transport == "USB3" } }
    var cioLaneCount: Int { lanes.filter { $0.transport == "CIO" && $0.isLive }.count }
    var dpLaneCount: Int { lanes.filter { $0.transport == "DisplayPort" && $0.isLive }.count }
    var usb3LaneCount: Int { lanes.filter { $0.transport == "USB3" && $0.isLive }.count }
    var liveLaneCount: Int { lanes.filter { $0.isLive }.count }
    var hasActiveUSB2: Bool { (usb2Transport ?? "").isEmpty == false }
}
