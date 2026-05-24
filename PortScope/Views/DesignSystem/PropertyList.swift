//
//  PropertyList.swift
//  PortScope
//
//  Two-column LabeledContent rows — the workhorse for every property bag
//  in the app. Replaces the old `StatGrid` of icon+label+value tiles in
//  most places. Tile grids are reserved for genuine dashboards (the
//  router adapter breakdown); everything else is rows.
//
//  Key design rule: empty / nil / placeholder ("—", "Not reported") values
//  produce *no row at all*. `PropertyRow.spec` is failable, so a row is
//  simply skipped by the @resultBuilder compactMap when there's nothing
//  worth saying. The user sees presence, not absence.
//

import SwiftUI

// MARK: - Spec

/// One row in a `PropertyList`. Construction is failable: an empty / nil /
/// placeholder value produces `nil`, which the @resultBuilder filters out.
struct PropertyRowSpec: Hashable {
    let label: String
    let value: String
    let mono: Bool
    let secret: Bool
    let valueColor: Color?
    let onTap: TapAction?

    enum TapAction: Hashable {
        case navigate(TBNodeID)
    }

    /// Primary entry point. Returns `nil` when the value should be omitted.
    init?(_ label: String,
          _ value: String?,
          mono: Bool = false,
          secret: Bool = false,
          valueColor: Color? = nil,
          tap: TapAction? = nil) {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty,
              v != "—",
              v != "-",
              v != "Not reported",
              v.lowercased() != "unknown" else { return nil }
        self.label = label
        self.value = v
        self.mono = mono
        self.secret = secret
        self.valueColor = valueColor
        self.onTap = tap
    }

    /// Non-failable variant for callers that already know the row should
    /// render (e.g. mandatory state rows that say "Empty").
    init(forcing label: String,
         _ value: String,
         mono: Bool = false,
         secret: Bool = false,
         valueColor: Color? = nil,
         tap: TapAction? = nil) {
        self.label = label
        self.value = value
        self.mono = mono
        self.secret = secret
        self.valueColor = valueColor
        self.onTap = tap
    }
}

// MARK: - Builder

@resultBuilder
enum PropertyListBuilder {
    static func buildBlock(_ specs: [PropertyRowSpec]...) -> [PropertyRowSpec] {
        specs.flatMap { $0 }
    }
    static func buildExpression(_ spec: PropertyRowSpec?) -> [PropertyRowSpec] {
        spec.map { [$0] } ?? []
    }
    static func buildExpression(_ specs: [PropertyRowSpec]) -> [PropertyRowSpec] {
        specs
    }
    static func buildOptional(_ component: [PropertyRowSpec]?) -> [PropertyRowSpec] {
        component ?? []
    }
    static func buildEither(first component: [PropertyRowSpec]) -> [PropertyRowSpec] { component }
    static func buildEither(second component: [PropertyRowSpec]) -> [PropertyRowSpec] { component }
    static func buildArray(_ components: [[PropertyRowSpec]]) -> [PropertyRowSpec] {
        components.flatMap { $0 }
    }
}

// MARK: - Views

struct PropertyList: View {
    let rows: [PropertyRowSpec]

    /// Use a labeled `rows:` parameter so the unlabeled init is reserved
    /// for the @PropertyListBuilder closure form. Mixing the two unlabeled
    /// initialisers tripped trailing-closure resolution.
    init(rows: [PropertyRowSpec]) { self.rows = rows }

    init(@PropertyListBuilder _ build: () -> [PropertyRowSpec]) {
        self.rows = build()
    }

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, spec in
                    if idx > 0 {
                        Rectangle()
                            .fill(PSColor.divider.opacity(0.7))
                            .frame(height: 0.5)
                    }
                    PropertyRow(spec: spec)
                }
            }
        }
    }
}

private struct PropertyRow: View {
    let spec: PropertyRowSpec
    @State private var revealed = false
    var onNavigate: ((TBNodeID) -> Void)? = nil

    var body: some View {
        LabeledContent {
            valueView
        } label: {
            Text(spec.label)
                .font(PSFont.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var valueView: some View {
        HStack(spacing: PSSpacing.xs) {
            Text(displayValue)
                .font(spec.mono ? PSFont.mono : PSFont.body)
                .foregroundStyle(spec.valueColor ?? .primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            if spec.secret {
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(revealed ? "Hide value" : "Reveal value")
            }
        }
    }

    private var displayValue: String {
        guard spec.secret, !revealed else { return spec.value }
        return maskValue(spec.value)
    }

    private func maskValue(_ v: String) -> String {
        if v.hasPrefix("0x") {
            return "0x" + String(repeating: "\u{2022}", count: max(v.count - 2, 4))
        }
        return String(repeating: "\u{2022}", count: min(max(v.count, 4), 24))
    }
}
