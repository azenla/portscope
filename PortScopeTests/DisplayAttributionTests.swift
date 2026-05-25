//
//  DisplayAttributionTests.swift
//  PortScopeTests
//
//  Cover the display-attribution heuristic the sidebar uses to nest external
//  displays under the physical port that drives them. The IOService plane
//  doesn't publish a clean port↔display link, so the implementation in
//  `displaysAttributed(to:allPorts:allDisplays:)` leans on runtime signals
//  (alt-mode HPD, DisplayPort tunnels). These tests pin down the three
//  branches: single carrier, N=N pair-up, and the "show all under every
//  carrier" fallback.
//

import Testing
import Foundation
@testable import PortScope

@Suite("Display attribution")
struct DisplayAttributionTests {

    @Test("portCarriesAnyDisplay sees both alt-mode and DP tunnels")
    func carriersDetected() {
        // Direct-attach panel: alt-mode HPD is asserted on a live port.
        let altMode = Fix.port(
            connector: .usbC,
            accessory: Fix.accessory(connectionActive: true,
                                     active: [.displayPort],
                                     hpdAsserted: true),
            mode: .displayOnly
        )
        #expect(portCarriesAnyDisplay(altMode))

        // Dock-tunneled: no alt-mode flag from the host, but there's a DP
        // tunnel on the router. CLAUDE.md explicitly calls out that dock-
        // routed displays never fire alt-mode HPD on the host side.
        let docked = Fix.port(
            connector: .usbC,
            mode: .thunderbolt(linkSpeed: 8),
            tunnels: [PortTunnel(kind: .displayPort,
                                 reservedBandwidth: 314,
                                 maxBandwidth: 922,
                                 adapterCount: 1)]
        )
        #expect(portCarriesAnyDisplay(docked))

        // Empty port with no signals at all.
        let empty = Fix.port(connector: .usbC, mode: .empty)
        #expect(!portCarriesAnyDisplay(empty))
    }

    @Test("Single carrier port claims every external display")
    func singleCarrierAttribution() {
        let displayCarrier = Fix.port(
            number: 1,
            connector: .usbC,
            accessory: Fix.accessory(connectionActive: true,
                                     active: [.displayPort],
                                     hpdAsserted: true),
            mode: .displayOnly
        )
        let plainPort = Fix.port(number: 2, connector: .usbC, mode: .empty)
        let displays = [
            Fix.display(id: 1, deviceTreeName: "dispext0"),
            Fix.display(id: 2, deviceTreeName: "dispext1")
        ]
        let attributed = displaysAttributed(to: displayCarrier,
                                            allPorts: [displayCarrier, plainPort],
                                            allDisplays: displays)
        #expect(attributed.count == 2)
        // The plain port shouldn't claim any of them.
        let plainAttributed = displaysAttributed(to: plainPort,
                                                 allPorts: [displayCarrier, plainPort],
                                                 allDisplays: displays)
        #expect(plainAttributed.isEmpty)
    }

    @Test("When N ports = N externals, pair them 1:1 in stable order")
    func nByNPairing() {
        let p1 = Fix.port(
            number: 1, connector: .usbC,
            accessory: Fix.accessory(connectionActive: true,
                                     active: [.displayPort],
                                     hpdAsserted: true),
            mode: .displayOnly
        )
        let p2 = Fix.port(
            number: 2, connector: .usbC,
            accessory: Fix.accessory(connectionActive: true,
                                     active: [.displayPort],
                                     hpdAsserted: true),
            mode: .displayOnly
        )
        let d1 = Fix.display(id: 1, deviceTreeName: "dispext0", title: "Studio")
        let d2 = Fix.display(id: 2, deviceTreeName: "dispext1", title: "LG")

        let onP1 = displaysAttributed(to: p1, allPorts: [p1, p2], allDisplays: [d1, d2])
        let onP2 = displaysAttributed(to: p2, allPorts: [p1, p2], allDisplays: [d1, d2])
        #expect(onP1.map(\.deviceTreeName) == ["dispext0"])
        #expect(onP2.map(\.deviceTreeName) == ["dispext1"])
    }

    @Test("Builtin panels never get attributed to a physical port")
    func builtinExcluded() {
        let p = Fix.port(
            connector: .usbC,
            accessory: Fix.accessory(connectionActive: true,
                                     active: [.displayPort],
                                     hpdAsserted: true),
            mode: .displayOnly
        )
        let builtin = Fix.display(id: 100, deviceTreeName: "disp0",
                                  isBuiltIn: true, title: "Built-in")
        let external = Fix.display(id: 101, deviceTreeName: "dispext0",
                                   title: "Studio")
        let result = displaysAttributed(to: p, allPorts: [p], allDisplays: [builtin, external])
        #expect(result.map(\.deviceTreeName) == ["dispext0"])
    }

    @Test("Count mismatch falls back to 'show every external under every carrier'")
    func countMismatchFallback() {
        // CLAUDE.md: "better to repeat than to vanish". Three carriers, two
        // displays — each carrier shows both displays.
        let ports = (1...3).map { idx in
            Fix.port(
                number: idx, connector: .usbC,
                accessory: Fix.accessory(connectionActive: true,
                                         active: [.displayPort],
                                         hpdAsserted: true),
                mode: .displayOnly
            )
        }
        let displays = [
            Fix.display(id: 1, deviceTreeName: "dispext0"),
            Fix.display(id: 2, deviceTreeName: "dispext1")
        ]
        for p in ports {
            let attributed = displaysAttributed(to: p, allPorts: ports, allDisplays: displays)
            #expect(attributed.count == 2,
                    "Mismatched carriers/displays should fall back to repeating each display under every carrier")
        }
    }

    @Test("Disconnected externals don't get attributed")
    func disconnectedSkipped() {
        let p = Fix.port(
            connector: .usbC,
            accessory: Fix.accessory(connectionActive: true,
                                     active: [.displayPort],
                                     hpdAsserted: true),
            mode: .displayOnly
        )
        let alive = Fix.display(id: 1, deviceTreeName: "dispext0", isConnected: true)
        let idle = Fix.display(id: 2, deviceTreeName: "dispext1", isConnected: false)
        let result = displaysAttributed(to: p, allPorts: [p], allDisplays: [alive, idle])
        #expect(result.map(\.deviceTreeName) == ["dispext0"])
    }
}
