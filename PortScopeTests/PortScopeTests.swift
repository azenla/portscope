//
//  PortScopeTests.swift
//  PortScopeTests
//
//  Entry-level smoke test. The real coverage lives in the per-area suites
//  (`IORegValueTests`, `TBFormattersTests`, `USBFormattersTests`, …) — this
//  file just sanity-checks that the host bundle was loaded correctly and the
//  catalogue resource is reachable, so a green run of this one test means the
//  test target is at least wired up right.
//

import Testing
import Foundation
@testable import PortScope

@Suite("Smoke")
struct PortScopeSmokeTests {

    @Test("Host bundle loads the bundled MacPortLocations.json catalogue")
    func catalogueLoads() {
        // Catalogue is read from `Bundle.main` — when this test target is
        // hosted in PortScope.app, that's the app bundle and the JSON is
        // present. If this assertion fails the host-app wiring is broken,
        // not the catalogue itself.
        let all = MacPortCatalog.all
        #expect(!all.isEmpty, "Expected the bundled MacPortLocations.json to load at least one chassis entry")
    }

    @Test("Known chassis identifiers resolve to a marketing name")
    func knownChassisResolves() {
        // Picked because they're stable shipping models: M1 MBA, base M2
        // 13″ MBP, and the 2024 M4 Pro Mac mini. If any of these vanish from
        // the catalogue something is genuinely wrong.
        let identifiers = ["MacBookAir10,1", "Mac14,2"]
        for id in identifiers {
            let entry = MacPortCatalog.all[id]
            #expect(entry != nil, "Expected '\(id)' in catalogue")
            #expect(entry?.marketingName.isEmpty == false,
                    "Catalogue entry for '\(id)' has empty marketing name")
        }
    }
}
