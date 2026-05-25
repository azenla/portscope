//
//  USBPDProfileTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("USB-PD profile")
struct USBPDProfileTests {

    @Test("PortSourcePower is uninteresting until something is allocated")
    func isInteresting() {
        let empty = PortSourcePower(wakeLimitMA: nil, sleepLimitMA: nil,
                                    sinks: [], outputProfile: nil)
        #expect(empty.isInteresting == false)
        #expect(empty.totalAllocatedMA == 0)

        let withLimit = PortSourcePower(wakeLimitMA: 1500, sleepLimitMA: nil,
                                        sinks: [], outputProfile: nil)
        #expect(withLimit.isInteresting)
    }

    @Test("totalAllocatedMA sums every attached sink")
    func totalAllocation() {
        let s = PortSourcePower(
            wakeLimitMA: 3000,
            sleepLimitMA: 500,
            sinks: [
                PortSinkConsumer(id: TBNodeID(raw: 1), name: "Keyboard",
                                 allocatedMA: 100, capabilityMA: 500, configCurrentMA: 100),
                PortSinkConsumer(id: TBNodeID(raw: 2), name: "Hub",
                                 allocatedMA: 900, capabilityMA: 1500, configCurrentMA: 900)
            ],
            outputProfile: nil
        )
        #expect(s.totalAllocatedMA == 1000)
        #expect(s.isInteresting)
    }
}
