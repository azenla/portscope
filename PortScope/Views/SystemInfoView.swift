//
//  SystemInfoView.swift
//  PortScope
//
//  "About this Mac"-style overview rendered at the top of the **Internal
//  Hardware** sidebar section. One landing card for the host's identity:
//  chip + cores, GPU, RAM, internal SSD, OS / firmware / serial. Pulls
//  its data from `SystemInfoSnapshot` which the scanner populates once
//  per full rescan (sysctl is cheap; the `system_profiler` portions are
//  cached and survive the 2-second power-poll refresh).
//

import SwiftUI

struct SystemInfoView: View {
    let info: SystemInfoSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: hardwareStats)
                if let storage = info.internalStorage {
                    SectionCard(title: "Internal Storage", symbol: "internaldrive") {
                        StatGrid(stats: storageStats(storage))
                    }
                }
                SectionCard(title: "Software", symbol: "apple.logo") {
                    StatGrid(stats: softwareStats)
                }
                if !info.security.isEmpty {
                    SectionCard(title: "Security Posture", symbol: "lock.shield") {
                        SecurityChipRow(posture: info.security)
                    }
                }
                if !info.timeSync.isEmpty {
                    SectionCard(title: "Time Sync · AVB",
                                symbol: "clock.badge.checkmark") {
                        StatGrid(stats: timeSyncStats)
                    }
                }
                if let vt = info.voiceTrigger {
                    SectionCard(title: "Always-On Voice Trigger",
                                symbol: "waveform.and.mic") {
                        VStack(alignment: .leading, spacing: 10) {
                            if vt.isExclaveIsolated {
                                ExclaveBadge()
                            }
                            StatGrid(stats: voiceTriggerStats(vt))
                        }
                    }
                }
                SectionCard(title: "Identifiers", symbol: "barcode") {
                    StatGrid(stats: identifierStats)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(info.marketingName ?? info.hwModel ?? "Mac")
                    .font(.title2).bold()
                if let chip = info.chipName {
                    Text(chip).foregroundStyle(.secondary).font(.callout)
                }
                if let sub = subline {
                    Text(sub).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    private var subline: String? {
        var parts: [String] = []
        if let cores = info.cpuCoreCount {
            let split = cpuCoreSplit
            if let split { parts.append("\(cores)-core CPU (\(split))") }
            else { parts.append("\(cores)-core CPU") }
        }
        if let gpu = info.gpuCoreCount { parts.append("\(gpu)-core GPU") }
        if let mem = info.memoryBytes { parts.append(formatMemoryBytes(mem)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var cpuCoreSplit: String? {
        switch (info.cpuPCoreCount, info.cpuECoreCount) {
        case (let p?, let e?): return "\(p)P + \(e)E"
        case (let p?, nil):    return "\(p)P"
        case (nil, let e?):    return "\(e)E"
        default:               return nil
        }
    }

    // MARK: - Stat grids

    private var hardwareStats: [Stat] {
        var out: [Stat] = []
        out.append(Stat(label: "Chip",
                        value: chipLabel,
                        symbol: "cpu"))
        out.append(Stat(label: "CPU Cores",
                        value: cpuCoresLabel,
                        symbol: "cpu"))
        if info.gpuCoreCount != nil || info.metalVersion != nil
            || info.socFeatures.gpuArchitecture != nil {
            out.append(Stat(label: "GPU",
                            value: gpuLabel,
                            symbol: "display"))
        }
        out.append(Stat(label: "Memory",
                        value: memoryLabel,
                        symbol: "memorychip"))
        if let model = info.hwModel {
            out.append(Stat(label: "Model ID",
                            value: model,
                            symbol: "tag"))
        }
        if info.socFeatures.supportsProcessorTrace {
            // M5 / T6050+ — surface the kernel's
            // `AppleProcessorTrace*` capability as an actionable bit
            // for developers debugging instruction-trace tooling.
            out.append(Stat(label: "Hardware Instruction Trace",
                            value: "Supported",
                            symbol: "waveform.path.ecg"))
        }
        return out
    }

    /// Chip label combines the marketing brand string with the
    /// silicon codename when we recognise it ("Apple M5 Max · T6050").
    /// Keeps the marketing-first ordering since that's what users
    /// read in About this Mac.
    private var chipLabel: String {
        let brand = info.chipName ?? "—"
        if let codename = info.socFeatures.codename,
           !brand.contains(codename) {
            return "\(brand) · \(codename)"
        }
        return brand
    }

    private var cpuCoresLabel: String {
        guard let total = info.cpuCoreCount else { return "—" }
        if let split = cpuCoreSplit { return "\(total) (\(split))" }
        return "\(total)"
    }

    private var gpuLabel: String {
        var parts: [String] = []
        if let cores = info.gpuCoreCount { parts.append("\(cores)-core") }
        if let arch = info.socFeatures.gpuArchitecture {
            parts.append("Apple \(arch)")
        }
        if let metal = info.metalVersion { parts.append(metal) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var memoryLabel: String {
        guard let bytes = info.memoryBytes else { return "—" }
        var parts: [String] = [formatMemoryBytes(bytes)]
        if let type = info.memoryType { parts.append(type) }
        if let mfr = info.memoryManufacturer { parts.append(mfr) }
        return parts.joined(separator: " · ")
    }

    private func storageStats(_ s: InternalStorageInfo) -> [Stat] {
        var out: [Stat] = []
        if let model = s.model {
            out.append(Stat(label: "Model", value: model, symbol: "internaldrive"))
        }
        if let cap = s.capacityBytes {
            out.append(Stat(label: "Capacity", value: formatStorageBytes(cap), symbol: "externaldrive"))
        }
        if let fw = s.firmware {
            // SP formats the NVMe revision with a US thousands separator
            // ("2,973.120"); the underlying value is the literal version
            // string ("2973.120"). Strip the comma so the rendered value
            // matches Apple's About This Mac UI and feels like a real
            // version number rather than a locale-formatted figure.
            out.append(Stat(label: "Firmware",
                            value: fw.replacingOccurrences(of: ",", with: ""),
                            symbol: "memorychip"))
        }
        if let bsd = s.bsdName {
            out.append(Stat(label: "BSD Name", value: bsd, symbol: "terminal"))
        }
        if let trim = s.trimSupported {
            out.append(Stat(label: "TRIM",
                            value: trim ? "Supported" : "Not Supported",
                            symbol: "scissors"))
        }
        if let smart = s.smartStatus {
            out.append(Stat(label: "S.M.A.R.T.",
                            value: smart,
                            symbol: "heart.text.square"))
        }
        if let serial = s.serial {
            out.append(Stat(label: "Serial",
                            value: serial,
                            symbol: "barcode",
                            isSecret: true))
        }
        return out
    }

    private var softwareStats: [Stat] {
        var out: [Stat] = []
        if let v = info.macOSVersion {
            out.append(Stat(label: "macOS",
                            value: info.macOSBuild.map { "\(v) (\($0))" } ?? v,
                            symbol: "apple.logo"))
        }
        if let k = info.kernelVersion {
            out.append(Stat(label: "Darwin Kernel",
                            value: k,
                            symbol: "terminal"))
        }
        if let fw = info.systemFirmware {
            out.append(Stat(label: "System Firmware",
                            value: fw,
                            symbol: "memorychip"))
        }
        return out
    }

    /// Time-sync / AVB stats: gPTP availability + AVB entity identifier
    /// formatted the way `avbutil` renders it (8-byte hex). Surfaced
    /// only when at least one of the two signals is present so the
    /// card stays hidden on hosts that don't run AVB.
    private var timeSyncStats: [Stat] {
        var out: [Stat] = []
        out.append(Stat(label: "Precision Time (gPTP)",
                        value: info.timeSync.gPTPAvailable
                            ? "Supported" : "Not supported",
                        symbol: "timer"))
        if let entity = info.timeSync.entityIDLabel {
            out.append(Stat(label: "AVB Entity ID",
                            value: entity,
                            symbol: "number"))
        }
        return out
    }

    /// Voice trigger stats — enabled flag, lifetime trigger counter,
    /// and which mic channels feed the detector. The trigger count
    /// resets at sleep/wake so it reads as a "since last wake"
    /// counter in practice.
    private func voiceTriggerStats(_ vt: VoiceTriggerInfo) -> [Stat] {
        var out: [Stat] = []
        out.append(Stat(label: "Status",
                        value: vt.enabled ? "Listening" : "Disabled",
                        symbol: vt.enabled
                            ? "ear.and.waveform" : "ear.fill"))
        if let count = vt.triggerCount {
            out.append(Stat(label: "Trigger Count",
                            value: "\(count)",
                            symbol: "number"))
        }
        if let mask = vt.activeChannelMask {
            // Render the bitmask as a list of channel indices —
            // `0x1` → "ch 0", `0x3` → "ch 0, 1", etc.
            let channels = (0..<64).filter { mask & (1 << $0) != 0 }
            if !channels.isEmpty {
                let label = channels.map { "ch \($0)" }.joined(separator: ", ")
                out.append(Stat(label: "Active Mics",
                                value: label,
                                symbol: "mic"))
            }
        }
        return out
    }

    private var identifierStats: [Stat] {
        var out: [Stat] = []
        if let serial = info.systemSerial {
            out.append(Stat(label: "Serial",
                            value: serial,
                            symbol: "barcode",
                            isSecret: true))
        }
        if let uuid = info.hardwareUUID {
            out.append(Stat(label: "Hardware UUID",
                            value: uuid,
                            symbol: "number",
                            isSecret: true))
        }
        return out
    }

    /// Storage capacity formatter — decimal units ("2 TB"), matching the
    /// way Apple bins NVMe sizes in About This Mac and on the spec sheet.
    private func formatStorageBytes(_ bytes: UInt64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useTB]
        fmt.countStyle = .decimal
        fmt.includesActualByteCount = false
        return fmt.string(fromByteCount: Int64(bytes))
    }

    /// Memory formatter — base-2 units ("128 GB"). Apple's marketing
    /// always presents RAM in binary GB even though the suffix is the
    /// decimal one; About this Mac shows a 137,438,953,472-byte module
    /// as "128 GB" too. Using ByteCountFormatter's decimal style here
    /// rendered "137.44 GB", which doesn't match any user-facing source.
    private func formatMemoryBytes(_ bytes: UInt64) -> String {
        let gib = bytes / (1024 * 1024 * 1024)
        if gib >= 1024 {
            let tib = Double(bytes) / Double(1024 * 1024 * 1024 * 1024)
            return String(format: "%.0f TB", tib)
        }
        return "\(gib) GB"
    }
}

/// Synthetic selector for the "System Overview" sidebar row. Like
/// `MagSafeSelector` and friends, it lives outside the IORegistry plane
/// so the row's selection doesn't collide with a real entry's id.
enum SystemInfoSelector {
    private static let mask: UInt64 = 0x5757_0070_0000_0001
    static let id = TBNodeID(raw: mask)
    static func isSystemID(_ id: TBNodeID) -> Bool { id.raw == mask }
}

/// Compact row of "is-present" chips for the eight security-posture
/// signals. Each chip lights up when the corresponding IOService is
/// matchable at scan time; absent chips render dimmed so the user can
/// see *which* piece of the stack is missing rather than just an
/// abridged list. M5-specific chips (Exclave SEP, Hardware Entropy)
/// dim gracefully on M3 / earlier hosts.
private struct SecurityChipRow: View {
    let posture: SecurityPosture

    private struct Chip: Identifiable {
        let id = UUID()
        let label: String
        let icon: String
        let on: Bool
        let help: String
    }

    private var chips: [Chip] {
        [
            Chip(label: "Lockdown Mode",
                 icon: "shield.lefthalf.filled.badge.checkmark",
                 on: posture.lockdownAvailable,
                 help: "AppleLockdownMode service present"),
            Chip(label: "Boot Policy",
                 icon: "lock.doc",
                 on: posture.bootPolicyMatched,
                 help: "BootPolicy service matched at boot"),
            Chip(label: "AMFI",
                 icon: "checkmark.seal",
                 on: posture.amfiActive,
                 help: "AppleMobileFileIntegrity active"),
            Chip(label: "System Policy",
                 icon: "person.badge.shield.checkmark",
                 on: posture.systemPolicyActive,
                 help: "AppleSystemPolicy (Gatekeeper) active"),
            Chip(label: "Endpoint Security",
                 icon: "eye.trianglebadge.exclamationmark",
                 on: posture.endpointSecurityActive,
                 help: "EndpointSecurityDriver loaded"),
            Chip(label: "Exclave SEP",
                 icon: "lock.square.stack",
                 on: posture.exclaveSepActive,
                 help: "ExclaveSEPManagerProxy present (M5+ / T6050+)"),
            Chip(label: "Hardware AES",
                 icon: "key.horizontal",
                 on: posture.hardwareAESPresent,
                 help: "AppleS8000AESAccelerator present"),
            Chip(label: "Hardware Entropy",
                 icon: "dice",
                 on: posture.hardwareTRNGPresent,
                 help: "RTBuddyEntropyEndpoint present (M5+)")
        ]
    }

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(chips) { c in
                HStack(spacing: 8) {
                    Image(systemName: c.icon)
                        .foregroundStyle(c.on ? Color.green : Color.secondary)
                        .frame(width: 18)
                    Text(c.label)
                        .font(.callout)
                        .foregroundStyle(c.on ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(c.on ? Color.green.opacity(0.12)
                                   : Color.secondary.opacity(0.08))
                )
                .help(c.help)
            }
        }
    }
}
