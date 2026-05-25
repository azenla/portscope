//
//  AccessoryScanner.swift
//  PortScope
//
//  Walks the per-receptacle accessory entries (HPM Type10/Type11 on M3+ /
//  Apple Silicon TB5 hosts, AppleTCControllerType10/Type11 on T6000-class
//  M1 Max / Pro and T8103 M1) to capture per-physical-port runtime state.
//  This data is invisible to the Thunderbolt and USB IOKit families — it
//  lives in IOAccessory, and tells us what's actually being negotiated on
//  each USB-C / MagSafe receptacle (active transports, USB-PD voltage,
//  plug orientation, displayport HPD, cable e-marker info, etc.).
//

import Foundation
import IOKit

nonisolated enum AccessoryScanner {
    /// IORegistry classes that publish per-receptacle accessory state.
    /// Type10 = USB-C receptacle, Type11 = MagSafe 3 receptacle, Type12 /
    /// Type18 are additional generations observed on M4 / A-series / Neo
    /// silicon (property schema identical to Type10), and the schema is
    /// also identical across:
    ///   - `AppleHPMInterfaceType10/11/12/18`  — M3+ Apple Silicon, TB5 hosts
    ///   - `AppleTCControllerType10/11`        — M1 / M2 family (T6000 + T8103)
    /// Both class hierarchies wrap the same `Port-USB-C@N` /
    /// `Port-MagSafe 3@N` IOAccessory entry, so matching either gives the
    /// same data. Empty on Intel hosts where no equivalent exists.
    ///
    /// Type12 / Type18 class names are adapted from WhatCable
    /// (Sources/WhatCableDarwinBackend/AppleHPMInterfaceWatcher.swift:21-29,
    /// MIT, Copyright (c) 2026 Darryl Morley) — needed for any future
    /// MacBook Neo / A-series Mac the catalogue ends up supporting.
    private static let hpmClasses = [
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
        "AppleHPMInterfaceType12",
        "AppleHPMInterfaceType18",
        "AppleTCControllerType10",
        "AppleTCControllerType11"
    ]

    /// Built-in receptacles that `IOAccessoryManager` publishes as plain
    /// `IOPort` instances rather than HPM/TC controllers. Each one carries
    /// the same `PortNumber` / `Transports*` / `ConnectionActive` shape but
    /// none of the USB-PD / e-marker / orientation children that USB-C
    /// receptacles have, so the resulting `PortAccessoryInfo` is sparser.
    /// USB-A appears on rear-jack-equipped desktops (Mac mini M2 Pro, …).
    private static let ioPortPlainTypes: Set<String> = ["USB-A"]

    /// HDMI receptacles are published through `AppleHDMIPortController`
    /// (a `IOPort` subclass) and carry `PortTypeDescription = "HDMI"`,
    /// `ConnectionActive`, `HDMI_HPD`, and `TransportsActive` (containing
    /// `"DisplayPort"` when a sink is driving the line). Only one HDMI
    /// receptacle exists on any Mac that ships one (Mac mini, Mac Studio,
    /// MacBook Pro 14"/16").
    private static let hdmiControllerClass = "AppleHDMIPortController"

    /// Find every accessory-managed receptacle (USB-C + MagSafe via HPM/TC
    /// classes, USB-A via plain `IOPort`) and turn each into a
    /// `PortAccessoryInfo`. The `connector` field distinguishes them — callers
    /// that only care about USB-C ports should filter on `connector == .usbC`.
    /// Sorted by connector family then by `PortNumber` ascending.
    static func scan() -> [PortAccessoryInfo] {
        var seen: Set<UInt64> = []
        var out: [PortAccessoryInfo] = []

        // Pre-scan all USB-PD SOP services and index by parent port key. Each
        // physical USB-C receptacle that has a powered e-marked cable in it
        // will resolve here. See `readEmarkersByPortKey()` and
        // `USBPDVDOModels.swift` for attribution.
        let emarkers = readEmarkersByPortKey()

        // Pre-scan dynamic per-port transport-state services (USB3 + CIO).
        // Reader shapes adapted from WhatCable
        // (Sources/WhatCableDarwinBackend/USB3TransportWatcher.swift and
        // TRMTransportWatcher.swift, MIT, Copyright (c) 2026 Darryl Morley).
        let usb3States = readUSB3StatesByPortKey()
        let cioStates = readCIOStatesByPortKey()

        // Pre-scan per-port PHY state — `AppleT*TypeCPhy` services. Keyed
        // by phyID (0-based); HPM port number is 1-based so lookup is
        // `portNumber - 1`.
        let phyStates = readPhyStatesByID()

        for cls in hpmClasses {
            for svc in IORegBridge.services(matchingClass: cls) {
                defer { IOObjectRelease(svc) }
                guard let id = IORegBridge.entryID(of: svc), !seen.contains(id) else { continue }
                seen.insert(id)

                let props = IORegBridge.properties(of: svc)
                guard let port = makePort(entry: svc, id: id, props: props,
                                           emarkers: emarkers,
                                           usb3States: usb3States,
                                           cioStates: cioStates,
                                           phyStates: phyStates) else { continue }
                out.append(port)
            }
        }

        // Plain-`IOPort` receptacles (USB-A, …). `IOServiceMatching("IOPort")`
        // will also drag in HPM/TC subclasses; the className gate plus the
        // entry-ID dedup keep us from double-counting.
        for svc in IORegBridge.services(matchingClass: "IOPort") {
            defer { IOObjectRelease(svc) }
            guard let id = IORegBridge.entryID(of: svc), !seen.contains(id) else { continue }
            let actualClass = IORegBridge.className(of: svc) ?? ""
            guard actualClass == "IOPort" else { continue }
            let props = IORegBridge.properties(of: svc)
            let portType = props["PortTypeDescription"]?.asString ?? ""
            guard ioPortPlainTypes.contains(portType) else { continue }
            guard props["IOPersonalityPublisher"]?.asString == "com.apple.iokit.IOAccessoryManager"
            else { continue }
            seen.insert(id)

            guard let port = makePort(entry: svc, id: id, props: props,
                                       emarkers: emarkers,
                                       usb3States: usb3States,
                                       cioStates: cioStates,
                                       phyStates: phyStates) else { continue }
            out.append(port)
        }

        // HDMI receptacles — `AppleHDMIPortController` is `IOPort`'s HDMI
        // subclass with the same property shape (`PortTypeDescription`,
        // `PortNumber`, `ConnectionActive`, `Transports*`). Live on Macs
        // that ship a built-in HDMI jack.
        for svc in IORegBridge.services(matchingClass: hdmiControllerClass) {
            defer { IOObjectRelease(svc) }
            guard let id = IORegBridge.entryID(of: svc), !seen.contains(id) else { continue }
            seen.insert(id)
            let props = IORegBridge.properties(of: svc)
            guard let port = makePort(entry: svc, id: id, props: props,
                                       emarkers: emarkers,
                                       usb3States: usb3States,
                                       cioStates: cioStates,
                                       phyStates: phyStates) else { continue }
            out.append(port)
        }

        out.sort {
            // USB-C first, then USB-A, HDMI, SD, MagSafe, everything else.
            // Within a connector family, sort by physical port number.
            if $0.connector != $1.connector {
                func rank(_ c: PortConnectorType) -> Int {
                    switch c {
                    case .acPower: return 0
                    case .magsafe: return 1
                    case .usbC: return 2
                    case .usbA: return 3
                    case .hdmi: return 4
                    case .sdCard: return 5
                    case .ethernet: return 6
                    case .other: return 7
                    }
                }
                let r0 = rank($0.connector), r1 = rank($1.connector)
                if r0 != r1 { return r0 < r1 }
            }
            return $0.portNumber < $1.portNumber
        }
        return out
    }

    private static func makePort(entry: io_registry_entry_t,
                                 id: UInt64,
                                 props: [String: IORegValue],
                                 emarkers: [PortKey: CableEmarkerInfo],
                                 usb3States: [PortKey: USB3TransportState],
                                 cioStates: [PortKey: CIOCableState],
                                 phyStates: [Int: PhyState]) -> PortAccessoryInfo? {
        guard let portNumber = props["PortNumber"]?.asUInt else { return nil }

        let connector = PortConnectorType(props["PortTypeDescription"]?.asString)
        let supported = parseTransports(props["TransportsSupported"])
        let provisioned = parseTransports(props["TransportsProvisioned"])
        let active = parseTransports(props["TransportsActive"])

        // USB-PD lives under `IOPortFeaturePowerIn/Out` children, which only
        // exist on USB-C / MagSafe HPM entries. USB-A IOPort entries have no
        // such children — skip the descent so we don't waste IORegistry walks.
        let pd: USBPDProfile? = {
            switch connector {
            case .usbC, .magsafe: return readUSBPDProfile(under: entry)
            default: return nil
            }
        }()

        // USB-A `IOPort` accessories don't publish `IOAccessoryUSBConnectString`
        // or `IOAccessoryDetect`. Derive both from `ConnectionActive` so the
        // sidebar's "empty / connected" colouring still works for USB-A.
        let connectionActive = props["ConnectionActive"]?.asBool ?? false
        let detected = props["IOAccessoryDetect"]?.asBool ?? connectionActive
        let connectionRaw = props["IOAccessoryUSBConnectString"]?.asString
        let connection: AccessoryConnection = {
            if let connectionRaw { return AccessoryConnection(connectionRaw) }
            return connectionActive ? .device : .none
        }()

        // Look up the SOP'/SOP'' e-marker entries indexed by parent port.
        // WhatCable's USBPDSOPWatcher.swift:184-192 prefers the
        // `ParentBuiltInPort{Type,Number}` keys over `ParentPort{Type,Number}`;
        // mirror that for the lookup. Port type integers: USB-C = 0x02,
        // MagSafe = 0x11 (the latter is documented in WhatCable
        // PowerSource.swift:71-82).
        let rawTypeForKey = portTypeRawForLookup(connector: connector,
                                                  props: props)
        let lookupKey = PortKey(portType: rawTypeForKey, portNumber: portNumber)
        let emarker = emarkers[lookupKey]
        let usb3 = usb3States[lookupKey]
        let cio = cioStates[lookupKey]
        // PHY services exist only for USB-C receptacles — MagSafe / HDMI /
        // SD / USB-A jacks are different silicon. `AppleTypeCPhyID` is
        // 0-indexed; HPM `PortNumber` is 1-indexed. The mapping
        // `phyID == portNumber - 1` holds on every Apple Silicon chassis
        // observed (Mac mini M4 Pro, MBP M5 Pro). When extending to
        // future hardware where this no longer holds, replace the
        // subtraction with a proper join (e.g. via a shared registry
        // path or location string).
        let phyLookup: PhyState? = (connector == .usbC)
            ? phyStates[Int(portNumber) - 1]
            : nil

        return PortAccessoryInfo(
            id: TBNodeID(raw: id),
            portNumber: Int(portNumber),
            connector: connector,
            connection: connection,
            connectionActive: connectionActive,
            detected: detected,
            plugOrientation: PlugOrientation(props["PlugOrientation"]?.asUInt),
            supportedTransports: supported,
            provisionedTransports: provisioned,
            activeTransports: active,
            hpdAsserted: props["HPDAsserted"]?.asBool ?? false,
            displayPortPinAssignment: props["DisplayPortPinAssignment"]?.asUInt ?? 0,
            activeCable: props["ActiveCable"]?.asBool ?? false,
            opticalCable: props["OpticalCable"]?.asBool ?? false,
            connectionCount: props["ConnectionCount"]?.asUInt ?? 0,
            plugEventCount: props["Plug Event Count"]?.asUInt ?? 0,
            overcurrentCount: props["Overcurrent Count"]?.asUInt ?? 0,
            cableVendorID: readDataAsUInt(props["SOPVID"]),
            cableProductID: readDataAsUInt(props["SOPPID"]),
            cableManufacturer: props["SOPMfgString"]?.asString,
            cableEmarker: emarker,
            usb3State: usb3,
            cioState: cio,
            phyState: phyLookup,
            usbPD: pd,
            registryProperties: props,
            registryPath: IORegBridge.path(of: entry)
        )
    }

    /// Cross-service join key used to attach a USB-PD SOP service to its
    /// parent HPM port. Mirrors the
    /// `"<parentPortType>/<parentPortNumber>"` shape WhatCable uses
    /// across watchers (see e.g. USBPDSOPWatcher.swift:181-192,
    /// PowerSourceWatcher.swift:111-119; MIT, Copyright (c) 2026 Darryl Morley).
    fileprivate struct PortKey: Hashable {
        let portType: UInt64
        let portNumber: UInt64
    }

    /// Pick the rawType integer the SOP services publish so the join key
    /// matches what those services say. Most HPM ports publish a raw
    /// integer port type the kernel uses to coordinate cross-service
    /// joins — when missing (HDMI, USB-A IOPort entries) fall back to a
    /// derived value from the connector enum.
    private static func portTypeRawForLookup(connector: PortConnectorType,
                                              props: [String: IORegValue]) -> UInt64 {
        if let raw = props["PortType"]?.asUInt { return raw }
        // Derived from WhatCable PowerSource.swift:71-82 (MagSafe = 0x11,
        // USB-C = 0x02). Other connector types don't get SOP entries.
        switch connector {
        case .magsafe: return 0x11
        case .usbC: return 0x02
        default: return 0
        }
    }

    /// Build a dictionary from `(parentPortType, parentPortNumber)` →
    /// `CableEmarkerInfo` by walking every
    /// `IOPortTransportComponentCCUSBPDSOPp` and `…SOPpp` service in the
    /// IORegistry and decoding its `Metadata.VDOs` array.
    ///
    /// SOP partner discovery, endpoint classification, parent-port key
    /// derivation, and the `Metadata.VDOs` blob layout are all adapted
    /// from WhatCable Sources/WhatCableDarwinBackend/USBPDSOPWatcher.swift
    /// (L13-17 for class names, L104-112 for per-key reads to avoid the
    /// `IOCFUnserializeBinary` abort, L128-131 for the Metadata.VDOs
    /// path, L154-178 for endpoint classification, L184-192 for the
    /// parent-port-key fallback chain). MIT, Copyright (c) 2026 Darryl
    /// Morley.
    private static func readEmarkersByPortKey() -> [PortKey: CableEmarkerInfo] {
        // SOP partner (the device on the other end of the cable) is also
        // visible but it isn't the e-marker; we deliberately match only
        // the two cable-side endpoints. `SOPp` = cable near-end (the
        // common case), `SOPpp` = cable far-end (some optical cables).
        let classes = [
            "IOPortTransportComponentCCUSBPDSOPp",
            "IOPortTransportComponentCCUSBPDSOPpp"
        ]
        var byKey: [PortKey: CableEmarkerInfo] = [:]

        for cls in classes {
            for svc in IORegBridge.services(matchingClass: cls) {
                defer { IOObjectRelease(svc) }
                let props = IORegBridge.properties(of: svc)
                guard let key = readParentPortKey(props: props) else { continue }
                guard let info = decodeEmarker(svcClass: cls, props: props) else { continue }
                // Prefer SOP' over SOP'' when both exist for the same port —
                // SOP' is the near-end e-marker, usually the more informative.
                if byKey[key] == nil || info.endpoint == .sopPrime {
                    byKey[key] = info
                }
            }
        }
        return byKey
    }

    private static func readParentPortKey(props: [String: IORegValue]) -> PortKey? {
        // Prefer BuiltIn keys, fall back to plain Parent keys, then to the
        // low byte of `Priority` as a last resort. WhatCable
        // USBPDSOPWatcher.swift:181-192.
        let portType = props["ParentBuiltInPortType"]?.asUInt
            ?? props["ParentPortType"]?.asUInt
            ?? (props["Priority"]?.asUInt).map { $0 & 0xFF }
        let portNumber = props["ParentBuiltInPortNumber"]?.asUInt
            ?? props["ParentPortNumber"]?.asUInt
        guard let portType, let portNumber else { return nil }
        return PortKey(portType: portType, portNumber: portNumber)
    }

    /// Build a dictionary from parent-port key →
    /// `USB3TransportState` by walking every `IOPortTransportStateUSB3`
    /// service. Reader shape adapted from WhatCable
    /// (Sources/WhatCableDarwinBackend/USB3TransportWatcher.swift:82-116,
    /// MIT, Copyright (c) 2026 Darryl Morley).
    private static func readUSB3StatesByPortKey() -> [PortKey: USB3TransportState] {
        var byKey: [PortKey: USB3TransportState] = [:]
        for svc in IORegBridge.services(matchingClass: "IOPortTransportStateUSB3") {
            defer { IOObjectRelease(svc) }
            let props = IORegBridge.properties(of: svc)
            guard let key = readParentPortKey(props: props) else { continue }
            let signaling = props["SuperSpeedSignaling"]?.asUInt ?? 0
            let description = props["SuperSpeedSignalingDescription"]?.asString
            let role = props["DataRole"]?.asString ?? props["PortDataRole"]?.asString
            byKey[key] = USB3TransportState(
                signaling: Int(signaling),
                signalingDescription: description,
                dataRole: role
            )
        }
        return byKey
    }

    /// Build a dictionary from parent-port key → `CIOCableState` by
    /// walking every `IOPortTransportStateCIO` service. Reader shape
    /// adapted from WhatCable
    /// (Sources/WhatCableDarwinBackend/TRMTransportWatcher.swift:177-191
    /// and Sources/WhatCableCore/CIOCableCapability.swift, MIT,
    /// Copyright (c) 2026 Darryl Morley).
    private static func readCIOStatesByPortKey() -> [PortKey: CIOCableState] {
        var byKey: [PortKey: CIOCableState] = [:]
        for svc in IORegBridge.services(matchingClass: "IOPortTransportStateCIO") {
            defer { IOObjectRelease(svc) }
            let props = IORegBridge.properties(of: svc)
            guard let key = readParentPortKey(props: props) else { continue }
            byKey[key] = CIOCableState(
                cableSpeed: props["CableSpeed"]?.asUInt.map { Int($0) },
                cableGenerationRaw: props["CableGeneration"]?.asUInt.map { Int($0) },
                generationRaw: props["Generation"]?.asUInt.map { Int($0) },
                asymmetricModeSupported: props["AsymmetricModeSupported"]?.asBool,
                legacyAdapter: props["LegacyAdapter"]?.asBool,
                linkTrainingMode: props["LinkTrainingMode"]?.asUInt.map { Int($0) }
            )
        }
        return byKey
    }

    /// Candidate `AppleT*TypeCPhy` IOKit classes — one per supported
    /// Apple Silicon SoC family. The schema is identical across them
    /// (`AppleTypeCPhyID`, `AppleTypeCPhyLane`, `AppleTypeCPhyUSB2`,
    /// `AppleTypeCPhyDisplayPortPclk`, `AppleTypeCPhyDisplayPortTunnel`),
    /// so a flat class list is sufficient.
    ///
    /// `T8132 / T8122 / T8112 / T6042 / T6022 / T6002 / T6000` are
    /// adapted from WhatCable
    /// (Sources/WhatCableDarwinBackend/AppleTypeCPhyWatcher.swift:18-26,
    /// MIT, Copyright (c) 2026 Darryl Morley).
    /// `T6050` (M4 Pro) was added after confirming on real hardware
    /// that it publishes the same property schema as the WhatCable-
    /// upstream classes.
    private static let phyClasses = [
        "AppleT8132TypeCPhy",
        "AppleT8122TypeCPhy",
        "AppleT8112TypeCPhy",
        "AppleT6042TypeCPhy",
        "AppleT6022TypeCPhy",
        "AppleT6002TypeCPhy",
        "AppleT6000TypeCPhy",
        "AppleT6050TypeCPhy",
        "AppleT6034TypeCPhy",
        "AppleT6052TypeCPhy"
    ]

    /// Walk every `AppleT*TypeCPhy` service and build a dictionary
    /// `phyID → PhyState`. PHY service properties layout per WhatCable
    /// (Sources/WhatCableDarwinBackend/AppleTypeCPhyWatcher.swift:117-174,
    /// MIT, Copyright (c) 2026 Darryl Morley); the DP-Pclk / DP-Tunnel
    /// nested-dict variant ("PCLK 1" / "Tunnel 0" sub-keys with
    /// `Link Rate` inside) is observed on Apple Silicon and flattened
    /// into the `dpLinks` / `dpTunnels` arrays.
    private static func readPhyStatesByID() -> [Int: PhyState] {
        var byID: [Int: PhyState] = [:]
        for cls in phyClasses {
            for svc in IORegBridge.services(matchingClass: cls) {
                defer { IOObjectRelease(svc) }
                let props = IORegBridge.properties(of: svc)
                guard let rawID = props["AppleTypeCPhyID"]?.asUInt else { continue }
                let phyID = Int(rawID)
                if byID[phyID] != nil { continue }

                let lanes = parsePhyLanes(props["AppleTypeCPhyLane"])
                let (u2Transport, u2Client) = parsePhyUSB2(props["AppleTypeCPhyUSB2"])
                let dpLinks = parsePhyDPDict(props["AppleTypeCPhyDisplayPortPclk"])
                let dpTunnels = parsePhyDPDict(props["AppleTypeCPhyDisplayPortTunnel"])

                byID[phyID] = PhyState(
                    id: phyID,
                    lanes: lanes,
                    usb2Transport: u2Transport,
                    usb2Client: u2Client,
                    dpLinks: dpLinks,
                    dpTunnels: dpTunnels
                )
            }
        }
        return byID
    }

    private static func parsePhyLanes(_ value: IORegValue?) -> [PhyLaneState] {
        guard case let .dictionary(kv) = value else { return [] }
        var lanes: [PhyLaneState] = []
        for (key, sub) in kv {
            // Sub-keys are "Lane 0" / "Lane 1" / etc. Extract trailing int.
            let parts = key.split(separator: " ")
            guard parts.count == 2, parts[0] == "Lane",
                  let idx = Int(parts[1]) else { continue }
            guard case let .dictionary(laneKV) = sub else {
                // Empty sub-dict is a kernel placeholder for "idle lane".
                // Surface it as a lane with no transport so the UI can
                // show "Lane N: idle" instead of dropping it silently.
                lanes.append(PhyLaneState(index: idx, transport: "", powerLevel: "", client: ""))
                continue
            }
            let d = Dictionary(laneKV, uniquingKeysWith: { a, _ in a })
            lanes.append(PhyLaneState(
                index: idx,
                transport: d["Transport"]?.asString ?? "",
                powerLevel: d["Power Level"]?.asString ?? "",
                client: d["Client"]?.asString ?? ""
            ))
        }
        return lanes.sorted { $0.index < $1.index }
    }

    private static func parsePhyUSB2(_ value: IORegValue?) -> (String?, String?) {
        guard case let .dictionary(kv) = value else { return (nil, nil) }
        let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
        let transport = d["Transport"]?.asString
        let client = d["Client"]?.asString
        if (transport ?? "").isEmpty && (client ?? "").isEmpty { return (nil, nil) }
        return (transport, client)
    }

    /// Both `AppleTypeCPhyDisplayPortPclk` and
    /// `AppleTypeCPhyDisplayPortTunnel` are dicts of sub-dicts, each
    /// sub-dict carrying a `Link Rate` string and optionally a `Clients`
    /// array. Flatten into a list of `PhyDPLink`. Empty top-level dict =
    /// no active DP.
    private static func parsePhyDPDict(_ value: IORegValue?) -> [PhyDPLink] {
        guard case let .dictionary(kv) = value, !kv.isEmpty else { return [] }
        var links: [PhyDPLink] = []
        for (_, sub) in kv {
            guard case let .dictionary(subKV) = sub else { continue }
            let d = Dictionary(subKV, uniquingKeysWith: { a, _ in a })
            let rate = d["Link Rate"]?.asString ?? ""
            // Clients can be array-of-strings or a plain string.
            var client: String? = nil
            if case let .array(arr) = d["Clients"], let first = arr.first,
               case let .string(s) = first { client = s }
            else if let s = d["Client"]?.asString { client = s }
            if !rate.isEmpty {
                links.append(PhyDPLink(linkRate: rate, client: client))
            }
        }
        return links
    }

    /// Decode the `Metadata.VDOs` array on one SOP service into a
    /// `CableEmarkerInfo`. Returns nil if the metadata is empty or
    /// VDO[0] can't be read (kernel placeholder on a service that's
    /// mid-teardown).
    private static func decodeEmarker(svcClass: String,
                                       props: [String: IORegValue]) -> CableEmarkerInfo? {
        guard case let .dictionary(metaKV) = props["Metadata"] else { return nil }
        let meta = Dictionary(metaKV, uniquingKeysWith: { a, _ in a })
        // `VDOs` array under Metadata. Each entry is a 4-byte LE Data blob.
        // WhatCable handles `VDOs (SOP1)` suffix variant too — surface here
        // by trying both keys.
        let vdoArr: [IORegValue]
        if case let .array(arr) = meta["VDOs"] { vdoArr = arr }
        else if case let .array(arr) = meta["VDOs (SOP1)"] { vdoArr = arr }
        else { return nil }
        guard vdoArr.count >= 1 else { return nil }

        func vdoAt(_ i: Int) -> UInt32? {
            guard i < vdoArr.count else { return nil }
            if case let .data(d) = vdoArr[i] { return decodeVDO(d) }
            return nil
        }
        guard let vdo0 = vdoAt(0) else { return nil }
        let idHeader = decodePDIDHeader(vdo0)

        // For cables we expect VDO[3] (Cable VDO). For non-cable endpoints
        // this isn't meaningful.
        guard idHeader.ufpProductType.isCable, let vdo3 = vdoAt(3) else { return nil }
        let isActive = idHeader.ufpProductType == .activeCable
        let cableVDO = decodePDCableVDO(vdo3, isActive: isActive)

        let activeVDO2: PDActiveCableVDO2?
        if isActive, let vdo4 = vdoAt(4) {
            activeVDO2 = decodePDActiveCableVDO2(vdo4)
        } else {
            activeVDO2 = nil
        }

        let certStat: PDCertStat? = vdoAt(1).map(decodePDCertStat(_:))
        let productVDO = vdoAt(2)

        // Classify endpoint from the IOKit class name. SOPp (one trailing p)
        // is near-end, SOPpp is far-end. WhatCable USBPDSOPWatcher.swift
        // L154-178 uses a three-tier fallback; the class-name check alone
        // is enough for PortScope's read-only scan.
        let endpoint: CableEmarkerEndpoint = svcClass.hasSuffix("SOPpp") ? .sopDoublePrime : .sopPrime

        return CableEmarkerInfo(
            vendorID: idHeader.vendorID,
            productType: idHeader.ufpProductType,
            cableVDO: cableVDO,
            activeVDO2: activeVDO2,
            certStat: certStat,
            productVDORaw: productVDO,
            endpoint: endpoint
        )
    }

    /// Parse a `Transports*` array (kernel publishes them as arrays of strings).
    private static func parseTransports(_ value: IORegValue?) -> Set<USBCTransport> {
        guard case .array(let arr) = value else { return [] }
        var out: Set<USBCTransport> = []
        for v in arr {
            if case .string(let s) = v { out.insert(USBCTransport(s)) }
        }
        return out
    }

    /// Children of an HPM port include a `Power In` wrapper, which itself has
    /// a `USB-PD` and (when an Apple charger is plugged in) a `Brick ID`
    /// `IOPortFeaturePowerSource` child. Walk both to pull the offered + winning
    /// power profiles.
    ///
    /// Apple Silicon publishes only `IOPortFeaturePowerIn` (sink-side PDOs)
    /// today; `IOPortFeaturePowerOut` is reserved for future hardware that
    /// exposes source-side PDOs. We match both classes so if the latter
    /// appears we surface it without further code changes.
    private static func readUSBPDProfile(under entry: io_registry_entry_t) -> USBPDProfile? {
        var winning: USBPDOption?
        var offered: [USBPDOption] = []
        var brickID: USBPDOption?

        // `IOPortFeaturePowerIn` is the canonical class of the "Power In"
        // wrapper child. Matching by class is more robust than matching by
        // name (the kernel sometimes appends bracketed status markers to the
        // human name string, e.g. "USB-PD [*]" for the currently-active one).
        for child in IORegBridge.children(of: entry) {
            defer { IOObjectRelease(child) }
            guard let cls = IORegBridge.className(of: child),
                  cls == "IOPortFeaturePowerIn" || cls == "IOPortFeaturePowerOut" else { continue }

            for source in IORegBridge.children(of: child) {
                defer { IOObjectRelease(source) }
                guard let sourceCls = IORegBridge.className(of: source),
                      sourceCls == "IOPortFeaturePowerSource" else { continue }
                let p = IORegBridge.properties(of: source)
                let sourceName = (p["PowerSourceName"]?.asString)
                    ?? IORegBridge.name(of: source)
                    ?? ""
                let options = parsePDOArray(p["PowerSourceOptions"])
                let win = parsePDODict(p["WinningPowerSourceOption"])

                switch sourceName {
                case "USB-PD":
                    winning = win
                    offered = options
                case "Brick ID":
                    brickID = options.first ?? win
                default:
                    // Some chargers expose vendor-specific PDOs (e.g. Apple's
                    // "Apple Brick ID" or PPS ranges). Treat the first one we
                    // see as the USB-PD profile if we haven't matched yet.
                    if winning == nil { winning = win }
                    if offered.isEmpty { offered = options }
                }
            }
        }

        if winning == nil, offered.isEmpty, brickID == nil { return nil }
        return USBPDProfile(winning: winning, offered: offered, brickID: brickID)
    }

    private static func parsePDOArray(_ value: IORegValue?) -> [USBPDOption] {
        guard case .array(let arr) = value else { return [] }
        var out: [USBPDOption] = []
        for v in arr {
            if let opt = parsePDODict(v) { out.append(opt) }
        }
        // Sort by voltage so the rendered table reads naturally.
        out.sort { $0.voltageMV < $1.voltageMV }
        return out
    }

    private static func parsePDODict(_ value: IORegValue?) -> USBPDOption? {
        guard case .dictionary(let kv) = value else { return nil }
        let dict = Dictionary(kv, uniquingKeysWith: { a, _ in a })
        guard let v = dict["Voltage (mV)"]?.asUInt,
              let i = dict["Max Current (mA)"]?.asUInt,
              let p = dict["Max Power (mW)"]?.asUInt else { return nil }
        return USBPDOption(voltageMV: v, maxCurrentMA: i, maxPowerMW: p)
    }

    /// SOPVID / SOPPID come back as 2-byte little-endian `Data` blobs.
    /// Convert them to a UInt64.
    private static func readDataAsUInt(_ value: IORegValue?) -> UInt64? {
        if let v = value?.asUInt { return v }
        guard case .data(let d) = value else { return nil }
        var result: UInt64 = 0
        for (idx, byte) in d.enumerated() where idx < 8 {
            result |= UInt64(byte) << (idx * 8)
        }
        return result == 0 ? nil : result
    }
}
