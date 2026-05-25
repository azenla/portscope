//
//  MacPortCatalogTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("MacPortCatalog")
struct MacPortCatalogTests {

    @Test("MacPortDescriptor.title uses 'Slot' for SD card, 'Port' otherwise")
    func descriptorTitle() {
        // Convention spelled out in MacPortDescriptor.title — codified here
        // so future refactors don't silently change the user-visible label.
        let usbc = MacPortDescriptor(connector: .usbC, portNumber: 1,
                                     location: "Right Front",
                                     capability: "Thunderbolt 5")
        #expect(usbc.title == "Right Front USB-C Port")

        let sd = MacPortDescriptor(connector: .sdCard, portNumber: 1,
                                   location: "Right",
                                   capability: "UHS-II")
        #expect(sd.title == "Right SD Card Slot")

        let hdmi = MacPortDescriptor(connector: .hdmi, portNumber: 1,
                                     location: "Rear (rightmost)",
                                     capability: "HDMI 2.1")
        #expect(hdmi.title == "Rear (rightmost) HDMI Port")
    }

    @Test("Lookup.descriptor returns nil for unknown ports")
    func descriptorLookup() {
        let entry = MacChassisEntry(
            marketingName: "Test Mac",
            chassis: "Test",
            ports: [
                MacPortDescriptor(connector: .usbC, portNumber: 1,
                                  location: "Left Rear",
                                  capability: "Thunderbolt 4"),
                MacPortDescriptor(connector: .usbC, portNumber: 2,
                                  location: "Left Front",
                                  capability: "Thunderbolt 4")
            ]
        )
        let lookup = MacPortCatalog.Lookup(modelID: "Test1,1", entry: entry)
        #expect(lookup.descriptor(for: .usbC, portNumber: 1)?.location == "Left Rear")
        #expect(lookup.descriptor(for: .usbC, portNumber: 99) == nil)
        #expect(lookup.descriptor(for: .magsafe, portNumber: 1) == nil)
    }

    @Test("Every catalogued chassis publishes a marketing name and ≥ 1 port")
    func catalogueIntegrity() {
        // Catch the common authoring mistake of adding a chassis entry to
        // MacPortLocations.json but forgetting either the marketing name or
        // the port list. A silent partial entry is worse than no entry at
        // all because the sidebar starts using the generic fallback for a
        // model that's "supposed to be covered".
        for (modelID, entry) in MacPortCatalog.all {
            #expect(!entry.marketingName.isEmpty,
                    "Chassis \(modelID) is missing a marketing_name")
            #expect(!entry.ports.isEmpty,
                    "Chassis \(modelID) has no ports — entry is incomplete")
        }
    }

    @Test("Per-chassis port numbers are unique within each connector family")
    func portNumbersUniqueWithinFamily() {
        // The kernel's `PortNumber` field is the chassis-relative position.
        // Two USB-C entries with the same port_number would mean the
        // catalogue is mislabelling a physical receptacle.
        for (modelID, entry) in MacPortCatalog.all {
            var seen: [PortConnectorType: Set<Int>] = [:]
            for p in entry.ports {
                var s = seen[p.connector] ?? []
                #expect(!s.contains(p.portNumber),
                        "Duplicate (\(p.connector.label) port \(p.portNumber)) in \(modelID)")
                s.insert(p.portNumber)
                seen[p.connector] = s
            }
        }
    }
}
