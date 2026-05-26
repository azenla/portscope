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
    /// Wi-Fi adapter facts (chipset, MAC, country, supported PHYs,
    /// connected network). Nil when no Wi-Fi interface is available.
    let wifi: WiFiInfo?
    /// Physical memory modules. Apple Silicon publishes one entry for
    /// the unified-memory pool; Intel Macs publish one per DIMM bank.
    let memoryDIMMs: [MemoryDIMMInfo]
    /// Built-in + connected cameras as published by SPCameraDataType.
    /// External / Continuity cameras (e.g. "Prism Camera" from a paired
    /// iPhone) show up here too.
    let cameras: [CameraInfo]
    /// Kernel-side ISP front-end for the built-in camera, pulled from
    /// `AppleH13CamIn` (M3) / `AppleH16CamIn` (M5). Carries firmware
    /// version, module serial, active/streaming state, and exclave
    /// isolation flag. Nil when the host has no built-in camera or the
    /// kext class isn't present (e.g. on a future-silicon Mac before
    /// the catalogue learns about it).
    let cameraISP: CameraISPInfo?
    /// Audio devices (built-in speakers, microphone, plus any HDMI /
    /// USB-C audio sinks). Lets the user see what their default I/O is.
    let audioDevices: [AudioDeviceInfo]
    /// NVRAM variables — boot config, SIP state, language, FMM name.
    /// Empty when nvram isn't readable (sandboxed builds).
    let nvram: NVRAMSnapshot
    /// Cached HID device census — Apple-vendor sensors, keyboards,
    /// trackpads, biometric, etc. Walked once per heavy-tier rescan
    /// so the sidebar doesn't re-enumerate IOKit on every re-render.
    let hidDevices: HIDDevicesSnapshot
    /// Cached Touch ID state — same caching rationale as `hidDevices`.
    /// Nil when no AppleMesaShim service is present.
    let touchID: TouchIDInfo
    /// Cached trackpad + keyboard info. Static across a rescan.
    let inputDevices: InputDevicesInfo
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
    /// Snapshot of the host's security plumbing: Lockdown Mode
    /// availability, Boot Policy match, AMFI / System Policy / Endpoint
    /// Security presence, and the M5+ exclave + hardware-entropy
    /// extensions. Populated cheaply on every full scan.
    let security: SecurityPosture

    static let empty = SystemInfoSnapshot(
        chipName: nil, cpuCoreCount: nil, cpuPCoreCount: nil,
        cpuECoreCount: nil, gpuCoreCount: nil, metalVersion: nil,
        memoryBytes: nil, memoryType: nil, memoryManufacturer: nil,
        internalStorage: nil, wifi: nil, memoryDIMMs: [],
        cameras: [], cameraISP: nil, audioDevices: [], nvram: .empty,
        hidDevices: .empty, touchID: .empty, inputDevices: .empty,
        macOSVersion: nil, macOSBuild: nil,
        kernelVersion: nil, systemFirmware: nil, hwModel: nil,
        marketingName: nil, systemSerial: nil, hardwareUUID: nil,
        security: .empty
    )

    var hasAnyData: Bool {
        chipName != nil || memoryBytes != nil || internalStorage != nil
            || macOSVersion != nil
    }
}

/// Wi-Fi adapter facts as published by SPAirPortDataType. The "Card Type"
/// line gives us an Apple silicon chip rev (N1, BCM4387, etc.); the
/// connected network block gives us SSID + channel + band + PHY mode.
nonisolated struct WiFiInfo: Hashable {
    /// Interface name — `en0` on most Macs.
    let interface: String?
    /// Chipset descriptor extracted from the "Card Type" line. Best-effort
    /// — Apple packs a lot into one string; we try to surface the most
    /// human-meaningful token ("Apple N1", "BCM4387", etc.).
    let chipset: String?
    /// Wi-Fi firmware revision parsed out of the same string.
    let firmwareRevision: String?
    /// Built-in MAC address. Marked sensitive in the view layer.
    let macAddress: String?
    /// Regulatory locale + country code, e.g. "FCC / US".
    let regulatoryRegion: String?
    /// All PHY modes the radio advertises ("a/b/g/n/ac/ax/be"). Splits into
    /// the highest-rate name in the UI so users immediately see "Wi-Fi 7"
    /// when "be" is in the list.
    let supportedPHYs: String?
    /// Connection state — `Connected`, `Disconnected`, etc.
    let status: String?
    /// Currently-joined network SSID. Sensitive (treated as PII).
    let currentSSID: String?
    /// Currently-joined network PHY mode (`802.11ax`, `802.11be`, …).
    let currentPHY: String?
    /// Channel + band, e.g. "157 (5GHz, 80MHz)".
    let currentChannel: String?
    /// True when the radio advertises 6 GHz channels (Wi-Fi 6E / 7).
    let supports6GHz: Bool
    /// Security mode in use ("WPA2 Personal" / "WPA3 Enterprise" / …).
    let security: String?
    /// Network type ("Infrastructure" / "Ad Hoc" / "AWDL"). Always
    /// "Infrastructure" for normal Wi-Fi networks; surfaces when the user
    /// is connected to an iPhone hotspot or AWDL link.
    let networkType: String?
    /// Received signal strength in dBm (e.g. -43). Closer to 0 is
    /// stronger; below -70 is weak.
    let rssiDBm: Int?
    /// Noise floor in dBm (e.g. -93). Subtract from `rssiDBm` to get SNR.
    let noiseDBm: Int?
    /// Negotiated transmit rate in Mbps (e.g. 520). Caps out at the PHY's
    /// max under ideal SNR; drops with interference.
    let transmitRateMbps: Int?
    /// 802.11ac/ax MCS index — encodes modulation + coding rate. Higher
    /// = denser modulation = more bandwidth (but needs better SNR).
    let mcsIndex: Int?
}

