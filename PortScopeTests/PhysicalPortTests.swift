//
//  PhysicalPortTests.swift
//  PortScopeTests
//
//  Covers the per-connector branches of `PhysicalPort.cliTitle` and
//  `PhysicalPort.statusLabel`. The status label is rendered as the
//  subtitle in the sidebar; the connector-specific cases (AC / Ethernet
//  / SD / HDMI) were added when those receptacles moved out of the
//  unified USB-C view, so they get a dedicated suite to make sure
//  refactors don't quietly swallow the special cases.
//

import Testing
import Foundation
@testable import PortScope

@Suite("PhysicalPort labels")
struct PhysicalPortTests {

    @Test("cliTitle uses singular form for connectors that only ship one")
    func cliTitles() {
        #expect(Fix.port(number: 1, connector: .usbC).cliTitle == "USB-C Port 1")
        #expect(Fix.port(number: 3, connector: .usbA).cliTitle == "USB-A Port 3")
        // HDMI / SD / MagSafe / AC Power chassis ship a single receptacle, so
        // the title drops the number.
        #expect(Fix.port(number: 1, connector: .hdmi).cliTitle == "HDMI Port")
        #expect(Fix.port(number: 1, connector: .sdCard).cliTitle == "SD Card Slot")
        #expect(Fix.port(number: 1, connector: .magsafe).cliTitle == "MagSafe 3 Port")
        #expect(Fix.port(number: 1, connector: .acPower).cliTitle == "Power Input")
    }

    @Test("Ethernet keeps the number only when more than one jack exists")
    func ethernetCliTitle() {
        // Single-jack Macs (mini, Studio, iMac) — drop the number; reads
        // like noise otherwise.
        #expect(Fix.port(number: 1, connector: .ethernet).cliTitle == "Ethernet Port")
        // Mac Pro back I/O card ships two jacks — keep the number so the
        // user can tell them apart.
        #expect(Fix.port(number: 2, connector: .ethernet).cliTitle == "Ethernet Port 2")
    }

    @Test("AC Power status surfaces measured wattage when telemetry is live")
    func acPowerStatus() {
        let pdo = USBPDOption(voltageMV: 20_000, maxCurrentMA: 2_500, maxPowerMW: 50_000)
        let acc = Fix.accessory(connector: .acPower,
                                connectionActive: true,
                                usbPD: USBPDProfile(winning: pdo, offered: [], brickID: nil))
        let port = Fix.port(connector: .acPower, accessory: acc, mode: .charging(watts: 50))
        #expect(port.statusLabel == "Drawing 50.0 W · 20.0 V")
    }

    @Test("AC Power status falls back to Empty/Connected when telemetry is absent")
    func acPowerStatusFallback() {
        let off = Fix.accessory(connector: .acPower, connectionActive: false)
        #expect(Fix.port(connector: .acPower, accessory: off).statusLabel == "Empty")

        let on = Fix.accessory(connector: .acPower, connectionActive: true)
        #expect(Fix.port(connector: .acPower, accessory: on).statusLabel == "Connected")
    }

    @Test("Ethernet status uses the live link-speed pill when up")
    func ethernetStatus() {
        let linked = Fix.accessory(
            connector: .ethernet,
            connectionActive: true,
            registryProperties: ["LinkSpeedMbps": .unsigned(10_000)]
        )
        #expect(Fix.port(connector: .ethernet, accessory: linked).statusLabel == "Linked · 10 Gb/s")

        let linkedUnknownSpeed = Fix.accessory(
            connector: .ethernet,
            connectionActive: true,
            registryProperties: [:]
        )
        #expect(Fix.port(connector: .ethernet,
                         accessory: linkedUnknownSpeed).statusLabel == "Linked")

        let unplugged = Fix.accessory(connector: .ethernet, connectionActive: false)
        #expect(Fix.port(connector: .ethernet,
                         accessory: unplugged).statusLabel == "Unplugged")
    }

    @Test("SD Card status reports card-present rather than mode label")
    func sdCardStatus() {
        let withCard = Fix.accessory(connector: .sdCard, connectionActive: true)
        #expect(Fix.port(connector: .sdCard, accessory: withCard).statusLabel == "Card inserted")

        let noCard = Fix.accessory(connector: .sdCard, connectionActive: false)
        #expect(Fix.port(connector: .sdCard, accessory: noCard).statusLabel == "Empty")
    }

    @Test("USB-only status appends '+ DP' when DP alt-mode is also live")
    func usbWithDPStatus() {
        // Many 5-in-1 hubs drive a monitor AND enumerate USB devices at
        // once. CLAUDE.md: the mode stays .usbOnly with a "+ DP" suffix on
        // the status line.
        let acc = Fix.accessory(connectionActive: true,
                                active: [.usb3, .displayPort],
                                hpdAsserted: true)
        let port = Fix.port(connector: .usbC,
                            accessory: acc,
                            mode: .usbOnly(speed: 3))
        #expect(port.statusLabel.contains("+ DP"))
        #expect(port.statusLabel.contains("USB 3.0"))
    }
}
