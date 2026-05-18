//
//  InternalHardwareModels.swift
//  PortScope
//
//  Models for the "Internal Hardware" sidebar section — non-removable buses
//  and devices that live on the SoC fabric: I²C, SPI/QSPI controllers, the
//  internal Smart Battery, and the MagSafe 3 receptacle. The MagSafe slot is
//  a peer to the USB-C receptacles in IOAccessory plane (HPM Type11 vs
//  Type10) but it doesn't carry data — it lives here because it's part of
//  the laptop chassis, not an expansion port.
//

import Foundation

/// Static snapshot of the internal-fabric hardware. Built once per rescan by
/// `InternalHardwareScanner`. Anything the user can't unplug lives here.
struct InternalHardwareSnapshot {
    /// I²C controllers (one per physical bus). Children are the slaves on the
    /// bus and their attached drivers.
    let i2cBuses: [TBNode]
    /// SPI and QSPI controllers.
    let spiBuses: [TBNode]
    /// AppleSmartBatteryManager subtree (battery manager + battery node).
    /// Nil on desktop hardware without a battery.
    let batteryManager: TBNode?
    /// MagSafe 3 receptacle accessory state (AppleHPMInterfaceType11).
    /// Nil on chassis without a MagSafe port. The `PortAccessoryInfo` carries
    /// the live charging / cable info when plugged in.
    let magsafe: PortAccessoryInfo?

    static let empty = InternalHardwareSnapshot(
        i2cBuses: [], spiBuses: [], batteryManager: nil, magsafe: nil
    )
}
