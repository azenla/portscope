//
//  DetailContainer.swift
//  PortScope
//
//  Shared ScrollView wrapper for every detail page. One place for the
//  padding rhythm, the minimum width, and the section gap so every page
//  reads as part of the same app.
//

import SwiftUI

struct DetailContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PSSpacing.sectionGap) {
                content()
            }
            .padding(PSSpacing.detailHPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }
}

/// Empty-state phrasing used at the bottom of cards / sections when there's
/// no content. Sits as `.tertiary` prose, no card frame — design-research
/// §4.6: "render nothing rather than empty cards".
struct EmptyStateNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(PSFont.body)
            .foregroundStyle(.tertiary)
    }
}
