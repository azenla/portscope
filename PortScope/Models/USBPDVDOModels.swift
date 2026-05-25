//
//  USBPDVDOModels.swift
//  PortScope
//
//  USB Power Delivery 3.0 / 3.1 Discover Identity VDO decoders. Every
//  USB-C cable with an e-marker silicon chip publishes its capabilities
//  (speed class, current rating, voltage rating, active/passive,
//  optical/copper, retimer/redriver, …) through the four-VDO Discover
//  Identity response. macOS surfaces those responses on
//  `IOPortTransportComponentCCUSBPDSOP{,p,pp}` services as a nested
//  `Metadata.VDOs` array of 4-byte little-endian `Data` blobs.
//
//  This file translates the raw VDOs into structured PortScope types.
//
//  Decoder structure (bit layout, enum values, polarity-inversion of the
//  Active Cable VDO 2 "supported" bits, the decode-warning set) adapted
//  from WhatCable
//  (Sources/WhatCableCore/USBPDVDO.swift, MIT,
//  Copyright (c) 2026 Darryl Morley). Refer to the USB Power Delivery
//  Specification, Revision 3.1, for the canonical bitfield definitions.
//

import Foundation

/// USB-PD ID Header VDO `ProductType` field. The 3-bit value at bits 29..27
/// (UFP) or 25..23 (DFP) classifies the device that answered Discover
/// Identity.
nonisolated enum PDProductType: Int, Hashable {
    case undefined = 0
    case pdusbHub = 1
    case pdusbPeripheral = 2
    case passiveCable = 3
    case activeCable = 4
    case ama = 5            // Alternate Mode Adapter
    case vpd = 6            // VCONN-Powered Device
    case other = 7

    var label: String {
        switch self {
        case .undefined: return "Unspecified"
        case .pdusbHub: return "USB Hub"
        case .pdusbPeripheral: return "USB Peripheral"
        case .passiveCable: return "Passive cable"
        case .activeCable: return "Active cable"
        case .ama: return "Alternate Mode Adapter"
        case .vpd: return "VCONN-powered device"
        case .other: return "Other"
        }
    }

    /// True when this product type identifies a cable (passive or active).
    /// Used to gate Cable VDO decoding — only cables publish VDO[3].
    var isCable: Bool {
        self == .passiveCable || self == .activeCable
    }
}

/// Cable speed class, encoded as bits 2..0 of the Cable VDO. PD 3.1 added
/// the 80 Gbps tier; PD 3.0 stopped at 40 Gbps.
nonisolated enum PDCableSpeed: Int, Hashable {
    case usb20 = 0
    case usb32Gen1 = 1   // 5 Gbps
    case usb32Gen2 = 2   // 10 Gbps
    case usb4Gen3 = 3    // 40 Gbps (PD 3.1 reinterpretation; was 20 Gbps in PD 3.0)
    case usb4Gen4 = 4    // 80 Gbps

    var label: String {
        switch self {
        case .usb20: return "USB 2.0 (480 Mb/s)"
        case .usb32Gen1: return "USB 3.2 Gen 1 (5 Gb/s)"
        case .usb32Gen2: return "USB 3.2 Gen 2 (10 Gb/s)"
        case .usb4Gen3: return "USB4 Gen 3 (40 Gb/s — Thunderbolt 4 class)"
        case .usb4Gen4: return "USB4 Gen 4 (80 Gb/s — Thunderbolt 5 class)"
        }
    }

    var maxGbps: Double {
        switch self {
        case .usb20: return 0.48
        case .usb32Gen1: return 5
        case .usb32Gen2: return 10
        case .usb4Gen3: return 40
        case .usb4Gen4: return 80
        }
    }
}

