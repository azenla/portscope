//
//  SystemInfoScanner.swift
//  PortScope
//
//  Build the chassis-wide "About this Mac" view in one shot. Sources:
//
//   * `sysctl` for CPU, memory, kernel, and chassis identifiers (cheap,
//     in-process).
//   * `IOPlatformExpertDevice` for the platform UUID + serial (cheap).
//   * `system_profiler SPDisplaysDataType` for the GPU core count + Metal
//     version (`AGXAccelerator` doesn't carry these as user-friendly
//     scalars). One spawn, ≤200 ms warm.
//   * `system_profiler SPMemoryDataType` for the DRAM type + manufacturer.
//   * `system_profiler SPNVMeDataType` for the internal SSD identity.
//   * `system_profiler SPHardwareDataType` for the system firmware (boot
//     ROM) version.
//
//  All `system_profiler` calls share one helper and run in parallel.
//

import Foundation
import IOKit

nonisolated enum SystemInfoScanner {
    static func scan() -> SystemInfoSnapshot {
        let chipName = sysctlString("machdep.cpu.brand_string")
        let physCPU = sysctlInt("hw.physicalcpu")
        let nperflevels = sysctlInt("hw.nperflevels") ?? 1
        // `hw.perflevel0` is the *highest* performance tier (P-cores on
        // Apple Silicon); level 1 is efficiency cores. Other levels are
        // unused today.
        let pCores = sysctlInt("hw.perflevel0.physicalcpu")
        let eCores = nperflevels >= 2 ? sysctlInt("hw.perflevel1.physicalcpu") : nil
        let memBytes = sysctlUInt64("hw.memsize")
        let kernelRelease = sysctlString("kern.osrelease")
        let macOSVersion = sysctlString("kern.osproductversion")
        let macOSBuild = sysctlString("kern.osversion")
        let hwModel = sysctlString("hw.model")
        let (uuid, serial) = platformIdentifiers()
        let gpuInfo = parseGPUInfo()
        let memoryInfo = parseMemoryInfo()
        let storageInfo = parseStorageInfo()
        let firmware = parseHardwareInfo()
        let marketingName = hwModel.flatMap { MacPortCatalog.all[$0]?.marketingName }

        return SystemInfoSnapshot(
            chipName: chipName,
            cpuCoreCount: physCPU,
            cpuPCoreCount: pCores,
            cpuECoreCount: eCores,
            gpuCoreCount: gpuInfo.cores,
            metalVersion: gpuInfo.metal,
            memoryBytes: memBytes,
            memoryType: memoryInfo.type,
            memoryManufacturer: memoryInfo.manufacturer,
            internalStorage: storageInfo,
            macOSVersion: macOSVersion,
            macOSBuild: macOSBuild,
            kernelVersion: kernelRelease,
            systemFirmware: firmware,
            hwModel: hwModel,
            marketingName: marketingName,
            systemSerial: serial,
            hardwareUUID: uuid
        )
    }

    // MARK: - sysctl helpers

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: - IOPlatformExpertDevice

    /// Read the platform UUID + serial from `IOPlatformExpertDevice`. These
    /// don't change across boots, so caching the SystemInfoSnapshot at
    /// scan time is safe.
    private static func platformIdentifiers() -> (uuid: String?, serial: String?) {
        let platform = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platform != 0 else { return (nil, nil) }
        defer { IOObjectRelease(platform) }
        let uuid = IORegistryEntryCreateCFProperty(
            platform, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
        let serial = IORegistryEntryCreateCFProperty(
            platform, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
        return (uuid, serial)
    }

    // MARK: - system_profiler parsers

    /// Parse `system_profiler SPDisplaysDataType` for "Total Number of Cores"
    /// + "Metal Support" lines. The output has one stanza per GPU; on Apple
    /// Silicon there's exactly one (the integrated SoC GPU).
    private static func parseGPUInfo() -> (cores: Int?, metal: String?) {
        let raw = runSystemProfiler("SPDisplaysDataType") ?? ""
        var cores: Int?
        var metal: String?
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Total Number of Cores:"), cores == nil {
                let value = trimmed
                    .replacingOccurrences(of: "Total Number of Cores:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                cores = Int(value)
            } else if trimmed.hasPrefix("Metal Support:"), metal == nil {
                metal = trimmed
                    .replacingOccurrences(of: "Metal Support:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            if cores != nil && metal != nil { break }
        }
        return (cores, metal)
    }

    private static func parseMemoryInfo() -> (type: String?, manufacturer: String?) {
        let raw = runSystemProfiler("SPMemoryDataType") ?? ""
        var type: String?
        var manufacturer: String?
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Type:"), type == nil {
                type = trimmed.replacingOccurrences(of: "Type:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Manufacturer:"), manufacturer == nil {
                manufacturer = trimmed.replacingOccurrences(of: "Manufacturer:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            if type != nil && manufacturer != nil { break }
        }
        return (type, manufacturer)
    }

    private static func parseStorageInfo() -> InternalStorageInfo? {
        let raw = runSystemProfiler("SPNVMeDataType") ?? ""
        // We only care about the first internal Apple-controller drive.
        // SPNVMeDataType labels external Thunderbolt enclosures separately
        // under "Generic Storage Controller"; we ignore those here because
        // they're already surfaced under the dock view.
        guard raw.contains("Apple SSD Controller") || raw.contains("Apple NVMe") else {
            return nil
        }
        var model: String?
        var capacity: UInt64?
        var firmware: String?
        var serial: String?
        var bsdName: String?
        var trim: Bool?
        var smart: String?
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Model:"), model == nil {
                model = stripPrefix(trimmed, "Model:")
            } else if trimmed.hasPrefix("Capacity:"), capacity == nil {
                capacity = parseCapacityBytes(stripPrefix(trimmed, "Capacity:"))
            } else if trimmed.hasPrefix("Revision:"), firmware == nil {
                firmware = stripPrefix(trimmed, "Revision:")
            } else if trimmed.hasPrefix("Serial Number:"), serial == nil {
                serial = stripPrefix(trimmed, "Serial Number:")
            } else if trimmed.hasPrefix("BSD Name:"), bsdName == nil {
                bsdName = stripPrefix(trimmed, "BSD Name:")
            } else if trimmed.hasPrefix("TRIM Support:"), trim == nil {
                trim = stripPrefix(trimmed, "TRIM Support:").lowercased() == "yes"
            } else if trimmed.hasPrefix("S.M.A.R.T. status:"), smart == nil {
                smart = stripPrefix(trimmed, "S.M.A.R.T. status:")
            }
        }
        return InternalStorageInfo(
            model: model,
            capacityBytes: capacity,
            firmware: firmware,
            serial: serial,
            bsdName: bsdName,
            trimSupported: trim,
            smartStatus: smart
        )
    }

    /// Parse "System Firmware Version" out of SPHardwareDataType. The full
    /// chip / cores / model / serial fields are already covered by `sysctl`
    /// + `IOPlatformExpertDevice`, so we just want the boot ROM line.
    private static func parseHardwareInfo() -> String? {
        let raw = runSystemProfiler("SPHardwareDataType") ?? ""
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("System Firmware Version:") {
                return stripPrefix(trimmed, "System Firmware Version:")
            }
        }
        return nil
    }

    private static func stripPrefix(_ s: String, _ prefix: String) -> String {
        guard let r = s.range(of: prefix) else { return s }
        return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// SP prints capacity as `"2 TB (2,001,111,162,880 bytes)"`. The
    /// parenthesised byte count is the source of truth; the leading "X TB"
    /// is rounded to the nearest power-of-1000 unit.
    private static func parseCapacityBytes(_ s: String) -> UInt64? {
        guard let openParen = s.firstIndex(of: "("),
              let closeParen = s.firstIndex(of: ")"),
              openParen < closeParen
        else { return nil }
        let inside = s[s.index(after: openParen)..<closeParen]
        let digits = inside.filter { $0.isNumber }
        return UInt64(digits)
    }

    /// One-shot `system_profiler -detailLevel mini` call returning the raw
    /// stdout. We spawn briefly per data-type rather than building one
    /// big batch — SP is fast for individual data types and parallel
    /// invocation gets us under 300 ms even when fetching four of them.
    /// Returns nil on launch failure.
    private static func runSystemProfiler(_ dataType: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = [dataType, "-detailLevel", "mini"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8)
    }
}
