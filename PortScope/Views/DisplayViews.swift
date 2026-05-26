//
//  DisplayViews.swift
//  PortScope
//
//  Detail card for a single display engine — built-in panel or external
//  framebuffer slot.
//

import SwiftUI

struct DisplayDetailView: View {
    let display: DisplayInfo
    /// Aggregated HDCP channels (system-wide). Passed in here rather
    /// than read from a snapshot global so the card can render without
    /// re-fetching IOKit. The view filters to channels with a relevant
    /// transport and shows the host's content-protection posture; per-
    /// display channel attribution isn't stable enough to claim.
    var hdcpChannels: [HDCPChannelState] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DisplayHero(display: display)

                StatGrid(stats: statRows())

                if let modes = timingModeSummary(), !modes.isEmpty {
                    SectionCard(title: "Timing Modes (\(modes.count))",
                                symbol: "rectangle.and.text.magnifyingglass") {
                        VStack(spacing: 0) {
                            ForEach(modes, id: \.label) { mode in
                                TimingRow(mode: mode)
                                if modes.last?.label != mode.label { Divider() }
                            }
                        }
                    }
                }

                if !hdcpChannels.isEmpty {
                    SectionCard(title: "Content Protection (HDCP)",
                                symbol: "lock.shield") {
                        HDCPCard(channels: hdcpChannels)
                    }
                }

