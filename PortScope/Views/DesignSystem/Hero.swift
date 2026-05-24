//
//  Hero.swift
//  PortScope
//
//  Unified detail-pane header. One implementation, used by every detail
//  view in the app — physical port, TB router, USB device, Bluetooth
//  controller, PCIe endpoint, built-in AC / Ethernet / HDMI / SD page.
//
//  No coloured circle behind the icon. No shadow. The visual hierarchy
//  is carried by typography: a 28 pt monochrome symbol in `.tint`, a
//  22 pt Semibold title, an optional secondary subtitle, and a single
//  optional StatusPill aligned to the trailing edge.
//

import SwiftUI

struct Hero: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let status: PSStatus?
    /// Optional trailing-edge ornament. The AC power page uses this for the
    /// live wattage display; the Ethernet page uses it for the negotiated
    /// link rate. Most views leave it nil and let the StatusPill do the work.
    let trailing: AnyView?

    init(symbol: String,
         title: String,
         subtitle: String? = nil,
         status: PSStatus? = nil,
         trailing: AnyView? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: PSSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PSFont.display)
                    .textSelection(.enabled)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(PSFont.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: PSSpacing.m)
            if let trailing {
                trailing
            } else if let status {
                StatusPill(status: status)
            }
        }
        .padding(.bottom, PSSpacing.l)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PSColor.divider.opacity(0.6))
                .frame(height: 0.5)
        }
    }
}
