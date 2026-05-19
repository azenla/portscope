//
//  BluetoothScanner.swift
//  PortScope
//
//  Builds a `BluetoothSnapshot` by shelling out to
//  `system_profiler -xml SPBluetoothDataType`. The IORegistry exposes
//  `IOBluetoothHCIController` but its property dict carries almost nothing
//  useful (no chipset name, firmware version, vendor/product ID, paired
//  device list, etc.). SPBluetoothDataType is the authoritative source that
//  the rest of macOS (System Information, Bluetooth menu) reads from.
//
//  We parse the XML plist directly so we never call into deprecated
//  IOBluetooth.framework symbols.
//

import Foundation

nonisolated enum BluetoothScanner {
    /// Run the scan synchronously. Safe to call off-main (the scanners are
    /// dispatched on a background task in the view model already).
    static func scan() -> BluetoothSnapshot {
        guard let plist = runSystemProfiler() else { return .empty }
        return parse(plist)
    }

    // MARK: - system_profiler invocation

    private static func runSystemProfiler() -> Any? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-xml", "SPBluetoothDataType", "-detailLevel", "full"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    // MARK: - Parsing

    private static func parse(_ plist: Any) -> BluetoothSnapshot {
        // SP returns an array of "data-type" dicts; we asked for one type,
        // so we expect a single-element top-level array.
        guard let top = plist as? [[String: Any]],
              let dataType = top.first,
              let items = dataType["_items"] as? [[String: Any]],
              let item = items.first else {
            return .empty
        }

        // Controller.
        let controller: BluetoothController?
        if let dict = item["controller_properties"] as? [String: Any] {
            controller = parseController(dict)
        } else {
            controller = nil
        }

        // Devices. SP wraps each device dict as `{ "DeviceName" : {…props} }`,
        // so we have to unwrap one level.
        let connected = parseDevices(item["device_connected"] as? [[String: Any]],
                                     isConnected: true)
        let paired = parseDevices(item["device_not_connected"] as? [[String: Any]],
                                  isConnected: false)

        return BluetoothSnapshot(controller: controller,
                                 connected: connected.sorted { $0.name < $1.name },
                                 paired: paired.sorted { $0.name < $1.name })
    }

    private static func parseController(_ dict: [String: Any]) -> BluetoothController {
        let state = (dict["controller_state"] as? String ?? "").lowercased()
        let disc = (dict["controller_discoverable"] as? String ?? "").lowercased()
        return BluetoothController(
            address: dict["controller_address"] as? String,
            chipset: dict["controller_chipset"] as? String,
            firmwareVersion: dict["controller_firmwareVersion"] as? String,
            productID: dict["controller_productID"] as? String,
            vendorID: dict["controller_vendorID"] as? String,
            transport: dict["controller_transport"] as? String,
            isOn: state.contains("on"),
            isDiscoverable: disc.contains("on"),
            supportedServicesRaw: dict["controller_supportedServices"] as? String
        )
    }

    private static func parseDevices(_ raw: [[String: Any]]?, isConnected: Bool) -> [BluetoothDevice] {
        guard let raw else { return [] }
        var out: [BluetoothDevice] = []
        out.reserveCapacity(raw.count)
        for wrapper in raw {
            guard let (name, dictAny) = wrapper.first,
                  let dict = dictAny as? [String: Any] else { continue }
            out.append(BluetoothDevice(
                name: name,
                address: dict["device_address"] as? String,
                vendorID: dict["device_vendorID"] as? String,
                productID: dict["device_productID"] as? String,
                firmwareVersion: dict["device_firmwareVersion"] as? String,
                minorType: dict["device_minorType"] as? String,
                rssi: dict["device_rssi"] as? String,
                serialNumber: dict["device_serialNumber"] as? String,
                servicesRaw: dict["device_services"] as? String,
                batteryLevel: dict["device_batteryLevel"] as? String,
                batteryLevelLeft: dict["device_batteryLevelLeft"] as? String,
                batteryLevelRight: dict["device_batteryLevelRight"] as? String,
                batteryLevelCase: dict["device_batteryLevelCase"] as? String,
                caseVersion: dict["device_caseVersion"] as? String,
                isConnected: isConnected
            ))
        }
        return out
    }
}
