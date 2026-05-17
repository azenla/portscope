//
//  SidebarView.swift
//  Boltprobe
//
//  Three-tier navigation:
//    1. Physical Ports — unified user view (TB / USB / Empty mode per port).
//    2. Thunderbolt — TB controllers and routers (raw IOKit tree, with
//       `.other` wrapper kexts unwrapped and their meaningful descendants
//       promoted up).
//    3. USB — USB host controllers, hubs, devices.
//

import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: BoltprobeViewModel
    @State private var expanded: Set<TBNodeID> = []
    /// IDs we've already seeded into `expanded` for first-render auto-open.
    /// Tracking this separately means a user collapse sticks — we never
    /// re-add an ID after it's been seen once.
    @State private var seeded: Set<TBNodeID> = []
    @State private var showDiagram: Bool = false

    var body: some View {
        let ports = TopologyMapper.physicalPorts(from: vm.snapshot)

        List(selection: $vm.selection) {
            Section("Physical Ports") {
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

            Section("Thunderbolt") {
                if vm.tbSnapshot.controllers.isEmpty {
                    Text("No Thunderbolt controllers")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(vm.tbSnapshot.controllers, id: \.id) { node in
                        ControllerBranch(node: node, expanded: $expanded)
                    }
                }
            }

            Section("USB") {
                if vm.usbSnapshot.controllers.isEmpty {
                    Text(vm.isScanning ? "Scanning…" : "No USB controllers")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(vm.usbSnapshot.controllers, id: \.id) { node in
                        USBBranch(node: node, depth: 0, expanded: $expanded)
                    }
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
        .task(id: vm.snapshot.capturedAt) {
            seedExpansion(ports: ports)
        }
    }

    /// Auto-open the rows the user almost certainly wants to see on first
    /// render, but only once per ID — so a manual collapse sticks.
    private func seedExpansion(ports: [PhysicalPort]) {
        var toOpen: [TBNodeID] = []
        for p in ports {
            let pid = PhysicalPortSelector.id(for: p)
            if p.connectedDevice != nil || !p.usbDeviceRoots.isEmpty {
                toOpen.append(pid)
            }
            // Top-level USB hubs get their immediate children visible.
            for root in p.usbDeviceRoots { toOpen.append(root.id) }
        }
        // TB controllers with a downstream router auto-open in the
        // Thunderbolt section.
        for ctrl in vm.tbSnapshot.controllers where controllerHasAttachedHost(ctrl) {
            toOpen.append(ctrl.id)
        }
        // USB host controllers in the USB section auto-open once.
        for ctrl in vm.usbSnapshot.controllers {
            toOpen.append(ctrl.id)
        }
        for id in toOpen where !seeded.contains(id) {
            expanded.insert(id)
            seeded.insert(id)
        }
    }

    private func controllerHasAttachedHost(_ node: TBNode) -> Bool {
        var stack = node.children
        while !stack.isEmpty {
            let n = stack.removeFirst()
            if n.kind == .switch, (n.properties["Depth"]?.asUInt ?? 0) > 0 {
                return true
            }
            stack.append(contentsOf: n.children)
        }
        return false
    }
}

// MARK: - Physical Ports section

private struct PortBranch: View {
    let port: PhysicalPort
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        let selectionID = PhysicalPortSelector.id(for: port)
        let device = port.connectedDevice
        let roots = port.usbDeviceRoots

        if device == nil && roots.isEmpty {
            PortRow(port: port).tag(selectionID)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(selectionID) },
                    set: { isOn in
                        if isOn { expanded.insert(selectionID) }
                        else { expanded.remove(selectionID) }
                    }
                )
            ) {
                if let device {
                    DeviceBranch(device: device, expanded: $expanded)
                }
                // Render the real USB bus hierarchy: top-level hubs become
                // disclosure rows that expand into their downstream devices,
                // matching what `ioreg -c IOUSBHostDevice` shows. Pass depth
                // 0 so the top-level hubs auto-expand to reveal what's
                // immediately under them; nested hubs stay collapsed.
                ForEach(roots, id: \.id) { dev in
                    USBBranch(node: dev, depth: 0, expanded: $expanded)
                }
            } label: {
                PortRow(port: port).tag(selectionID)
            }
            .tag(selectionID)
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
            Image(systemName: port.mode.symbol)
                .foregroundStyle(port.mode.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("USB-C Port \(port.number)")
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

// MARK: - Thunderbolt section (controllers expand to show full TB tree)

private struct ControllerBranch: View {
    let node: TBNode
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        // Skip `.other` wrapper kexts (DPConnectionManager, IPService, etc.)
        // and promote their meaningful descendants up — same recursion the
        // deeper rows use, so nothing in the IOKit tree is hidden.
        let kids = promotedChildren(of: node)
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(node.id) },
                set: { isOn in
                    if isOn { expanded.insert(node.id) } else { expanded.remove(node.id) }
                }
            )
        ) {
            ForEach(kids, id: \.id) { child in
                FullTopologyRow(node: child, depth: 1, expanded: $expanded)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.kind.sfSymbol)
                    .foregroundStyle(node.kind.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title).lineLimit(1).font(.callout)
                    Text(enrichedSubtitle).font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .tag(node.id)
    }

    /// True when a downstream router with depth > 0 lives under this controller.
    private var isAttachedHost: Bool {
        return connectedDeviceTitle != nil
    }

    /// Pull a meaningful subtitle from the tree: the name of the external device
    /// downstream, or "No external device" if the controller is idle. Falls
    /// back to the formatter-generated subtitle when nothing useful is found.
    private var enrichedSubtitle: String {
        if let dev = connectedDeviceTitle {
            return "Connected · \(dev)"
        }
        return "No external device"
    }

    /// Search the controller's subtree for the first external router (depth > 0).
    private var connectedDeviceTitle: String? {
        var stack = node.children
        while !stack.isEmpty {
            let n = stack.removeFirst()
            if n.kind == .switch, (n.properties["Depth"]?.asUInt ?? 0) > 0 {
                let vendor = n.properties["Device Vendor Name"]?.asString
                let model = n.properties["Device Model Name"]?.asString
                if let v = vendor, let m = model { return "\(v) \(m)" }
                if let m = model { return m }
                return n.title
            }
            stack.append(contentsOf: n.children)
        }
        return nil
    }
}

