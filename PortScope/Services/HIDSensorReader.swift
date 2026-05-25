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

    /// Snapshot every readable sensor across all known sensor types.
    /// Keyed by the kernel's HID service `RegistryID` so the caller can
    /// join against the IORegistry walk used elsewhere.
    ///
    /// Apple's HID Event System gates each *sensor type* on a distinct
    /// PrimaryUsage code. A shared services list returns nothing useful;
    /// the kernel only populates the event payload after matching a
    /// service whose primary usage matches the page + type we're asking
    /// about. We open one client per type, set the appropriate matching
    /// dict, and merge the readings. Codes come from Apple's HID usage
    /// tables + the conventions Stats / Sensei / asitop use; they've
    /// been stable across Apple Silicon generations.
    static func readAll() -> [UInt64: Reading] {
        var out: [UInt64: Reading] = [:]
        // Temperature sensors — PMU per-core thermal probes + the
        // chassis / NVMe / battery probes that pass through HID.
        readGroup(usagePage: 0xff00, usage: 0x05,
                  eventType: HIDEventType.temperature.rawValue,
                  field: HIDEventField.temperatureLevel,
                  unit: "°C", eventName: "Temperature",
                  validRange: -50...200, into: &out)
        // Power rails — Apple's per-rail energy / power meters.
        readGroup(usagePage: 0xff00, usage: 0x0a,
                  eventType: HIDEventType.power.rawValue,
                  field: HIDEventField.powerMeasurement,
                  unit: "W", eventName: "Power",
                  validRange: 0...10_000, into: &out)
        // Current sensors — separately published on usage 0x0b.
        readGroup(usagePage: 0xff00, usage: 0x0b,
                  eventType: HIDEventType.power.rawValue,
                  field: HIDEventField.powerMeasurement,
                  unit: "A", eventName: "Current",
                  validRange: -50...50, into: &out)
        // Ambient light — on the standard HID Sensors page (0x20).
        readGroup(usagePage: 0x20, usage: 0x41,
                  eventType: HIDEventType.ambientLight.rawValue,
                  field: HIDEventField.ambientLightLevel,
                  unit: "lux", eventName: "Ambient Light",
                  validRange: 0...200_000, into: &out)
        return out
    }

    // MARK: - Per-type pass

    /// One matched-and-read pass for a single sensor type. Scopes the
    /// IOHIDEventSystem client to services that publish the requested
    /// PrimaryUsagePage + PrimaryUsage pair, then copies the typed
    /// event off each one and reads the float field.
    private static func readGroup(usagePage: Int,
                                  usage: Int,
                                  eventType: Int64,
                                  field: Int32,
                                  unit: String,
                                  eventName: String,
                                  validRange: ClosedRange<Double>,
                                  into out: inout [UInt64: Reading]) {
        // Monitor-type client (1) is the read-events-as-user surface —
        // requires the `com.apple.private.hid.client.event-monitor`
        // entitlement that PortScope.entitlements ships. Without the
        // entitlement the kernel hands back a Simple-type client whose
        // CopyEvent calls return nil, so the panel falls back to the
        // discovery-only mode.
        let client: AnyObject
        if let m = _IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 1, nil) {
            client = m.takeRetainedValue()
        } else if let s = _IOHIDEventSystemClientCreate(kCFAllocatorDefault) {
            client = s.takeRetainedValue()
        } else {
            return
        }
        let matching: [String: Any] = [
            "PrimaryUsagePage": usagePage,
            "PrimaryUsage": usage
        ]
        _ = _IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)

        guard let servicesUM = _IOHIDEventSystemClientCopyServices(client) else {
            return
        }
        let services = servicesUM.takeRetainedValue()
        let count = CFArrayGetCount(services)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service: AnyObject = unsafeBitCast(raw, to: AnyObject.self)
            guard let regID = registryID(of: service) else { continue }
            guard let eventUM = _IOHIDServiceClientCopyEvent(service, eventType, nil, 0) else {
                continue
            }
            let event = eventUM.takeRetainedValue()
            let v = _IOHIDEventGetFloatValue(event, field)
            guard v.isFinite, validRange.contains(v) else { continue }
            out[regID] = Reading(serviceID: regID,
                                 value: v,
                                 unit: unit,
                                 eventType: eventName)
        }
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