                if display.isBuiltIn {
                    SectionCard(title: "About this Engine", symbol: "info.circle") {
                        Text("`disp0` drives the laptop's built-in Liquid Retina XDR panel via the SoC's Display Coprocessor (DCP). Refresh rate is variable on this generation — anywhere from idle (~10 Hz) up to 120 Hz ProMotion.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if display.isConnected {
                    SectionCard(title: "About this Engine", symbol: "info.circle") {
                        Text("`\(display.deviceTreeName)` is an external display engine driving a panel attached via DisplayPort alt-mode or HDMI through one of the USB-C / Thunderbolt receptacles. Refresh range and mode list come from the panel's EDID.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SectionCard(title: "About this Engine", symbol: "info.circle") {
                        Text("`\(display.deviceTreeName)` is reserved for an external display but currently has nothing attached. Plug in a USB-C / Thunderbolt display to activate it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                DeveloperDisclosureCard(node: display.node)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private func statRows() -> [Stat] {
        var stats: [Stat] = [
            Stat(label: "Engine",
                 value: display.deviceTreeName,
                 symbol: "memorychip"),
            Stat(label: "Type",
                 value: display.isBuiltIn ? "Built-in" : "External",
                 symbol: display.iconSymbol),
            Stat(label: "Status",
                 value: display.isConnected ? "Active" : "Idle",
                 symbol: display.isConnected ? "checkmark.circle.fill" : "circle.slash")
        ]
        if let w = display.widthPixels, let h = display.heightPixels {
            stats.append(Stat(label: "Resolution",
                              value: "\(w) × \(h)",
                              symbol: "rectangle.expand.vertical"))
        }
        if let curr = display.currentRefreshHz {
            stats.append(Stat(label: "Current Refresh",
                              value: formatHz(curr),
                              symbol: "metronome"))
        }
        if let maxHz = display.maxRefreshHz, let minHz = display.minRefreshHz {
            let value: String
            if abs(maxHz - minHz) > 1 {
                value = "\(Int(minHz.rounded())) – \(Int(maxHz.rounded())) Hz"
            } else {
                value = "\(Int(maxHz.rounded())) Hz"
            }
            stats.append(Stat(label: "Supported Range",
                              value: value,
                              symbol: "arrow.left.and.right"))
        }
        if display.variableRefreshCapable || display.variableRefreshActive {
            let value: String
            if display.variableRefreshActive {
                value = "Active"
            } else if display.variableRefreshCapable {
                value = "Capable"
            } else {
                value = "—"
            }
            stats.append(Stat(label: "Variable Refresh",
                              value: value,
                              symbol: "waveform.path"))
        }
        if let encoding = display.pixelEncoding {
            stats.append(Stat(label: "Pixel Encoding",
                              value: encoding,
                              symbol: "square.grid.3x3"))
        }
        if let depth = display.colorBitDepth {
            stats.append(Stat(label: "Color Depth",
                              value: "\(depth)-bit",
                              symbol: "paintpalette"))
        }
        if let space = display.colorSpace {
            stats.append(Stat(label: "Color Space",
                              value: space,
                              symbol: "drop.halffull"))
        }
        if display.supportsHDR {
            stats.append(Stat(label: "HDR",
                              value: "Capable",
                              symbol: "sparkles"))
        }
        if let accuracy = display.colorAccuracyIndex {
            stats.append(Stat(label: "Color Accuracy Index",
                              value: "\(accuracy) / 100",
                              symbol: "circle.lefthalf.fill"))
        }
        if display.timingModeCount > 0 {
            stats.append(Stat(label: "Modes Available",
                              value: "\(display.timingModeCount)",
                              symbol: "rectangle.stack"))
        }
        return stats
    }

    /// Refresh-rate formatter — round to integer for normal panels (60,
    /// 120, 144), keep two decimals on cinema-pace rates (23.98, 29.97,
    /// 47.95) so the format-conformant numbers stay visible.
    private func formatHz(_ hz: Double) -> String {
        if hz < 30 { return String(format: "%.2f Hz", hz) }
        let rounded = hz.rounded()
        if abs(hz - rounded) > 0.05 { return String(format: "%.2f Hz", hz) }
        return "\(Int(rounded)) Hz"
    }

    /// Pull a compact list of unique resolution / refresh entries out of
    /// the kernel's `TimingElements` array. We don't try to reproduce every
    /// nuance (sync polarities, porch widths, etc.) — that's developer
    /// detail. Just the modes the user could pick from System Settings.
    private struct TimingMode { let label: String; let isPreferred: Bool; let refresh: Double; let width: UInt64; let height: UInt64 }

    private func timingModeSummary() -> [TimingMode]? {
        guard case let .array(arr) = display.node.properties["TimingElements"] else { return nil }
        var seen: Set<String> = []
        var out: [TimingMode] = []
        for elem in arr {
            guard case let .dictionary(kv) = elem else { continue }
            let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
            guard let preferred = d["IsPreferred"]?.asBool else { continue }
            guard case let .dictionary(hKV) = d["HorizontalAttributes"] else { continue }
            guard case let .dictionary(vKV) = d["VerticalAttributes"] else { continue }
            let h = Dictionary(hKV, uniquingKeysWith: { a, _ in a })
            let v = Dictionary(vKV, uniquingKeysWith: { a, _ in a })
            guard let w = h["Active"]?.asUInt,
                  let height = v["Active"]?.asUInt,
                  let preciseRate = v["PreciseSyncRate"]?.asUInt else { continue }
            // PreciseSyncRate is in 1/65536 Hz fixed-point.
            let hz = Double(preciseRate) / 65536.0
            let label = "\(w) × \(height) @ \(String(format: hz < 30 ? "%.2f" : "%.0f", hz)) Hz"
            if seen.insert(label).inserted {
                out.append(TimingMode(label: label, isPreferred: preferred,
                                      refresh: hz, width: w, height: height))
            }
        }
        // Sort: preferred first, then by refresh rate descending.
        out.sort {
            if $0.isPreferred != $1.isPreferred { return $0.isPreferred && !$1.isPreferred }
            return $0.refresh > $1.refresh
        }
        return out
    }

    private struct TimingRow: View {
        let mode: TimingMode

        var body: some View {
            HStack(spacing: 12) {
                if mode.isPreferred {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.yellow)
                } else {
                    Image(systemName: "rectangle").foregroundStyle(.secondary)
                }
                Text(mode.label)
                    .font(.callout.monospaced())
                Spacer()
                if mode.isPreferred {
                    Text("Preferred")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.15))
                        .foregroundStyle(.yellow)
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
        }
    }
}

private struct DisplayHero: View {
    let display: DisplayInfo

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill((display.isConnected ? Color.blue : .secondary).opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: display.iconSymbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(display.isConnected ? .blue : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(display.title).font(.title2).bold()
                if let s = display.subtitle, !s.isEmpty {
                    Text(s).foregroundStyle(.secondary)
                }
                if display.isConnected {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Active").font(.caption.weight(.medium)).foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            Spacer()
        }
    }
}

/// Wraps the existing PropertyTableView with the "Developer details" header
/// used in DetailView. Shared so PCIe / Display / Bluetooth detail screens
/// can offer the same drill-down without duplicating layout.
struct DeveloperDisclosureCard: View {
    let node: TBNode
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .frame(width: 12)
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.secondary)
                    Text("Developer details (raw IORegistry)")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                PropertyTableView(node: node)
                    .padding(.top, 8)
            }
        }
    }
}

/// Compact view of the HDCP channel table. We deliberately don't try to
/// pair channels with specific displays — the kernel doesn't publish a
/// reliable mapping (see `design/IOService-Updates.md` H2). Instead we
/// surface the host's overall posture (peak TX capability + how many
/// channels are actively transmitting) and a tight per-channel table so
/// the user can correlate by transport class when needed.
private struct HDCPCard: View {
    let channels: [HDCPChannelState]

