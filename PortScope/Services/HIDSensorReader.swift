//
//  HIDSensorReader.swift
//  PortScope
//
//  Read live values from the HID Event System — Apple's name for the
//  in-kernel pipeline that publishes thermal, power, and ambient-light
//  sensor readings. The public `IOHIDManager` API can enumerate HID
//  devices but doesn't return the *typed* sensor events PortScope
//  needs; the typed-event readers live in `IOHIDEventSystemClient`,
//  which is a private framework. Apple sensor apps (iStat Menus,
//  Stats, TG Pro, asitop, etc.) all use this same surface, and the
//  symbols have been stable since Mac OS X 10.7.
//
//  We declare the entry points with `@_silgen_name` so the linker
//  resolves them against the running `/System/Library/Frameworks/
//  IOKit.framework/IOKit` binary at process start. Return types use
//  `Unmanaged` so ARC handles the +1 retain Apple's `*Create` /
//  `*Copy` functions hand back.
//

import Foundation
import IOKit
import CoreFoundation

// MARK: - Private symbol bindings
//
// All `@_silgen_name` bindings are explicitly `nonisolated` so they
// can be called from `Task.detached` paths without an actor hop.

@_silgen_name("IOHIDEventSystemClientCreate")
nonisolated private func _IOHIDEventSystemClientCreate(
    _ allocator: CFAllocator?
) -> Unmanaged<AnyObject>?

/// The default `Create` returns a "Simple" client (type 4) that can't
/// read events — `IOHIDServiceClientCopyEvent` returns nil for every
/// query. To read sensor values we need a Monitor (type 1) client.
/// The function takes a client type and an attributes dictionary; on
/// macOS Sonoma+ both can be nil for the Monitor client.
@_silgen_name("IOHIDEventSystemClientCreateWithType")
nonisolated private func _IOHIDEventSystemClientCreateWithType(
    _ allocator: CFAllocator?,
    _ type: Int32,
    _ attributes: CFDictionary?
) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
nonisolated private func _IOHIDEventSystemClientSetMatching(
    _ client: AnyObject,
    _ matching: CFDictionary?
) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
nonisolated private func _IOHIDEventSystemClientCopyServices(
    _ client: AnyObject
) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyEvent")
nonisolated private func _IOHIDServiceClientCopyEvent(
    _ service: AnyObject, _ type: Int64,
    _ matching: AnyObject?, _ options: Int64
) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyProperty")
nonisolated private func _IOHIDServiceClientCopyProperty(
    _ service: AnyObject, _ key: CFString
) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetFloatValue")
nonisolated private func _IOHIDEventGetFloatValue(
    _ event: AnyObject, _ field: Int32
) -> Double

// MARK: - HID event types + fields
//
// These mirror Apple's `IOHIDEventTypes.h`. Each event-type integer
// has a base of `type << 16` and field offsets above it. The values
// here are the ones PortScope reads (temperature, power, ambient
// light) — the full enum is much larger but irrelevant to a sensor
// viewer.

nonisolated private enum HIDEventType: Int64 {
    case temperature = 15
    case power = 25
    case ambientLight = 12
}

nonisolated private enum HIDEventField {
    static func base(_ type: HIDEventType) -> Int32 {
        return Int32(type.rawValue << 16)
    }
    static let temperatureLevel: Int32 = base(.temperature) + 0
    static let powerMeasurement: Int32 = base(.power) + 0
    static let ambientLightLevel: Int32 = base(.ambientLight) + 0
}

// MARK: - Public reader

