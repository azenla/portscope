//
//  Fixtures.swift
//  PortScopeTests
//
//  Tiny factory helpers used by the unit-test suites. The app code is built
//  around value types whose memberwise initializers take ~20 fields each;
//  these helpers fill in the boring defaults so each test only has to spell
//  out what it actually exercises.
//

import Foundation
@testable import PortScope

enum Fix {
    static func id(_ raw: UInt64) -> TBNodeID { TBNodeID(raw: raw) }

    /// Bare-bones TBNode. Defaults pick the most common shape: an `.other`
    /// kernel kext with no children and no properties. Tests override only
    /// what they care about.
    static func node(
        id: UInt64 = 1,
        kind: TBNodeKind = .other,
        title: String = "Node",
        subtitle: String? = nil,
        className: String = "IOService",
        properties: [String: IORegValue] = [:],
        children: [TBNode] = [],
        registryPath: String? = nil
    ) -> TBNode {
        TBNode(
            id: Fix.id(id),
            kind: kind,
            title: title,
            subtitle: subtitle,
            className: className,
            properties: properties,
            propertyOrder: properties.keys.sorted(),
            children: children,
            registryPath: registryPath
        )
    }

    /// A `PortAccessoryInfo` shaped like an empty USB-C receptacle.
    static func accessory(
        id: UInt64 = 0x1000,
        portNumber: Int = 1,
        connector: PortConnectorType = .usbC,
        connection: AccessoryConnection = .none,
        connectionActive: Bool = false,
        detected: Bool = false,
        active: Set<USBCTransport> = [],
        hpdAsserted: Bool = false,
        cableVendorID: UInt64? = nil,
        cableProductID: UInt64? = nil,
        cableManufacturer: String? = nil,
        usbPD: USBPDProfile? = nil,
        registryProperties: [String: IORegValue] = [:],
        registryPath: String? = nil
    ) -> PortAccessoryInfo {
        PortAccessoryInfo(
            id: Fix.id(id),
            portNumber: portNumber,
            connector: connector,
            connection: connection,
            connectionActive: connectionActive,
            detected: detected,
            plugOrientation: .unattached,
            supportedTransports: [],
            provisionedTransports: [],
            activeTransports: active,
            hpdAsserted: hpdAsserted,
            displayPortPinAssignment: 0,
            activeCable: false,
            opticalCable: false,
            connectionCount: 0,
            plugEventCount: 0,
            overcurrentCount: 0,
            cableVendorID: cableVendorID,
            cableProductID: cableProductID,
            cableManufacturer: cableManufacturer,
            cableEmarker: nil,
            usb3State: nil,
            cioState: nil,
            phyState: nil,
            usbPD: usbPD,
            registryProperties: registryProperties,
            registryPath: registryPath
        )
    }

    /// A `PhysicalPort` with synthetic lane/controller stubs. Convenient when
    /// the test only cares about the connector and the accessory/tunnel state.
    static func port(
        number: Int = 1,
        connector: PortConnectorType = .usbC,
        accessory: PortAccessoryInfo? = nil,
        connectedDevice: ConnectedDevice? = nil,
        mode: PhysicalPortMode = .empty,
        tunnels: [PortTunnel] = [],
        laneAdapter: TBNode? = nil,
        linkLane: TBNode? = nil
    ) -> PhysicalPort {
        let stub = laneAdapter ?? Fix.node(id: UInt64(0xA000 + number),
                                           kind: .port,
                                           title: "Lane")
        return PhysicalPort(
            number: number,
            id: stub.id,
            connector: connector,
            laneAdapter: stub,
            linkLane: linkLane,
            controller: stub,
            connectedDevice: connectedDevice,
            mode: mode,
            attachedUSBDevices: [],
            usbDeviceRoots: [],
            tunnels: tunnels,
            accessory: accessory,
            sourcePower: nil,
            thunderboltPeer: nil
        )
    }

    /// A `DisplayInfo` with the bare minimum filled in. Default is an
    /// external, connected, 4K@60 display.
    static func display(
        id: UInt64 = 0xD100,
        deviceTreeName: String = "dispext0",
        isBuiltIn: Bool = false,
        isConnected: Bool = true,
        title: String = "External Display"
    ) -> DisplayInfo {
        DisplayInfo(
            backingID: Fix.id(id),
            deviceTreeName: deviceTreeName,
            node: Fix.node(id: id, title: title),
            title: title,
            subtitle: nil,
            isConnected: isConnected,
            isBuiltIn: isBuiltIn,
            widthPixels: 3840,
            heightPixels: 2160,
            minRefreshHz: 60,
            maxRefreshHz: 60,
            currentRefreshHz: 60,
            colorBitDepth: 10,
            pixelEncoding: "RGB",
            colorSpace: "sRGB",
            colorAccuracyIndex: nil,
            supportsHDR: false,
            variableRefreshCapable: false,
            variableRefreshActive: false,
            timingModeCount: 1
        )
    }
}
