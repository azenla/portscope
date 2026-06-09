//
//  InternalHardwareModels.swift
//  PortScope
//
//  Models for the chassis power hardware surfaced in the Physical Device
//  section's Power subgroup: the internal Smart Battery and the MagSafe 3
//  receptacle. The MagSafe slot is a peer to the USB-C receptacles in the
//  IOAccessory plane (HPM Type11 vs Type10) but it doesn't carry data — it
//  lives here because it's part of the laptop chassis, not an expansion port.
//

import Foundation

/// Static snapshot of the internal power hardware. Built once per rescan by
/// `InternalHardwareScanner`; the battery subtree is also re-read on the
/// 2-second power poll.
nonisolated struct InternalHardwareSnapshot {
    /// AppleSmartBatteryManager subtree (battery manager + battery node).
    /// Nil on desktop hardware without a battery — but note the kernel
    /// publishes the manager on desktops too as a power-telemetry endpoint
    /// (`BatteryInstalled = false`), so consumers must gate on
    /// `BatteryInstalled` before rendering a battery.
    let batteryManager: TBNode?
    /// MagSafe 3 receptacle accessory state (AppleHPMInterfaceType11).
    /// Nil on chassis without a MagSafe port. The `PortAccessoryInfo` carries
    /// the live charging / cable info when plugged in.
    let magsafe: PortAccessoryInfo?

    static let empty = InternalHardwareSnapshot(
        batteryManager: nil, magsafe: nil
    )
}