nonisolated struct HIDSensorReader {
    struct Reading {
        let serviceID: UInt64
        let value: Double
        let unit: String
        let eventType: String
    }

    /// Snapshot every readable sensor in one IOHIDEventSystemClient
    /// session. Keyed by the kernel's HID service `RegistryID` so the
    /// caller can join against the IORegistry walk used elsewhere.
    static func readAll() -> [UInt64: Reading] {
        // `kIOHIDEventSystemClientTypeMonitor = 1`. The basic
        // `IOHIDEventSystemClientCreate` defaults to "Simple" which
        // can't read events; Monitor is the read-events-as-a-user
        // client type. Admin (type 0) requires root and isn't needed.
        guard let clientUM = _IOHIDEventSystemClientCreateWithType(
            kCFAllocatorDefault, 1, nil
        ) else { return [:] }
        let client = clientUM.takeRetainedValue()
        // Match every service on the Apple Vendor usage page (0xff00).
        // Without the matching dict the kernel returns the full HID
        // device list and most of those services don't carry typed
        // sensor events — we'd waste time querying keyboards / mice
        // for a temperature reading.
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00]
        _ = _IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)

        guard let servicesUM = _IOHIDEventSystemClientCopyServices(client) else {
            return [:]
        }
        let services = servicesUM.takeRetainedValue()
        let count = CFArrayGetCount(services)
        var out: [UInt64: Reading] = [:]
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            // CFArrayGetValueAtIndex returns +0; bridge to AnyObject for
            // the typed CF-bridged helpers below. The array owns the
            // service references for its lifetime, so we don't retain.
            let service: AnyObject = unsafeBitCast(raw, to: AnyObject.self)
            guard let regID = registryID(of: service) else { continue }
            // Each service is one specific sensor. Try the three event
            // types we know how to interpret; the first that returns
            // a finite value wins.
            if let r = readTemperature(service: service, regID: regID) {
                out[regID] = r
                continue
            }
            if let r = readPower(service: service, regID: regID) {
                out[regID] = r
                continue
            }
            if let r = readAmbientLight(service: service, regID: regID) {
                out[regID] = r
                continue
            }
        }
        return out
    }

    // MARK: - Single-event reads

    private static func readTemperature(service: AnyObject, regID: UInt64) -> Reading? {
        guard let eventUM = _IOHIDServiceClientCopyEvent(service,
                                                         HIDEventType.temperature.rawValue,
                                                         nil, 0) else { return nil }
        let event = eventUM.takeRetainedValue()
        let v = _IOHIDEventGetFloatValue(event, HIDEventField.temperatureLevel)
        // Apple Silicon publishes thermal readings in degrees Celsius.
        // Reject NaN / infinity and obviously-impossible readings, but
        // keep low values — calibration sensors and idle cores can sit
        // near 0 °C and that's a legitimate reading.
        guard v.isFinite, v > -50, v < 200 else { return nil }
        return Reading(serviceID: regID, value: v, unit: "°C", eventType: "Temperature")
    }

    private static func readPower(service: AnyObject, regID: UInt64) -> Reading? {
        guard let eventUM = _IOHIDServiceClientCopyEvent(service,
                                                         HIDEventType.power.rawValue,
                                                         nil, 0) else { return nil }
        let event = eventUM.takeRetainedValue()
        let v = _IOHIDEventGetFloatValue(event, HIDEventField.powerMeasurement)
        guard v.isFinite, v >= 0 else { return nil }
        return Reading(serviceID: regID, value: v, unit: "W", eventType: "Power")
    }

    private static func readAmbientLight(service: AnyObject, regID: UInt64) -> Reading? {
        guard let eventUM = _IOHIDServiceClientCopyEvent(service,
                                                         HIDEventType.ambientLight.rawValue,
                                                         nil, 0) else { return nil }
        let event = eventUM.takeRetainedValue()
        let v = _IOHIDEventGetFloatValue(event, HIDEventField.ambientLightLevel)
        guard v.isFinite, v >= 0 else { return nil }
        return Reading(serviceID: regID, value: v, unit: "lux", eventType: "Ambient Light")
    }

    // MARK: - Property helpers

    /// The IOHIDServiceClient publishes its kernel IORegistry entry id
    /// as the `RegistryID` property — same number `IOObjectGetRegistryEntryID`
    /// would return on the underlying io_service_t. Used to merge HID
    /// readings with the static sensor list mined from IORegistry.
    private static func registryID(of service: AnyObject) -> UInt64? {
        guard let cfUM = _IOHIDServiceClientCopyProperty(service, "RegistryID" as CFString) else {
            return nil
        }
        let cf = cfUM.takeRetainedValue()
        if let n = cf as? UInt64 { return n }
        if let n = cf as? NSNumber { return n.uint64Value }
        return nil
    }
}