/// Cable current rating, encoded as bits 6..5 of the Cable VDO. `usbDefault`
/// is the bag-of-chargers case where the cable doesn't claim explicit
/// 3 A or 5 A capability — USB-C spec treats default cables as 3 A-safe.
nonisolated enum PDCableCurrent: Int, Hashable {
    case usbDefault = 0
    case threeAmp = 1
    case fiveAmp = 2

    var maxAmps: Double {
        switch self {
        case .usbDefault: return 3.0
        case .threeAmp: return 3.0
        case .fiveAmp: return 5.0
        }
    }

    var label: String {
        switch self {
        case .usbDefault: return "USB default"
        case .threeAmp: return "3 A"
        case .fiveAmp: return "5 A"
        }
    }
}

/// Used in the Cable VDO to distinguish passive (VDO[3] is the only cable
/// VDO) from active (VDO[4] adds Active Cable VDO 2). Sourced from the ID
/// Header's UFP product type.
nonisolated enum PDCableType: Hashable {
    case passive
    case active
}

/// One spec-violation tell that surfaced during VDO decode. These are
/// independently emitted from the trust-flag layer so the e-marker
/// detail view can show them next to the affected field.
nonisolated enum PDDecodeWarning: Hashable {
    case reservedSpeedEncoding(Int)
    case reservedCurrentEncoding(Int)
    case reservedCableLatencyEncoding(Int)
    case invalidVDOVersion(Int)
    case invalidCableTermination(Int)
    case eprClaimedWithLowMaxVoltage

    var label: String {
        switch self {
        case .reservedSpeedEncoding(let v):
            return String(format: "Reserved cable-speed encoding 0x%X", v)
        case .reservedCurrentEncoding(let v):
            return String(format: "Reserved cable-current encoding 0x%X", v)
        case .reservedCableLatencyEncoding(let v):
            return String(format: "Reserved cable-latency encoding 0x%X", v)
        case .invalidVDOVersion(let v):
            return String(format: "Invalid VDO version 0x%X for cable type", v)
        case .invalidCableTermination(let v):
            return String(format: "Invalid cable termination 0x%X for cable type", v)
        case .eprClaimedWithLowMaxVoltage:
            return "EPR Capable bit set but Max VBUS is 20 V (spec requires 48 V or 50 V)"
        }
    }
}

/// VDO[0] decoded.
nonisolated struct PDIDHeader: Hashable {
    let usbCommHost: Bool
    let usbCommDevice: Bool
    let modalOperation: Bool
    let ufpProductType: PDProductType
    let dfpProductType: PDProductType
    let vendorID: Int
}

/// VDO[3] decoded — the Cable VDO. Carried by every e-marked cable (passive
/// or active).
nonisolated struct PDCableVDO: Hashable {
    let speed: PDCableSpeed
    let current: PDCableCurrent
    /// Approximate max wattage at the cable's declared max VBUS × max current.
    let maxWatts: Int
    /// Max VBUS the cable carries. 20 V / 30 V / 40 V / 50 V.
    let maxVolts: Int
    let cableType: PDCableType
    let vbusThroughCable: Bool
    /// Bit 17 — extended-power-range capable. Real EPR also requires the
    /// cable to support 48 V or 50 V; see `decodeWarnings`.
    let eprCapable: Bool
    /// Raw 4-bit cable latency field. Use `latencyNanoseconds` for the
    /// typed interpretation when it's a non-reserved value.
    let cableLatencyEncoded: Int
    /// Raw 3-bit VDO version field. Validity depends on cable type — see
    /// `decodeWarnings`.
    let vdoVersionEncoded: Int
    /// Raw 2-bit cable termination field. Validity depends on cable type.
    let cableTerminationEncoded: Int
    let decodeWarnings: [PDDecodeWarning]

    /// Approximate one-way latency in ns. Maps 10 ns/m roughly for copper;
    /// active cables additionally carry 1000 ns / 2000 ns optical lengths.
    /// Returns `nil` for reserved codes flagged in `decodeWarnings`.
    var latencyNanoseconds: Int? {
        switch cableLatencyEncoded {
        case 0b0001: return 10
        case 0b0010: return 20
        case 0b0011: return 30
        case 0b0100: return 40
        case 0b0101: return 50
        case 0b0110: return 60
        case 0b0111: return 70
        case 0b1000: return 80
        case 0b1001 where cableType == .active: return 1000
        case 0b1010 where cableType == .active: return 2000
        default: return nil
        }
    }
}

