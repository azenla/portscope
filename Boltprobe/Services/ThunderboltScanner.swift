//
//  ThunderboltScanner.swift
//  Boltprobe
//
//  Walks the IOService plane and produces a TBSnapshot.
//

import Foundation
import IOKit

enum ThunderboltScanner {
    /// Capture the entire TB subsystem.
    static func scan() -> TBSnapshot {
        var controllers: [TBNode] = []
        let services = IORegBridge.services(matchingClass: "IOThunderboltController")
        for svc in services {
            if let node = buildNode(from: svc) {
                controllers.append(node)
            }
            IOObjectRelease(svc)
        }
        controllers.sort { $0.title < $1.title }

        let pcie = collectDownstream(parentClass: "IOThunderboltSwitch",
                                     deviceClass: "IOPCIDevice",
                                     bridgeClass: "IOPCIBridge")
        let usb = collectDownstream(parentClass: "IOThunderboltSwitch",
                                    deviceClass: "IOUSBHostDevice",
                                    bridgeClass: nil)

        return TBSnapshot(capturedAt: Date(),
                          controllers: controllers,
                          pcieDevicesOverTB: pcie,
                          usbDevicesOverTB: usb)
    }

    // MARK: - Recursive walk

    /// Recursively build a `TBNode` from an IORegistry entry.
    private static func buildNode(from entry: io_registry_entry_t) -> TBNode? {
        guard let cls = IORegBridge.className(of: entry),
              let id = IORegBridge.entryID(of: entry) else { return nil }

        let name = IORegBridge.name(of: entry) ?? cls
        let location = IORegBridge.location(of: entry)
        let props = IORegBridge.properties(of: entry)
        let kind = classify(class: cls)
        let path = IORegBridge.path(of: entry)

        // Build child nodes.
        var childNodes: [TBNode] = []
        for child in IORegBridge.children(of: entry) {
            if let n = buildNode(from: child) {
                childNodes.append(n)
            }
            IOObjectRelease(child)
        }
        // Sort children to keep order stable: ports first by number, then everything else.
        childNodes.sort { lhs, rhs in
            let lp = lhs.properties["Port Number"]?.asUInt ?? UInt64.max
            let rp = rhs.properties["Port Number"]?.asUInt ?? UInt64.max
            if lp != rp { return lp < rp }
            return lhs.title < rhs.title
        }

        let (title, subtitle) = makeLabels(class: cls,
                                           name: name,
                                           location: location,
                                           kind: kind,
                                           props: props)
        let ordered = preferredOrder(for: kind, keys: Array(props.keys))

        return TBNode(
            id: TBNodeID(raw: id),
            kind: kind,
            title: title,
            subtitle: subtitle,
            className: cls,
            properties: props,
            propertyOrder: ordered,
            children: childNodes,
            registryPath: path
        )
    }

    // MARK: - Labels

    private static func makeLabels(class cls: String,
                                   name: String,
                                   location: String?,
                                   kind: TBNodeKind,
                                   props: [String: IORegValue]) -> (String, String?) {
        switch kind {
        case .controller:
            let title = "Thunderbolt Host Controller"
            let gen = props["Generation"]?.asUInt.map { "Apple Silicon gen \($0)" }
            return (title, gen)

        case .switch:
            let depth = props["Depth"]?.asUInt ?? 0
            if depth == 0 {
                // The host's built-in router.
                return ("Mac Host Router", "Built-in Thunderbolt root")
            }
            let model = props["Device Model Name"]?.asString
            let vendor = props["Device Vendor Name"]?.asString
            let title: String
            if let m = model, let v = vendor {
                title = "\(v) \(m)"
            } else if let m = model {
                title = m
            } else {
                title = "Thunderbolt Router"
            }
            return (title, "Depth \(depth) · external device")

        case .port:
            let n = props["Port Number"]?.asUInt ?? 0
            // The kernel's "Description" string is authoritative (e.g. "Thunderbolt Port",
            // "DP or HDMI Adapter", "PCIe Adapter"). Use it rather than guessing from
            // Adapter Type, since the integer encoding varies by chip vendor.
            let desc = props["Description"]?.asString ?? "Port"
            let title = "Port \(n) — \(humanAdapter(desc))"

            let speed = props["Current Link Speed"]?.asUInt ?? 0
            var bits: [String] = []
            if speed > 0 {
                bits.append(tbGenerationShortLabel(speed))
            } else if desc == "Port is inactive" {
                bits.append("Inactive")
            }
            if let w = props["Current Link Width"]?.asUInt, w > 0 { bits.append("×\(w)") }
            return (title, bits.isEmpty ? nil : bits.joined(separator: " · "))

        case .localNode:
            return ("Local Node", "This Mac on the TB fabric")

        case .usbBus:
            return ("USB Host Bus", "Provided over Thunderbolt")

        case .pcieBridge:
            return ("PCIe Bridge", nil)

        case .pcieDevice:
            let model = props["IOName"]?.asString ?? props["model"]?.asString
            return (model ?? "PCIe Device", nil)

        case .usbDevice:
            let product = props["kUSBProductString"]?.asString
                ?? props["USB Product Name"]?.asString
                ?? props["Product Name"]?.asString
            let vendor = props["kUSBVendorString"]?.asString
                ?? props["USB Vendor Name"]?.asString
                ?? props["Vendor Name"]?.asString
            return (product ?? "USB Device", vendor)

        case .networkIf:
            let bsd = props["BSD Name"]?.asString
            return ("Thunderbolt Networking", bsd.map { "Interface \($0)" })

        case .domain:
            return ("Thunderbolt Domain", nil)
        case .other:
            return (name, nil)
        }
    }

