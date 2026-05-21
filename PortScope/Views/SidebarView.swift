//
//  SidebarView.swift
//  PortScope
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
    @ObservedObject var vm: PortScopeViewModel
    @State private var expanded: Set<TBNodeID> = []
    /// IDs we've already seeded into `expanded` for first-render auto-open.
    /// Tracking this separately means a user collapse sticks — we never
    /// re-add an ID after it's been seen once.
    @State private var seeded: Set<TBNodeID> = []
    @State private var showDiagram: Bool = false
    /// Top-level sidebar sections that the user has collapsed. Each entry
    /// keys a section by its stable name; missing = expanded (the default).
    @State private var collapsedSections: Set<String> = []
    /// Persistent preference (Settings → Show Hardware Buses). When false
    /// the sidebar shows only the Physical Ports section. When true the
    /// raw Thunderbolt / USB / PCIe bus trees are surfaced too.
    @AppStorage(SidebarVisibility.showBusesKey) private var showBuses: Bool = false
    /// Persistent preference (Settings → Show All Devices). When false the
    /// sidebar omits Displays / Bluetooth / Internal Hardware. Independent
    /// of `showBuses` — both default off.
    @AppStorage(SidebarVisibility.showAllDevicesKey) private var showAllDevices: Bool = false

    var body: some View {
        let ports = TopologyMapper.physicalPorts(from: vm.snapshot)
        let hw = vm.snapshot.internalHardware

        List(selection: $vm.selection) {
            collapsibleSection("Physical Ports", icon: "powerplug.fill") {
                // MagSafe lives at the very top of Physical Ports when present
                // — it's a chassis receptacle just like the USB-C ports, even
                // though it only carries power.
                if let magsafe = hw.magsafe {
                    MagSafeRow(accessory: magsafe)
                        .tag(MagSafeSelector.id)
                }
                if ports.isEmpty && hw.magsafe == nil {
                    Text(vm.isScanning ? "Scanning…" : "No Thunderbolt controllers")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    PortsByConnector(ports: ports, expanded: $expanded)
                }
            }

            if showBuses {
                collapsibleSection("Thunderbolt", icon: "bolt.horizontal.circle") {
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

                collapsibleSection("USB", icon: "cable.connector") {
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

            if showAllDevices {
                displaysSection
                bluetoothSection
            }
            if showBuses {
                pcieSection
            }
            if showAllDevices {
                internalHardwareSection
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PortScope")
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

    @ViewBuilder
    private var displaysSection: some View {
        let displays = vm.snapshot.displays
        if !displays.displays.isEmpty {
            collapsibleSection("Displays", icon: "display") {
                ForEach(displays.displays) { display in
                    DisplaySidebarRow(display: display).tag(display.id)
                }
            }
        }
    }

    @ViewBuilder
    private var bluetoothSection: some View {
        let bt = vm.snapshot.bluetooth
        if bt.controller != nil || bt.totalDeviceCount > 0 {
            collapsibleSection("Bluetooth", icon: "dot.radiowaves.left.and.right") {
                if let _ = bt.controller {
                    BluetoothControllerRow(snapshot: bt)
                        .tag(BluetoothSelector.controllerID)
                }
                if !bt.connected.isEmpty {
                    BluetoothSubgroupHeader(title: "Connected (\(bt.connected.count))")
                    ForEach(bt.connected) { dev in
                        BluetoothDeviceRow(device: dev)
                            .tag(BluetoothSelector.id(for: dev))
                    }
                }
                if !bt.paired.isEmpty {
                    BluetoothSubgroupHeader(title: "Paired (\(bt.paired.count))")
                    ForEach(bt.paired) { dev in
                        BluetoothDeviceRow(device: dev)
                            .tag(BluetoothSelector.id(for: dev))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pcieSection: some View {
        let pcie = vm.snapshot.pcie
        if !pcie.roots.isEmpty {
            collapsibleSection("PCIe", icon: "square.stack.3d.up") {
                ForEach(pcie.roots) { root in
                    PCIBranch(node: root, expanded: $expanded)
                }
            }
        }
    }

    @ViewBuilder
    private var internalHardwareSection: some View {
        let hw = vm.snapshot.internalHardware
        // MagSafe moved to Physical Ports; this section covers buses +
        // battery + SoC coprocessors grouped thematically.
        let hasAny = hw.batteryManager != nil
            || !hw.i2cBuses.isEmpty
            || !hw.spiBuses.isEmpty
            || !hw.coprocessorGroups.isEmpty
        if hasAny {
            collapsibleSection("Internal Hardware", icon: "cpu") {
                if let bm = hw.batteryManager {
                    // The manager wraps the battery — surface the battery
                    // directly as the row, since the manager itself is
                    // uninteresting.
                    if let battery = bm.children.first(where: { $0.kind == .battery }) {
                        BatteryRow(node: battery)
                            .tag(battery.id)
                    } else {
                        BatteryRow(node: bm).tag(bm.id)
                    }
                }

                if !hw.i2cBuses.isEmpty || !hw.spiBuses.isEmpty {
                    coprocessorSubsection(title: "Buses", icon: "point.3.connected.trianglepath.dotted") {
                        ForEach(hw.i2cBuses, id: \.id) { bus in
                            FullTopologyRow(node: bus, depth: 0, expanded: $expanded)
                        }
                        ForEach(hw.spiBuses, id: \.id) { bus in
                            FullTopologyRow(node: bus, depth: 0, expanded: $expanded)
                        }
                    }
                }

                ForEach(hw.coprocessorGroups) { group in
                    coprocessorSubsection(title: group.category.title,
                                          icon: group.category.symbol) {
                        ForEach(group.coprocessors, id: \.id) { block in
                            FullTopologyRow(node: block, depth: 0, expanded: $expanded)
                        }
                    }
                }
            }
        }
    }

    /// Render a labelled subsection inside the Internal Hardware section.
    /// Stateless on collapse: these aren't expensive to render so we keep
    /// them always-open for now. Visual grouping cuts the formerly-flat
    /// list of 30+ coprocessors into bite-sized chunks.
    @ViewBuilder
    private func coprocessorSubsection<Content: View>(
        title: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.top, 4)
        content()
    }

    /// A sidebar `Section` whose header is a clickable chevron that
    /// hides/shows its body. Section name doubles as the collapse key, so
    /// state persists across rescans (the body recomputes from `vm.snapshot`
    /// every render but the header state lives on the view).
    @ViewBuilder
    private func collapsibleSection<Content: View>(
        _ name: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(name)
        Section {
            if !isCollapsed { content() }
        } header: {
            Button {
                if isCollapsed { collapsedSections.remove(name) }
                else { collapsedSections.insert(name) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(name)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

/// Render the physical ports list split into connector-family subsections
/// (USB-C, USB-A, …). Subsection headers only appear when more than one
/// family is present, so the common single-family case stays clean.
private struct PortsByConnector: View {
    let ports: [PhysicalPort]
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        let groups = grouped()
        ForEach(groups, id: \.title) { group in
            if groups.count > 1 {
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 4)
            }
            ForEach(group.ports, id: \.id) { port in
                PortBranch(port: port, expanded: $expanded)
            }
        }
    }

    private struct Group {
        let title: String
        let ports: [PhysicalPort]
    }

    private func grouped() -> [Group] {
        // MagSafe is rendered separately by `MagSafeRow` at the top of the
        // Physical Ports section, so omit it here to avoid duplicate rows.
        // (`TopologyMapper.physicalPorts` includes it so the CLI dumper and
        // any future unified view see a single port list.)
        let usbC = ports.filter { $0.connector == .usbC }
        let usbA = ports.filter { $0.connector == .usbA }
        let hdmi = ports.filter { $0.connector == .hdmi }
        let sd = ports.filter { $0.connector == .sdCard }
        let other = ports.filter {
            switch $0.connector {
            case .usbC, .usbA, .hdmi, .sdCard, .magsafe: return false
            case .other: return true
            }
        }
        var out: [Group] = []
        if !usbC.isEmpty { out.append(Group(title: "USB-C", ports: usbC)) }
        if !usbA.isEmpty { out.append(Group(title: "USB-A", ports: usbA)) }
        if !hdmi.isEmpty { out.append(Group(title: "HDMI", ports: hdmi)) }
        if !sd.isEmpty { out.append(Group(title: "SD Card", ports: sd)) }
        if !other.isEmpty { out.append(Group(title: "Expanded Ports", ports: other)) }
        return out
    }
}

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
                Text(port.cliTitle)
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

// MARK: - Internal Hardware rows

private struct MagSafeRow: View {
    let accessory: PortAccessoryInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "powerplug.fill")
                .foregroundStyle(accessory.connectionActive ? .green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("MagSafe 3 Port")
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        // When unplugged, lead with "Disconnected" plus the lifetime plug
        // count; when live, surface the negotiated wattage.
        if accessory.connectionActive {
            if let win = accessory.usbPD?.winning {
                return "Charging · \(win.powerLabel)"
            }
            return "Connected"
        }
        let plugs = accessory.plugEventCount
        return plugs == 0 ? "Idle" : "Idle · \(plugs) plug events"
    }
}

private struct BatteryRow: View {
    let node: TBNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(node.kind.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var symbol: String {
        let pct = node.properties["CurrentCapacity"]?.asUInt ?? 0
        let charging = node.properties["IsCharging"]?.asBool ?? false
        if charging { return "battery.100.bolt" }
        if pct >= 75 { return "battery.100" }
        if pct >= 50 { return "battery.75percent" }
        if pct >= 25 { return "battery.50percent" }
        if pct > 0 { return "battery.25percent" }
        return "battery.0percent"
    }

    private var subtitle: String {
        let pct = node.properties["CurrentCapacity"]?.asUInt ?? 0
        let charging = node.properties["IsCharging"]?.asBool ?? false
        let external = node.properties["ExternalConnected"]?.asBool ?? false
        var parts: [String] = ["\(pct)%"]
        if charging { parts.append("Charging") }
        else if external { parts.append("On AC") }
        else { parts.append("On battery") }
        return parts.joined(separator: " · ")
    }
}

/// Synthetic IDs for the MagSafe row in the Internal Hardware section. The
/// underlying `AppleHPMInterfaceType11` entry has its own real registry ID,
/// but routing the row through a synthetic ID lets `ContentView` dispatch to
/// the dedicated MagSafe detail view instead of the generic property table.
enum MagSafeSelector {
    private static let mask: UInt64 = 0xCAFE_F00D_0000_0001
    static let id = TBNodeID(raw: mask)

    static func isMagSafeID(_ id: TBNodeID) -> Bool { id.raw == mask }
}

// MARK: - Bluetooth rows

private struct BluetoothControllerRow: View {
    let snapshot: BluetoothSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(snapshot.controller?.isOn == true ? .blue : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bluetooth Controller")
                Text(subtitle)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        guard let c = snapshot.controller else { return "—" }
        var parts: [String] = []
        if c.isOn { parts.append("On") } else { parts.append("Off") }
        if !c.displayChipset.isEmpty && c.displayChipset != "Unknown" {
            parts.append(c.displayChipset)
        }
        return parts.joined(separator: " · ")
    }
}

private struct BluetoothDeviceRow: View {
    let device: BluetoothDevice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.category.symbol)
                .foregroundStyle(device.isConnected ? device.category.color : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                if let s = subtitle, !s.isEmpty {
                    Text(s)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if device.isConnected { parts.append("Connected") }
        if let m = device.minorType, !m.isEmpty { parts.append(m) }
        if let rssi = device.rssi { parts.append("\(rssi) dBm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct BluetoothSubgroupHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Display row

private struct DisplaySidebarRow: View {
    let display: DisplayInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: display.iconSymbol)
                .foregroundStyle(display.isConnected ? .blue : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.title).lineLimit(1)
                if let s = display.subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Idle").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - PCI branch

struct PCIBranch: View {
    let node: PCINode
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        if node.children.isEmpty {
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
                ForEach(node.children) { child in
                    PCIBranch(node: child, expanded: $expanded)
                }
            } label: {
                label
            }
            .tag(node.id)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind.symbol)
                .foregroundStyle(node.kind.color)
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
