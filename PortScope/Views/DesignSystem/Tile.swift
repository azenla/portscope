//
//  Tile.swift
//  PortScope
//
//  The dashboard primitive — the exception, not the default. Used by the
//  router AdapterBreakdown where the user is genuinely scanning at-a-glance
//  ("4 lanes · 2 DP live · 4 USB · 1 PCIe"). Property bags belong in
//  `PropertyList`, not here.
//

import SwiftUI

struct Tile: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var subtitle: String? = nil
    var tint: Color = Color(NSColor.tertiaryLabelColor)
    var onTap: (() -> Void)? = nil

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: PSSpacing.xs + 2) {
                if let symbol {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12, weight: .regular))
                }
                Text(title)
                    .font(PSFont.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(PSFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(PSSpacing.tilePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PSColor.tile)
        .clipShape(RoundedRectangle(cornerRadius: PSRadii.tile, style: .continuous))

        if let onTap {
            Button(action: onTap) { inner }
                .buttonStyle(.plain)
        } else {
            inner
        }
    }
}

struct TileGrid<Content: View>: View {
    let minWidth: CGFloat
    @ViewBuilder let content: () -> Content

    init(minWidth: CGFloat = PSSpacing.tileMinWidth,
         @ViewBuilder content: @escaping () -> Content) {
        self.minWidth = minWidth
        self.content = content
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minWidth), spacing: PSSpacing.s, alignment: .topLeading)],
            alignment: .leading,
            spacing: PSSpacing.s
        ) {
            content()
        }
    }
}
