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
            memoryDIMMs: heavy.memoryDIMMs,
            cameras: heavy.cameras,
            cameraISP: heavy.cameraISP,
            audioDevices: heavy.audio,
            nvram: heavy.nvram,
            hidDevices: heavy.hidDevices,
            touchID: heavy.touchID,
            trustedAccessories: heavy.trustedAccessories,
            inputDevices: heavy.inputDevices,
            macOSVersion: macOSVersion,
            macOSBuild: macOSBuild,
            kernelVersion: kernelRelease,
            systemFirmware: heavy.firmware,
            hwModel: hwModel,
            marketingName: marketingName,
            systemSerial: serial,
            hardwareUUID: uuid,
            security: scanSecurityPosture(),
            socFeatures: SoCCatalog.scan(family: chipName),
            timeSync: scanTimeSync(),
            voiceTrigger: scanVoiceTrigger(),
            cryptexes: heavy.cryptexes
        )
    }

    /// Read the AOP voice trigger device. Properties:
    ///   - `VTEnabled` (Bool)  — pipeline currently listening
    ///   - `VTTriggerCount` (UInt64) — running detection count
    ///   - `VTActiveChannelMask` (UInt64) — which mics feed the
    ///      detector
    ///   - `IOExclaveProxy` (Bool) — runs in exclave (M5+)
    ///
    /// Returns nil when the service isn't registered — this
    /// shouldn't happen on any modern Apple Silicon Mac but the
    /// fallback keeps the system info card honest.
    private static func scanVoiceTrigger() -> VoiceTriggerInfo? {
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPAudioIsolatedVoiceTriggerDevice")
        )
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        let props = IORegBridge.properties(of: svc)
        return VoiceTriggerInfo(
            enabled: props["VTEnabled"]?.asBool ?? false,
            triggerCount: props["VTTriggerCount"]?.asUInt,
            activeChannelMask: props["VTActiveChannelMask"]?.asUInt,
            isExclaveIsolated: props["IOExclaveProxy"]?.asBool ?? false
        )
    }

    /// Probe the gPTP manager + AVB nub. Cheap (two `IOServiceMatching`
    /// calls + one property read). Returns `.empty` on hosts without
    /// AVB / gPTP plumbing.
    private static func scanTimeSync() -> TimeSyncInfo {
        let gPTP = hasService("IOTimeSyncgPTPManager")
        var entityID: UInt64? = nil
        let avb = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOAVBNub")
        )
        if avb != 0 {
            defer { IOObjectRelease(avb) }
            let props = IORegBridge.properties(of: avb)
            entityID = props["EntityID"]?.asUInt
        }
        return TimeSyncInfo(gPTPAvailable: gPTP, avbEntityID: entityID)
    }

    // MARK: - Security posture

    /// Eight cheap `IOServiceMatching` probes — each one looks up whether
    /// a service of the given class is registered with the IOKit matching
    /// dispatch. Returns existence as a Bool; doesn't read any properties
    /// or children. Sub-millisecond total. See `SecurityPosture` for what
    /// each class signals.
    private static func scanSecurityPosture() -> SecurityPosture {
        return SecurityPosture(
            lockdownAvailable:      hasService("AppleLockdownMode"),
            bootPolicyMatched:      hasService("BootPolicy"),
            amfiActive:             hasService("AppleMobileFileIntegrity"),
            systemPolicyActive:     hasService("AppleSystemPolicy"),
            endpointSecurityActive: hasService("EndpointSecurityDriver"),
            // M5+ only — `ExclaveSEPManagerProxy` doesn't exist on M3,
            // so the probe simply returns false there and the chip just
            // doesn't render.
            exclaveSepActive:       hasService("ExclaveSEPManagerProxy"),
            hardwareAESPresent:     hasService("AppleS8000AESAccelerator"),
            hardwareTRNGPresent:    hasService("RTBuddyEntropyEndpoint")
        )
    }

    /// One-shot "does an IOService with this class exist on this host"
    /// check. Releases the iterator immediately — we just want the first
    /// match's existence. Returns false on lookup failure too (matches
    /// the "service is absent" semantic the caller wants).
    private static func hasService(_ className: String) -> Bool {
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(className)
        )
        guard svc != 0 else { return false }
        IOObjectRelease(svc)
        return true
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
        var memoryDIMMs: [MemoryDIMMInfo] = []
        var storage: InternalStorageInfo? = nil
        var firmware: String? = nil
        var wifi: WiFiInfo? = nil
        var cameras: [CameraInfo] = []
        var cameraISP: CameraISPInfo? = nil
        var audio: [AudioDeviceInfo] = []
        var nvram: NVRAMSnapshot = .empty
        var hidDevices: HIDDevicesSnapshot = .empty
        var touchID: TouchIDInfo = .empty
        var trustedAccessories: [TrustedAccessoryInfo] = []
        var inputDevices: InputDevicesInfo = .empty
        var cryptexes: [CryptexInfo] = []
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
            out.memoryDIMMs = parseMemoryDIMMs(rolledUpType: m.type,
                                               rolledUpManufacturer: m.manufacturer)
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
            out.cameraISP = scanCameraISP()
        }
        queue.async(group: group) {
            out.audio = parseAudio()
        }
        queue.async(group: group) {
            out.nvram = NVRAMScanner.scan()
        }
        queue.async(group: group) {
            out.hidDevices = HIDDeviceScanner.scan()
        }
        queue.async(group: group) {
            out.touchID = TouchIDInfo.read()
        }
        queue.async(group: group) {
            out.trustedAccessories = TrustedAccessoryScanner.scan()
        }
        queue.async(group: group) {
            out.cryptexes = CryptexScanner.scan()
        }
        queue.async(group: group) {
            out.inputDevices = InputDevicesInfo.read()
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

    /// Parse `SPMemoryDataType` for per-DIMM stanzas. On Apple Silicon SP
    /// only emits a single "Memory: X · Type: Y · Manufacturer: Z" block
    /// (unified memory, no socketed DIMMs), so we synthesise a single
    /// `MemoryDIMMInfo` from the rolled-up fields + `hw.memsize`. On Intel
    /// Macs SP enumerates each physical DIMM bank with size, slot, speed,
    /// status, manufacturer, and part number — we walk the slot stanzas
    /// and emit one entry per slot.
    private static func parseMemoryDIMMs(rolledUpType: String?,
                                         rolledUpManufacturer: String?) -> [MemoryDIMMInfo] {
        let raw = runSystemProfiler("SPMemoryDataType") ?? ""
        var out: [MemoryDIMMInfo] = []
        var currentName: String?
        var currentSlot: String?
        var currentSize: UInt64?
        var currentType: String?
        var currentManuf: String?
        var currentSpeed: String?
        var currentPart: String?
        var inSlotStanza = false

        let commit = {
            if let n = currentName {
                out.append(MemoryDIMMInfo(
                    name: n, slot: currentSlot, capacityBytes: currentSize,
                    type: currentType, manufacturer: currentManuf,
                    speed: currentSpeed, partNumber: currentPart
                ))
            }
            currentName = nil; currentSlot = nil; currentSize = nil
            currentType = nil; currentManuf = nil; currentSpeed = nil
            currentPart = nil
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Intel-style: a slot stanza starts with "BANK X/DIMM:" or
            // "DIMM0:" — both are device-name-followed-by-colon with no
            // additional `: value` payload on the same line.
            if trimmed.hasSuffix(":"), !trimmed.contains(": "),
               trimmed != "Memory:" {
                commit()
                currentName = String(trimmed.dropLast())
                inSlotStanza = true
                continue
            }
            guard inSlotStanza else { continue }
            if trimmed.hasPrefix("Size:") {
                currentSize = parseMemorySize(stripPrefix(trimmed, "Size:"))
            } else if trimmed.hasPrefix("Type:") {
                currentType = stripPrefix(trimmed, "Type:")
            } else if trimmed.hasPrefix("Manufacturer:") {
                currentManuf = stripPrefix(trimmed, "Manufacturer:")
            } else if trimmed.hasPrefix("Speed:") {
                currentSpeed = stripPrefix(trimmed, "Speed:")
            } else if trimmed.hasPrefix("Part Number:") {
                currentPart = stripPrefix(trimmed, "Part Number:")
            } else if trimmed.hasPrefix("Slot:") {
                currentSlot = stripPrefix(trimmed, "Slot:")
            }
        }
        commit()

        // Apple Silicon path: no slot stanzas were found, just the
        // top-level rolled-up fields. Synthesise a single entry from
        // `hw.memsize` + the rolled-up type / manufacturer so the
        // Memory section still has something concrete to render.
        if out.isEmpty {
            var size: UInt64 = 0
            var s: size_t = MemoryLayout<UInt64>.size
            sysctlbyname("hw.memsize", &size, &s, nil, 0)
            if size > 0 {
                out.append(MemoryDIMMInfo(
                    name: "Unified Memory",
                    slot: nil,
                    capacityBytes: size,
                    type: rolledUpType,
                    manufacturer: rolledUpManufacturer,
                    speed: nil,
                    partNumber: nil
                ))
            }
        }
        return out
    }

    /// Decode SP's "Size:" values which arrive as "16 GB" / "8 GB" /
    /// "32 GB"-style strings. Multiply by 1024^3 because Apple sticks to
    /// the binary-GB convention for RAM specifically (see SystemInfoView's
    /// `formatMemoryBytes`).
    private static func parseMemorySize(_ s: String) -> UInt64? {
        let parts = s.split(separator: " ")
        guard let first = parts.first, let n = UInt64(first) else { return nil }
        if parts.count >= 2 {
            switch parts[1].uppercased() {
            case "GB", "GIB": return n * 1024 * 1024 * 1024
            case "MB", "MIB": return n * 1024 * 1024
            case "TB", "TIB": return n * 1024 * 1024 * 1024 * 1024
            default: return n
            }
        }
        return n
    }

    /// Parse `SPNVMeDataType` for the internal Apple-controller drive,
    /// including controller name, partition map, removability, and the
    /// list of APFS / HFS+ volumes hosted on the drive. External TB
    /// enclosures show up as "Generic Storage Controller" in SP — we
    /// skip those here because they're already surfaced under the dock.
    private static func parseStorageInfo() -> InternalStorageInfo? {
        let raw = runSystemProfiler("SPNVMeDataType") ?? ""
        guard raw.contains("Apple SSD Controller") || raw.contains("Apple NVMe") else {
            return nil
        }
        var controllerName: String?
        var model: String?
        var capacity: UInt64?
        var firmware: String?
        var serial: String?
        var bsdName: String?
        var trim: Bool?
        var smart: String?
        var partitionMap: String?
        var removable: Bool?
        var volumes: [VolumeInfo] = []
        // Lightweight stanza tracker. SP uses indented sections — the
        // controller is the outer block ("Apple SSD Controller:"), each
        // drive is one level in ("APPLE SSD AP…:"), and "Volumes:" is
        // the deepest block we care about. We watch for the volume sub-
        // headers (one indent level under "Volumes:") and collect their
        // child fields.
        var inVolumes = false
        var currentVolumeName: String?
        var currentVolumeBSD: String?
        var currentVolumeCapacity: UInt64?
        var currentVolumeContent: String?

        let commitVolume = {
            if let n = currentVolumeName {
                volumes.append(VolumeInfo(
                    name: n,
                    capacityBytes: currentVolumeCapacity,
                    bsdName: currentVolumeBSD,
                    content: currentVolumeContent
                ))
            }
            currentVolumeName = nil; currentVolumeBSD = nil
            currentVolumeCapacity = nil; currentVolumeContent = nil
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "NVMExpress:" { continue }
            if trimmed == "Volumes:" {
                inVolumes = true
                continue
            }
            if trimmed.hasSuffix(":"), !trimmed.contains(": ") {
                // A new device-name / controller-name / volume-name stanza.
                if inVolumes {
                    commitVolume()
                    currentVolumeName = String(trimmed.dropLast())
                } else if controllerName == nil
                            && (trimmed.contains("Controller") || trimmed.contains("NVMe")) {
                    controllerName = String(trimmed.dropLast())
                } else if model == nil {
                    // Drive stanza name often matches "Model:" but we
                    // wait for the explicit "Model:" line below; this
                    // branch just resets the volumes tracker so a fresh
                    // drive entry doesn't inherit the previous one's
                    // volumes.
                    inVolumes = false
                }
                continue
            }
            if inVolumes {
                if trimmed.hasPrefix("Capacity:") {
                    currentVolumeCapacity = parseCapacityBytes(stripPrefix(trimmed, "Capacity:"))
                } else if trimmed.hasPrefix("BSD Name:") {
                    currentVolumeBSD = stripPrefix(trimmed, "BSD Name:")
                } else if trimmed.hasPrefix("Content:") {
                    currentVolumeContent = stripPrefix(trimmed, "Content:")
                }
                continue
            }
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
            } else if trimmed.hasPrefix("Partition Map Type:"), partitionMap == nil {
                partitionMap = stripPrefix(trimmed, "Partition Map Type:")
            } else if trimmed.hasPrefix("Detachable Drive:"), removable == nil {
                removable = stripPrefix(trimmed, "Detachable Drive:").lowercased() == "yes"
            } else if trimmed.hasPrefix("Removable Media:"), removable == nil {
                removable = stripPrefix(trimmed, "Removable Media:").lowercased() == "yes"
            }
        }
        commitVolume()
        return InternalStorageInfo(
            model: model,
            capacityBytes: capacity,
            firmware: firmware,
            serial: serial,
            bsdName: bsdName,
            trimSupported: trim,
            smartStatus: smart,
            controllerName: controllerName,
            partitionMapType: partitionMap,
            removable: removable,
            volumes: volumes
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
        var security: String?
        var networkType: String?
        var rssiDBm: Int?
        var noiseDBm: Int?
        var transmitRateMbps: Int?
        var mcsIndex: Int?

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
                } else if trimmed.hasPrefix("Security:") {
                    security = stripPrefix(trimmed, "Security:")
                } else if trimmed.hasPrefix("Network Type:") {
                    networkType = stripPrefix(trimmed, "Network Type:")
                } else if trimmed.hasPrefix("Signal / Noise:") {
                    // "−43 dBm / −93 dBm" — split on " / " and parse the
                    // leading numeric token of each half.
                    let pair = stripPrefix(trimmed, "Signal / Noise:")
                    let halves = pair.components(separatedBy: " / ")
                    if halves.count == 2 {
                        rssiDBm = leadingInt(halves[0])
                        noiseDBm = leadingInt(halves[1])
                    }
                } else if trimmed.hasPrefix("Transmit Rate:") {
                    transmitRateMbps = leadingInt(stripPrefix(trimmed, "Transmit Rate:"))
                } else if trimmed.hasPrefix("MCS Index:") {
                    mcsIndex = leadingInt(stripPrefix(trimmed, "MCS Index:"))
                } else if trimmed == "Other Local Wi-Fi Networks:"
                            || trimmed == "awdl0:" {
                    // We've fallen out of the current-network stanza;
                    // stop committing into its fields.
                    inCurrentNetwork = false
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
            supports6GHz: supportedChannels?.contains("6GHz") == true,
            supportsTSN: hasService("TSNWiFiInterface"),
            security: security,
            networkType: networkType,
            rssiDBm: rssiDBm,
            noiseDBm: noiseDBm,
            transmitRateMbps: transmitRateMbps,
            mcsIndex: mcsIndex
        )
    }

    /// Pull the leading integer (with optional `-` / `−` sign) out of a
    /// string like "-43 dBm" or "520". Used by the Wi-Fi current-network
    /// parser since SP formats those values with a trailing unit.
    private static func leadingInt(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")  // Unicode minus
        var digits = ""
        for ch in trimmed {
            if ch == "-" || ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
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

    // MARK: - Camera ISP

    /// Look up the built-in camera's ISP front-end driver. Apple bumps
    /// the class suffix with each silicon generation (`AppleH13CamIn`
    /// on M3 / T6031, `AppleH16CamIn` on M5 / T6050, presumably `H17`
    /// on whatever ships next), so we sweep a small candidate list
    /// rather than hard-coding one. The properties dictionary is
    /// stable across the generations — see
    /// `design/IOService-Updates.md` H1 for the full schema.
    ///
    /// Returns nil when no candidate matches (chassis with no built-in
    /// camera, or a future silicon revision we haven't catalogued yet).
    private static func scanCameraISP() -> CameraISPInfo? {
        // Candidate classes ordered newest-first so an M-series host
        // with two matching kexts loaded (rare) prefers the newer one.
        let candidates = [
            "AppleH17CamIn",   // speculative — future-proofing the lookup
            "AppleH16CamIn",   // M5 / T6050
            "AppleH15CamIn",   // unobserved but consistent with the naming
            "AppleH14CamIn",   // unobserved
            "AppleH13CamIn"    // M3 / T6031
        ]
        for cls in candidates {
            let svc = IOServiceGetMatchingService(
                kIOMainPortDefault, IOServiceMatching(cls)
            )
            guard svc != 0 else { continue }
            defer { IOObjectRelease(svc) }
            let props = IORegBridge.properties(of: svc)
            let id = IORegBridge.entryID(of: svc) ?? 0
            return CameraISPInfo(
                kextClass: cls,
                firmwareVersion: props["ISPFirmwareVersion"]?.asString,
                firmwareLinkDate: props["ISPFirmwareLinkDate"]?.asString,
                firmwareLoaded: props["FirmwareLoaded"]?.asBool ?? false,
                frontCameraModuleSerial: props["FrontCameraModuleSerialNumString"]?.asString,
                frontIRProjectorSerial: props["FrontIRStructuredLightProjectorSerialNumString"]?.asString,
                frontCameraExpected: props["FrontCameraExpected"]?.asBool ?? false,
                frontCameraActive: props["FrontCameraActive"]?.asBool ?? false,
                frontCameraStreaming: props["FrontCameraStreaming"]?.asBool ?? false,
                isExclaveIsolated: props["IOExclaveProxy"]?.asBool ?? false,
                backingID: TBNodeID(raw: id)
            )
        }
        return nil
    }
}
