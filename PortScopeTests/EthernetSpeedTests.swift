//
//  EthernetSpeedTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("Ethernet helpers")
struct EthernetSpeedTests {

    @Test("ethernetSpeedLabel uses friendly marketing units for known speeds")
    func friendlyLabels() {
        #expect(ethernetSpeedLabel(10) == "10 Mb/s")
        #expect(ethernetSpeedLabel(100) == "100 Mb/s")
        #expect(ethernetSpeedLabel(1_000) == "1 Gb/s")
        #expect(ethernetSpeedLabel(2_500) == "2.5 Gb/s")
        #expect(ethernetSpeedLabel(5_000) == "5 Gb/s")
        #expect(ethernetSpeedLabel(10_000) == "10 Gb/s")
    }

    @Test("ethernetSpeedLabel falls back gracefully for odd negotiated values")
    func fallbackLabels() {
        // Some PHYs occasionally report odd auto-neg speeds (e.g. 25 Gb/s on
        // Mac Pro option cards). They should still render, not vanish.
        #expect(ethernetSpeedLabel(25_000) == "25.0 Gb/s")
        #expect(ethernetSpeedLabel(7) == "7 Mb/s")
    }

    @Test("decodeEthernetSpeedMbps decodes the IFM_* packed word")
    func decodeMedium() {
        // Format mirrors the kernel's hex-string `IOActiveMedium`. Bits 5..7
        // = 0x20 marks an ethernet medium; low 5 bits pick the subtype.
        // 1G-T base = 0x20 | 16 = 0x30 ; with IFM_FDX (0x00100000) high bits.
        #expect(decodeEthernetSpeedMbps(.string("00100030")) == 1_000)
        // 10G-T base = 0x20 | 26 = 0x3a
        #expect(decodeEthernetSpeedMbps(.string("0010003a")) == 10_000)
        // 2.5G-T base = 0x20 | 29 = 0x3d
        #expect(decodeEthernetSpeedMbps(.string("0010003d")) == 2_500)
    }

    @Test("decodeEthernetSpeedMbps rejects non-ethernet media types")
    func decodeRejectsNonEther() {
        // High nibble != 2 means a different IFM_TYPE (Wi-Fi, fibre channel,
        // …) — we must not invent ethernet speeds for them.
        #expect(decodeEthernetSpeedMbps(.string("00100040")) == nil)
        // Garbage strings round-trip to nil, not 0.
        #expect(decodeEthernetSpeedMbps(.string("not hex")) == nil)
        #expect(decodeEthernetSpeedMbps(nil) == nil)
    }

    @Test("decodeEthernetSpeedMbps prefers the explicit unsigned form")
    func decodePrefersUnsigned() {
        // Newer drivers publish a numeric Mb/s directly; if so we use it
        // verbatim without attempting to decode IFM_* bits.
        #expect(decodeEthernetSpeedMbps(.unsigned(2_500)) == 2_500)
        // Zero unsigned should fall through (not be reported as 0 Mb/s).
        #expect(decodeEthernetSpeedMbps(.unsigned(0)) == nil)
    }

    @Test("formatMACAddress canonicalises the hex-string variant")
    func macFromHexString() {
        let v = IORegValue.string("0x6c6e070a2336")
        #expect(formatMACAddress(v) == "6c:6e:07:0a:23:36")
    }

    @Test("formatMACAddress canonicalises the Data variant")
    func macFromData() {
        let bytes = Data([0x00, 0xC5, 0x85, 0x0F, 0xBD, 0xCB])
        #expect(formatMACAddress(.data(bytes)) == "00:c5:85:0f:bd:cb")
    }

    @Test("formatMACAddress returns nil for unparseable input")
    func macUnparseable() {
        #expect(formatMACAddress(nil) == nil)
        #expect(formatMACAddress(.unsigned(123)) == nil)
        // Too few bytes — pass the string through unchanged rather than
        // truncating to a fake MAC.
        let short = IORegValue.string("0x00c5")
        #expect(formatMACAddress(short) == "0x00c5")
    }
}
