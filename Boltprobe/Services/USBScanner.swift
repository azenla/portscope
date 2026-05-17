//
//  USBScanner.swift
//  Boltprobe
//
//  Walks the IOService plane for USB host controllers and produces a USBSnapshot.
//  Also records whether each controller is reached over a Thunderbolt switch,
//  so the UI can cross-link a USB device to its TB context.
//

import Foundation
import IOKit

enum USBScanner {
    static func scan() -> USBSnapshot {
        var controllers: [TBNode] = []
        var tbContext: [TBNodeID: TBNodeID] = [:]
        var seen = Set<UInt64>()

        for cls in ["IOUSBHostController", "AppleUSBHostController", "IOUSBController"] {
            for svc in IORegBridge.services(matchingClass: cls) {
                defer { IOObjectRelease(svc) }
                guard let id = IORegBridge.entryID(of: svc), !seen.contains(id) else { continue }
                // IOServiceMatching returns subclasses too. Filter out port
                // wrappers (e.g. `AppleUSBXHCIAUSSPort`) that inherit from the
                // controller base class but represent individual USB ports.
                if let svcCls = IORegBridge.className(of: svc),
                   svcCls.hasSuffix("Port") || svcCls.contains("XHCIPort") {
                    continue
                }
                seen.insert(id)
                let tbAncestor = findTBSwitchAncestor(of: svc)
                if let node = NodeBuilder.build(from: svc) {
                    controllers.append(node)
                    if let tb = tbAncestor { tbContext[node.id] = tb }
                }
            }
        }

        controllers.sort { lhs, rhs in
            let la = locationSortKey(for: lhs)
            let ra = locationSortKey(for: rhs)
            if la != ra { return la < ra }
            return lhs.title < rhs.title
        }
        return USBSnapshot(capturedAt: Date(), controllers: controllers, tbContext: tbContext)
    }

    /// Walk parents to find an `IOThunderboltSwitch` ancestor — meaning the
    /// USB controller is reached through a tunneled TB switch. Returns the
    /// switch's registry entry ID.
    private static func findTBSwitchAncestor(of entry: io_registry_entry_t) -> TBNodeID? {
        var current: io_registry_entry_t = entry
        var releaseCurrent = false
        defer { if releaseCurrent { IOObjectRelease(current) } }

        for _ in 0..<64 {
            guard let parent = IORegBridge.parent(of: current) else { return nil }
            if releaseCurrent { IOObjectRelease(current) }
            current = parent
            releaseCurrent = true

            if let cls = IORegBridge.className(of: current),
               cls.contains("ThunderboltSwitch") {
                if let id = IORegBridge.entryID(of: current) {
                    return TBNodeID(raw: id)
                }
            }
        }
        return nil
    }

    private static func locationSortKey(for node: TBNode) -> UInt64 {
        return node.properties["locationID"]?.asUInt
            ?? node.properties["IOPCIConfigSpace"]?.asUInt
            ?? UInt64.max
    }
}
