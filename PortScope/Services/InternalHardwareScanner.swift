//
//  InternalHardwareScanner.swift
//  PortScope
//
//  Picks out the SoC-internal buses and devices that aren't USB or
//  Thunderbolt: I²C / SPI / QSPI controllers, the AppleSmartBatteryManager
//  subtree, and the MagSafe 3 receptacle. All hosted on Apple Silicon's
//  `arm-io` fabric — invisible to the regular USB and TB scanners.
//

import Foundation
import IOKit

nonisolated enum InternalHardwareScanner {
    static func scan(accessories: [PortAccessoryInfo]) -> InternalHardwareSnapshot {
        let arm = scanARMDevices()
        let battery = scanBatteryManager()
        let magsafe = accessories.first { port in
            if case .magsafe = port.connector { return true }
            return false
        }
        let groups = groupCoprocessors(arm.coprocessors)
        let systemInfo = SystemInfoScanner.scan()
        return InternalHardwareSnapshot(
            systemInfo: systemInfo,
            i2cBuses: arm.i2c,
            spiBuses: arm.spi,
            batteryManager: battery,
            magsafe: magsafe,
            coprocessorGroups: groups
        )
    }

    /// Bucket the flat list of named SoC blocks by function. The mapping
    /// follows the device-tree naming Apple has used since M1; new
    /// generations have added more `dispext` / `dcpext` instances but the
    /// short prefixes haven't changed. Anything unknown ends up in `.other`
    /// rather than being dropped so future silicon doesn't go silent.
    private static func groupCoprocessors(_ all: [TBNode]) -> [SoCCoprocessorGroup] {
        var buckets: [SoCCoprocessorCategory: [TBNode]] = [:]
        for node in all {
            let name = deviceTreeName(of: node)
            let category = categorise(name: name)
            buckets[category, default: []].append(node)
        }
        return SoCCoprocessorCategory.allCases.compactMap { category in
            guard let nodes = buckets[category], !nodes.isEmpty else { return nil }
            return SoCCoprocessorGroup(
                category: category,
                coprocessors: nodes.sorted { $0.title < $1.title }
            )
        }
    }

    private static func categorise(name: String) -> SoCCoprocessorCategory {
        let displayPrefixes = ["dcp", "dcpext", "disp", "dispext", "gfx-asc", "sgx", "agx"]
        let imagePrefixes   = ["isp", "ane", "jpeg", "scaler"]
        let videoPrefixes   = ["avd", "ave"]
        let storagePrefixes = ["ans", "mcc"]
        let securityPrefixes = ["sep", "aop", "pmgr", "pmp", "smc", "aic"]
        let radioPrefixes   = ["wlan", "bluetooth"]

        if displayPrefixes.contains(where: { matches(name: name, prefix: $0) }) {
            return .displayAndGraphics
        }
        if imagePrefixes.contains(where: { matches(name: name, prefix: $0) }) {
            return .mediaImage
        }
        if videoPrefixes.contains(where: { matches(name: name, prefix: $0) }) {
            return .mediaVideo
        }
        if storagePrefixes.contains(where: { matches(name: name, prefix: $0) }) {
            return .storageMemory
        }
        if securityPrefixes.contains(where: { matches(name: name, prefix: $0) }) {
            return .securityPower
        }
        if radioPrefixes.contains(where: { matches(name: name, prefix: $0) }) {
            return .radios
        }
        return .other
    }

    private static func matches(name: String, prefix: String) -> Bool {
        if name == prefix { return true }
        if name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            return suffix.isEmpty || suffix.allSatisfy(\.isNumber)
        }
        return false
    }

    private static func deviceTreeName(of node: TBNode) -> String {
        if case .string(let s) = node.properties["name"] ?? .string("") { return s }
        if case .data(let d) = node.properties["name"] ?? .string("") {
            return String(data: d, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters) ?? ""
        }
        // Fall back to device-tree title heuristic: the IORegistry entry's
        // `name` is what NodeBuilder fed into the formatter, so the title's
        // tail is usually the device-tree token.
        return node.title.lowercased().replacingOccurrences(of: " ", with: "")
    }

    // MARK: - ARM I/O buses + coprocessors

    /// Walk every `AppleARMIODevice` once. We classify each by its
    /// device-tree name into one of three buckets: i2c bus, SPI/QSPI bus, or
    /// a user-meaningful SoC coprocessor (Secure Enclave, Always-On
    /// Processor, NAND controller, image signal processor, etc.). The
    /// dozens of remaining entries (DARTs, GPIO blocks, DMA controllers,
    /// timers, AOP MMIO regions, etc.) are dropped — surfacing every one
    /// would bury the meaningful blocks under a wall of plumbing.
    private static func scanARMDevices() -> (i2c: [TBNode], spi: [TBNode], coprocessors: [TBNode]) {
        var i2c: [TBNode] = []
        var spi: [TBNode] = []
        var coprocessors: [TBNode] = []
        var seenCoprocessorLabels: Set<String> = []

        for svc in IORegBridge.services(matchingClass: "AppleARMIODevice") {
            defer { IOObjectRelease(svc) }
            guard let name = IORegBridge.name(of: svc) else { continue }
            let isI2C = name.hasPrefix("i2c")
            let isSPI = name.hasPrefix("spi") || name.hasPrefix("qspi")
            let coprocessorTitle = NodeFormatter.socCoprocessorTitle(for: name)
            guard isI2C || isSPI || coprocessorTitle != nil else { continue }
            guard let node = NodeBuilder.build(from: svc) else { continue }
            if isI2C {
                i2c.append(promoteBusSlaves(under: node))
            } else if isSPI {
                spi.append(promoteBusSlaves(under: node))
            } else if let title = coprocessorTitle {
                // De-duplicate by friendly title rather than by device-tree
                // name: e.g. `dcp` and `dcp-sac-controller` would otherwise
                // both surface as "Display Coprocessor". Keep the first.
                if seenCoprocessorLabels.insert(title).inserted {
                    coprocessors.append(node)
                }
            }
        }

        i2c.sort { $0.title < $1.title }
        spi.sort { $0.title < $1.title }
        coprocessors.sort { $0.title < $1.title }
        return (i2c, spi, coprocessors)
    }

    /// The bus controller (AppleS5L8940XI2CController / AppleSPIMCController)
    /// is a kext wrapper that sits between the bus node and its slaves. The
    /// user doesn't care about the controller — they want to see what's on
    /// the bus. Skip past the controller wrapper and adopt its children.
    private static func promoteBusSlaves(under bus: TBNode) -> TBNode {
        let interestingControllerClasses: Set<String> = [
            "AppleS5L8940XI2CController",
            "AppleSPIMCController",
            "AppleQSPIMCController"
        ]
        // Find the first child whose class is the controller wrapper and
        // adopt its children; keep all other children as-is.
        var newChildren: [TBNode] = []
        for child in bus.children {
            if interestingControllerClasses.contains(child.className) {
                newChildren.append(contentsOf: child.children)
            } else {
                newChildren.append(child)
            }
        }
        return TBNode(
            id: bus.id,
            kind: bus.kind,
            title: bus.title,
            subtitle: bus.subtitle,
            className: bus.className,
            properties: bus.properties,
            propertyOrder: bus.propertyOrder,
            children: newChildren,
            registryPath: bus.registryPath
        )
    }

    // MARK: - Battery

    /// Match the AppleSmartBatteryManager once and build its subtree (the
    /// battery node hangs off it). Returns nil on desktops or VMs without a
    /// battery. NodeBuilder will classify the children — `AppleSmartBattery`
    /// becomes `.battery`, the manager itself stays as `.batteryManager`.
    /// Exposed so the view model's periodic power refresh can pull fresh
    /// telemetry without re-walking the AppleARMIODevice haystack.
    static func scanBatteryManager() -> TBNode? {
        for svc in IORegBridge.services(matchingClass: "AppleSmartBatteryManager") {
            defer { IOObjectRelease(svc) }
            if let node = NodeBuilder.build(from: svc) {
                return node
            }
        }
        return nil
    }
}
