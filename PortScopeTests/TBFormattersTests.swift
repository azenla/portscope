//
//  TBFormattersTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("Thunderbolt formatters")
struct TBFormattersTests {

    @Test("tbBandwidthLabel uses Mb/s under 1 Gb/s and Gb/s above")
    func bandwidth() {
        // Field is in 100 Mb/s units (see CLAUDE.md "Bandwidth fields are in
        // 100 Mb/s units, not 10 Mb/s.")
        #expect(tbBandwidthLabel(0) == "0 Gb/s")
        #expect(tbBandwidthLabel(1) == "100 Mb/s")
        #expect(tbBandwidthLabel(9) == "900 Mb/s")
        #expect(tbBandwidthLabel(10) == "1 Gb/s")
        #expect(tbBandwidthLabel(800) == "80 Gb/s")
        #expect(tbBandwidthLabel(1200) == "120 Gb/s")
    }

    @Test("tbGenerationShortLabel uses the WhatCable-anchored encoding")
    func generationShort() {
        // Per CLAUDE.md, the `Current Link Speed` encoding is:
        //   0   = inactive
        //   0x2 = TB5 / USB4 v2 (40 Gb/s/lane)
        //   0x4 = TB4 / USB4 v1 (20 Gb/s/lane)
        //   0x8 = TB3 (10 Gb/s/lane)
        // The earlier mapping that called `8 = TB5` was empirically wrong
        // and was replaced — these assertions track the corrected codes.
        #expect(tbGenerationShortLabel(0) == "Inactive")
        #expect(tbGenerationShortLabel(0x2) == "TB5")
        #expect(tbGenerationShortLabel(0x4) == "TB4")
        #expect(tbGenerationShortLabel(0x8) == "TB3")
        // Bitmask combinations (used for Target/Supported, not Current)
        // fall through to tbSupportedLinkSpeedLabel.
        #expect(tbGenerationShortLabel(0xE) == "TB5 · TB4 · TB3")
    }

    @Test("tbLinkSpeedLabel is the long-form counterpart")
    func linkSpeed() {
        #expect(tbLinkSpeedLabel(0) == "Inactive")
        #expect(tbLinkSpeedLabel(0x2).contains("40 Gb/s per lane"))
        #expect(tbLinkSpeedLabel(0x4).contains("20 Gb/s per lane"))
        #expect(tbLinkSpeedLabel(0x8).contains("10 Gb/s per lane"))
        // Bitmask values (Target/Supported style) fall through to the
        // supported-link label.
        #expect(tbLinkSpeedLabel(0xE) == "TB5 · TB4 · TB3")
    }

    @Test("TBAdapterType decodes the stable codes and labels them")
    func adapterTypeStable() {
        #expect(TBAdapterType(rawValue: 0) == .inactive)
        if case .lane(let i) = TBAdapterType(rawValue: 1) {
            #expect(i == 1)
        } else {
            Issue.record("rawValue 1 should map to a lane adapter")
        }
        #expect(TBAdapterType(rawValue: 2) == .nhi)
    }

    @Test("TBAdapterType treats unknown high codes as opaque")
    func adapterTypeUnknown() {
        // Per CLAUDE.md: the high-value codes are NOT portable across TB
        // controller generations, so the enum deliberately keeps them as raw
        // values rather than mislabeling them.
        let t = TBAdapterType(rawValue: 0x100001)
        if case .unknown(let v) = t {
            #expect(v == 0x100001)
            #expect(t.label.contains("100001"))
        } else {
            Issue.record("0x100001 must be .unknown to avoid vendor-specific mislabeling")
        }
    }

    @Test("usbBcdVersion drops trailing zero sub-revision")
    func bcdVersion() {
        #expect(usbBcdVersion(0x0320) == "3.2")
        #expect(usbBcdVersion(0x0321) == "3.2.1")
        #expect(usbBcdVersion(0x0210) == "2.1")
        #expect(usbBcdVersion(nil) == "—")
    }

    @Test("usbCapabilityFromBCD maps protocol version to peak speed")
    func capabilityCeiling() {
        // Major bumps mean a real ceiling change; minor bumps within 3.x
        // distinguish 3.0 / 3.1 / 3.2 because USB-IF uses different
        // signalling rates per minor (5G → 10G → 20G).
        #expect(usbCapabilityFromBCD(0x0200) == .high)
        #expect(usbCapabilityFromBCD(0x0210) == .high)
        #expect(usbCapabilityFromBCD(0x0300) == .super)
        #expect(usbCapabilityFromBCD(0x0310) == .superPlus)
        #expect(usbCapabilityFromBCD(0x0320) == .superPlusBy2)
        #expect(usbCapabilityFromBCD(0x0110) == .full)
        #expect(usbCapabilityFromBCD(0x0100) == .full)
        #expect(usbCapabilityFromBCD(nil) == nil)
        // Unknown major version doesn't get a guess — better to render
        // nothing than mislabel the speed ceiling.
        #expect(usbCapabilityFromBCD(0x0500) == nil)
    }

    @Test("usbIsDowngraded only fires when capability > negotiated")
    func downgrade() {
        // USB-3.2 device negotiated at SuperSpeed (5 G) — downgraded.
        #expect(usbIsDowngraded(bcdUSB: 0x0320,
                                currentSpeed: UInt64(USBSpeed.super.rawValue)) == true)
        // USB-2.0 device negotiated at Full Speed — downgraded
        // (HID-by-design is a hint the UI overlays, not a kernel signal).
        #expect(usbIsDowngraded(bcdUSB: 0x0200,
                                currentSpeed: UInt64(USBSpeed.full.rawValue)) == true)
        // USB-3.0 device negotiated at SuperSpeed — match, no downgrade.
        #expect(usbIsDowngraded(bcdUSB: 0x0300,
                                currentSpeed: UInt64(USBSpeed.super.rawValue)) == false)
        // No bcdUSB → can't decide → don't surface.
        #expect(usbIsDowngraded(bcdUSB: nil,
                                currentSpeed: UInt64(USBSpeed.high.rawValue)) == false)
    }

    @Test("TBNode.formatValue prefixes hex for selected fields")
    func nodeFormatValue() {
        let s = TBNode.formatValue("Vendor ID", .unsigned(0x05ac))
        #expect(s.contains("0x05AC"))
        #expect(s.contains("(1452)"))

        let uid = TBNode.formatValue("UID", .unsigned(0xdeadbeef))
        #expect(uid.contains("00000000DEADBEEF"))

        // Power-flavoured fields get a watt approximation at 5 V appended.
        let pwr = TBNode.formatValue("UsbPowerSinkAllocation", .unsigned(900))
        #expect(pwr.contains("900 mA"))
        #expect(pwr.contains("W @ 5 V"))
    }
}
