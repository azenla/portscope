//
//  SectionHeader.swift
//  PortScope
//
//  Sentence-case 11 pt Semibold +0.3 tracking. The single header style
//  used everywhere — sidebar subgroups, detail-pane sections, disclosure
//  card titles. Replaces the previous mix of ALL-CAPS tertiary captions
//  and `.headline` banners.
//

import SwiftUI

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    init(_ title: String, trailing: AnyView? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .psSectionHeader()
            if let trailing {
                Spacer()
                trailing
            }
        }
    }
}
