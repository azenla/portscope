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
        let buses = scanARMBuses()
        let battery = scanBatteryManager()
        let magsafe = accessories.first { port in
            if case .magsafe = port.connector { return true }
            return false
        }
        return InternalHardwareSnapshot(
            i2cBuses: buses.i2c,
            spiBuses: buses.spi,
            batteryManager: battery,
            magsafe: magsafe
        )
    }

    // MARK: - ARM I/O buses

    /// Walk every `AppleARMIODevice` and pick out the i2c / SPI / QSPI ones
    /// by their device-tree name prefix. There are dozens of `AppleARMIODevice`
    /// instances on a typical Apple Silicon host (DARTs, GPIO blocks, audio,
    /// AOP, etc.); we only care about the buses that carry observable
    /// peripherals.
    private static func scanARMBuses() -> (i2c: [TBNode], spi: [TBNode]) {
        var i2c: [TBNode] = []
        var spi: [TBNode] = []

        for svc in IORegBridge.services(matchingClass: "AppleARMIODevice") {
            defer { IOObjectRelease(svc) }
            guard let name = IORegBridge.name(of: svc) else { continue }
            let isI2C = name.hasPrefix("i2c")
            let isSPI = name.hasPrefix("spi") || name.hasPrefix("qspi")
            guard isI2C || isSPI else { continue }
            guard let node = NodeBuilder.build(from: svc) else { continue }
            // Promote slaves out from under the IOKit controller wrapper
            // (AppleS5L8940XI2CController / AppleSPIMCController / etc.) so
            // the bus view reads `i2c1 → audio-speaker@38`, not
            // `i2c1 → AppleS5L8940XI2CController → audio-speaker@38`.
            let promoted = promoteBusSlaves(under: node)
            if isI2C { i2c.append(promoted) } else { spi.append(promoted) }
        }

        i2c.sort { $0.title < $1.title }
        spi.sort { $0.title < $1.title }
        return (i2c, spi)
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
