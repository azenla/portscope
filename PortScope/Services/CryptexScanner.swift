//
//  CryptexScanner.swift
//  PortScope
//
//  Walk `AppleAPFSGraft` services and turn them into typed
//  `CryptexInfo` records. The Cheer-prefixed grafts are Apple's
//  signed system cryptexes (per-arch system surface + toolchain +
//  exclave OS on M5+); the Revival-prefixed grafts are Apple
//  Intelligence on-device model packs. Documented in
//  `design/IOService-Updates.md` M7.
//

import Foundation
import IOKit

nonisolated enum CryptexScanner {
    static func scan() -> [CryptexInfo] {
        var out: [CryptexInfo] = []
        var seen: Set<String> = []
        for svc in IORegBridge.services(matchingClass: "AppleAPFSGraft") {
            defer { IOObjectRelease(svc) }
            let props = IORegBridge.properties(of: svc)
            guard let full = props["FullName"]?.asString,
                  !full.isEmpty else { continue }
            // Deduplicate by full name. The arm64e system cryptex
            // typically registers twice (one for the cryptex itself,
            // one for an alias graft) — surfacing both would mislead
            // the user into thinking the system shipped two of them.
            guard seen.insert(full).inserted else { continue }
            let sealed = props["Sealed"]?.asString.map { $0 == "Yes" }
                ?? props["Sealed"]?.asBool ?? false
            let isSystem = props["System content"]?.asBool ?? false
            out.append(CryptexInfo(
                fullName: full,
                displayName: friendlyName(for: full),
                isSealed: sealed,
                isSystemContent: isSystem
            ))
        }
        // Stable order: system content first, then by display name.
        return out.sorted {
            if $0.isSystemContent != $1.isSystemContent {
                return $0.isSystemContent && !$1.isSystemContent
            }
            return $0.displayName < $1.displayName
        }
    }

    /// Produce a friendlier label than the raw `FullName`. Apple's
    /// signing-manifest naming scheme isn't fully public — the
    /// `Cheer*` and `Revival*` prefixes are well-known release-train
    /// identifiers from the SEPOS / RestoreOS toolchains — so we just
    /// pattern-match the tail token.
    private static func friendlyName(for fullName: String) -> String {
        let tail = fullName.split(separator: ".").last.map(String.init)
            ?? fullName
        switch tail {
        case "arm64eSystemCryptex":
            return "System (arm64e)"
        case "MetalToolchainCryptex":
            return "Metal Toolchain"
        case "UniversalMacExclaveOS":
            return "Exclave OS"
        case "AppCryptex":
            return "App Cryptex"
        default:
            // Heuristics: Apple Intelligence packs are very long
            // tokens ending in `_Cryptex` — shorten to "Apple
            // Intelligence Model".
            if tail.hasSuffix("Cryptex")
                && tail.contains("LANGUAGE_INSTRUCT") {
                return "Apple Intelligence Language Model"
            }
            if tail.hasSuffix("Cryptex")
                && tail.contains("DIFFUSION") {
                return "Apple Intelligence Image Diffusion"
            }
            // Strip a trailing "Cryptex" suffix to keep things tidy.
            if tail.hasSuffix("Cryptex") {
                let trimmed = String(tail.dropLast("Cryptex".count))
                return trimmed.isEmpty ? tail : trimmed
            }
            return tail
        }
    }
}