/// Physical medium the cable uses to carry data, bit 10 of Active Cable VDO 2.
nonisolated enum PDPhysicalConnection: Int, Hashable {
    case copper = 0
    case optical = 1

    var label: String {
        switch self {
        case .copper: return "Copper"
        case .optical: return "Optical"
        }
    }
}

/// What the silicon in the cable plug does to the signal, bit 9 of Active
/// Cable VDO 2. Re-timers fully decode and re-emit; re-drivers boost in
/// place.
nonisolated enum PDActiveElement: Int, Hashable {
    case redriver = 0
    case retimer = 1

    var label: String {
        switch self {
        case .redriver: return "Re-driver"
        case .retimer: return "Re-timer"
        }
    }
}

/// VDO[4] decoded — Active Cable VDO 2, only present on active cables.
nonisolated struct PDActiveCableVDO2: Hashable {
    /// Bits 31..24. Max ambient temp the cable's silicon is rated for. 0
    /// means "not specified."
    let maxOperatingTempC: Int
    /// Bits 23..16. Thermal-shutdown trip point. 0 means "not specified."
    let shutdownTempC: Int
    /// Bit 11.
    let u3ToU0TransitionThroughU3S: Bool
    /// Bit 10.
    let physicalConnection: PDPhysicalConnection
    /// Bit 9.
    let activeElement: PDActiveElement
    /// Bit 8 — note: stored as the inverse of the raw bit, so `true` here
    /// means "USB4 is supported." See WhatCable USBPDVDO.swift L404-419 for
    /// the polarity-inversion rationale (the spec uses 0 = supported for
    /// the protocol bits but 1 = supported for everything else).
    let usb4Supported: Bool
    /// Bits 7..6. Number of USB 2.0 hub hops the cable consumes.
    let usb2HubHopsConsumed: Int
    /// Bit 5 — inverted; `true` means USB 2.0 supported.
    let usb2Supported: Bool
    /// Bit 4 — inverted; `true` means USB 3.2 supported.
    let usb32Supported: Bool
    /// Bit 3.
    let twoLanesSupported: Bool
    /// Bit 2.
    let opticallyIsolated: Bool
    /// Bit 1.
    let usb4AsymmetricMode: Bool
    /// Bit 0.
    let usbGen2OrHigher: Bool
}

/// VDO[1] decoded — Cert Stat, carrying the USB-IF certification XID. Cables
/// without certification leave this at zero.
nonisolated struct PDCertStat: Hashable {
    let xid: UInt32
    var isPresent: Bool { xid != 0 }
}

/// Combined e-marker info for one physical cable end. PortScope stores this
/// per receptacle (the SOP' partner — cable near-end e-marker is the common
/// case; the far-end SOP'' is rare and is currently not surfaced).
nonisolated struct CableEmarkerInfo: Hashable {
    /// Vendor ID from the e-marker ID Header. Distinct from the SOP
    /// (port partner) VID that `PortAccessoryInfo.cableVendorID`
    /// already carries — that one is the device on the other end of the
    /// cable, this one is the cable silicon itself.
    let vendorID: Int
    /// Product type from the ID Header — useful for the "passive vs active"
    /// classification.
    let productType: PDProductType
    /// VDO[3] decoded. Always present on an e-marked cable.
    let cableVDO: PDCableVDO
    /// VDO[4] decoded. Only present when `productType == .activeCable`.
    let activeVDO2: PDActiveCableVDO2?
    /// VDO[1] decoded. Cables without a USB-IF certification leave `xid = 0`.
    let certStat: PDCertStat?
    /// VDO[2] when present — the Product VDO. Surfaced raw because the
    /// product VDO layout is product-specific (bcdDevice + USB-IF
    /// product-type-specific fields).
    let productVDORaw: UInt32?
    /// Endpoint the kernel classified this e-marker as — `sopPrime` (cable
    /// near-end) is by far the most common; `sopDoublePrime` is the
    /// far-end e-marker on optical / longer cables.
    let endpoint: CableEmarkerEndpoint
}

