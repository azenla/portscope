//
//  HardwareSensorsView.swift
//  PortScope
//
//  Modal sheet (sibling of the Thunderbolt Topology view) that lists
//  every sensor the kernel exposes through IOKit on the host. Driven
//  by `SensorScanner.scan()` which walks the relevant service classes
//  and synthesises a friendly name per sensor from the kernel
//  `Product` string + decoded SMC key. Live values surface for the
//  battery / charger telemetry the kernel publishes as regular
//  IORegistry properties; HID-only sensors (the per-core thermal /
//  power probes) appear as discovery rows because their values are
//  only readable through the HID Event System (private API).
//

import SwiftUI

struct HardwareSensorsView: View {
    @State private var snapshot: HardwareSensorsSnapshot = .empty
    @State private var refreshTimer: Timer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
        .frame(minWidth: 760, minHeight: 720)
        .onAppear {
            snapshot = SensorScanner.scan()
            // Re-scan every 2 seconds so the live values (battery temp,
            // wall power) tick forward without the user mashing Refresh.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor in
                    self.snapshot = SensorScanner.scan()
                }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.medium")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hardware Sensors").font(.title2.bold())
                Text("Every sensor the kernel exposes through IOKit on this host.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    /// Tally bar so the user can see at a glance how many of each kind
    /// of sensor are present (e.g. "75 thermal · 150 power rails · 1
    /// ambient light · 1 trackpad").
    private var summary: some View {
        HStack(spacing: 14) {
            ForEach(snapshot.grouped, id: \.category) { group in
                HStack(spacing: 4) {
                    Image(systemName: group.category.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(group.sensors.count)")
                        .font(.caption.weight(.medium).monospacedDigit())
                    Text(group.category.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Capsule())
            }
            Spacer()
        }
    }

    private func sensorGroupCard(category: SensorCategory,
                                 sensors: [HardwareSensor]) -> some View {
        SectionCard(title: "\(category.title) (\(sensors.count))",
                    symbol: category.symbol) {
            VStack(spacing: 0) {
                ForEach(sensors) { sensor in
                    SensorRow(sensor: sensor)
                    if sensor.id != sensors.last?.id { Divider() }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Sensors with a live value read it from a published IORegistry property. Others (per-core PMU thermal / power probes, ALS, motion) require an HID Event System subscription to read — surfaced here as discovery rows. Sensor names are synthesised from the kernel `Product` string + the SMC key when the kernel publishes both.")
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

private struct SensorRow: View {
    let sensor: HardwareSensor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: sensor.category.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(sensor.name).font(.callout.weight(.medium))
                if let sub = sensor.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(sensor.kernelClass)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let v = sensor.value {
                HStack(spacing: 4) {
                    Text(formatValue(v))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    if let u = sensor.unit {
                        Text(u).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
            } else {
                Text("Live read needs HID")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
    }

    private func formatValue(_ v: Double) -> String {
        if abs(v) >= 100 { return String(format: "%.0f", v) }
        if abs(v) >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}