    /// Translate the kernel's "Description" string into a short human label.
    private static func humanAdapter(_ description: String) -> String {
        switch description {
        case "Thunderbolt Port": return "Lane Adapter"
        case "Port is inactive": return "Inactive"
        case "Thunderbolt Native Host Interface Adapter": return "Native Host Interface"
        case "DP or HDMI Adapter": return "Display Adapter"
        case "USB Adapter": return "USB Adapter"
        case "USB Gen T Adapter": return "USB Gen-T Adapter"
        case "PCIe Adapter": return "PCIe Adapter"
        default: return description.isEmpty ? "Port" : description
        }
    }

    // MARK: - Classification

    private static func classify(class cls: String) -> TBNodeKind {
        // Be precise: wrapper kext classes (DPConnectionManager, IPService,
        // IPPort, DPInAdapter*, etc) classify as `.other` so the topology view
        // can hide them and promote their meaningful descendants.
        if cls.contains("ThunderboltControllerType")
            || cls.contains("ThunderboltController") && !cls.contains("Apple") {
            return .controller
        }
        if cls == "IOThunderboltLocalNode" { return .localNode }
        if cls.contains("ThunderboltSwitch") { return .switch }
        if cls == "IOThunderboltPort" { return .port }
        if cls == "IOEthernetInterface" { return .networkIf }
        if cls == "IOPCIBridge" { return .pcieBridge }
        if cls == "IOPCIDevice" { return .pcieDevice }
        if cls == "IOUSBHostDevice" || cls == "IOUSBDevice" { return .usbDevice }
        return .other
    }

    /// Provide a TB-prioritised ordering of property keys.
    private static func preferredOrder(for kind: TBNodeKind, keys: [String]) -> [String] {
        let priorities: [String]
        switch kind {
        case .controller:
            priorities = [
                "Generation", "User Client Version", "Thunderbolt Version",
                "TMU Mode", "CLx SW Objection", "JTAG Device Count",
                "Using Bus Power"
            ]
        case .switch:
            priorities = [
                "Device Vendor Name", "Device Model Name",
                "Vendor ID", "Device ID", "UID",
                "Thunderbolt Version", "Depth", "Route String",
                "Upstream Port Number", "Max Port Number",
                "Firmware Version", "EEPROM Revision",
                "Min Required TMU Mode", "Buffer Allocation Request",
                "DROM", "FW Counters"
            ]
        case .port:
            priorities = [
                "Port Number", "Description", "Adapter Type",
                "Thunderbolt Version",
                "Current Link Speed", "Current Link Width",
                "Target Link Speed", "Target Link Width",
                "Supported Link Speed", "Supported Link Width", "Supported Link Modes",
                "Link Bandwidth",
                "Required Bandwidth Allocated", "Maximum Bandwidth Allocated",
                "Lane", "Dual-Link Port", "Dual-Link Port RID",
                "Max In Hop ID", "Max Out Hop ID", "Max Credits",
                "Bus Power", "CLx State",
                "Vendor ID", "Device ID", "Revision ID",
                "Hop Table",
                "Socket ID", "Micro Type", "Micro Version", "Micro Route String", "Micro Address",
                "TRM Policy", "TRM Transport ID", "TRM Hash Set",
                "TRM Transport Active 0", "TRM Transport Active 1",
                "TRM Transport Restricted", "TRM Identification Restricted"
            ]
        default:
            priorities = []
        }
        var seen = Set<String>()
        var ordered: [String] = []
        for k in priorities where keys.contains(k) && !seen.contains(k) {
            ordered.append(k); seen.insert(k)
        }
        for k in keys.sorted() where !seen.contains(k) {
            ordered.append(k); seen.insert(k)
        }
        return ordered
    }

    // MARK: - Downstream PCIe / USB collection

    /// Find every `deviceClass` whose IOService-plane ancestor chain crosses a node of `parentClass`.
    /// Used to compile a flat list of PCIe / USB devices that reach the system over Thunderbolt.
    private static func collectDownstream(parentClass: String,
                                          deviceClass: String,
                                          bridgeClass: String?) -> [TBNode] {
        let candidates = IORegBridge.services(matchingClass: deviceClass)
        defer { candidates.forEach { IOObjectRelease($0) } }

        var results: [TBNode] = []
        for cand in candidates {
            guard let kind = ancestorKind(of: cand, matching: parentClass) else { continue }
            guard let node = buildNode(from: cand) else { continue }
            // Tag with where this device sits.
            let ancestorTitle = kind
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
            // Filter out the integrated controller's own PCIe topology by checking
            // whether the device sits beneath an actual external switch (Depth > 0).
            if requireExternal(parent: cand) {
                results.append(augmented)
            }
            _ = bridgeClass // currently unused; reserved for future bridge dedup
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
