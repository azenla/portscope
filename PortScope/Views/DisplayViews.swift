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

    var body: some View {
        DetailContainer {
            Hero(
                symbol: display.iconSymbol,
                title: display.title,
                subtitle: display.subtitle?.isEmpty == false ? display.subtitle : nil,
                status: display.isConnected ? .active : .idle
            )

            PropertyList {
                PropertyRowSpec("Engine", display.deviceTreeName, mono: true)
                PropertyRowSpec(forcing: "Type", display.isBuiltIn ? "Built-in" : "External")
                PropertyRowSpec(forcing: "Status", display.isConnected ? "Active" : "Idle")
                PropertyRowSpec("Resolution", resolutionString)
                PropertyRowSpec("Refresh", refreshString)
                PropertyRowSpec("Color depth",
                                display.colorBitDepth.map { "\($0)-bit" })
                PropertyRowSpec("Color accuracy",
                                display.colorAccuracyIndex.map { "\($0) / 100" })
                if display.supportsHDR {
                    PropertyRowSpec(forcing: "HDR / EDR", "Supported")
                }
                PropertyRowSpec("Modes available",
                                display.timingModeCount > 0
                                    ? "\(display.timingModeCount)"
                                    : nil)
            }

            if let modes = timingModeSummary(), !modes.isEmpty {
                DisclosureCard("Supported timing modes (\(modes.count))",
                               icon: "rectangle.stack") {
                    TimingModesTable(modes: modes)
                }
            }

            engineExplainer

            DisclosureCard("Developer details (raw IORegistry)",
                           icon: "wrench.and.screwdriver") {
                PropertyTableView(node: display.node)
            }
        }
    }

    @ViewBuilder
    private var engineExplainer: some View {
        if display.isBuiltIn {
            EmptyStateNote(text: "`disp0` drives the laptop's built-in Liquid Retina XDR panel via the SoC's Display Coprocessor (DCP). Refresh rate is variable on this generation — anywhere from idle (~10 Hz) up to 120 Hz ProMotion.")
        } else if display.isConnected {
            EmptyStateNote(text: "`\(display.deviceTreeName)` is an external display engine driving a panel attached via DisplayPort alt-mode or HDMI through one of the USB-C / Thunderbolt receptacles. Refresh range and mode list come from the panel's EDID.")
        } else {
            EmptyStateNote(text: "`\(display.deviceTreeName)` is reserved for an external display but currently has nothing attached. Plug in a USB-C / Thunderbolt display to activate it.")
        }
    }

    private var resolutionString: String? {
        guard let w = display.widthPixels, let h = display.heightPixels else { return nil }
        return "\(w) × \(h)"
    }

    private var refreshString: String? {
        guard let maxHz = display.maxRefreshHz else { return nil }
        if let minHz = display.minRefreshHz, abs(maxHz - minHz) > 1 {
            return "\(Int(minHz.rounded())) – \(Int(maxHz.rounded())) Hz"
        }
        return "\(Int(maxHz.rounded())) Hz"
    }

    // MARK: - Timing modes

    struct TimingMode: Identifiable, Hashable {
        let id: UUID
        let label: String
        let isPreferred: Bool
        let refresh: Double
        let width: UInt64
        let height: UInt64
    }

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
            let hz = Double(preciseRate) / 65536.0
            let label = "\(w) × \(height) @ \(String(format: hz < 30 ? "%.2f" : "%.0f", hz)) Hz"
            if seen.insert(label).inserted {
                out.append(TimingMode(id: UUID(),
                                      label: label,
                                      isPreferred: preferred,
                                      refresh: hz,
                                      width: w,
                                      height: height))
            }
        }
        out.sort {
            if $0.isPreferred != $1.isPreferred { return $0.isPreferred && !$1.isPreferred }
            return $0.refresh > $1.refresh
        }
        return out
    }
}

private struct TimingModesTable: View {
    let modes: [DisplayDetailView.TimingMode]

    var body: some View {
        Table(of: DisplayDetailView.TimingMode.self) {
            TableColumn("Resolution") { mode in
                Text("\(mode.width) × \(mode.height)").monospacedDigit()
            }
            TableColumn("Refresh") { mode in
                Text(String(format: mode.refresh < 30 ? "%.2f Hz" : "%.0f Hz",
                            mode.refresh))
                    .monospacedDigit()
            }
            TableColumn("Default") { mode in
                if mode.isPreferred {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(PSColor.active)
                } else {
                    Text("")
                }
            }
            .width(60)
        } rows: {
            ForEach(modes) { mode in
                TableRow(mode)
            }
        }
        .frame(minHeight: CGFloat(min(modes.count + 1, 10)) * 26)
    }
}
