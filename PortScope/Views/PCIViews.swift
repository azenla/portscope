//
//  PCIViews.swift
//  PortScope
//
//  Detail card for a PCIe node — host bridge, downstream bridge, or
//  endpoint.
//

import SwiftUI

struct PCIDeviceView: View {
    let node: PCINode
    let ancestors: [TBNode]
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        DetailContainer {
            BreadcrumbBar(ancestors: ancestors, onNavigate: onNavigate)
            Hero(symbol: node.kind.symbol,
                 title: node.title,
                 subtitle: node.subtitle?.isEmpty == false ? node.subtitle : nil,
                 status: heroStatus)

            PropertyList {
                PropertyRowSpec(forcing: "Role", roleLabel)
                PropertyRowSpec("PCI class",
                                node.classCode.map {
                                    pciClassLabel($0, node.subclassCode, node.progIF)
                                })
                PropertyRowSpec("Vendor", vendorLabel)
                PropertyRowSpec("Device",
                                node.deviceID.map { String(format: "0x%04X", $0) },
                                mono: true)
                PropertyRowSpec("Subsystem", subsystemLabel, mono: true)
                PropertyRowSpec("BDF", node.bdf, mono: true)
                PropertyRowSpec("Slot", node.slotName)
                PropertyRowSpec("Link", linkLabel)
                PropertyRowSpec("Link capability", linkCapabilityLabel)
                if node.isBuiltIn {
                    PropertyRowSpec(forcing: "Provenance", "Built-in")
                }
            }

            if !node.children.isEmpty {
                VStack(alignment: .leading, spacing: PSSpacing.m) {
                    SectionHeader("Downstream devices (\(node.children.count))")
                    VStack(spacing: 0) {
                        ForEach(node.children) { child in
                            if child.id != node.children.first?.id {
                                Rectangle()
                                    .fill(PSColor.divider.opacity(0.7))
                                    .frame(height: 0.5)
                            }
                            PCIChildRow(node: child)
                        }
                    }
                }
            }

            DisclosureCard("Developer details (raw IORegistry)",
                           icon: "wrench.and.screwdriver") {
                PropertyTableView(node: node.node)
            }
        }
    }

    private var heroStatus: PSStatus? {
        node.isBuiltIn ? .builtIn : .active
    }

    private var roleLabel: String {
        switch node.kind {
        case .rootBridge: return "Host bridge"
        case .bridge:     return "Bridge"
        case .endpoint:   return "Endpoint"
        }
    }

    private var vendorLabel: String? {
        guard let vendor = node.vendorID else { return nil }
        let vName = pciVendorName(vendor) ?? "Unknown"
        return "\(vName) (\(String(format: "0x%04X", vendor)))"
    }

    private var subsystemLabel: String? {
        guard let sub = node.subsystemVendorID, let dev = node.subsystemDeviceID else { return nil }
        return String(format: "0x%04X : 0x%04X", sub, dev)
    }

    private var linkLabel: String? {
        guard let speed = node.linkSpeed, let width = node.linkWidth else { return nil }
        return "\(pciLinkSpeedShortLabel(speed)) · ×\(width)"
    }

    private var linkCapabilityLabel: String? {
        guard let speed = node.maxLinkSpeed, let width = node.maxLinkWidth else { return nil }
        return "\(pciLinkSpeedShortLabel(speed)) · ×\(width)"
    }
}

private struct PCIChildRow: View {
    let node: PCINode

    var body: some View {
        HStack(spacing: PSSpacing.s + 4) {
            Image(systemName: node.kind.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).font(PSFont.body).lineLimit(1)
                if let s = node.subtitle, !s.isEmpty {
                    Text(s)
                        .font(PSFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let speed = node.linkSpeed, let width = node.linkWidth {
                Text("\(pciLinkSpeedShortLabel(speed)) ×\(width)")
                    .font(PSFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, PSSpacing.s)
    }
}
