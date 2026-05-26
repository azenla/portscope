//
//  SoCCatalog.swift
//  PortScope
//
//  Identifies the host's SoC family by probing for the chip-specific
//  IOService classes Apple ships per silicon generation. The class
//  names (e.g. `AppleT6050MemCacheController`, `AGXAcceleratorG17X`,
//  `AppleProcessorTraceT6050`) carry the codename + GPU architecture
//  that `machdep.cpu.brand_string` doesn't — and they're more reliable
//  than `hw.model`, which sometimes pools two chassis variants under
//  one identifier.
//
//  Documented in `design/IOService-Updates.md` H7.
//

import Foundation
import IOKit

nonisolated struct SoCFeatures: Hashable {
    /// Marketing family name, e.g. "M5 Max", "M3 Pro", "M2 Ultra".
    /// Pulled from `machdep.cpu.brand_string`; carried alongside the
    /// codename so views have one source of truth.
    let family: String?
    /// SoC codename, e.g. "T6050" (M5 Max), "T6031" (M3 Max). Extracted
    /// from the suffix of a chip-specific class like
    /// `AppleT6050ANEHAL`.
    let codename: String?
    /// GPU architecture marketing token, e.g. "G17" (M5 family),
    /// "G15" (M3 family). Inferred from the `AGXAcceleratorG{N}X`
    /// class registered by the GPU driver.
    let gpuArchitecture: String?
    /// True when the kernel publishes an `AppleProcessorTrace*` service
    /// (M5+ silicon). Future-proofed against later codenames via a
    /// short candidate list.
    let supportsProcessorTrace: Bool

    static let empty = SoCFeatures(
        family: nil, codename: nil, gpuArchitecture: nil,
        supportsProcessorTrace: false
    )

    var isEmpty: Bool {
        codename == nil && gpuArchitecture == nil
            && !supportsProcessorTrace
    }
}

nonisolated enum SoCCatalog {
    /// One-shot probe — a handful of `IOServiceMatching` lookups, each
    /// just confirming a class is registered. Sub-millisecond total.
    /// `family` is the marketing string from `sysctl`
    /// (`machdep.cpu.brand_string`) so we don't duplicate that read.
    static func scan(family: String? = nil) -> SoCFeatures {
        return SoCFeatures(
            family: family,
            codename: detectCodename(),
            gpuArchitecture: detectGPUArch(),
            supportsProcessorTrace: detectProcessorTrace()
        )
    }

    /// Probe a small list of known per-SoC class names and return the
    /// embedded codename token. Each Apple SoC ships an
    /// `AppleT<codename>ANEHAL` class (the Neural Engine HAL), which
    /// is one of the most reliable "what chip am I on" signals on
    /// Apple Silicon. The list is ordered newest-first so a host with
    /// multiple matching classes loaded prefers the newer one.
    private static func detectCodename() -> String? {
        let candidates = [
            "T6050",  // M5 Max
            "T6041",  // M5 Pro (anticipated; pattern matches Apple's naming)
            "T6040",  // M5 (base)
            "T6031",  // M3 Max
            "T6021",  // M3 Pro
            "T6020",  // M3 (base)
            "T6011",  // M2 Max
            "T6001",  // M2 Pro
            "T8112",  // M2 (base)
            "T6010",  // M1 Max
            "T6000",  // M1 Pro
            "T8103"   // M1 (base)
        ]
        for codename in candidates where hasService("AppleT\(codename)ANEHAL") {
            return codename
        }
        return nil
    }

    /// Find the GPU architecture marketing token by walking the
    /// AGXAccelerator class names that Apple stamps per generation.
    /// Newest-first.
    private static func detectGPUArch() -> String? {
        let candidates: [(String, String)] = [
            ("AGXAcceleratorG17X", "G17"),  // M5 family
            ("AGXAcceleratorG16X", "G16"),  // M4 family
            ("AGXAcceleratorG15X", "G15"),  // M3 family
            ("AGXAcceleratorG14X", "G14"),  // M2 family
            ("AGXAcceleratorG13X", "G13"),  // M1 family
            ("AGXAcceleratorG13G", "G13G")  // M1 base small-die variant
        ]
        for (cls, arch) in candidates where hasService(cls) {
            return arch
        }
        return nil
    }

    /// Look for any AppleProcessorTrace<codename> service. Hardware
    /// instruction trace landed on T6050 / M5; future generations will
    /// likely keep it.
    private static func detectProcessorTrace() -> Bool {
        let candidates = [
            "AppleProcessorTraceT6050",   // M5 Max
            "AppleProcessorTraceT6041",   // anticipated future variants
            "AppleProcessorTraceT6040",
            "AppleProcessorTraceT6051"
        ]
        for cls in candidates where hasService(cls) { return true }
        return false
    }

    private static func hasService(_ className: String) -> Bool {
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(className)
        )
        guard svc != 0 else { return false }
        IOObjectRelease(svc)
        return true
    }
}
