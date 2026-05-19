//
//  ThunderboltScanner.swift
//  PortScope
//
//  Walks the IOService plane and produces a TBSnapshot.
//

import Foundation
import IOKit

nonisolated enum ThunderboltScanner {
    /// Capture the entire TB subsystem.
    static func scan() -> TBSnapshot {
        var controllers: [TBNode] = []
        let services = IORegBridge.services(matchingClass: "IOThunderboltController")
        for svc in services {
            if let node = NodeBuilder.build(from: svc) {
                controllers.append(node)
            }
            IOObjectRelease(svc)
        }
        controllers.sort { $0.title < $1.title }

        let pcie = collectDownstream(parentClass: "IOThunderboltSwitch",
                                     deviceClass: "IOPCIDevice")
        let usb = collectDownstream(parentClass: "IOThunderboltSwitch",
                                    deviceClass: "IOUSBHostDevice")

        return TBSnapshot(capturedAt: Date(),
                          controllers: controllers,
                          pcieDevicesOverTB: pcie,
                          usbDevicesOverTB: usb)
    }

    // MARK: - Downstream PCIe / USB collection

    /// Find every `deviceClass` whose IOService-plane ancestor chain crosses a node of `parentClass`.
    /// Used to compile a flat list of devices that reach the system over Thunderbolt.
    private static func collectDownstream(parentClass: String,
                                          deviceClass: String) -> [TBNode] {
        let candidates = IORegBridge.services(matchingClass: deviceClass)
        defer { candidates.forEach { IOObjectRelease($0) } }

        var results: [TBNode] = []
        for cand in candidates {
            guard let ancestorTitle = ancestorKind(of: cand, matching: parentClass) else { continue }
            guard let node = NodeBuilder.build(from: cand) else { continue }
            let augmented = TBNode(
                id: node.id,
                kind: node.kind,
                title: node.title,
                subtitle: [node.subtitle, ancestorTitle].compactMap { $0 }.joined(separator: " · "),
                className: node.className,
                properties: node.properties,
                propertyOrder: node.propertyOrder,
                children: node.children,
                registryPath: node.registryPath
            )
            if requireExternal(parent: cand) {
                results.append(augmented)
            }
        }
        results.sort { $0.title < $1.title }
        return results
    }

    /// Returns a short label for the closest ancestor of the given class.
    private static func ancestorKind(of entry: io_registry_entry_t, matching className: String) -> String? {
        var current: io_registry_entry_t = entry
        var releaseCurrent = false
        defer { if releaseCurrent { IOObjectRelease(current) } }

        for _ in 0..<64 {
            guard let parent = IORegBridge.parent(of: current) else { return nil }
            if releaseCurrent { IOObjectRelease(current) }
            current = parent
            releaseCurrent = true

            if let cls = IORegBridge.className(of: current),
               cls.contains(className) || IORegBridge.conforms(current, to: className) {
                let model = IORegBridge.properties(of: current)["Device Model Name"]?.asString
                let route = IORegBridge.properties(of: current)["Route String"]?.asUInt.map { String(format: "0x%llX", $0) }
                if let m = model, let r = route { return "under \(m) (route \(r))" }
                if let m = model { return "under \(m)" }
                return "under \(cls)"
            }
        }
        return nil
    }

    /// Heuristic: is this device actually beyond a downstream TB port (i.e. user-attached),
    /// not part of the integrated controller's own routing.
    private static func requireExternal(parent entry: io_registry_entry_t) -> Bool {
        var current: io_registry_entry_t = entry
        var releaseCurrent = false
        defer { if releaseCurrent { IOObjectRelease(current) } }

        for _ in 0..<64 {
            guard let parent = IORegBridge.parent(of: current) else { return false }
            if releaseCurrent { IOObjectRelease(current) }
            current = parent
            releaseCurrent = true

            if let cls = IORegBridge.className(of: current),
               cls.contains("ThunderboltSwitch") {
                let depth = IORegBridge.properties(of: current)["Depth"]?.asUInt ?? 0
                return depth > 0
            }
        }
        return false
    }
}
