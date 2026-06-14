//
//  EthernetScanner.swift
//  PortScope
//
//  Surface built-in RJ-45 Ethernet jacks as physical ports. Apple Silicon
//  desktops use `BCM5701Enet` (Broadcom NetXtreme) on Mac mini / iMac /
//  Mac Studio, or AppleAVE2 on the SoC's internal NIC. The driver
//  publishes link state through `IOLinkStatus` and link speed through
//  `IOActiveMedium` (a packed 32-bit medium ID — bits 0..15 are the
//  speed in 100 kb/s units on most media types). USB / Thunderbolt-
//  tunneled adapters publish the same class but `IOBuiltin` is false on
//  their interface child; we filter on that to avoid duplicating ports
//  that already show up via their USB-C / TB carrier.
//

import Foundation
import IOKit

nonisolated enum EthernetScanner {
    /// Synthetic accessory entries for each built-in Ethernet jack. The
    /// Mac Pro ships two; everything else ships one. Empty on chassis
    /// without an integrated RJ-45 (every laptop except the older 16″
    /// Intel MBP).
    static func scan() -> [PortAccessoryInfo] {
        var out: [PortAccessoryInfo] = []
        var portNumber = 0
        // Match on IOEthernetInterface because that's where `IOBuiltin`
        // lives. IOServiceMatching returns subclasses too — `IOSkywalk-
        // LegacyEthernetInterface` (Wi-Fi), `IOEthernetUserClient`-spawned
        // bridge interfaces, etc. — so we explicitly require the *exact*
        // class to filter Wi-Fi and virtual Skywalk interfaces out.
        for svc in IORegBridge.services(matchingClass: "IOEthernetInterface") {
            defer { IOObjectRelease(svc) }
            guard IORegBridge.className(of: svc) == "IOEthernetInterface" else { continue }
            let props = IORegBridge.properties(of: svc)
            guard props["IOBuiltin"]?.asBool == true else { continue }
            // The parent controller must be a real ethernet driver. TB/
            // USB-tunneled adapters carry `IOPCITunnelCompatible = Yes` on
            // their controller; we drop those so the receptacle shows up
            // under its hosting USB-C port instead of as its own row.
            guard isRealBuiltInController(svc) else { continue }
            guard let id = IORegBridge.entryID(of: svc) else { continue }
            portNumber += 1

            // Pull link state + medium from the parent IOEthernetController.
            // (The interface itself only knows the BSD name and flags.)
            var ctrlProps: [String: IORegValue] = [:]
            if let parent = IORegBridge.parent(of: svc) {
                ctrlProps = IORegBridge.properties(of: parent)
                IOObjectRelease(parent)
            }
            // Bit 0 (`kIONetworkLinkValid`) only means "status is
            // meaningful" — a jack with no cable publishes 1. Bit 1
            // (`kIONetworkLinkActive`) is the actual link.
            let linkActive = (ctrlProps["IOLinkStatus"]?.asUInt ?? 0) & 0x3 == 0x3
            let speedMbps = decodeEthernetSpeedMbps(ctrlProps["IOActiveMedium"])

            var merged = props
            // Surface the controller's link/medium properties under the
            // accessory's raw_properties so the Developer details
            // disclosure exposes them without an extra plane walk.
            for (k, v) in ctrlProps {
                if merged[k] == nil { merged[k] = v }
            }
            // Synthesise a couple of tidy fields so Renderers don't need
            // to decode IOActiveMedium themselves.
            if let mbps = speedMbps {
                merged["LinkSpeedMbps"] = .unsigned(mbps)
            }
            merged["LinkActive"] = .bool(linkActive)

            out.append(PortAccessoryInfo(
                id: TBNodeID(raw: id),
                portNumber: portNumber,
                connector: .ethernet,
                connection: linkActive ? .device : .none,
                connectionActive: linkActive,
                detected: linkActive,
                plugOrientation: .unattached,
                supportedTransports: [],
                provisionedTransports: [],
                activeTransports: [],
                hpdAsserted: false,
                displayPortPinAssignment: 0,
                activeCable: false,
                opticalCable: false,
                connectionCount: 0,
                plugEventCount: 0,
                overcurrentCount: 0,
                cableVendorID: nil,
                cableProductID: nil,
                cableManufacturer: nil,
                cableEmarker: nil,
                usb3State: nil,
                cioState: nil,
                phyState: nil,
                usbPD: nil,
                registryProperties: merged,
                registryPath: IORegBridge.path(of: svc)
            ))
        }
        return out
    }

    /// True when the parent of an IOEthernetInterface looks like a
    /// chassis-built-in jack — i.e. driven by a real ethernet controller
    /// reachable through a non-Thunderbolt PCIe path. We accept the Apple
    /// Silicon-known classes (`BCM5701Enet`, `AppleAVE2*`) explicitly and
    /// fall back to a tunnel-flag check for the long tail.
    private static func isRealBuiltInController(_ ifaceSvc: io_registry_entry_t) -> Bool {
        guard let parent = IORegBridge.parent(of: ifaceSvc) else { return false }
        defer { IOObjectRelease(parent) }
        let cls = IORegBridge.className(of: parent) ?? ""
        if cls == "BCM5701Enet" { return true }
        if cls.hasPrefix("AppleAVE") { return true }
        // Anything carrying the TB tunnel flag is reachable over USB-C/TB
        // and should appear under that port, not as its own ethernet row.
        let parentProps = IORegBridge.properties(of: parent)
        if parentProps["IOPCITunnelled"]?.asBool == true { return false }
        // Reject obvious non-physical controllers by name.
        let rejectPrefixes = [
            "IOSkywalk", "IO80211", "AppleBCMWLAN",
            "AppleThunderboltIP",   // TB Bridge networking — one per TB port
            "AppleUSBEthernet",     // External USB ethernet adapter
            "AppleEthernetVirtual", // VLAN / bond / bridge interfaces
            "ApplePCIE"             // PCIe bridges that aren't ethernet
        ]
        for p in rejectPrefixes where cls.hasPrefix(p) { return false }
        return true
    }

    // IOActiveMedium decoding lives in `decodeEthernetSpeedMbps`
    // (USBEthernetSynth.swift) — one IFM_* table shared with the
    // USB-Ethernet synth so the Darwin subtype codes can't drift.
}
