//
//  SDCardScanner.swift
//  PortScope
//
//  Surface the built-in SD card reader as a physical port whenever the
//  chassis has one. The receptacle is rendered the same way USB-C / USB-A
//  are: the row appears as long as the hardware exists; card-present is
//  reflected in the mode (empty vs. card inserted).
//
//  The reader on Apple Silicon laptops sits behind a dedicated PCIe lane
//  (`pcie-sdreader` device-tree name) on the SoC's PCIe complex. When a
//  card goes in, the storage stack publishes `IOMedia` nodes underneath
//  the reader's driver — that's how we distinguish "empty slot" from
//  "card in".
//

import Foundation
import IOKit

nonisolated enum SDCardScanner {
    /// Synthetic accessory entry for the SD slot. Empty when the Mac has
    /// no reader; otherwise exactly one entry, with `connectionActive`
    /// set iff a card is currently mounted.
    static func scan() -> [PortAccessoryInfo] {
        var out: [PortAccessoryInfo] = []
        for svc in IORegBridge.services(matchingClass: "IOPCIDevice") {
            defer { IOObjectRelease(svc) }
            let props = IORegBridge.properties(of: svc)
            // `name` is a NUL-terminated UTF-8 data blob on PCI bridges.
            let dtName = props["name"]?.asString
                ?? props["name"]?.asDataString
                ?? ""
            guard dtName == "pcie-sdreader" else { continue }
            guard let id = IORegBridge.entryID(of: svc) else { continue }
            let cardPresent = hasIOMediaDescendant(svc)
            out.append(synthesise(entry: svc, id: id, props: props, cardPresent: cardPresent))
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
                                   props: [String: IORegValue],
                                   cardPresent: Bool) -> PortAccessoryInfo {
        return PortAccessoryInfo(
            id: TBNodeID(raw: id),
            portNumber: 1,
            connector: .sdCard,
            connection: cardPresent ? .device : .none,
            connectionActive: cardPresent,
            detected: cardPresent,
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
            registryProperties: props,
            registryPath: IORegBridge.path(of: entry)
        )
    }
}
