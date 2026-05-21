//
//  PowerInputScanner.swift
//  PortScope
//
//  Surface the built-in AC power input on desktop Macs (Mac mini, iMac,
//  Mac Studio, Mac Pro) as a physical port. The kernel publishes
//  measured wattage / voltage / amperage through `AppleSmartBattery`'s
//  `PowerTelemetryData` dict even on chassis with no battery — the same
//  telemetry the battery service uses to report load on laptops.
//
//  Laptops (battery installed) get their power-input representation
//  through MagSafe and USB-C PD already, so we skip them here to avoid
//  double-counting.
//

import Foundation
import IOKit

nonisolated enum PowerInputScanner {
    /// Synthetic accessory for the desktop power-supply jack, or empty
    /// on laptops where MagSafe / USB-C PD already covers it.
    static func scan() -> [PortAccessoryInfo] {
        for svc in IORegBridge.services(matchingClass: "AppleSmartBattery") {
            defer { IOObjectRelease(svc) }
            let props = IORegBridge.properties(of: svc)
            // `BatteryInstalled = No` + `ExternalConnected = Yes` is the
            // canonical desktop signature. Skip everything else.
            let installed = props["BatteryInstalled"]?.asBool ?? false
            let external = props["ExternalConnected"]?.asBool ?? false
            guard !installed, external else { continue }
            guard let id = IORegBridge.entryID(of: svc) else { continue }

            // PowerTelemetryData is a nested dict. SystemPowerIn is mW,
            // SystemVoltageIn is mV, SystemCurrentIn is mA. The kernel
            // updates these every few seconds; treat them as a live
            // snapshot rather than instantaneous.
            var watts: Double = 0
            var volts: Double = 0
            var amps: Double = 0
            if case let .dictionary(kv) = props["PowerTelemetryData"] {
                let dict = Dictionary(kv, uniquingKeysWith: { a, _ in a })
                if let mw = dict["SystemPowerIn"]?.asUInt { watts = Double(mw) / 1000.0 }
                if let mv = dict["SystemVoltageIn"]?.asUInt { volts = Double(mv) / 1000.0 }
                if let ma = dict["SystemCurrentIn"]?.asUInt { amps  = Double(ma) / 1000.0 }
            }

            let pd = USBPDProfile(
                winning: USBPDOption(
                    voltageMV: UInt64(volts * 1000),
                    maxCurrentMA: UInt64(amps * 1000),
                    maxPowerMW: UInt64(watts * 1000)
                ),
                offered: [],
                brickID: nil
            )

            return [PortAccessoryInfo(
                id: TBNodeID(raw: id),
                portNumber: 1,
                connector: .acPower,
                connection: .device,
                connectionActive: true,
                detected: true,
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
                usbPD: watts > 0 ? pd : nil,
                registryProperties: props,
                registryPath: IORegBridge.path(of: svc)
            )]
        }
        return []
    }
}
