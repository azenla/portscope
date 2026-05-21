//
//  SDCardScanner.swift
//  PortScope
//
//  Surface the built-in SD card reader as a physical port — but only when
//  a card is actually inserted, mirroring the user's intuition that an
//  empty SD slot is uninteresting.
//
//  The reader on Apple Silicon laptops sits behind a dedicated PCIe lane
//  (`pcie-sdreader` device-tree name) on the SoC's PCIe complex. When a
//  card goes in, the storage stack publishes `IOMedia` nodes underneath
//  the reader's driver. Card-out: no media. That presence flag is the
//  authoritative "is something here right now" signal we use.
//

import Foundation
import IOKit

nonisolated enum SDCardScanner {
    /// Synthetic accessory entries for the SD slot, one per chassis. Empty
    /// when the Mac has no reader, or when the reader is empty.
    static func scan() -> [PortAccessoryInfo] {
        var out: [PortAccessoryInfo] = []
        for svc in IORegBridge.services(matchingClass: "IOPCIDevice") {
            defer { IOObjectRelease(svc) }
            let props = IORegBridge.properties(of: svc)
            // `name` is a NUL-terminated UTF-8 data blob on PCI bridges.
            let dtName = props["name"]?.asString
                ?? unwrapDataString(props["name"])
                ?? ""
            guard dtName == "pcie-sdreader" else { continue }
            guard hasIOMediaDescendant(svc) else { continue }
            guard let id = IORegBridge.entryID(of: svc) else { continue }
            out.append(synthesise(entry: svc, id: id, props: props))
            break // One SD slot is the maximum any Mac has shipped.
        }
        return out
    }

    /// True iff any descendant in the IOService plane is an `IOMedia`. The
    /// kernel publishes IOMedia only when a usable card is mounted, so this
    /// distinguishes "slot present but empty" from "card inserted".
    private static func hasIOMediaDescendant(_ entry: io_registry_entry_t) -> Bool {
        var stack: [io_registry_entry_t] = IORegBridge.children(of: entry)
        var owned = stack
        defer { owned.forEach { IOObjectRelease($0) } }
        while let n = stack.popLast() {
            if IORegBridge.conforms(n, to: "IOMedia") { return true }
            let kids = IORegBridge.children(of: n)
            owned.append(contentsOf: kids)
            stack.append(contentsOf: kids)
        }
        return false
    }

    private static func synthesise(entry: io_registry_entry_t,
                                   id: UInt64,
                                   props: [String: IORegValue]) -> PortAccessoryInfo {
        return PortAccessoryInfo(
            id: TBNodeID(raw: id),
            portNumber: 1,
            connector: .sdCard,
            connection: .device,
            connectionActive: true,
            detected: true,
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
            usbPD: nil,
            registryProperties: props,
            registryPath: IORegBridge.path(of: entry)
        )
    }

    private static func unwrapDataString(_ value: IORegValue?) -> String? {
        guard case let .data(d) = value else { return nil }
        let s = String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters) ?? ""
        return s.isEmpty ? nil : s
    }
}
