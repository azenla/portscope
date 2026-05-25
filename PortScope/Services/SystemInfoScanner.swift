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
    /// Two-tier scan so launch stays fast:
    ///
    /// - **Cheap tier (always)**: `sysctl` + `IOPlatformExpertDevice`
    ///   reads. Sub-millisecond on warm caches; fine to run on every full
    ///   rescan. Populates chip, CPU cores, RAM size, kernel/macOS
    ///   versions, model identifier, serial / UUID.
    /// - **Heavy tier (gated)**: six `system_profiler` spawns
    ///   (`SPDisplaysDataType` / `SPMemoryDataType` / `SPNVMeDataType` /
    ///   `SPHardwareDataType` / `SPAirPortDataType` / `SPCameraDataType` /
    ///   `SPAudioDataType`). Each takes 50–200 ms warm and they bottleneck
    ///   the first paint, so we only run them when the user has opted into
    ///   Show All Devices. The corresponding sidebar sections (Wi-Fi /
    ///   Cameras / Audio) are gated behind the same toggle, and the
    ///   System Overview view still renders cleanly when these fields are
    ///   nil (showing chip / cores / RAM / OS / identifiers).
    ///
    /// The toggle is read straight from `UserDefaults` via the same key
    /// `SidebarView` uses; passing it down explicitly would force every
    /// caller (scanner pipeline, CLI dumper, tests) to learn about it.
    static func scan() -> SystemInfoSnapshot {
        // Read the toggle's UserDefaults key directly. `SidebarVisibility`
        // lives on the MainActor (project default isolation), and this
        // scanner is `nonisolated` so it can be driven from
        // `Task.detached` — pulling the constant in would force the call
        // back onto the main actor. The key string is the single source
        // of truth in `PortScopeApp.swift`; matched here verbatim.
        let includeHeavy = UserDefaults.standard
            .bool(forKey: "showAllDevices")
        return scan(includeHeavySources: includeHeavy)
    }

    static func scan(includeHeavySources: Bool) -> SystemInfoSnapshot {
        // Cheap tier — always populated.
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
        let marketingName = hwModel.flatMap { MacPortCatalog.all[$0]?.marketingName }

        // Heavy tier — only when Show All Devices is on. Run the six
        // `system_profiler` invocations concurrently rather than serially:
        // they're independent processes and the kernel + SP both handle
        // parallel invocations fine. Empirically drops the heavy-tier
        // cost from ~500–800 ms serial to ~150–250 ms on a warm cache
        // (limited by the slowest single SP data type).
        let heavy = includeHeavySources ? parseHeavySources() : HeavySources()

        return SystemInfoSnapshot(
            chipName: chipName,
            cpuCoreCount: physCPU,
            cpuPCoreCount: pCores,
            cpuECoreCount: eCores,
            gpuCoreCount: heavy.gpuCores,
            metalVersion: heavy.metal,
            memoryBytes: memBytes,
            memoryType: heavy.memoryType,
            memoryManufacturer: heavy.memoryManufacturer,
            internalStorage: heavy.storage,
            wifi: heavy.wifi,
            cameras: heavy.cameras,
            audioDevices: heavy.audio,
            macOSVersion: macOSVersion,
            macOSBuild: macOSBuild,
            kernelVersion: kernelRelease,
            systemFirmware: heavy.firmware,
            hwModel: hwModel,
            marketingName: marketingName,
            systemSerial: serial,
            hardwareUUID: uuid
        )
    }

    /// Bundle of the heavy-tier results so the parallel parser has one
    /// place to land everything. Default-initialised to the "skipped"
    /// shape so the gated-off path can return an empty struct without
    /// touching `system_profiler`.
    private struct HeavySources {
        var gpuCores: Int? = nil
        var metal: String? = nil
        var memoryType: String? = nil
        var memoryManufacturer: String? = nil
        var storage: InternalStorageInfo? = nil
        var firmware: String? = nil
        var wifi: WiFiInfo? = nil
        var cameras: [CameraInfo] = []
        var audio: [AudioDeviceInfo] = []
    }

    /// Run the six `system_profiler` data-type fetches in parallel via a
    /// concurrent `DispatchQueue` + `DispatchGroup`. SP itself is a
    /// process-per-invocation tool with negligible internal locking, so
    /// firing six processes in parallel lets the OS overlap their I/O.
    /// Each closure writes to its own `nonisolated(unsafe)` slot — there's
    /// no shared state to coordinate, and the `group.wait()` provides the
    /// happens-before that lets us read the results back safely on the
    /// caller.
    private static func parseHeavySources() -> HeavySources {
        nonisolated(unsafe) var out = HeavySources()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()

        queue.async(group: group) {
            let g = parseGPUInfo()
            out.gpuCores = g.cores
            out.metal = g.metal
        }
        queue.async(group: group) {
            let m = parseMemoryInfo()
            out.memoryType = m.type
            out.memoryManufacturer = m.manufacturer
        }
        queue.async(group: group) {
            out.storage = parseStorageInfo()
        }
        queue.async(group: group) {
            out.firmware = parseHardwareInfo()
        }
        queue.async(group: group) {
            out.wifi = parseWiFiInfo()
        }
        queue.async(group: group) {
            out.cameras = parseCameras()
        }
        queue.async(group: group) {
            out.audio = parseAudio()
        }
        group.wait()
        return out
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

    /// Parse `SPAirPortDataType`. The output is heavily nested — interface
    /// stanzas are indented under the top-level Wi-Fi block, and the
    /// connected-network section is indented again. We walk the lines,
    /// tracking section headers, and only commit fields when we're inside
    /// the right scope. Best-effort: SP can render slightly differently
    /// across macOS revs (kept the parsing forgiving).
    private static func parseWiFiInfo() -> WiFiInfo? {
        let raw = runSystemProfiler("SPAirPortDataType") ?? ""
        guard !raw.isEmpty else { return nil }
        var iface: String?
        var cardType: String?
        var mac: String?
        var locale: String?
        var country: String?
        var phys: String?
        var status: String?
        var supportedChannels: String?
        var inCurrentNetwork = false
        var ssid: String?
        var currentPHY: String?
        var currentChannel: String?

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Interface name is "en0:" at the deepest indentation we care
            // about — grab the first one.
            if iface == nil, trimmed.hasSuffix(":"),
               trimmed.hasPrefix("en"), !trimmed.contains(" ") {
                iface = String(trimmed.dropLast())
                continue
            }
            // "Current Network Information:" opens a nested block. Inside
            // it, the very next "<SSID>:" line is the joined network; the
            // following PHY Mode / Channel rows are about it.
            if trimmed == "Current Network Information:" {
                inCurrentNetwork = true
                continue
            }
            if inCurrentNetwork {
                if ssid == nil, trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                    ssid = String(trimmed.dropLast())
                    continue
                }
                if trimmed.hasPrefix("PHY Mode:") {
                    currentPHY = stripPrefix(trimmed, "PHY Mode:")
                } else if trimmed.hasPrefix("Channel:") {
                    currentChannel = stripPrefix(trimmed, "Channel:")
                } else if !trimmed.contains(":") {
                    // Blank or a section we don't care about — keep going.
                }
            }
            if trimmed.hasPrefix("Card Type:") {
                cardType = stripPrefix(trimmed, "Card Type:")
            } else if trimmed.hasPrefix("MAC Address:") {
                mac = stripPrefix(trimmed, "MAC Address:")
            } else if trimmed.hasPrefix("Locale:") {
                locale = stripPrefix(trimmed, "Locale:")
            } else if trimmed.hasPrefix("Country Code:") {
                country = stripPrefix(trimmed, "Country Code:")
            } else if trimmed.hasPrefix("Supported PHY Modes:") {
                phys = stripPrefix(trimmed, "Supported PHY Modes:")
            } else if trimmed.hasPrefix("Supported Channels:") {
                supportedChannels = stripPrefix(trimmed, "Supported Channels:")
            } else if trimmed.hasPrefix("Status:") {
                status = stripPrefix(trimmed, "Status:")
            }
        }

        // Boil "Card Type" down to something human ("Apple N1" / "BCM4387"
        // / etc.). The kernel string is a sequence of `key: value` tokens
        // separated by commas; the interesting one is "chip id" or the
        // family token immediately after the chipset rev. We don't have a
        // clean mapping, so we surface the whole line in `firmwareRevision`
        // and try a couple of heuristics for the short label.
        let chipset = shortWiFiChipset(cardType: cardType)
        let regulatory: String? = {
            switch (locale, country) {
            case (let l?, let c?): return "\(l) / \(c)"
            case (let l?, nil):    return l
            case (nil, let c?):    return c
            default:               return nil
            }
        }()
        return WiFiInfo(
            interface: iface,
            chipset: chipset,
            firmwareRevision: cardType,
            macAddress: mac,
            regulatoryRegion: regulatory,
            supportedPHYs: phys,
            status: status,
            currentSSID: ssid,
            currentPHY: currentPHY,
            currentChannel: currentChannel,
            supports6GHz: supportedChannels?.contains("6GHz") == true
        )
    }

    /// Apple's `Card Type` line packs "chip id: 0x11 api 1.2 firmware
    /// [Rev …] N1B1 …". The "N1B1" / "BCM4387" token is the recognisable
    /// chipset shorthand. We do a best-effort extraction and fall back to
    /// "Wi-Fi Adapter" when we can't pin it down.
    private static func shortWiFiChipset(cardType: String?) -> String? {
        guard let s = cardType else { return nil }
        // Apple silicon-integrated radio.
        if s.contains("N1B1") || s.contains("N1_silicon") { return "Apple N1" }
        if s.contains("BCM4387") { return "Broadcom BCM4387" }
        if s.contains("BCM4378") { return "Broadcom BCM4378" }
        if s.contains("BCM4377") { return "Broadcom BCM4377" }
        if let range = s.range(of: #"BCM\d+"#, options: .regularExpression) {
            return "Broadcom \(s[range])"
        }
        return "Wi-Fi Adapter"
    }

    private static func parseCameras() -> [CameraInfo] {
        let raw = runSystemProfiler("SPCameraDataType") ?? ""
        var out: [CameraInfo] = []
        var name: String?
        var modelID: String?
        var uniqueID: String?

        let commit = {
            if let n = name {
                out.append(CameraInfo(name: n, modelID: modelID, uniqueID: uniqueID))
            }
            name = nil; modelID = nil; uniqueID = nil
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "Camera:" { continue }
            // Top-level entries inside the Camera: block end in ":" with
            // no whitespace and no preceding key — that's the device name.
            if trimmed.hasSuffix(":"), !trimmed.contains(": ") {
                commit()
                name = String(trimmed.dropLast())
                continue
            }
            if trimmed.hasPrefix("Model ID:") {
                modelID = stripPrefix(trimmed, "Model ID:")
            } else if trimmed.hasPrefix("Unique ID:") {
                uniqueID = stripPrefix(trimmed, "Unique ID:")
            }
        }
        commit()
        return out
    }

    private static func parseAudio() -> [AudioDeviceInfo] {
        let raw = runSystemProfiler("SPAudioDataType") ?? ""
        var out: [AudioDeviceInfo] = []
        var name: String?
        var manufacturer: String?
        var transport: String?
        var outChannels: Int?
        var inChannels: Int?
        var sampleRate: Int?
        var isDefaultOut = false
        var isDefaultIn = false

        let commit = {
            if let n = name {
                out.append(AudioDeviceInfo(
                    name: n,
                    manufacturer: manufacturer,
                    transport: transport,
                    outputChannels: outChannels,
                    inputChannels: inChannels,
                    sampleRateHz: sampleRate,
                    isDefaultOutput: isDefaultOut,
                    isDefaultInput: isDefaultIn
                ))
            }
            name = nil; manufacturer = nil; transport = nil
            outChannels = nil; inChannels = nil; sampleRate = nil
            isDefaultOut = false; isDefaultIn = false
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "Audio:" || trimmed == "Devices:" { continue }
            if trimmed.hasSuffix(":"), !trimmed.contains(": ") {
                commit()
                name = String(trimmed.dropLast())
                continue
            }
            if trimmed.hasPrefix("Manufacturer:") {
                manufacturer = stripPrefix(trimmed, "Manufacturer:")
            } else if trimmed.hasPrefix("Transport:") {
                transport = stripPrefix(trimmed, "Transport:")
            } else if trimmed.hasPrefix("Output Channels:") {
                outChannels = Int(stripPrefix(trimmed, "Output Channels:"))
            } else if trimmed.hasPrefix("Input Channels:") {
                inChannels = Int(stripPrefix(trimmed, "Input Channels:"))
            } else if trimmed.hasPrefix("Current SampleRate:") {
                sampleRate = Int(stripPrefix(trimmed, "Current SampleRate:"))
            } else if trimmed.hasPrefix("Default Output Device:") {
                isDefaultOut = stripPrefix(trimmed, "Default Output Device:")
                    .lowercased() == "yes"
            } else if trimmed.hasPrefix("Default Input Device:") {
                isDefaultIn = stripPrefix(trimmed, "Default Input Device:")
                    .lowercased() == "yes"
            }
        }
        commit()
        return out
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
