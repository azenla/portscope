//
//  AccessoryEnumTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("Accessory enums")
struct AccessoryEnumTests {

    @Test("PortConnectorType maps every kernel string we know")
    func connectorType() {
        #expect(PortConnectorType("USB-C") == .usbC)
        #expect(PortConnectorType("USB-A") == .usbA)
        #expect(PortConnectorType("MagSafe 3") == .magsafe)
        #expect(PortConnectorType("HDMI") == .hdmi)
        #expect(PortConnectorType("SD") == .sdCard)
        #expect(PortConnectorType("SD Card") == .sdCard)
        #expect(PortConnectorType("SDXC") == .sdCard)
        #expect(PortConnectorType("AC Power") == .acPower)
        #expect(PortConnectorType("Power") == .acPower)
        #expect(PortConnectorType("RJ-45") == .ethernet)
        #expect(PortConnectorType("Ethernet") == .ethernet)
        // Unknown kernel strings round-trip through .other so the kernel
        // value isn't lost.
        if case .other(let s) = PortConnectorType("DisplayPort 1.4") {
            #expect(s == "DisplayPort 1.4")
        } else {
            Issue.record("Unknown port descriptions should preserve the raw kernel string")
        }
        // Nil description => .other("Unknown") (never .usbC by default).
        if case .other(let s) = PortConnectorType(nil) {
            #expect(s == "Unknown")
        } else {
            Issue.record("Nil description should fall back to .other(\"Unknown\")")
        }
    }

    @Test("PortConnectorType.label is stable user-facing text")
    func connectorLabel() {
        #expect(PortConnectorType.usbC.label == "USB-C")
        #expect(PortConnectorType.magsafe.label == "MagSafe 3")
        #expect(PortConnectorType.acPower.label == "AC Power")
    }

    @Test("AccessoryConnection.isConnected is false only for .none")
    func connectionState() {
        #expect(AccessoryConnection(nil) == .none)
        #expect(AccessoryConnection("None") == .none)
        #expect(AccessoryConnection.none.isConnected == false)
        #expect(AccessoryConnection("Device").isConnected == true)
        #expect(AccessoryConnection("Audio Adapter") == .audioAdapter)
        #expect(AccessoryConnection("Audio Adapter").isConnected == true)
        // Unknown roles preserve the raw kernel string but count as connected.
        if case .other(let s) = AccessoryConnection("Vendor Mode X") {
            #expect(s == "Vendor Mode X")
        } else {
            Issue.record("Unknown connection roles should round-trip through .other")
        }
    }

    @Test("PlugOrientation decodes the kernel codes")
    func plugOrientation() {
        #expect(PlugOrientation(0) == .unattached)
        #expect(PlugOrientation(nil) == .unattached)
        #expect(PlugOrientation(1) == .unflipped)
        #expect(PlugOrientation(2) == .flipped)
        if case .unknown(let v) = PlugOrientation(7) {
            #expect(v == 7)
        } else {
            Issue.record("Unknown orientation codes should round-trip the raw value")
        }
    }

    @Test("USBCTransport recognises the canonical kernel strings")
    func transports() {
        #expect(USBCTransport("CC") == .cc)
        #expect(USBCTransport("USB2") == .usb2)
        #expect(USBCTransport("USB3") == .usb3)
        #expect(USBCTransport("CIO") == .cio)
        #expect(USBCTransport("DisplayPort") == .displayPort)
        if case .other(let s) = USBCTransport("Vendor-X") {
            #expect(s == "Vendor-X")
        } else {
            Issue.record("Unrecognised transport names should fall through to .other")
        }
    }

    @Test("displayPortPinAssignmentLabel covers all USB-IF pin assignments")
    func pinAssignment() {
        #expect(displayPortPinAssignmentLabel(0) == "None")
        #expect(displayPortPinAssignmentLabel(1).hasPrefix("A"))
        #expect(displayPortPinAssignmentLabel(6).hasPrefix("F"))
        #expect(displayPortPinAssignmentLabel(7) == "Assignment 7")
    }

    @Test("USBPDOption formats voltage/current/power for the table view")
    func pdOptionLabels() {
        let o = USBPDOption(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000)
        #expect(o.voltageLabel == "20 V")
        // %.2g chops trailing zeros — 5.0 A renders as "5 A".
        #expect(o.currentLabel == "5 A")
        // ≥ 10 W rounds to whole watts; below uses one decimal.
        #expect(o.powerLabel == "100 W")

        let small = USBPDOption(voltageMV: 5_000, maxCurrentMA: 900, maxPowerMW: 4_500)
        #expect(small.voltageLabel == "5 V")
        #expect(small.powerLabel == "4.5 W")
    }

    @Test("PortAccessoryInfo.cableLabel joins what we know with a separator")
    func cableLabel() {
        let with = Fix.accessory(
            cableVendorID: 0x291A,
            cableProductID: 0x83B5,
            cableManufacturer: "Infineon"
        )
        let l = with.cableLabel
        #expect(l?.contains("Infineon") == true)
        #expect(l?.contains("VID 0x291A") == true)
        #expect(l?.contains("PID 0x83B5") == true)

        // No e-marker fields known at all → no label.
        let none = Fix.accessory()
        #expect(none.cableLabel == nil)
    }

    @Test("carriesDisplay requires the connection to actually be live")
    func carriesDisplay() {
        // CLAUDE.md: HPDAsserted can linger after a display is unplugged, so
        // we must gate it on connectionActive — otherwise an empty port
        // reads as "carrying a display".
        let lingering = Fix.accessory(connectionActive: false, hpdAsserted: true)
        #expect(lingering.carriesDisplay == false)

        let live = Fix.accessory(connectionActive: true, hpdAsserted: true)
        #expect(live.carriesDisplay == true)

        let altMode = Fix.accessory(connectionActive: true, active: [.displayPort])
        #expect(altMode.carriesDisplay == true)
    }

    @Test("carriesThunderbolt mirrors the CIO transport flag")
    func carriesTB() {
        #expect(Fix.accessory(active: [.cio]).carriesThunderbolt == true)
        #expect(Fix.accessory(active: [.usb3]).carriesThunderbolt == false)
        #expect(Fix.accessory(active: []).carriesThunderbolt == false)
    }
}
