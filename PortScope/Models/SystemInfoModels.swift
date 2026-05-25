//
//  SystemInfoModels.swift
//  PortScope
//
//  Top-of-stack "About this Mac"-style facts: SoC family, CPU/GPU
//  topology, installed memory, internal NVMe, OS + firmware versions.
//  Everything in here is read from `sysctl` + `system_profiler` rather
//  than IOKit directly — the kernel exposes most of these facts only
//  through `IOPlatformExpertDevice` properties that don't survive the
//  generic `NodeBuilder` pipeline cleanly. Surfaced as the first row
//  inside the **Internal Hardware** sidebar section so the user lands
//  on a one-glance overview of the host they're inspecting.
//

import Foundation

nonisolated struct SystemInfoSnapshot: Hashable {
    /// "Apple M5 Max" — from `machdep.cpu.brand_string`.
    let chipName: String?
    /// Total CPU cores — `hw.physicalcpu`.
    let cpuCoreCount: Int?
    /// Performance ("super") cores. macOS exposes the perf/efficiency split
    /// via `hw.perflevelN.physicalcpu` (level 0 = highest performance).
    let cpuPCoreCount: Int?
    /// Efficiency cores. `hw.perflevel1.physicalcpu` when nperflevels > 1.
    let cpuECoreCount: Int?
    /// GPU core count. The kernel doesn't publish this anywhere structured;
    /// we parse it out of `system_profiler SPDisplaysDataType` once at
    /// scan time so it survives an offline / sandboxed run.
    let gpuCoreCount: Int?
    /// "Metal 4" / "Metal 3" — Apple's marketing tier for the GPU.
    let metalVersion: String?
    /// Total installed memory in bytes — `hw.memsize`.
    let memoryBytes: UInt64?
    /// "LPDDR5" — from SPMemoryDataType.
    let memoryType: String?
    /// "Samsung" / "Micron" — from SPMemoryDataType.
    let memoryManufacturer: String?
    /// Internal SSD details when an Apple ANS3-style controller is present.
    let internalStorage: InternalStorageInfo?
    /// macOS marketing version — `kern.osproductversion` (e.g. "26.5").
    let macOSVersion: String?
    /// macOS build identifier — `kern.osversion` (e.g. "25F71").
    let macOSBuild: String?
    /// Darwin kernel release — `kern.osrelease` (e.g. "25.5.0").
    let kernelVersion: String?
    /// System firmware (boot ROM) version — from SPHardwareDataType.
    let systemFirmware: String?
    /// Chassis identifier — `hw.model`.
    let hwModel: String?
    /// Marketing chassis name from `MacPortCatalog`, e.g.
    /// "MacBook Pro (16-inch, 2026, M5 Max)". Nil for unrecognised hosts.
    let marketingName: String?
    /// System (chassis) serial — `IOPlatformSerialNumber`.
    let systemSerial: String?
    /// Hardware UUID — `IOPlatformUUID`.
    let hardwareUUID: String?

    static let empty = SystemInfoSnapshot(
        chipName: nil, cpuCoreCount: nil, cpuPCoreCount: nil,
        cpuECoreCount: nil, gpuCoreCount: nil, metalVersion: nil,
        memoryBytes: nil, memoryType: nil, memoryManufacturer: nil,
        internalStorage: nil, macOSVersion: nil, macOSBuild: nil,
        kernelVersion: nil, systemFirmware: nil, hwModel: nil,
        marketingName: nil, systemSerial: nil, hardwareUUID: nil
    )

    var hasAnyData: Bool {
        chipName != nil || memoryBytes != nil || internalStorage != nil
            || macOSVersion != nil
    }
}

/// Internal NVMe SSD facts. The drive is an Apple-controller PCIe device
/// (`AppleANS3NVMeController`); the kernel exposes its identity strings on
/// the embedded NVMe namespace via `IONVMeBlockStorageDevice`. We mirror
/// the subset that's user-actionable.
nonisolated struct InternalStorageInfo: Hashable {
    /// Marketing model — e.g. "APPLE SSD AP2048Z".
    let model: String?
    /// Total raw capacity in bytes.
    let capacityBytes: UInt64?
    /// Firmware revision — e.g. "2,973.120".
    let firmware: String?
    /// Drive serial number. Treated as sensitive (masked by default).
    let serial: String?
    /// BSD identifier — e.g. "disk0".
    let bsdName: String?
    /// True when the controller advertises TRIM support.
    let trimSupported: Bool?
    /// macOS S.M.A.R.T. roll-up status, when available.
    let smartStatus: String?
}
