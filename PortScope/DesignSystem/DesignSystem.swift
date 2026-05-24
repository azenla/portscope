//
//  DesignSystem.swift
//  PortScope
//
//  Single source of truth for typography, spacing, radii, and colour.
//  Every view in `Views/` reads tokens from here so a change to the
//  visual language ripples through the whole app from one file.
//
//  Naming uses a short `PS…` prefix so call sites read crisply
//  (`PSFont.body`, `PSSpacing.l`) and the tokens are easy to grep.
//

import SwiftUI

// MARK: - Typography

/// SF Pro everywhere; SF Mono is reserved for MACs, BSD names, hex registry
/// IDs, and inside tabular cells where digits must align. Sizes follow
/// macOS 26 (Tahoe) / About-This-Mac conventions.
enum PSFont {
    static let display     = Font.system(size: 22, weight: .semibold)
    static let title       = Font.system(size: 17, weight: .semibold)
    static let subtitle    = Font.system(size: 13, weight: .semibold)
    static let body        = Font.system(size: 13)
    static let bodyEmph    = Font.system(size: 13, weight: .medium)
    static let label       = Font.system(size: 13)
    static let caption     = Font.system(size: 11)
    static let captionEmph = Font.system(size: 11, weight: .medium)
    static let mono        = Font.system(size: 12, design: .monospaced)
    static let monoSmall   = Font.system(size: 11, design: .monospaced)
}

/// View modifier for sentence-case section headers shared by the sidebar
/// and detail-pane. 11 pt Semibold, tracking +0.3, no uppercasing.
extension View {
    /// Sentence-case section header used by `SectionHeader` and the
    /// sidebar subgroup helper. Reads as a label, not a banner.
    func psSectionHeader() -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .tracking(0.3)
    }
}

// MARK: - Colour

/// Status colours are the only saturated swatches allowed on screen. Every
/// other foreground reads from `.primary`, `.secondary`, `.tertiary`, or
/// `.tint`. The window / sidebar / detail-pane backgrounds come from the
/// system materials — never overridden.
enum PSColor {
    // Chrome — never use as foreground.
    static let card    = Color(NSColor.controlBackgroundColor)
    static let tile    = Color(NSColor.underPageBackgroundColor)
    static let divider = Color(NSColor.separatorColor)

    // Status palette.
    static let active   = Color.green       // link up, tunnel up, charging in, drawing power
    static let warning  = Color.orange      // USB 2.0 on a USB 3 cable, undervolt, oddities
    static let error    = Color.red         // overcurrent, parse failure, link exceeds capacity
    static let powerIn  = Color.yellow      // Mac is sinking power (USB-PD / MagSafe / AC)
    static let powerOut = Color.blue        // Mac is sourcing power to attached devices
    static let info     = Color.indigo      // neutral informational, e.g. "Built-in"
}

// MARK: - Spacing

/// 4 pt base unit. Use `PSSpacing.s/m/l/xl` rather than literal padding so
/// the rhythm stays consistent across views.
enum PSSpacing {
    static let xs: CGFloat  = 4
    static let s:  CGFloat  = 8
    static let m:  CGFloat  = 12
    static let l:  CGFloat  = 16
    static let xl: CGFloat  = 24
    static let xxl: CGFloat = 32

    static let sidebarRow:     CGFloat = 28
    static let sidebarIndent:  CGFloat = 16

    static let detailHPadding: CGFloat = 24
    static let cardPadding:    CGFloat = 16
    static let tilePadding:    CGFloat = 12
    static let sectionGap:     CGFloat = 22
    static let tileMinWidth:   CGFloat = 160
}

// MARK: - Corner radii

enum PSRadii {
    static let card: CGFloat = 10
    static let tile: CGFloat = 6
    static let chip: CGFloat = 4
}