/// One camera entry from SPCameraDataType. The kernel publishes both the
/// built-in FaceTime camera and any active Continuity / DriverKit cameras
/// (Apple's "Prism Camera" / external iPhone webcam).
nonisolated struct CameraInfo: Hashable, Identifiable {
    var id: String { uniqueID ?? name }
    let name: String
    /// Model identifier reported by the kernel (e.g. "iPhone18,2" for an
    /// iPhone-as-webcam, or "MacBook Pro Camera" for the built-in).
    let modelID: String?
    /// Device-unique camera ID. Surfaced for parity with the kernel
    /// `unique_id`; treated as sensitive.
    let uniqueID: String?
}

/// Built-in camera ISP (Image Signal Processor) front-end driver state.
/// Pulled from `AppleH13CamIn` (M3 / T6031) or `AppleH16CamIn` (M5 /
/// T6050) — Apple bumps the class suffix per silicon generation but the
/// property schema is stable. Only the built-in camera has an ISP card
/// (Continuity / external cameras don't route through this block), so
/// the snapshot carries a single optional. Pulled once during the heavy
/// scan tier; static across a session.
///
/// Documented in `design/IOService-Updates.md` H1.
nonisolated struct CameraISPInfo: Hashable {
    /// IOKit class name observed on this host, e.g. `"AppleH16CamIn"`.
    /// Doubles as the silicon-generation tell (`H13` = M3-class, `H16` =
    /// M5-class). Surfaced verbatim in Developer Details.
    let kextClass: String
    /// ISP firmware version string, e.g. `"5.502"`.
    let firmwareVersion: String?
    /// Firmware link-date string baked into the kext, e.g.
    /// `"Apr 27 2026 - 21:14:34"`. Reflects the macOS build that
    /// shipped the kext, not anything the user can change.
    let firmwareLinkDate: String?
    /// True when the kernel reports the firmware has been loaded into
    /// the ISP. Distinct from "the camera is streaming" — the firmware
    /// stays resident as soon as the engine is powered.
    let firmwareLoaded: Bool
    /// Front (FaceTime / built-in) camera module's serial number, when
    /// the kernel publishes it. Treated as sensitive — masked by
    /// default in the view layer.
    let frontCameraModuleSerial: String?
    /// IR structured-light projector serial when present. M-series
    /// MacBook Pros publish a placeholder ("XXXXXXXX") here; iPads /
    /// future Macs with Face ID would populate it for real.
    let frontIRProjectorSerial: String?
    /// True when the chassis is expected to have a front camera (i.e.
    /// the camera isn't physically disabled at the factory).
    let frontCameraExpected: Bool
    /// True when the kernel has the camera powered up. Spikes from
    /// `false` → `true` when an app starts a capture session.
    let frontCameraActive: Bool
    /// True while the ISP is actually streaming pixels. Distinct from
    /// `active` — a powered-on but idle camera is `active && !streaming`.
    let frontCameraStreaming: Bool
    /// True when the ISP is fronted by an Exclave proxy (`IOExclaveProxy
    /// = Yes` on the kext object). M5 / T6050+; absent on M3 and earlier.
    let isExclaveIsolated: Bool
    /// IORegistry entry ID of the ISP node so callers can pull the raw
    /// property table for Developer Details disclosure.
    let backingID: TBNodeID
}

/// One audio device from SPAudioDataType. Covers built-in speakers / mic
/// and any HDMI / USB-C audio sinks the user has hooked up.
nonisolated struct AudioDeviceInfo: Hashable, Identifiable {
    var id: String { name }
    let name: String
    let manufacturer: String?
    /// Transport mechanism: `Built-in`, `HDMI`, `USB`, `Bluetooth`, …
    let transport: String?
    /// Output channel count when the device sources audio.
    let outputChannels: Int?
    /// Input channel count when the device sinks audio.
    let inputChannels: Int?
    /// Active sample rate in Hz.
    let sampleRateHz: Int?
    /// True when this device is the system's default audio output.
    let isDefaultOutput: Bool
    /// True when this device is the system's default audio input.
    let isDefaultInput: Bool
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
    /// Apple SSD controller marketing name (e.g. "Apple SSD Controller").
    let controllerName: String?
    /// Partition map type (e.g. "GPT (GUID Partition Table)").
    let partitionMapType: String?
    /// True when SP reports the drive as removable / detachable.
    let removable: Bool?
    /// APFS / HFS+ volumes hosted on the drive.
    let volumes: [VolumeInfo]
}

