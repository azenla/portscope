//
//  DisclosureCard.swift
//  PortScope
//
//  Collapsible card with a sentence-case header and a rotating chevron.
//  The Developer Details disclosure that every detail view ends with uses
//  this, and so does the Timing Modes disclosure on the display page.
//  Default collapsed; consumers can pass `initiallyOpen: true` for cases
//  where the content is the point (e.g. an empty-state explainer).
//

import SwiftUI

struct DisclosureCard<Content: View>: View {
    let title: String
    let icon: String?
    let initiallyOpen: Bool
    @ViewBuilder let content: () -> Content

    @State private var open: Bool

    init(_ title: String,
         icon: String? = nil,
         initiallyOpen: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.initiallyOpen = initiallyOpen
        self.content = content
        self._open = State(initialValue: initiallyOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: PSSpacing.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10, alignment: .center)
                    if let icon {
                        Image(systemName: icon)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                            .frame(width: 16)
                    }
                    Text(title)
                        .psSectionHeader()
                    Spacer()
                }
                .padding(.vertical, PSSpacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                content()
                    .padding(.top, PSSpacing.xs)
                    .padding(.bottom, PSSpacing.s)
            }
        }
    }
}
