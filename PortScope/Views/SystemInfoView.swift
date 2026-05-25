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
        if let mem = info.memoryBytes { parts.append(formatBytes(mem)) }
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
                        value: info.chipName ?? "—",
                        symbol: "cpu"))
        out.append(Stat(label: "CPU Cores",
                        value: cpuCoresLabel,
                        symbol: "cpu"))
        if info.gpuCoreCount != nil || info.metalVersion != nil {
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
        return out
    }

    private var cpuCoresLabel: String {
        guard let total = info.cpuCoreCount else { return "—" }
        if let split = cpuCoreSplit { return "\(total) (\(split))" }
        return "\(total)"
    }

    private var gpuLabel: String {
        var parts: [String] = []
        if let cores = info.gpuCoreCount { parts.append("\(cores)-core") }
        if let metal = info.metalVersion { parts.append(metal) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var memoryLabel: String {
        guard let bytes = info.memoryBytes else { return "—" }
        var parts: [String] = [formatBytes(bytes)]
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
            out.append(Stat(label: "Capacity", value: formatBytes(cap), symbol: "externaldrive"))
        }
        if let fw = s.firmware {
            out.append(Stat(label: "Firmware", value: fw, symbol: "memorychip"))
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

    /// Decimal-units byte formatter ("128 GB", "2 TB") matching Apple's
    /// own About this Mac convention. We don't want to surface RAM as
    /// "119 GiB" — users compare it against Apple's spec sheet.
    private func formatBytes(_ bytes: UInt64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useTB]
        fmt.countStyle = .decimal
        fmt.includesActualByteCount = false
        return fmt.string(fromByteCount: Int64(bytes))
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
