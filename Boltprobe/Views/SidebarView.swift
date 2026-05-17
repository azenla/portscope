//
//  SidebarView.swift
//  Boltprobe
//
//  Two-tier navigation:
//    1. Thunderbolt Ports — minimal user view (physical ports → connected device).
//    2. Full Topology — the raw IOKit tree for power users.
//

import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: BoltprobeViewModel
    @State private var expanded: Set<TBNodeID> = []
    @State private var showFullTopology: Bool = false
    @State private var showDiagram: Bool = false

    var body: some View {
        let ports = TopologyMapper.physicalPorts(from: vm.snapshot)

        List(selection: $vm.selection) {
            Section("Thunderbolt Ports") {
                if ports.isEmpty {
                    Text(vm.isScanning ? "Scanning…" : "No Thunderbolt controllers")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(ports, id: \.id) { port in
                        PortBranch(port: port, expanded: $expanded)
                    }
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showFullTopology) {
                    ForEach(vm.snapshot.controllers, id: \.id) { node in
                        FullTopologyRow(node: node, depth: 0, expanded: $expanded)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.indent")
                            .foregroundStyle(.secondary)
                        Text("Full Topology").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Boltprobe")
        .frame(minWidth: 280)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDiagram = true
                } label: {
                    Label("Diagram", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Show topology diagram")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.rescan()
                } label: {
                    if vm.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help("Re-scan IORegistry")
                .disabled(vm.isScanning)
            }
        }
        .sheet(isPresented: $showDiagram) {
            DiagramView(snapshot: vm.snapshot)
        }
        .onAppear {
            // Auto-expand ports that have a device attached.
            for p in ports where p.connectedDevice != nil {
                expanded.insert(p.id)
            }
        }
    }
}

// MARK: - Simplified view branches

private struct PortBranch: View {
    let port: PhysicalPort
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        if let device = port.connectedDevice {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(port.id) },
                    set: { isOn in
                        if isOn { expanded.insert(port.id) }
                        else { expanded.remove(port.id) }
                    }
                )
            ) {
                DeviceBranch(device: device, expanded: $expanded)
            } label: {
                PortRow(port: port).tag(port.id)
            }
            .tag(port.id)
        } else {
            PortRow(port: port).tag(port.id)
        }
    }
}

private struct DeviceBranch: View {
    let device: ConnectedDevice
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        if device.daisyChained.isEmpty {
            DeviceRow(device: device).tag(device.id)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(device.id) },
                    set: { isOn in
                        if isOn { expanded.insert(device.id) }
                        else { expanded.remove(device.id) }
                    }
                )
            ) {
                ForEach(device.daisyChained, id: \.id) { child in
                    DeviceBranch(device: child, expanded: $expanded)
                }
            } label: {
                DeviceRow(device: device).tag(device.id)
            }
            .tag(device.id)
        }
    }
}

private struct PortRow: View {
    let port: PhysicalPort

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: port.connectedDevice == nil ? "bolt.horizontal.circle"
                                                          : "bolt.horizontal.circle.fill")
                .foregroundStyle(port.connectedDevice == nil ? Color.secondary : .blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Thunderbolt Port \(port.number)")
                Text(port.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: ConnectedDevice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.purple)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.title).lineLimit(1)
                if let s = device.subtitle, !s.isEmpty {
                    Text(s)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Full topology (raw tree)

private struct FullTopologyRow: View {
    let node: TBNode
    let depth: Int
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        let kids = visibleChildren(of: node)
        if kids.isEmpty {
            label.tag(node.id)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(node.id) || depth < 1 },
                    set: { isOn in
                        if isOn { expanded.insert(node.id) } else { expanded.remove(node.id) }
                    }
                )
            ) {
                ForEach(kids, id: \.id) { child in
                    FullTopologyRow(node: child, depth: depth + 1, expanded: $expanded)
                }
            } label: {
                label
            }
            .tag(node.id)
        }
    }

    /// Skip kernel-extension / framework wrappers (kind == .other) and promote
    /// their meaningful descendants up. Keeps the tree shaped around TB concepts
    /// rather than driver implementation details.
    private func visibleChildren(of node: TBNode) -> [TBNode] {
        var out: [TBNode] = []
        for c in node.children {
            if c.kind == .other {
                out.append(contentsOf: visibleChildren(of: c))
            } else {
                out.append(c)
            }
        }
        return out
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: node.kind.sfSymbol)
                .foregroundStyle(node.kind.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .lineLimit(1)
                    .font(.callout)
                if let s = node.subtitle, !s.isEmpty {
                    Text(s)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