/// Which PD partner the Discover Identity response came from. Determined
/// by the IOKit service class name (`IOPortTransportComponentCCUSBPDSOPp`
/// vs `IOPortTransportComponentCCUSBPDSOPpp`) — see the WhatCable
/// classification fallback in `USBPDSOPWatcher.swift:154-178`.
nonisolated enum CableEmarkerEndpoint: Hashable {
    case sopPrime          // cable near-end (the common case)
    case sopDoublePrime    // cable far-end (some optical / Thunderbolt cables)
}

// MARK: - Decode helpers

/// IOKit publishes each VDO as a 4-byte little-endian `Data` blob.
/// Returns `nil` if the blob is the wrong size.
nonisolated func decodeVDO(_ data: Data) -> UInt32? {
    guard data.count >= 4 else { return nil }
    return data.withUnsafeBytes { buf in
        buf.loadUnaligned(as: UInt32.self).littleEndian
    }
}

/// Decode VDO[0] (ID Header). USB-PD R3.1 Table 6.36.
nonisolated func decodePDIDHeader(_ vdo: UInt32) -> PDIDHeader {
    PDIDHeader(
        usbCommHost: (vdo >> 31) & 1 == 1,
        usbCommDevice: (vdo >> 30) & 1 == 1,
        modalOperation: (vdo >> 26) & 1 == 1,
        ufpProductType: PDProductType(rawValue: Int((vdo >> 27) & 0b111)) ?? .undefined,
        dfpProductType: PDProductType(rawValue: Int((vdo >> 23) & 0b111)) ?? .undefined,
        vendorID: Int(vdo & 0xFFFF)
    )
}

/// Decode VDO[3] (Cable VDO). `isActive` is taken from the ID Header's UFP
/// product type — see `PDProductType.isCable` / `.activeCable`. The
/// passive-vs-active split changes both which bit values are spec-valid
/// and the latency-encoding interpretation.
nonisolated func decodePDCableVDO(_ vdo: UInt32, isActive: Bool) -> PDCableVDO {
    let speedBits = Int(vdo & 0b111)
    let decodedSpeed = PDCableSpeed(rawValue: speedBits)
    let speed = decodedSpeed ?? .usb20
    let vbusThrough = (vdo >> 4) & 1 == 1
    let currentBits = Int((vdo >> 5) & 0b11)
    let decodedCurrent = PDCableCurrent(rawValue: currentBits)
    let current = decodedCurrent ?? .usbDefault
    let maxVBits = Int((vdo >> 9) & 0b11)
    let latencyBits = Int((vdo >> 13) & 0b1111)
    let cableType: PDCableType = isActive ? .active : .passive
    let cableTerminationBits = Int((vdo >> 11) & 0b11)
    let vdoVersionBits = Int((vdo >> 21) & 0b111)
    let eprCapable = (vdo >> 17) & 1 == 1

    var warnings: [PDDecodeWarning] = []
    if decodedSpeed == nil { warnings.append(.reservedSpeedEncoding(speedBits)) }
    if decodedCurrent == nil { warnings.append(.reservedCurrentEncoding(currentBits)) }

    // Cable Latency field. 0000 is "Invalid" for both cable types.
    // Passive cables also treat 1001..1111 as Invalid; active cables
    // accept 1001 (~1000 ns optical) and 1010 (~2000 ns optical), and
    // treat 1011..1111 as Invalid.
    let latencyInvalid: Bool
    if latencyBits == 0 {
        latencyInvalid = true
    } else if isActive {
        latencyInvalid = latencyBits >= 0b1011
    } else {
        latencyInvalid = latencyBits >= 0b1001
    }
    if latencyInvalid { warnings.append(.reservedCableLatencyEncoding(latencyBits)) }

    // VDO Version (bits 23..21). Passive: only 000 valid. Active: 000,
    // 010, 011 accepted.
    let vdoVersionInvalid: Bool
    if isActive {
        vdoVersionInvalid = !(vdoVersionBits == 0 || vdoVersionBits == 0b010 || vdoVersionBits == 0b011)
    } else {
        vdoVersionInvalid = vdoVersionBits != 0
    }
    if vdoVersionInvalid { warnings.append(.invalidVDOVersion(vdoVersionBits)) }

    // Cable Termination (bits 12..11). Passive: 00 (VCONN not required) or
    // 01 (VCONN required). Active: 10 (one end active) or 11 (both ends).
    let cableTerminationInvalid: Bool
    if isActive {
        cableTerminationInvalid = cableTerminationBits < 0b10
    } else {
        cableTerminationInvalid = cableTerminationBits >= 0b10
    }
    if cableTerminationInvalid { warnings.append(.invalidCableTermination(cableTerminationBits)) }

    // Passive cable claims EPR but reports only 20 V Max VBUS. EPR requires
    // 48 V or 50 V; only encoding 11 (50V) is consistent.
    if !isActive && eprCapable && maxVBits == 0 {
        warnings.append(.eprClaimedWithLowMaxVoltage)
    }

    let volts: Double
    switch maxVBits {
    case 1: volts = 30
    case 2: volts = 40
    case 3: volts = 50
    default: volts = 20
    }
    let amps = current.maxAmps
    let watts = Int((volts * amps).rounded())

    let maxVolts: Int
    switch maxVBits {
    case 1: maxVolts = 30
    case 2: maxVolts = 40
    case 3: maxVolts = 50
    default: maxVolts = 20
    }

    return PDCableVDO(
        speed: speed,
        current: current,
        maxWatts: watts,
        maxVolts: maxVolts,
        cableType: cableType,
        vbusThroughCable: vbusThrough,
        eprCapable: eprCapable,
        cableLatencyEncoded: latencyBits,
        vdoVersionEncoded: vdoVersionBits,
        cableTerminationEncoded: cableTerminationBits,
        decodeWarnings: warnings
    )
}