/// One logical volume on the internal NVMe drive, as published by
/// `SPNVMeDataType`'s "Volumes:" sub-block. Apple Silicon stock layout
/// has four volumes (iSCPreboot, Macintosh HD, Recovery, Update) plus
/// any extra user-created APFS volumes.
nonisolated struct VolumeInfo: Hashable, Identifiable {
    var id: String { bsdName ?? name }
    let name: String
    let capacityBytes: UInt64?
    let bsdName: String?
    /// APFS role string ("Apple_APFS_ISC", "Apple_APFS", "Apple_APFS_Recovery"
    /// …). Useful for separating user data from system + recovery volumes.
    let content: String?
}

/// One memory module / DIMM. On Apple Silicon there's a single unified
/// memory pool (no replaceable DIMMs), so this is a single entry. On
/// Intel Macs SP enumerated each physical DIMM with size, type, speed,
/// status, manufacturer; we mirror that schema so the same view code
/// handles both.
nonisolated struct MemoryDIMMInfo: Hashable, Identifiable {
    var id: String { slot ?? name }
    /// Bank / module name. On Apple Silicon: "Onboard Memory" since
    /// there's only one. On Intel: "DIMM0", "DIMM1", …
    let name: String
    /// Slot identifier. May be nil on Apple Silicon (no physical slot).
    let slot: String?
    /// Capacity in bytes.
    let capacityBytes: UInt64?
    /// "LPDDR5" / "DDR4" / etc.
    let type: String?
    /// "Samsung" / "Micron" / "SK hynix" / …
    let manufacturer: String?
    /// Operating speed when published ("6400 MHz" on M-series LPDDR5).
    let speed: String?
    /// Part number when the kernel publishes one. Usually only on Intel
    /// DIMMs that came through the SMBIOS path.
    let partNumber: String?
}

/// Presence flags for the host's security plumbing. Each Bool is the
/// answer to "does an `IOServiceMatching(<class>)` lookup find anything
/// at boot" — a cheap probe (no property reads, no children walk) that
/// returns within microseconds. The flags collectively answer "is this
/// Mac running the standard macOS security stack" without claiming any
/// runtime state (e.g. whether Lockdown Mode is *enabled*, only whether
/// the capability is *available*). The richer runtime state lives in
/// user-space prefs and outside the IOKit plane.
///
/// Documented in `design/IOService-Updates.md` H5; classes selected
/// from the M3 Max + M5 Max audits in the adjacent design files.
nonisolated struct SecurityPosture: Hashable {
    /// `AppleLockdownMode` service — the Lockdown Mode subsystem is
    /// present and matchable. Says nothing about whether the user has
    /// actually turned it on (that's in `~/Library/Preferences`).
    let lockdownAvailable: Bool
    /// `BootPolicy` — Apple's signed-boot policy module is matched.
    /// Always true on a stock-config Mac; absence is the diagnostic
    /// signal that something is wrong with secure boot.
    let bootPolicyMatched: Bool
    /// `AppleMobileFileIntegrity` — AMFI enforcing code-signing for
    /// the kernel + userspace executables.
    let amfiActive: Bool
    /// `AppleSystemPolicy` — Gatekeeper / system-policy enforcement.
    let systemPolicyActive: Bool
    /// `EndpointSecurityDriver` — the ES framework KEXT used by
    /// EDR-style tools (and macOS's own daemons).
    let endpointSecurityActive: Bool
    /// `ExclaveSEPManagerProxy` — the Secure Enclave is fronted by an
    /// exclave-world proxy. M5 / T6050+ only; absent on M3 and earlier.
    let exclaveSepActive: Bool
    /// `AppleS8000AESAccelerator` — hardware AES used for FileVault /
    /// storage encryption. Present on every Apple Silicon Mac so far.
    let hardwareAESPresent: Bool
    /// `RTBuddyEntropyEndpoint` — RTKit-hosted hardware TRNG endpoint.
    /// Surfaced as M5+ but the class may show up on future silicon
    /// retro-fitted to M-series hosts.
    let hardwareTRNGPresent: Bool

    /// Boolean chip count for compact rendering ("4 of 8 enforced").
    var enforcedCount: Int {
        var c = 0
        if lockdownAvailable     { c += 1 }
        if bootPolicyMatched     { c += 1 }
        if amfiActive            { c += 1 }
        if systemPolicyActive    { c += 1 }
        if endpointSecurityActive { c += 1 }
        if exclaveSepActive      { c += 1 }
        if hardwareAESPresent    { c += 1 }
        if hardwareTRNGPresent   { c += 1 }
        return c
    }

    static let empty = SecurityPosture(
        lockdownAvailable: false,
        bootPolicyMatched: false,
        amfiActive: false,
        systemPolicyActive: false,
        endpointSecurityActive: false,
        exclaveSepActive: false,
        hardwareAESPresent: false,
        hardwareTRNGPresent: false
    )

    var isEmpty: Bool {
        return enforcedCount == 0
    }
}
