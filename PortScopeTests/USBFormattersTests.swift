//
//  USBFormattersTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("USB formatters")
struct USBFormattersTests {

    @Test("usbSpeedLabel maps each enum case to a full label")
    func speedLabel() {
        #expect(usbSpeedLabel(0).hasPrefix("USB 1.0"))
        #expect(usbSpeedLabel(2) == "USB 2.0 High Speed")
        #expect(usbSpeedLabel(3).contains("SuperSpeed"))
        #expect(usbSpeedLabel(5).contains("USB 3.2"))
        #expect(usbSpeedLabel(99) == "—")
        #expect(usbSpeedLabel(nil) == "—")
    }

    @Test("usbSpeedShortLabel is concise for dense rows")
    func speedShort() {
        #expect(usbSpeedShortLabel(2) == "USB 2.0")
        #expect(usbSpeedShortLabel(4) == "USB 3.1")
        #expect(usbSpeedShortLabel(5) == "USB 3.2×2")
        #expect(usbSpeedShortLabel(nil) == "—")
    }

    @Test("USBSpeed.rateLabel switches to Gb/s above 1000 Mb/s")
    func rateLabel() {
        // 1.5 Mb/s for `.low` round-trips through %.0f formatting because
        // 1.5 ≥ 1 — that's an irrelevant detail though. The assertion we
        // care about is the unit choice: USB 2 stays in Mb/s, USB 3 hops
        // to Gb/s. Assert on `contains` so the harmless rounding of `.low`
        // doesn't lock us into a printf quirk.
        #expect(USBSpeed.low.rateLabel.contains("Mb/s"))
        #expect(USBSpeed.full.rateLabel == "12 Mb/s")
        #expect(USBSpeed.high.rateLabel == "480 Mb/s")
        #expect(USBSpeed.super.rateLabel == "5 Gb/s")
        #expect(USBSpeed.superPlus.rateLabel == "10 Gb/s")
        #expect(USBSpeed.superPlusBy2.rateLabel == "20 Gb/s")
    }

    @Test("usbDeviceClassLabel resolves known classes and falls back")
    func classLabel() {
        #expect(usbDeviceClassLabel(0x09) == "USB Hub")
        #expect(usbDeviceClassLabel(0x08) == "Mass Storage")
        #expect(usbDeviceClassLabel(0xFF) == "Vendor-Specific")
        // Unknown class codes fall back to a stable "Class 0xNN" string —
        // never an empty label.
        #expect(usbDeviceClassLabel(0x7A).contains("0x7A"))
        #expect(usbDeviceClassLabel(nil) == "Unknown")
    }

    @Test("PhysicalPortMode labels reflect the case payload")
    func modeLabels() {
        #expect(PhysicalPortMode.empty.label == "Empty")
        #expect(PhysicalPortMode.displayOnly.label == "Display")
        #expect(PhysicalPortMode.unknown.label == "Unknown")
        #expect(PhysicalPortMode.charging(watts: 30).label == "Charging · 30 W")
        // Charging without a known wattage still reads as charging — never
        // "Charging · 0 W", which would be misleading.
        #expect(PhysicalPortMode.charging(watts: nil).label == "Charging")
        #expect(PhysicalPortMode.charging(watts: 0).label == "Charging")
        // A thunderbolt port with link speed 0 still reports "Thunderbolt"
        // (not "Inactive") — the mode being .thunderbolt means we know it
        // is, even if we can't read a link speed yet.
        #expect(PhysicalPortMode.thunderbolt(linkSpeed: 0).label == "Thunderbolt")
        // Per the corrected WhatCable encoding: 0x2 = TB5, 0x4 = TB4,
        // 0x8 = TB3. The previous mapping (8 = TB5) was empirically
        // wrong on every TB5-class host and has been replaced.
        #expect(PhysicalPortMode.thunderbolt(linkSpeed: 0x2).label == "TB5")
        #expect(PhysicalPortMode.thunderbolt(linkSpeed: 0x8).label == "TB3")
        #expect(PhysicalPortMode.usbOnly(speed: nil).label == "USB")
        #expect(PhysicalPortMode.usbOnly(speed: 5).label == "USB 3.2×2")
    }
}
