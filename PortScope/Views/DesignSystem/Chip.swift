//
//  Chip.swift
//  PortScope
//
//  Inline small label. Used for transport names (CIO, USB3, DP), hop tags,
//  and ad-hoc tags scattered through the detail pane. Replaces the local
//  `Tag` and `TransportChip` definitions that grew bespoke styling.
//

import SwiftUI

struct Chip: View {
    let label: String
    var symbol: String? = nil
    var tint: Color = Color(NSColor.secondaryLabelColor)
    /// Saturated when true (filled background), muted when false (subtle background, secondary text).
    var emphasized: Bool = false
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: PSSpacing.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .medium))
            }
            Text(label)
                .font(monospaced ? PSFont.monoSmall : PSFont.captionEmph)
        }
        .foregroundStyle(emphasized ? tint : Color(NSColor.secondaryLabelColor))
        .padding(.horizontal, PSSpacing.s - 1)
        .padding(.vertical, 2)
        .background(
            (emphasized ? tint.opacity(0.18) : Color(NSColor.quaternaryLabelColor).opacity(0.45))
        )
        .clipShape(RoundedRectangle(cornerRadius: PSRadii.chip, style: .continuous))
    }
}

/// Loose flow of chips. Replaces the bespoke `FlowChips` / `FlowLayout`
/// pair used inside DetailView; same layout, exposed under the design-
/// system namespace so consumers don't reach into DetailView internals.
struct ChipFlow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        FlowLayout(spacing: PSSpacing.xs + 2) { content() }
    }
}
