//
//  HIDDeviceScanner.swift
//  PortScope
//
//  Enumerate every IOKit HID service on the host and bucket it by
//  category (keyboard / trackpad / multitouch / sensor / biometric /
//  audio / generic). We walk both `IOHIDDevice` (USB / BT / external)
//  and `IOHIDEventService` (kernel-resident drivers for the built-in
//  sensors, keyboards, and trackpads) so the sidebar surfaces the
//  full HID census instead of just the user-attached peripherals.
//

import Foundation
import IOKit

nonisolated enum HIDDeviceScanner {
    static func scan() -> HIDDevicesSnapshot {
        var seen = Set<UInt64>()
        var out: [HIDDeviceInfo] = []
        // IOHIDEventService covers the kernel-driver path used by every
        // sensor + the built-in keyboard / trackpad. IOHIDDevice covers
        // user-attached USB / Bluetooth peripherals. They overlap on
        // some devices; the registry id is the dedupe key.
        for cls in ["IOHIDEventService", "IOHIDDevice"] {
            for svc in IORegBridge.services(matchingClass: cls) {
                defer { IOObjectRelease(svc) }
                guard let regID = IORegBridge.entryID(of: svc) else { continue }
                if seen.contains(regID) { continue }
                seen.insert(regID)
                let props = IORegBridge.properties(of: svc)
                let kernelClass = IORegBridge.className(of: svc) ?? cls
                let product = props["Product"]?.asString
                let manufacturer = props["Manufacturer"]?.asString
                let vid = props["VendorID"]?.asUInt
                let pid = props["ProductID"]?.asUInt
                let usagePage = props["PrimaryUsagePage"]?.asUInt
                let usage = props["PrimaryUsage"]?.asUInt
                let builtIn = props["Built-In"]?.asBool ?? false
                let category = classify(kernelClass: kernelClass,
                                        usagePage: usagePage,
                                        usage: usage,
                                        product: product)
                out.append(HIDDeviceInfo(
                    registryID: regID,
                    product: product,
                    manufacturer: manufacturer,
                    kernelClass: kernelClass,
                    vendorID: vid,
                    productID: pid,
                    usagePage: usagePage,
                    usage: usage,
                    builtIn: builtIn,
                    category: category
                ))
            }
        }
        return HIDDevicesSnapshot(devices: out)
    }

    /// Pick a sidebar bucket for a HID device. Apple-driver class names
    /// are the strongest signal — every kernel-resident sensor / keyboard
    /// / trackpad has a recognisable prefix. We fall back to the HID
    /// usage page only when the class name is generic.
    private static func classify(kernelClass: String,
                                 usagePage: UInt64?,
                                 usage: UInt64?,
                                 product: String?) -> HIDDeviceCategory {
        if kernelClass.contains("PMUTempSensor") { return .temperatureSensor }
        if kernelClass.contains("PMUPowerSensor") { return .powerSensor }
        if kernelClass.contains("NVMeTemperatureSensor") { return .temperatureSensor }
        if kernelClass.contains("ALSColorDriver") || kernelClass.contains("SPUVD6286")
            || kernelClass.contains("ALSSensor") { return .ambientLight }
        if kernelClass.contains("Keyboard") { return .keyboard }
        if kernelClass.contains("Multitouch") { return .multitouch }
        if kernelClass.contains("Trackpad") { return .trackpad }
        if kernelClass.contains("Mesa") { return .biometric }
        if kernelClass.contains("Audio") { return .audio }
        if kernelClass.contains("Buttons") { return .button }
        // HID usage pages — kept narrow on purpose, only the ones Apple
        // actually uses for built-in chassis HID. The full HID spec
        // enumerates many more pages, but they all funnel into one of
        // these driver classes.
        switch usagePage {
        case 0x01: // Generic Desktop — keyboard/mouse-ish
            if let u = usage, u == 6 { return .keyboard }
            return .generic
        case 0x0D: return .multitouch          // Digitiser
        case 0x20: return .powerSensor         // Sensor page
        case 0xFF00: return .powerSensor       // Apple Vendor
        default: break
        }
        if let p = product?.lowercased() {
            if p.contains("trackpad") { return .trackpad }
            if p.contains("keyboard") { return .keyboard }
            if p.contains("button") { return .button }
        }
        return .generic
    }
}
