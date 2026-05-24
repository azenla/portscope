//
//  StatusDot.swift
//  PortScope
//
//  6 pt right-edge dot for sidebar rows. Carries the "is this row alive?"
//  signal that used to live in coloured icons + buried subtitles. Reads at
//  a glance: green = active data path, yellow = sinking power, blue =
//  sourcing power, red = error, grey-secondary = idle. Nil → no dot.
//

import SwiftUI

struct StatusDot: View {
    let status: PSStatus?

    var body: some View {
        if let status {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .accessibilityLabel(status.label)
        }
    }
}
