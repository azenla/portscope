//
//  HardwareSensorsView.swift
//  PortScope
//
//  Modal sheet (sibling of the Thunderbolt Topology view) that surveys
//  every sensor PortScope can read live values from. Driven by
//  `SensorScanner.scan()` which merges static IORegistry identification
//  (Product, SMC key, kernel class) with live HID Event System readings
//  for temperature / power / ambient light, plus direct IORegistry
//  reads for battery + AC-PSU telemetry.
//
//  Layout is a continuous, reflowing chip grid grouped by sensor
//  category. Each chip carries the friendly name, the live value, and
//  a fine-print line with the SMC key when available. The grid fills
//  whatever width the sheet provides — better signal density for a
//  view that can have 200+ live readings on a busy M-class chip.
//

import SwiftUI

struct HardwareSensorsView: View {
    @State private var snapshot: HardwareSensorsSnapshot = .empty
    @State private var refreshTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    ForEach(snapshot.grouped, id: \.category) { group in
                        sensorGroupCard(category: group.category,
                                        sensors: group.sensors)
                    }
                    legend
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.04))
            Divider()
            footer
        }
        .frame(minWidth: 1100, minHeight: 820)
        .task {
            // Drive the refresh loop on a background task so the
            // IOHIDEventSystem reads + IORegistry walks don't block the
            // main thread. Each iteration scans off-main and hops back
            // to MainActor only to publish the new snapshot.
            refreshTask?.cancel()
            refreshTask = Task.detached(priority: .userInitiated) {
                while !Task.isCancelled {
                    let snap = SensorScanner.scan()
                    await MainActor.run { self.snapshot = snap }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        .onDisappear { refreshTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.medium")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hardware Sensors").font(.title2.bold())
                Text("Live readings from every sensor PortScope can reach through the HID Event System.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    /// Tally chips so the user can see at a glance how many of each
    /// category are present and live ("Temperature 89 · Power 47 ·
    /// Ambient Light 1 · Battery 1").
    private var summary: some View {
        FlowChips {
            ForEach(snapshot.grouped, id: \.category) { group in
                HStack(spacing: 6) {
                    Image(systemName: group.category.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(group.sensors.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                    Text(group.category.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Capsule())
            }
        }
    }

    private func sensorGroupCard(category: SensorCategory,
                                 sensors: [HardwareSensor]) -> some View {
        SectionCard(title: "\(category.title) (\(sensors.count))",
                    symbol: category.symbol) {
            FlowChips {
                ForEach(sensors) { sensor in
                    SensorChip(sensor: sensor)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Values stream from the HID Event System for thermal / power / ambient-light sensors; battery and AC-PSU readings come straight from `AppleSmartBattery` IORegistry properties. Names are synthesised from the kernel `Product` string + the decoded 4-character SMC key — e.g. `Tp01` → \"Performance Core p01\".")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var footer: some View {
        HStack {
            Text("\(snapshot.sensors.count) sensor\(snapshot.sensors.count == 1 ? "" : "s") · updated \(updatedAgo)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
    }

    private var updatedAgo: String {
        let s = Int(-snapshot.capturedAt.timeIntervalSinceNow)
        if s < 2 { return "just now" }
        return "\(s) s ago"
    }
}

// MARK: - Chip

/// One sensor rendered as a compact chip: friendly name across the
/// top, the live value as the focal element, and a fine-print SMC-key
/// subtitle. Colour-coded by category so the eye finds clusters of
/// thermal vs power vs light rows at a glance.
private struct SensorChip: View {
    let sensor: HardwareSensor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: sensor.category.symbol)
                    .font(.caption2)
                    .foregroundStyle(accent)
                Text(sensor.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(formatValue(sensor.value ?? .nan))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                if let unit = sensor.unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let sub = sensor.subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 200, alignment: .leading)
        .background(accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(0.25), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var accent: Color {
        switch sensor.category {
        case .temperature: return .orange
        case .power:       return .red
        case .voltage:     return .yellow
        case .current:     return .yellow
        case .energy:      return .green
        case .light:       return .blue
        case .motion:      return .purple
        case .biometric:   return .pink
        case .button:      return .gray
        case .touch:       return .cyan
        case .other:       return .secondary
        }
    }

    private func formatValue(_ v: Double) -> String {
        if !v.isFinite { return "—" }
        if abs(v) >= 1000 { return String(format: "%.0f", v) }
        if abs(v) >= 100 { return String(format: "%.0f", v) }
        if abs(v) >= 10 { return String(format: "%.1f", v) }
        if abs(v) >= 1 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }
}