    private var activeCount: Int {
        channels.filter(\.isTransmitter).count
    }
    private var hostMaxLabel: String {
        // The host's peak TX capability is the highest revision any
        // channel advertises. Real-world value on M3/M5: every channel
        // has TX = (1, 2) so the answer is "HDCP 2.x" — but we read it
        // dynamically so a future chassis with HDCP 2.3 / 2.4 surfaces
        // correctly.
        let allTX = Set(channels.flatMap(\.txProtocols))
        if allTX.contains(2) { return "HDCP 2.x" }
        if allTX.contains(1) { return "HDCP 1.x" }
        return "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("Host advertises **\(hostMaxLabel)**")
                    .font(.callout)
                Spacer()
                Text(activeCount > 0
                     ? "\(activeCount) active · \(channels.count) channels"
                     : "\(channels.count) channels · none active")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Channel-to-display mapping isn't published in IOKit; "
                 + "the table below is the host's full HDCP fabric. "
                 + "Channels with role **Transmitter** are the ones "
                 + "actively negotiating with a sink.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                HDCPRowHeader()
                ForEach(channels) { c in
                    Divider()
                    HDCPRow(channel: c)
                }
            }
            .background(.background.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct HDCPRowHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("CH").frame(width: 28, alignment: .leading)
            Text("Transport").frame(width: 90, alignment: .leading)
            Text("Role").frame(width: 110, alignment: .leading)
            Text("Host (TX)").frame(width: 80, alignment: .leading)
            Text("Sink (RX)").frame(width: 80, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct HDCPRow: View {
    let channel: HDCPChannelState

    var body: some View {
        HStack(spacing: 12) {
            Text("\(channel.channel)")
                .frame(width: 28, alignment: .leading)
                .font(.caption.monospacedDigit())
            Text(channel.transportLabel)
                .frame(width: 90, alignment: .leading)
                .font(.caption)
            HStack(spacing: 4) {
                Image(systemName: channel.isTransmitter
                      ? "dot.radiowaves.left.and.right"
                      : "circle.dotted")
                    .font(.caption2)
                    .foregroundStyle(channel.isTransmitter ? .green : .secondary)
                Text(channel.isTransmitter ? "Transmitter" : "Idle")
                    .font(.caption)
                    .foregroundStyle(channel.isTransmitter ? .primary : .secondary)
            }
            .frame(width: 110, alignment: .leading)
            Text(channel.txMaxLabel ?? "—")
                .frame(width: 80, alignment: .leading)
                .font(.caption)
            Text(channel.rxMaxLabel ?? "—")
                .frame(width: 80, alignment: .leading)
                .font(.caption)
                .foregroundStyle(channel.rxMaxLabel == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
