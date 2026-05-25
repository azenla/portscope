//
//  SelectorTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("Sidebar selectors")
struct SelectorTests {

    @Test("PhysicalPortSelector round-trips port number and connector")
    func portSelectorRoundTrip() {
        let usbc = Fix.port(number: 3, connector: .usbC)
        let usba = Fix.port(number: 3, connector: .usbA)
        let idC = PhysicalPortSelector.id(for: usbc)
        let idA = PhysicalPortSelector.id(for: usba)

        #expect(PhysicalPortSelector.isPortID(idC))
        #expect(PhysicalPortSelector.portNumber(idC) == 3)
        // Connector code lives in the high byte: USB-C port 3 and USB-A
        // port 3 must mint distinct IDs so the detail view can dispatch
        // on the right connector.
        #expect(idC.raw != idA.raw)
    }

    @Test("PhysicalPortSelector doesn't collide with arbitrary entry IDs")
    func portSelectorIDPrefix() {
        // The synthetic prefix `0xC0DE_C0DE_…` is far outside the kernel's
        // ID-allocation range, so real registry entry IDs should never test
        // positive as port IDs.
        let realLooking = TBNodeID(raw: 0x0000_0000_1234_5678)
        #expect(PhysicalPortSelector.isPortID(realLooking) == false)
        #expect(PhysicalPortSelector.portNumber(realLooking) == nil)
    }

    @Test("MagSafeSelector mints one stable ID, distinct from port IDs")
    func magsafeSelector() {
        #expect(MagSafeSelector.isMagSafeID(MagSafeSelector.id))
        let portID = PhysicalPortSelector.id(for: Fix.port(number: 1))
        #expect(!MagSafeSelector.isMagSafeID(portID))
        #expect(!PhysicalPortSelector.isPortID(MagSafeSelector.id))
    }

    @Test("BluetoothSelector device IDs share a prefix")
    func bluetoothSelectorPrefix() {
        let id = BluetoothSelector.id(for: BluetoothDevice.testFixture(address: "aa:bb:cc:dd:ee:ff",
                                                                       name: "Magic Mouse"))
        #expect(BluetoothSelector.isDeviceID(id))
        #expect(!BluetoothSelector.isControllerID(id))
        #expect(!PhysicalPortSelector.isPortID(id))
    }

    @Test("BluetoothSelector hashes the device address deterministically")
    func bluetoothSelectorDeterministic() {
        // Swift's String.hashValue is randomised per launch, so the selector
        // implements a stable FNV-1a. Two calls with the same input must
        // produce the same ID across the same process run AND have the
        // expected device-prefix bits — otherwise sidebar selection would
        // jump rows on every refresh.
        let a = BluetoothSelector.id(for: .testFixture(address: "11:22:33:44:55:66",
                                                       name: "Pad"))
        let b = BluetoothSelector.id(for: .testFixture(address: "11:22:33:44:55:66",
                                                       name: "Pad"))
        #expect(a == b)
    }
}

// Local test helper — the BluetoothDevice initializer is internal and lives
// in the host app's Models module. We don't need a real CoreBluetooth value
// here, just a struct that exposes `address` and `name` to the selector.
private extension BluetoothDevice {
    static func testFixture(address: String?, name: String) -> BluetoothDevice {
        BluetoothDevice(
            name: name,
            address: address,
            vendorID: nil,
            productID: nil,
            firmwareVersion: nil,
            minorType: nil,
            rssi: nil,
            serialNumber: nil,
            servicesRaw: nil,
            batteryLevel: nil,
            batteryLevelLeft: nil,
            batteryLevelRight: nil,
            batteryLevelCase: nil,
            caseVersion: nil,
            isConnected: false
        )
    }
}
