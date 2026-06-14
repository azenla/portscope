//
//  IORegValueTests.swift
//  PortScopeTests
//

import Testing
import Foundation
@testable import PortScope

@Suite("IORegValue")
struct IORegValueTests {

    @Test("asUInt converts numeric variants and bools")
    func asUInt() {
        #expect(IORegValue.unsigned(42).asUInt == 42)
        #expect(IORegValue.number(7).asUInt == 7)
        #expect(IORegValue.bool(true).asUInt == 1)
        #expect(IORegValue.bool(false).asUInt == 0)
        #expect(IORegValue.string("hi").asUInt == nil)
    }

    @Test("asInt round-trips signed values")
    func asInt() {
        #expect(IORegValue.number(-12).asInt == -12)
        #expect(IORegValue.unsigned(100).asInt == 100)
        #expect(IORegValue.bool(true).asInt == 1)
    }

    @Test("asString only succeeds for the string case")
    func asString() {
        #expect(IORegValue.string("hello").asString == "hello")
        #expect(IORegValue.number(1).asString == nil)
        #expect(IORegValue.bool(true).asString == nil)
    }

    @Test("asBool only succeeds for the bool case")
    func asBool() {
        #expect(IORegValue.bool(true).asBool == true)
        #expect(IORegValue.bool(false).asBool == false)
        #expect(IORegValue.unsigned(1).asBool == nil)
    }

    @Test("asDataString decodes a blob, trims control chars, nils empties")
    func asDataString() {
        // NUL-terminated UTF-8 blob, as device-tree `name` / `AAPL,slot-name`
        // arrive — trailing NUL is a control character and gets trimmed.
        let blob = IORegValue.data(Data("Slot- 0".utf8 + [0]))
        #expect(blob.asDataString == "Slot- 0")
        // Empty (or all-control) blobs decode to nil, not "".
        #expect(IORegValue.data(Data([0, 0])).asDataString == nil)
        #expect(IORegValue.data(Data()).asDataString == nil)
        // Non-data cases never match.
        #expect(IORegValue.string("x").asDataString == nil)
    }

    @Test("asNulTrimmedString truncates at the first NUL, keeps empties as \"\"")
    func asNulTrimmedString() {
        let blob = IORegValue.data(Data("IOService:/foo".utf8 + [0] + "junk".utf8))
        #expect(blob.asNulTrimmedString == "IOService:/foo")
        // Unlike asDataString, a leading NUL yields "" rather than nil.
        #expect(IORegValue.data(Data([0, 0])).asNulTrimmedString == "")
        #expect(IORegValue.string("x").asNulTrimmedString == nil)
    }

    @Test("display formats short data blobs as hex")
    func displayShortData() {
        let d = Data([0xde, 0xad, 0xbe, 0xef])
        #expect(IORegValue.data(d).display == "<deadbeef>")
    }

    @Test("display truncates long data blobs with byte count")
    func displayLongData() {
        let d = Data(repeating: 0xAB, count: 64)
        let s = IORegValue.data(d).display
        #expect(s.contains("(64 bytes)"))
        #expect(s.hasPrefix("<"))
    }

    @Test("display renders array contents recursively")
    func displayArray() {
        let v = IORegValue.array([.string("a"), .number(1), .bool(false)])
        #expect(v.display == "(\"a\", 1, No)")
    }

    @Test("display renders empty containers compactly")
    func displayEmptyContainers() {
        #expect(IORegValue.array([]).display == "()")
        #expect(IORegValue.dictionary([]).display == "{}")
    }

    @Test("equality treats dictionaries as ordered pair lists")
    func dictionaryEquality() {
        let a = IORegValue.dictionary([("a", .number(1)), ("b", .number(2))])
        let same = IORegValue.dictionary([("a", .number(1)), ("b", .number(2))])
        let reordered = IORegValue.dictionary([("b", .number(2)), ("a", .number(1))])
        #expect(a == same)
        // Different cases of IORegValue must never be equal even if the
        // payloads would coerce — `.number(1) != .unsigned(1)` keeps the
        // representation distinguishable.
        #expect(IORegValue.number(1) != IORegValue.unsigned(1))
        // Order is part of identity for dictionaries because we preserve
        // the IORegistry's canonical sort order.
        #expect(a != reordered)
    }

    @Test("prettyCompatibleString joins array entries with separator")
    func prettyCompatibleArray() {
        let v = IORegValue.array([.string("jpeg,t8110jpeg"), .string("s5l8920x")])
        #expect(prettyCompatibleString(v) == "jpeg,t8110jpeg · s5l8920x")
    }

    @Test("prettyCompatibleString handles NUL-separated data blobs")
    func prettyCompatibleDataBlob() {
        // device-tree string arrays are sometimes serialised as NUL-separated bytes
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "ane,t8110".utf8)
        bytes.append(0)
        bytes.append(contentsOf: "ane".utf8)
        bytes.append(0)
        let v = IORegValue.data(Data(bytes))
        #expect(prettyCompatibleString(v) == "ane,t8110 · ane")
    }

    @Test("prettyCompatibleString passes plain strings through unchanged")
    func prettyCompatiblePlainString() {
        #expect(prettyCompatibleString(.string("solo")) == "solo")
    }
}
