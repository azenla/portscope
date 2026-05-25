//
//  PCIViews.swift
//  PortScope
//
//  Detail card for a PCIe node — host bridge, downstream bridge, or
//  endpoint. Pulls vendor / class info out of the PCINode model and falls
//  back to the standard Developer-details disclosure for everything else.
//

import SwiftUI

struct PCIDeviceView: View {
    let node: PCINode
    let ancestors: [TBNode]
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BreadcrumbBar(ancestors: ancestors, onNavigate: onNavigate)
                PCIHero(node: node)

                StatGrid(stats: statRows())

                if !node.children.isEmpty {
                    SectionCard(title: "Downstream Devices (\(node.children.count))",
                                symbol: "rectangle.connected.to.line.below") {
                        VStack(spacing: 0) {
                            ForEach(node.children) { child in
                                ChildRow(node: child)
                                if node.children.last?.id != child.id { Divider() }
                            }
                        }
                    }
                }

                DeveloperDisclosureCard(node: node.node)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private func statRows() -> [Stat] {
        var stats: [Stat] = [
            Stat(label: "Role",
                 value: roleLabel,
                 symbol: node.kind.symbol),
        ]
        if let cls = node.classCode {
            stats.append(Stat(label: "PCI Class",
                              value: pciClassLabel(cls, node.subclassCode, node.progIF),
                              symbol: "tag"))
        }
        if let vendor = node.vendorID {
            let vName = pciVendorName(vendor) ?? "Unknown"
            stats.append(Stat(label: "Vendor",
                              value: "\(vName) (\(String(format: "0x%04X", vendor)))",
                              symbol: "building.2"))
        }
        if let device = node.deviceID {
            stats.append(Stat(label: "Device",
                              value: String(format: "0x%04X", device),
                              symbol: "shippingbox"))
        }
        if let sub = node.subsystemVendorID, let dev = node.subsystemDeviceID {
            stats.append(Stat(label: "Subsystem",
                              value: String(format: "0x%04X : 0x%04X", sub, dev),
                              symbol: "rectangle.dashed"))
        }
        if let bdf = node.bdf {
            stats.append(Stat(label: "BDF",
                              value: bdf,
                              symbol: "barcode"))
        }
        if let slot = node.slotName {
            stats.append(Stat(label: "Slot",
                              value: slot,
                              symbol: "tray"))
        }
        if let speed = node.linkSpeed, let width = node.linkWidth {
            stats.append(Stat(label: "Link",
                              value: "\(pciLinkSpeedShortLabel(speed)) ×\(width)",
                              symbol: "antenna.radiowaves.left.and.right"))
        }
        if let speed = node.maxLinkSpeed, let width = node.maxLinkWidth {
            stats.append(Stat(label: "Link Capability",
                              value: "\(pciLinkSpeedShortLabel(speed)) ×\(width)",
                              symbol: "speedometer"))
        }
        // Link efficiency — negotiated vs max throughput, expressed as a
        // percentage. Directly answers "is my NVMe / eGPU running at full
        // speed?" — the most-asked PCIe question, and one the user would
        // otherwise have to compute by hand from the two link rows above.
        if let curS = node.linkSpeed, let curW = node.linkWidth,
           let maxS = node.maxLinkSpeed, let maxW = node.maxLinkWidth,
           maxS > 0, maxW > 0 {
            let curThroughput = Double(curS) * Double(curW)
            let maxThroughput = Double(maxS) * Double(maxW)
            let pct = Int((curThroughput / maxThroughput * 100).rounded())
            stats.append(Stat(label: "Link Efficiency",
                              value: pct >= 100 ? "100% (at capability)" : "\(pct)% of capability",
                              symbol: "chart.bar"))
        }
        if node.isBuiltIn {
            stats.append(Stat(label: "Provenance",
                              value: "Built-in",
                              symbol: "checkmark.shield"))
        }
        return stats
    }

    private var roleLabel: String {
        switch node.kind {
        case .rootBridge: return "Host Bridge"
        case .bridge:     return "Bridge"
        case .endpoint:   return "Endpoint"
        }
    }

    private struct ChildRow: View {
        let node: PCINode

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: node.kind.symbol)
                    .foregroundStyle(node.kind.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.callout)
                    if let s = node.subtitle, !s.isEmpty {
                        Text(s).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let speed = node.linkSpeed, let width = node.linkWidth {
                    Text("\(pciLinkSpeedShortLabel(speed)) ×\(width)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
        }
    }
}

private struct PCIHero: View {
    let node: PCINode

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(node.kind.color.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: node.kind.symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(node.kind.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title).font(.title2).bold().textSelection(.enabled)
                if let s = node.subtitle, !s.isEmpty {
                    Text(s).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
