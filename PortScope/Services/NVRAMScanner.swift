//
//  NVRAMScanner.swift
//  PortScope
//
//  Parse the system's NVRAM variables. Apple Silicon Macs keep boot
//  configuration, language preferences, and audio state in NVRAM —
//  some of it is genuinely useful for triage (SIP status,
//  auto-boot setting, boot volume UUID, OS-update state) and the rest
//  is opaque blobs we keep around for power users.
//
//  We shell out to `/usr/sbin/nvram -p`. NVRAM is also readable via
//  `IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options")`
//  but the tool-output path is simpler and matches what users see in
//  Terminal. NVRAM is small and read-once at scan time.
//

import Foundation

nonisolated struct NVRAMSnapshot: Hashable {
    /// All published NVRAM variables, raw key + value. Many values are
    /// percent-encoded binary blobs; we keep them as-is for the
    /// developer view and let curated entries pick out the human-
    /// readable subset.
    let allVariables: [(key: String, value: String)]
    /// User-friendly subset that gets a curated row in the detail view.
    /// Each entry is `(key, displayValue, description)`.
    let highlighted: [HighlightedVar]

    static let empty = NVRAMSnapshot(allVariables: [], highlighted: [])

    static func == (lhs: NVRAMSnapshot, rhs: NVRAMSnapshot) -> Bool {
        lhs.allVariables.elementsEqual(rhs.allVariables, by: ==)
            && lhs.highlighted == rhs.highlighted
    }

    func hash(into hasher: inout Hasher) {
        for (k, v) in allVariables { hasher.combine(k); hasher.combine(v) }
    }
}

nonisolated struct HighlightedVar: Hashable, Identifiable {
    var id: String { key }
    let key: String
    let display: String
    let description: String
    let symbol: String
}

nonisolated enum NVRAMScanner {
    static func scan() -> NVRAMSnapshot {
        let raw = runNVRAM() ?? ""
        var all: [(String, String)] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            // `nvram -p` separates key + value with a single tab.
            let parts = line.split(separator: "\t", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            all.append((String(parts[0]),
                        String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let highlighted = curateHighlights(from: all)
        return NVRAMSnapshot(allVariables: all, highlighted: highlighted)
    }

    /// Pull out variables that are genuinely useful to a user / triager.
    /// Everything else stays in the All Variables table for the power
    /// user who wants to spelunk.
    private static func curateHighlights(from all: [(String, String)]) -> [HighlightedVar] {
        let map = Dictionary(uniqueKeysWithValues: all)
        var out: [HighlightedVar] = []

        if let v = map["auto-boot"] {
            out.append(HighlightedVar(
                key: "auto-boot",
                display: v.lowercased() == "true" ? "Yes" : "No",
                description: "Boots automatically when power is applied",
                symbol: "power.circle"))
        }
        if let v = map["csr-active-config"] {
            out.append(HighlightedVar(
                key: "csr-active-config",
                display: decodeSIP(v),
                description: "System Integrity Protection state",
                symbol: "shield"))
        }
        if let v = map["boot-args"], !v.isEmpty {
            out.append(HighlightedVar(
                key: "boot-args",
                display: v,
                description: "Custom kernel boot arguments",
                symbol: "terminal"))
        }
        if let v = map["boot-volume"] {
            out.append(HighlightedVar(
                key: "boot-volume",
                display: v,
                description: "APFS preboot / system / data volume UUIDs",
                symbol: "internaldrive"))
        }
        if let v = map["prev-lang:kbd"] {
            out.append(HighlightedVar(
                key: "prev-lang:kbd",
                display: v,
                description: "Language + keyboard layout at last boot",
                symbol: "globe"))
        }
        if let v = map["ota-updateType"] {
            out.append(HighlightedVar(
                key: "ota-updateType",
                display: v,
                description: "Last OS update method",
                symbol: "arrow.down.circle"))
        }
        if let v = map["supervised"] {
            out.append(HighlightedVar(
                key: "supervised",
                display: v.lowercased() == "true" ? "Yes" : "No",
                description: "Device is supervised (MDM-managed)",
                symbol: "person.badge.shield.checkmark"))
        }
        if let v = map["LocationServicesEnabled"] {
            // Stored as a one-byte hex blob — `%01` = enabled.
            let enabled = v.contains("%01") || v.lowercased() == "true"
            out.append(HighlightedVar(
                key: "LocationServicesEnabled",
                display: enabled ? "Yes" : "No",
                description: "Location services persistent flag",
                symbol: "location"))
        }
        if let v = map["panicmedic-auxkc-present"] {
            out.append(HighlightedVar(
                key: "panicmedic-auxkc-present",
                display: v,
                description: "Auxiliary kernel collection availability for panic medic",
                symbol: "wrench.and.screwdriver"))
        }
        if let v = map["fmm-computer-name"] {
            out.append(HighlightedVar(
                key: "fmm-computer-name",
                display: v,
                description: "Find My Mac computer name",
                symbol: "macbook"))
        }
        return out
    }

    /// Decode the csr-active-config NVRAM blob into a SIP state label.
    /// The kernel stores SIP flags as a little-endian 32-bit word with
    /// individual feature bits — 0x00000000 = SIP enabled (the default
    /// posture); anything else means some protections have been
    /// disabled with `csrutil`.
    private static func decodeSIP(_ raw: String) -> String {
        // `nvram -p` percent-encodes binary blobs. Look for the well-
        // known values; fall through to "Custom" for anything else.
        let cleaned = raw.replacingOccurrences(of: "%00", with: "")
            .replacingOccurrences(of: "%", with: "")
        if cleaned.isEmpty { return "Enabled (full)" }
        // 0x77 = all flags disabled (csrutil disable)
        if cleaned.hasPrefix("77") { return "Disabled (all)" }
        return "Custom · raw \(raw)"
    }

    private static func runNVRAM() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/nvram")
        proc.arguments = ["-p"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        // Drain stdout *before* waiting: a large `nvram -p` dump can fill
        // the 64 KB pipe buffer and deadlock against waitUntilExit().
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
