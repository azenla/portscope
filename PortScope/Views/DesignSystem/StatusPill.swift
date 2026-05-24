//
//  StatusPill.swift
//  PortScope
//
//  One pill, one view. The single saturated status indicator a detail view
//  is allowed to carry — appears in the trailing edge of the hero. Subtitle
//  text picks up the rest of the story ("Active · 60 W in · DP").
//

import SwiftUI

/// Status values the pill knows how to render. The labels live with the
/// pill (not the caller) so the same value renders identically everywhere.
enum PSStatus: Hashable {
    case active                 // link up / tunnel up / connected
    case idle                   // adapter present but not carrying data
    case disabled               // "Port is inactive"
    case empty                  // no device, no telemetry — receptacle is empty
    case builtIn                // depth-0 router, internal device
    case warning(String)        // anomaly worth flagging
    case error(String)          // hard failure
    case powerIn(String)        // Mac is sinking power — "60 W"
    case powerOut(String)       // Mac is sourcing power — "4.5 W"
    case custom(String, Color)  // escape hatch for one-off labels

    var label: String {
        switch self {
        case .active:           return "Active"
        case .idle:             return "Idle"
        case .disabled:         return "Disabled"
        case .empty:            return "Empty"
        case .builtIn:          return "Built-in"
        case .warning(let s):   return s
        case .error(let s):     return s
        case .powerIn(let s):   return s
        case .powerOut(let s):  return s
        case .custom(let s, _): return s
        }
    }

    /// The saturated swatch carried by the pill. `idle` / `disabled` /
    /// `empty` are intentionally desaturated (system secondary / tertiary)
    /// so they don't compete with the active states for attention.
    var color: Color {
        switch self {
        case .active:           return PSColor.active
        case .idle:             return Color(NSColor.secondaryLabelColor)
        case .disabled, .empty: return Color(NSColor.tertiaryLabelColor)
        case .builtIn:          return PSColor.info
        case .warning:          return PSColor.warning
        case .error:            return PSColor.error
        case .powerIn:          return PSColor.powerIn
        case .powerOut:         return PSColor.powerOut
        case .custom(_, let c): return c
        }
    }
}

struct StatusPill: View {
    let status: PSStatus

    var body: some View {
        HStack(spacing: PSSpacing.xs + 2) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.label)
                .font(PSFont.captionEmph)
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, PSSpacing.s)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.15))
        .clipShape(Capsule())
        .accessibilityLabel(status.label)
    }
}
