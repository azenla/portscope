//
//  BreadcrumbBar.swift
//  PortScope
//
//  Clickable ancestor chain shown above the detail header. Each chip
//  jumps to that ancestor in one click — the way back out of a deep
//  selection (USB interface, lane adapter, downstream bridge) without
//  hunting through the sidebar.
//

import SwiftUI

struct BreadcrumbBar: View {
    /// Oldest-first ancestor chain. `.other` kext-wrapper nodes should
    /// already be filtered upstream (see `PortScopeViewModel.ancestors`).
    let ancestors: [TBNode]
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        if ancestors.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(ancestors.enumerated()), id: \.offset) { idx, node in
                        chip(for: node)
                        if idx < ancestors.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(for node: TBNode) -> some View {
        Button {
            onNavigate(node.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: node.kind.sfSymbol)
                    .font(.system(size: 10))
                    .foregroundStyle(node.kind.accentColor)
                Text(node.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(node.title)
    }
}
