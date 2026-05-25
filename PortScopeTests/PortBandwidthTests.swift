//
//  PortBandwidthTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("Port bandwidth summary")
struct PortBandwidthTests {

    @Test("Fractions clamp to [0,1] and account for link being down")
    func fractions() {
        // Link Bandwidth in 100 Mb/s units; 800 = 80 Gb/s
        let summary = PortBandwidthSummary(
            linkBandwidth: 800,
            reserved: 200,
            max: 400,
            perTunnel: []
        )
        #expect(summary.hasLink)
        #expect(summary.reservedFraction == 0.25)
        #expect(summary.maxFraction == 0.5)
        #expect(!summary.planExceedsCapacity)
    }

    @Test("planExceedsCapacity flags scheduler overcommit")
    func overcommit() {
        // CLAUDE.md notes that exceeding capacity is informational, not a
        // failure — but the flag should still flip so the UI can colour
        // the bar red.
        let s = PortBandwidthSummary(linkBandwidth: 400,
                                     reserved: 100, max: 600, perTunnel: [])
        #expect(s.planExceedsCapacity)
    }

    @Test("Link down zeros the fractions instead of dividing by zero")
    func linkDown() {
        let s = PortBandwidthSummary(linkBandwidth: 0,
                                     reserved: 50, max: 100, perTunnel: [])
        #expect(s.reservedFraction == 0)
        #expect(s.maxFraction == 0)
        #expect(!s.hasLink)
        #expect(!s.planExceedsCapacity)
    }

    @Test("Fractions saturate at 1.0 — they never exceed visually")
    func saturation() {
        let s = PortBandwidthSummary(linkBandwidth: 100,
                                     reserved: 200, max: 200, perTunnel: [])
        #expect(s.reservedFraction == 1.0)
        #expect(s.maxFraction == 1.0)
    }

    @Test("hasReservation flips when either reserved or max is nonzero")
    func reservationFlag() {
        #expect(PortBandwidthSummary(linkBandwidth: 100, reserved: 0, max: 0, perTunnel: []).hasReservation == false)
        #expect(PortBandwidthSummary(linkBandwidth: 100, reserved: 1, max: 0, perTunnel: []).hasReservation)
        #expect(PortBandwidthSummary(linkBandwidth: 100, reserved: 0, max: 1, perTunnel: []).hasReservation)
    }
}
