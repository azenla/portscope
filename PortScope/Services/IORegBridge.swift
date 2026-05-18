//
//  IORegBridge.swift
//  PortScope
//
//  Generic bridge for reading the IORegistry as Swift values.
//

import Foundation
import IOKit

/// A type-erased IORegistry value. Mirrors what `ioreg` prints.
indirect enum IORegValue: Hashable {
    case string(String)
    case number(Int64)
    case unsigned(UInt64)
    case bool(Bool)
    case data(Data)
    case array([IORegValue])
    case dictionary([(String, IORegValue)])

    static func == (lhs: IORegValue, rhs: IORegValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.unsigned(let a), .unsigned(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.data(let a), .data(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.dictionary(let a), .dictionary(let b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.0 != y.0 || x.1 != y.1 { return false }
            return true
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let s): hasher.combine(0); hasher.combine(s)
        case .number(let n): hasher.combine(1); hasher.combine(n)
        case .unsigned(let u): hasher.combine(2); hasher.combine(u)
        case .bool(let b): hasher.combine(3); hasher.combine(b)
        case .data(let d): hasher.combine(4); hasher.combine(d)
        case .array(let a): hasher.combine(5); hasher.combine(a)
        case .dictionary(let d):
            hasher.combine(6)
            for (k, v) in d { hasher.combine(k); hasher.combine(v) }
        }
    }

    /// Lossy human display, suitable for the detail inspector.
    var display: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return String(n)
        case .unsigned(let u): return String(u)
        case .bool(let b): return b ? "Yes" : "No"
        case .data(let d):
            if d.count <= 32 {
                return "<\(d.map { String(format: "%02x", $0) }.joined())>"
            } else {
                let head = d.prefix(16).map { String(format: "%02x", $0) }.joined()
                return "<\(head)\u{2026} (\(d.count) bytes)>"
            }
        case .array(let arr):
            if arr.isEmpty { return "()" }
            return "(\(arr.map { $0.display }.joined(separator: ", ")))"
        case .dictionary(let kv):
            if kv.isEmpty { return "{}" }
            let body = kv.map { "\"\($0.0)\"=\($0.1.display)" }.joined(separator: ",")
            return "{\(body)}"
        }
    }

    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var asInt: Int64? {
        switch self {
        case .number(let n): return n
        case .unsigned(let u): return Int64(bitPattern: u)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var asUInt: UInt64? {
        switch self {
        case .number(let n): return UInt64(bitPattern: n)
        case .unsigned(let u): return u
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

/// Read a fixed C string buffer using a closure that fills it.
private func readIOName(_ fill: (UnsafeMutablePointer<CChar>) -> kern_return_t) -> String? {
    let size = 128 // io_name_t is char[128]
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: size)
    defer { buf.deallocate() }
    buf.initialize(repeating: 0, count: size)
    let kr = fill(buf)
    guard kr == KERN_SUCCESS else { return nil }
    return String(cString: buf)
}

enum IORegBridge {
    /// Convert any CFTypeRef value coming out of IOKit into an `IORegValue`.
    static func convert(_ raw: Any?) -> IORegValue? {
        guard let raw = raw else { return nil }
        let cf = raw as CFTypeRef
        let typeID = CFGetTypeID(cf)
        switch typeID {
        case CFStringGetTypeID():
            return .string(cf as! String)
        case CFBooleanGetTypeID():
            return .bool(CFBooleanGetValue((cf as! CFBoolean)))
        case CFNumberGetTypeID():
            let nsNum = cf as! NSNumber
            let typeStr = String(cString: nsNum.objCType)
            switch typeStr.first {
            case "Q", "L", "I", "S", "C":
                return .unsigned(nsNum.uint64Value)
            default:
                return .number(nsNum.int64Value)
            }
        case CFDataGetTypeID():
            return .data(cf as! Data)
        case CFArrayGetTypeID():
            let arr = cf as! NSArray
            var out: [IORegValue] = []
            out.reserveCapacity(arr.count)
            for v in arr {
                if let conv = convert(v) { out.append(conv) }
            }
            return .array(out)
        case CFDictionaryGetTypeID():
            let dict = cf as! NSDictionary
            var pairs: [(String, IORegValue)] = []
            pairs.reserveCapacity(dict.count)
            for (k, v) in dict {
                let key = (k as? String) ?? String(describing: k)
                if let conv = convert(v) { pairs.append((key, conv)) }
            }
            pairs.sort { $0.0 < $1.0 }
            return .dictionary(pairs)
        default:
            return .string(String(describing: cf))
        }
    }

    static func properties(of entry: io_registry_entry_t) -> [String: IORegValue] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        var out: [String: IORegValue] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict {
            if let conv = convert(v) { out[k] = conv }
        }
        return out
    }

    static func className(of entry: io_registry_entry_t) -> String? {
        readIOName { IOObjectGetClass(entry, $0) }
    }

    static func name(of entry: io_registry_entry_t) -> String? {
        readIOName { IORegistryEntryGetName(entry, $0) }
    }

    static func location(of entry: io_registry_entry_t, plane: String = kIOServicePlane) -> String? {
        readIOName { IORegistryEntryGetLocationInPlane(entry, plane, $0) }
    }

    static func entryID(of entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        let kr = IORegistryEntryGetRegistryEntryID(entry, &id)
        return kr == KERN_SUCCESS ? id : nil
    }

    static func conforms(_ entry: io_registry_entry_t, to className: String) -> Bool {
        return IOObjectConformsTo(entry, className) != 0
    }

    /// Enumerate direct children of `entry` in a plane. Caller must release each.
    static func children(of entry: io_registry_entry_t, plane: String = kIOServicePlane) -> [io_registry_entry_t] {
        var iter: io_iterator_t = 0
        let kr = IORegistryEntryGetChildIterator(entry, plane, &iter)
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var out: [io_registry_entry_t] = []
        while case let child = IOIteratorNext(iter), child != 0 {
            out.append(child)
        }
        return out
    }

    /// Parent in a plane. Caller must release.
    static func parent(of entry: io_registry_entry_t, plane: String = kIOServicePlane) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        let kr = IORegistryEntryGetParentEntry(entry, plane, &parent)
        return kr == KERN_SUCCESS ? parent : nil
    }

    /// Find all services matching a class name. Caller must release each.
    static func services(matchingClass className: String) -> [io_service_t] {
        guard let dict = IOServiceMatching(className) else { return [] }
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iter)
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var out: [io_service_t] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            out.append(svc)
        }
        return out
    }

    static func path(of entry: io_registry_entry_t, plane: String = kIOServicePlane) -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        let kr = buf.withUnsafeMutableBufferPointer { bp -> kern_return_t in
            IORegistryEntryGetPath(entry, plane, bp.baseAddress!)
        }
        guard kr == KERN_SUCCESS else { return nil }
        return String(cString: buf)
    }
}
