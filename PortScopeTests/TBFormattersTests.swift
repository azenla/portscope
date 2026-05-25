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

    @Test("tbGenerationShortLabel covers the speeds we've seen in the wild")
    func generationShort() {
        #expect(tbGenerationShortLabel(0) == "Inactive")
        #expect(tbGenerationShortLabel(1) == "TB3 Gen 1")
        #expect(tbGenerationShortLabel(2) == "TB3 Gen 2")
        #expect(tbGenerationShortLabel(4) == "TB4")
        #expect(tbGenerationShortLabel(8) == "TB5")
        #expect(tbGenerationShortLabel(14) == "TB5 async")
        // Unknown values fall back to a numeric label so a future kernel
        // adding a new code doesn't produce an empty string.
        #expect(tbGenerationShortLabel(99) == "Speed 99")
    }

    @Test("tbLinkSpeedLabel is the long-form counterpart")
    func linkSpeed() {
        #expect(tbLinkSpeedLabel(0) == "Inactive")
        #expect(tbLinkSpeedLabel(8).contains("80 Gb/s"))
        #expect(tbLinkSpeedLabel(14).contains("120 Gb/s tx"))
        #expect(tbLinkSpeedLabel(255).contains("255"))
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