// MARK: - USB section

private struct USBBranch: View {
    let node: TBNode
    let depth: Int
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        // USB host controllers wrap each port in an `.other` kext (e.g.
        // `AppleUSB20XHCIARMPort`) whose child is the real `IOUSBHostDevice`.
        // A flat filter would drop the wrapper *and* the device with it —
        // recurse through wrappers and promote real USB nodes up. Interfaces
        // are hidden here and shown only in the device's detail view.
        let kids = promotedUSBChildren(of: node)
        if kids.isEmpty {
            label.tag(node.id)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(node.id) },
                    set: { isOn in
                        if isOn { expanded.insert(node.id) } else { expanded.remove(node.id) }
                    }
                )
            ) {
                ForEach(kids, id: \.id) { child in
                    USBBranch(node: child, depth: depth + 1, expanded: $expanded)
                }
            } label: {
                label
            }
            .tag(node.id)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: node.kind.sfSymbol)
                .foregroundStyle(node.kind.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).lineLimit(1).font(.callout)
                if let s = node.subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Thunderbolt tree row

/// Walk a node's children, dropping `.other` wrapper kexts and promoting their
/// meaningful descendants up. Shared by `ControllerBranch` and `FullTopologyRow`
/// so a port hidden under one IOService wrapper is still visible in the tree.
private func promotedChildren(of node: TBNode) -> [TBNode] {
    var out: [TBNode] = []
    for c in node.children {
        if c.kind == .other {
            out.append(contentsOf: promotedChildren(of: c))
        } else {
            out.append(c)
        }
    }
    return out
}

/// Same recursion as `promotedChildren` but also hides USB interfaces — they
/// don't carry their own subtree worth navigating and the device detail view
/// surfaces them in a dedicated section.
private func promotedUSBChildren(of node: TBNode) -> [TBNode] {
    var out: [TBNode] = []
    for c in node.children {
        if c.kind == .other {
            out.append(contentsOf: promotedUSBChildren(of: c))
        } else if c.kind != .usbInterface {
            out.append(c)
        }
    }
    return out
}

private struct FullTopologyRow: View {
    let node: TBNode
    let depth: Int
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        let kids = promotedChildren(of: node)
        if kids.isEmpty {
            label.tag(node.id)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(node.id) },
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
