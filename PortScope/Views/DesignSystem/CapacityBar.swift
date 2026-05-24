//
//  CapacityBar.swift
//  PortScope
//
//  Disk-Utility-style segmented capacity / bandwidth bar. The numbers ride
//  on the same line as the title; the bar itself is a single 10 pt strip
//  with one filled segment for the actively reserved share and an outlined
//  segment for the planned/max share. Anything over capacity is hatched
//  red on the right edge.
//
//  Used by:
//   - TB lane adapter (link bandwidth)
//   - PhysicalPortDetailView (uplink to host)
//   - AC power detail (input wattage vs PSU rating)
//   - Bluetooth device (battery percent)
//

import SwiftUI

/// Generic Disk-Utility-style capacity bar.
///
/// `value` is the *primary* fill (the saturated share). `secondaryValue`
/// (if non-nil) is the planned / max-allocated overlay drawn behind the
/// primary fill in a lighter tint. `capacity` is the denominator.
struct CapacityBar: View {
    /// Title above the bar — short, sentence case ("Bandwidth", "Charge").
    let title: String?
    let value: Double
    let secondaryValue: Double?
    let capacity: Double
    /// Display labels. Built by the caller so units stay caller-specific
    /// (Gb/s / W / %). `headlineValue` shows on the right of the title row;
    /// `legend` is the small grey line below the bar.
    let headlineValue: String?
    let legend: String?
    var tint: Color = PSColor.active

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || headlineValue != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(PSFont.subtitle)
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    if let headlineValue {
                        Text(headlineValue)
                            .font(PSFont.bodyEmph.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
            }
            GeometryReader { geo in
                let primaryFrac = fraction(value, capacity)
                let secondaryFrac = secondaryValue.map { fraction($0, capacity) } ?? 0
                let overage = capacity > 0 && (secondaryValue ?? value) > capacity
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(NSColor.quaternaryLabelColor).opacity(0.35))
                    if secondaryFrac > primaryFrac {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tint.opacity(0.30))
                            .frame(width: geo.size.width * secondaryFrac)
                    }
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint)
                        .frame(width: geo.size.width * primaryFrac)
                    if overage {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(PSColor.error, lineWidth: 1)
                    }
                }
            }
            .frame(height: 10)
            if let legend {
                Text(legend)
                    .font(PSFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func fraction(_ v: Double, _ cap: Double) -> Double {
        guard cap > 0 else { return 0 }
        return min(max(v / cap, 0), 1)
    }
}
