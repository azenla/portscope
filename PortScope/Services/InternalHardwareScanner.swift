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

enum InternalHardwareScanner {
    static func scan(accessories: [PortAccessoryInfo]) -> InternalHardwareSnapshot {
        let arm = scanARMDevices()
        let battery = scanBatteryManager()
        let magsafe = accessories.first { port in
            if case .magsafe = port.connector { return true }
            return false
        }
        return InternalHardwareSnapshot(
            i2cBuses: arm.i2c,
            spiBuses: arm.spi,
            batteryManager: battery,
            magsafe: magsafe,
            socCoprocessors: arm.coprocessors
        )
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
    private static func scanBatteryManager() -> TBNode? {
        for svc in IORegBridge.services(matchingClass: "AppleSmartBatteryManager") {
            defer { IOObjectRelease(svc) }
            if let node = NodeBuilder.build(from: svc) {
                return node
            }
        }
        return nil
    }
}
