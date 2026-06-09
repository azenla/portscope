//
//  InternalHardwareScanner.swift
//  PortScope
//
//  Picks out the chassis power hardware that isn't USB or Thunderbolt:
//  the AppleSmartBatteryManager subtree and the MagSafe 3 receptacle.
//

import Foundation
import IOKit

nonisolated enum InternalHardwareScanner {
    static func scan(accessories: [PortAccessoryInfo]) -> InternalHardwareSnapshot {
        let battery = scanBatteryManager()
        let magsafe = accessories.first { port in
            if case .magsafe = port.connector { return true }
            return false
        }
        return InternalHardwareSnapshot(
            batteryManager: battery,
            magsafe: magsafe
        )
    }

    // MARK: - Battery

    /// Match the AppleSmartBatteryManager once and build its subtree (the
    /// battery node hangs off it). Returns nil on desktops or VMs without a
    /// battery. NodeBuilder will classify the children — `AppleSmartBattery`
    /// becomes `.battery`, the manager itself stays as `.batteryManager`.
    /// Exposed so the view model's periodic power refresh can pull fresh
    /// telemetry without a full rescan.
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