/// Decode VDO[4] (Active Cable VDO 2). Only valid when the cable is active —
/// caller checks `idHeader.ufpProductType == .activeCable`.
///
/// NOTE: the USB4 / USB 3.2 / USB 2.0 "supported" bits at positions 8/4/5
/// are *inverted* in the spec — `0` means supported, `1` means not
/// supported. The decoder normalises to `true = supported`. The other
/// boolean bits use the conventional `1 = yes`. This polarity-inversion
/// trick is from WhatCable Sources/WhatCableCore/USBPDVDO.swift:404-419.
nonisolated func decodePDActiveCableVDO2(_ vdo: UInt32) -> PDActiveCableVDO2 {
    let maxTemp = Int((vdo >> 24) & 0xFF)
    let shutdownTemp = Int((vdo >> 16) & 0xFF)
    let physBits = Int((vdo >> 10) & 1)
    let elemBits = Int((vdo >> 9) & 1)

    return PDActiveCableVDO2(
        maxOperatingTempC: maxTemp,
        shutdownTempC: shutdownTemp,
        u3ToU0TransitionThroughU3S: (vdo >> 11) & 1 == 1,
        physicalConnection: PDPhysicalConnection(rawValue: physBits) ?? .copper,
        activeElement: PDActiveElement(rawValue: elemBits) ?? .redriver,
        usb4Supported: (vdo >> 8) & 1 == 0,
        usb2HubHopsConsumed: Int((vdo >> 6) & 0b11),
        usb2Supported: (vdo >> 5) & 1 == 0,
        usb32Supported: (vdo >> 4) & 1 == 0,
        twoLanesSupported: (vdo >> 3) & 1 == 1,
        opticallyIsolated: (vdo >> 2) & 1 == 1,
        usb4AsymmetricMode: (vdo >> 1) & 1 == 1,
        usbGen2OrHigher: vdo & 1 == 1
    )
}

/// Decode VDO[1] (Cert Stat). Whole 32-bit VDO is the USB-IF XID; `0` means
/// the cable carries no certification.
nonisolated func decodePDCertStat(_ vdo: UInt32) -> PDCertStat {
    PDCertStat(xid: vdo)
}
