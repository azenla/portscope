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
    /// Type10 = USB-C receptacle, Type11 = MagSafe 3 receptacle, and the
    /// property schema is identical (port number, transports, USB-PD
    /// children) regardless of which class hierarchy the host exposes:
    ///   - `AppleHPMInterfaceType10/11`  — M3+ Apple Silicon, TB5 hosts
    ///   - `AppleTCControllerType10/11`  — M1 / M2 family (T6000 + T8103)
    /// Both classes wrap the same `Port-USB-C@N` / `Port-MagSafe 3@N`
    /// IOAccessory entry, so matching either gives the same data. Empty on
    /// Intel hosts where no equivalent exists.
    private static let hpmClasses = [
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
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

        for cls in hpmClasses {
            for svc in IORegBridge.services(matchingClass: cls) {
                defer { IOObjectRelease(svc) }
                guard let id = IORegBridge.entryID(of: svc), !seen.contains(id) else { continue }
                seen.insert(id)

                let props = IORegBridge.properties(of: svc)
                guard let port = makePort(entry: svc, id: id, props: props) else { continue }
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

            guard let port = makePort(entry: svc, id: id, props: props) else { continue }
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
            guard let port = makePort(entry: svc, id: id, props: props) else { continue }
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
                                 props: [String: IORegValue]) -> PortAccessoryInfo? {
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
            usbPD: pd,
            registryProperties: props,
            registryPath: IORegBridge.path(of: entry)
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
