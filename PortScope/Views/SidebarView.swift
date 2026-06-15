//
//  SidebarView.swift
//  PortScope
//
//  Three-tier navigation:
//    1. Physical Device — unified user view organised into subcategories:
//       Power (Internal Battery, MagSafe, AC PSU), then USB-C, USB-A, HDMI,
//       SD Card, Ethernet, etc. Every connector kind is rendered under its
//       own labelled subgroup so the chassis layout is legible at a glance.
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
    /// Opens secondary windows (topology / sensors) — replaces the
    /// previous sheet bindings so each opens as a real macOS window
    /// the user can move / resize / minimize independently.
    @Environment(\.openWindow) private var openWindow
    /// Top-level sidebar sections that the user has collapsed. Each entry
    /// keys a section by its stable name; missing = expanded (the default).
    @State private var collapsedSections: Set<String> = []
    /// Inline subgroups (POWER / USB-C / Buses / Connected …) that the
    /// user has collapsed. Keyed by a namespaced string (e.g. "physical:Power",
    /// "ih:Buses", "bt:Connected") to keep top-level and subgroup names from
    /// colliding even if they happen to match.
    @State private var collapsedSubgroups: Set<String> = []
    /// Persistent preference (Settings → Show Hardware Buses). Default ON
    /// — these are the raw IOKit-derived hierarchies most users actually
    /// want when they launch a hardware-inspector. Toggle off to focus on
    /// the high-level Physical Ports view.
    @AppStorage(SidebarVisibility.showBusesKey) private var showBuses: Bool = true
    /// Persistent preference (Settings → Show Intermediate USB Hubs). When
    /// off (the default) USB hub nodes are flattened away so leaf devices
    /// sit directly under the port — useful for cascaded dock internals
    /// where every branch has 3–4 generic "USB2.0 Hub" rows between the
    /// port and the actual device. Flip on to surface the raw hub chain
    /// AND the "Thunderbolt PCIe Slot N" root bridge (with its whole
    /// bridge tree) on each TB-capable port; with the toggle off only
    /// leaf PCIe endpoints (NVMe / eGPU / etc.) appear, with the
    /// bridges flattened away the same way USB hubs are.
    @AppStorage(SidebarVisibility.showIntermediateHubsKey) private var showIntermediateHubs: Bool = false
    /// Persistent preference (Settings → Show Built-in Devices). Default
    /// ON — internal battery and built-in display are part of the
    /// chassis the user is looking at and belong in the default view.
    /// Toggle off to focus the Physical Device section on receptacles
    /// you can plug into.
    @AppStorage(SidebarVisibility.showBuiltinDevicesKey) private var showBuiltinDevices: Bool = true

    var body: some View {
        let ports = TopologyMapper.physicalPorts(from: vm.snapshot)
        let hw = vm.snapshot.internalHardware
        // `AppleSmartBatteryManager` and `AppleSmartBattery` both show up on
        // desktops too — the kernel uses the smart-battery service as a
        // power-telemetry endpoint for `PowerTelemetryData` even when no
        // pack is present. Gate on `BatteryInstalled` so the Mac mini /
        // iMac / Studio / Pro don't grow a phantom 0% battery row in the
        // Power subgroup.
        let batteryNode: TBNode? = {
            guard showBuiltinDevices,
                  let battery = hw.batteryManager?.children
                    .first(where: { $0.kind == .battery }),
                  battery.properties["BatteryInstalled"]?.asBool == true
            else { return nil }
            return battery
        }()
        // Each Physical Device subgroup (Power / USB-C / USB-A / HDMI / …)
        // is its own Section, so SwiftUI's `List` can manage cell identity
        // cleanly across power-poll refreshes (a flat sequence of buttons +
        // rows used to leak text from one row onto the next when the list
        // re-rendered). With subgroup Sections doing the visual grouping, a
        // top-level "Physical Device" wrapper isn't needed — and nesting
        // Section inside Section in a sidebar List doesn't render the inner
        // headers anyway.
        // Map from a TB function-adapter port's ID to the USB device roots
        // tunneled through it. Lets the Thunderbolt tree show the actual USB
        // devices nested under the "USB Adapter" port that's providing the
        // tunnel, rather than forcing the user to cross-reference the USB
        // section. Built once per render from `ports`.
        let tbProvidedUSB = tbProvidedUSBMap(ports: ports)
        // Map from a `PhysicalPortSelector` ID to the TB-tunneled PCIe
        // tree behind that port. The mapping uses the registry-
        // allocation-order pairing between TB controllers and
        // "Thunderbolt PCIe Slot N" root bridges (see
        // `tbControllerPCIeSlotMap`).
        //
        // Two display modes, parallel to how USB hubs are handled:
        //
        //   - `showIntermediateHubs == true` (Show Intermediate USB
        //     Hubs is on): surface the **PCIe Slot N root bridge**
        //     itself, with its full bridge subtree underneath. Mirrors
        //     the raw hub-chain view: the user sees every kernel
        //     artefact in the path. Empty slots still appear so the
        //     PCIe lane allocated to this TB controller is visible.
        //   - `showIntermediateHubs == false` (default): flatten the
        //     bridge tree the same way USB hubs are flattened, leaving
        //     only the leaf `.endpoint` devices (NVMe / eGPU / capture
        //     card). Idle slots with no endpoints are hidden so they
        //     don't clutter the default view.
        //
        // On most Apple Silicon docks today this map is empty in the
        // default view — docks expose storage over USB, not real PCIe.
        let tbPCIeEndpointsByPort: [TBNodeID: [PCINode]] = {
            let slots = tbControllerPCIeSlotMap(controllers: vm.tbSnapshot.controllers,
                                                pcieRoots: vm.snapshot.pcie.roots)
            var out: [TBNodeID: [PCINode]] = [:]
            for p in ports {
                guard let slot = slots[p.controller.id] else { continue }
                let nodes: [PCINode]
                if showIntermediateHubs {
                    // Show the full bridge subtree rooted at the PCIe
                    // slot. Always include the slot row, even when no
                    // endpoint is tunneled — the empty bridge is the
                    // kernel's view of "this is the PCIe lane allocated
                    // to this TB controller."
                    nodes = [slot]
                } else {
                    // Flat endpoints only; hide idle slots.
                    let endpoints = pcieEndpointDescendants(of: slot)
                    guard !endpoints.isEmpty else { continue }
                    nodes = endpoints
                }
                out[PhysicalPortSelector.id(for: p)] = nodes
            }
            return out
        }()

        List(selection: $vm.selection) {
            physicalDeviceContent(ports: ports,
                                  hw: hw,
                                  batteryNode: batteryNode,
                                  flattenHubs: !showIntermediateHubs,
                                  pcieByPortID: tbPCIeEndpointsByPort)

            if showBuses {
                collapsibleSection("Thunderbolt", icon: "bolt.horizontal.circle") {
                    if vm.tbSnapshot.controllers.isEmpty {
                        Text("No Thunderbolt controllers")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(vm.tbSnapshot.controllers, id: \.id) { node in
                            ControllerBranch(node: node,
                                             expanded: $expanded,
                                             flattenHubs: !showIntermediateHubs,
                                             providedUSB: tbProvidedUSB)
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
                            USBBranch(node: node,
                                      depth: 0,
                                      expanded: $expanded,
                                      flattenHubs: !showIntermediateHubs)
                        }
                    }
                }
            }

            displaysSection
            if showBuses {
                pcieSection
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PortScope")
        .frame(minWidth: 280)
        .toolbar {
            // View-state controls (expand/collapse all + rescan) share a
            // single Liquid Glass grouping so they read as one related
            // cluster, with the More menu separated into its own group by a
            // fixed spacer. Operates on the sidebar's expansion state
            // directly so the user can blow open every TB / USB tree at
            // once or collapse them back to the section headers.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if expanded.isEmpty {
                        expanded = collectAllExpandableIDs(ports: ports)
                    } else {
                        expanded.removeAll()
                    }
                } label: {
                    Label(expanded.isEmpty ? "Expand All" : "Collapse All",
                          systemImage: expanded.isEmpty
                            ? "rectangle.expand.vertical"
                            : "rectangle.compress.vertical")
                }
                .help(expanded.isEmpty ? "Expand every disclosure row" : "Collapse every disclosure row")

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

            // Fixed spacer splits the view-state cluster from the More
            // menu into separate Liquid Glass groupings. Gated because
            // ToolbarSpacer is macOS 26+; on earlier systems the items
            // just sit adjacent (the ToolbarItemGroup still clusters the
            // expand/refresh pair).
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            // Triple-dot menu for additional panels. Topology lives here
            // now; future panels (bandwidth heatmap, power timeline, hop-
            // table inspector, etc.) get added to the same menu so the
            // main toolbar stays uncluttered. In a toolbar the Menu picks
            // up the system glass-button treatment automatically, so no
            // explicit menu style is needed.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu {
                        Button {
                            openWindow(id: PortScopeWindowID.simplifiedTopology)
                        } label: {
                            Label("Simplified",
                                  systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        Button {
                            openWindow(id: PortScopeWindowID.detailedTopology)
                        } label: {
                            Label("Detailed",
                                  systemImage: "circle.hexagongrid.circle")
                        }
                    } label: {
                        Label("Thunderbolt Topology",
                              systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    Button {
                        openWindow(id: PortScopeWindowID.hardwareSensors)
                    } label: {
                        Label("Hardware Sensors",
                              systemImage: "thermometer.medium")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .task(id: vm.snapshot.capturedAt) {
            seedExpansion(ports: ports)
        }
    }

    /// Content of the Physical Device section. Pulled out so the section
    /// header can be conditionally wrapped (top-level toggle gating).
    @ViewBuilder
    private func physicalDeviceContent(ports: [PhysicalPort],
                                       hw: InternalHardwareSnapshot,
                                       batteryNode: TBNode?,
                                       flattenHubs: Bool,
                                       pcieByPortID: [TBNodeID: [PCINode]]) -> some View {
        if ports.isEmpty && hw.magsafe == nil && batteryNode == nil {
            Text(vm.isScanning ? "Scanning…" : "No physical ports detected")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            PortsByConnector(ports: ports,
                             battery: batteryNode,
                             magsafe: hw.magsafe,
                             allDisplays: vm.snapshot.displays.displays,
                             expanded: $expanded,
                             collapsedSubgroups: $collapsedSubgroups,
                             flattenHubs: flattenHubs,
                             pcieByPortID: pcieByPortID)
        }
    }

    /// Walk every tree the sidebar can render and collect each disclosure
    /// row's id. Used by the toolbar Expand-All action so the user can
    /// blow open every TB / USB / PCIe / coprocessor subtree in one
    /// click. Physical-port synthetic ids and TB device ids are included
    /// alongside the IORegistry-backed ones; collapse-all just clears
    /// the expansion set, no enumeration needed.
    private func collectAllExpandableIDs(ports: [PhysicalPort]) -> Set<TBNodeID> {
        var out: Set<TBNodeID> = []
        for p in ports {
            out.insert(PhysicalPortSelector.id(for: p))
            if let dev = p.connectedDevice {
                walkConnected(dev, into: &out)
            }
            for root in p.usbDeviceRoots { walkNode(root, into: &out) }
        }
        for ctrl in vm.tbSnapshot.controllers { walkNode(ctrl, into: &out) }
        for ctrl in vm.usbSnapshot.controllers { walkNode(ctrl, into: &out) }
        for root in vm.snapshot.pcie.roots { walkPCI(root, into: &out) }
        if let bm = vm.snapshot.internalHardware.batteryManager { walkNode(bm, into: &out) }
        return out
    }

    private func walkNode(_ node: TBNode, into set: inout Set<TBNodeID>) {
        set.insert(node.id)
        for c in node.children { walkNode(c, into: &set) }
    }

    private func walkPCI(_ node: PCINode, into set: inout Set<TBNodeID>) {
        set.insert(node.id)
        for c in node.children { walkPCI(c, into: &set) }
    }

    private func walkConnected(_ device: ConnectedDevice, into set: inout Set<TBNodeID>) {
        set.insert(device.id)
        for c in device.daisyChained { walkConnected(c, into: &set) }
    }

    /// Auto-open the rows the user almost certainly wants to see on first
    /// render, but only once per ID — so a manual collapse sticks.
    private func seedExpansion(ports: [PhysicalPort]) {
        var toOpen: [TBNodeID] = []
        let allDisplays = vm.snapshot.displays.displays
        for p in ports {
            let pid = PhysicalPortSelector.id(for: p)
            let outputs = displayOutputsAttributed(to: p,
                                                   allPorts: ports,
                                                   allDisplays: allDisplays)
            if p.connectedDevice != nil
                || !p.usbDeviceRoots.isEmpty
                || !outputs.isEmpty {
                toOpen.append(pid)
            }
            // When a TB device hosts USB endpoints or DP/HDMI outputs (the
            // common dock case), the device row is the disclosure that
            // contains those branches — auto-open it so the user sees
            // what's behind the dock on first render. Daisy-chained
            // sub-devices stay collapsed.
            if let device = p.connectedDevice,
               (!p.usbDeviceRoots.isEmpty || !outputs.isEmpty) {
                toOpen.append(device.id)
            }
            // Top-level USB hubs get their immediate children visible.
            for root in p.usbDeviceRoots { toOpen.append(root.id) }
            // DP/HDMI adapter rows auto-open so the display is visible
            // without an extra click.
            for output in outputs {
                if let id = output.adapter?.id { toOpen.append(id) }
            }
        }
        // TB controllers with a downstream router auto-open in the
        // Thunderbolt section.
        for ctrl in vm.tbSnapshot.controllers where controllerHasAttachedHost(ctrl) {
            toOpen.append(ctrl.id)
            // Also auto-open the Mac Host Router and the active host-side
            // USB Adapter port — that's where the TB-tunneled USB devices
            // get grafted in, and leaving the chain collapsed would hide
            // the new nested USB tree on first render.
            if let rootSwitch = findRootSwitchInController(ctrl) {
                toOpen.append(rootSwitch.id)
                for adapter in activeHostUSBAdapters(under: ctrl) {
                    toOpen.append(adapter.id)
                }
            }
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

    /// A sidebar `Section` whose header is a clickable chevron that
    /// hides/shows its body. The chevron rotates smoothly between collapsed
    /// (0°) and expanded (90°) so it matches macOS's native sidebar
    /// disclosure idiom. Section name doubles as the collapse key, so state
    /// persists across rescans (the body recomputes from `vm.snapshot` every
    /// render but the header state lives on the view).
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
                // No `withAnimation` here: animating row inserts/removes
                // inside a SwiftUI sidebar `List` causes ghost frames where
                // text from one row paints on top of another. The chevron
                // has its own rotation animation, so the affordance still
                // feels live without the broken row transition.
                if isCollapsed { collapsedSections.remove(name) }
                else { collapsedSections.insert(name) }
            } label: {
                HStack(spacing: 6) {
                    DisclosureChevron(isExpanded: !isCollapsed, style: .section)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)
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

// MARK: - Physical Device section

/// Render the physical-device list split into labelled subcategories. The
/// Power subgroup combines the Internal Battery, MagSafe, and the desktop
/// AC PSU (whichever exist on this host) into one section above the data
/// ports — those are all "how the Mac is fed power", which is conceptually
/// separate from the data-connector grid below. Data subgroups (USB-C,
/// USB-A, HDMI, SD Card, Ethernet, …) follow in chassis order. Subgroup
/// headers always render, even when only one family is present — the
/// consistent layout makes the chassis legible at a glance.
private struct PortsByConnector: View {
    let ports: [PhysicalPort]
    /// `AppleSmartBattery` node (classified as `.battery` by `NodeFormatter`).
    /// Nil on desktops / VMs without a battery.
    let battery: TBNode?
    /// MagSafe receptacle accessory, when the chassis ships one.
    let magsafe: PortAccessoryInfo?
    /// Full display list — used to attribute externals to each port so the
    /// sidebar can render a display row alongside the dock's USB devices.
    let allDisplays: [DisplayInfo]
    @Binding var expanded: Set<TBNodeID>
    /// Shared subgroup-collapse state owned by `SidebarView`. Each subgroup
    /// uses a namespaced key (`"physical:Power"`, `"physical:USB-C"`, …) so
    /// it doesn't collide with subgroup keys used by other sections.
    @Binding var collapsedSubgroups: Set<String>
    let flattenHubs: Bool
    /// TB-tunneled PCIe endpoints keyed by `PhysicalPortSelector` ID. Each
    /// list is the set of real PCIe endpoint devices reached through that
    /// physical port — fed forward to `PortBranch` → `DeviceBranch` so
    /// the dock row nests them alongside the USB device tree.
    let pcieByPortID: [TBNodeID: [PCINode]]

    var body: some View {
        let powerPorts = ports.filter { $0.connector == .acPower }
        let hasPower = battery != nil || magsafe != nil || !powerPorts.isEmpty
        let dataGroups = dataGroups()

        if hasPower {
            collapsibleSubgroup(key: "physical:Power",
                                title: "Power",
                                collapsedSubgroups: $collapsedSubgroups) {
                if let battery {
                    BatteryRow(node: battery).tag(battery.id)
                }
                if let magsafe {
                    MagSafeRow(accessory: magsafe).tag(MagSafeSelector.id)
                }
                ForEach(powerPorts, id: \.id) { port in
                    PortBranch(port: port,
                               displayOutputs: displayOutputsFor(port),
                               expanded: $expanded,
                               flattenHubs: flattenHubs,
                               pcieEndpoints: pcieByPortID[PhysicalPortSelector.id(for: port)] ?? [])
                }
            }
        }
        ForEach(dataGroups, id: \.title) { group in
            collapsibleSubgroup(key: "physical:\(group.title)",
                                title: group.title,
                                collapsedSubgroups: $collapsedSubgroups) {
                ForEach(group.ports, id: \.id) { port in
                    PortBranch(port: port,
                               displayOutputs: displayOutputsFor(port),
                               expanded: $expanded,
                               flattenHubs: flattenHubs,
                               pcieEndpoints: pcieByPortID[PhysicalPortSelector.id(for: port)] ?? [])
                }
            }
        }
    }

    private func displayOutputsFor(_ port: PhysicalPort) -> [PortDisplayOutput] {
        displayOutputsAttributed(to: port,
                                 allPorts: ports,
                                 allDisplays: allDisplays)
    }

    private struct Group {
        let title: String
        let ports: [PhysicalPort]
    }

    /// Data-connector subgroups, in chassis order. AC PSU is excluded —
    /// it's rendered in the Power subgroup alongside the battery and
    /// MagSafe. MagSafe is excluded for the same reason.
    private func dataGroups() -> [Group] {
        let usbC = ports.filter { $0.connector == .usbC }
        let usbA = ports.filter { $0.connector == .usbA }
        let hdmi = ports.filter { $0.connector == .hdmi }
        let sd = ports.filter { $0.connector == .sdCard }
        let ethernet = ports.filter { $0.connector == .ethernet }
        let other = ports.filter {
            switch $0.connector {
            case .usbC, .usbA, .hdmi, .sdCard, .magsafe, .acPower, .ethernet:
                return false
            case .other:
                return true
            }
        }
        var out: [Group] = []
        if !usbC.isEmpty { out.append(Group(title: "USB-C", ports: usbC)) }
        if !usbA.isEmpty { out.append(Group(title: "USB-A", ports: usbA)) }
        if !hdmi.isEmpty { out.append(Group(title: "HDMI", ports: hdmi)) }
        if !sd.isEmpty { out.append(Group(title: "SD Card", ports: sd)) }
        if !ethernet.isEmpty { out.append(Group(title: "Ethernet", ports: ethernet)) }
        if !other.isEmpty { out.append(Group(title: "Expanded Ports", ports: other)) }
        return out
    }
}

// MARK: - Shared disclosure chevron + subgroup helper

/// One rotating chevron used by every collapse affordance in the sidebar —
/// the top-level section header and the inline subgroup header — so the
/// affordance looks identical across all levels and you don't get the
/// "two slightly different chevrons" feeling you used to. Rotates from
/// 0° (collapsed) to 90° (expanded) with a short easing, matching macOS's
/// own sidebar disclosure idiom.
struct DisclosureChevron: View {
    let isExpanded: Bool
    let style: Style

    enum Style {
        case section   // bigger, more prominent
        case subgroup  // small, matches uppercase tertiary header text
    }

    var body: some View {
        Image(systemName: "chevron.right")
            .font(font)
            .foregroundStyle(.tertiary)
            .frame(width: 12, alignment: .center)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private var font: Font {
        switch style {
        case .section: return .caption.weight(.semibold)
        case .subgroup: return .caption2.weight(.semibold)
        }
    }
}

/// Inline collapsible subgroup. Used inside top-level sections to label
/// related rows (POWER / USB-C / Buses / Connected …). Header is a clickable
/// chevron + uppercase title; on collapse, the content closure is skipped
/// entirely so the rows disappear from the List.
///
/// Implemented as a `Section { rows } header: { button }` rather than a flat
/// `Button + rows` sequence so that SwiftUI's `List` treats the header as a
/// section affordance instead of a sibling cell. The previous flat layout
/// produced visible ghosting during sidebar refreshes — when the power-poll
/// re-rendered the list, cell reuse could leave a row's text from one
/// subgroup briefly painted on top of the next subgroup's row (most easily
/// seen as "SD Card Slot" bleeding through the HDMI row).
///
/// Toggling the collapse state deliberately does not use `withAnimation` —
/// animating row insertion/removal inside a SwiftUI sidebar `List` is the
/// other half of the same ghosting bug. The chevron has its own rotation
/// animation, so the user still sees a smooth affordance.
///
/// `key` is namespaced (e.g. `"physical:Power"`, `"ih:Buses"`) so subgroup
/// titles that happen to match top-level section names don't share state.
@ViewBuilder
fileprivate func collapsibleSubgroup<Content: View>(
    key: String,
    title: String,
    icon: String? = nil,
    collapsedSubgroups: Binding<Set<String>>,
    @ViewBuilder content: () -> Content
) -> some View {
    let isCollapsed = collapsedSubgroups.wrappedValue.contains(key)
    Section {
        if !isCollapsed { content() }
    } header: {
        Button {
            if isCollapsed { collapsedSubgroups.wrappedValue.remove(key) }
            else { collapsedSubgroups.wrappedValue.insert(key) }
        } label: {
            HStack(spacing: 6) {
                DisclosureChevron(isExpanded: !isCollapsed, style: .subgroup)
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, alignment: .center)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PortBranch: View {
    let port: PhysicalPort
    /// Display outputs attributed to this port: one entry per active
    /// DP/HDMI function adapter on the dock's router (with the display
    /// nested under it), or a single adapter-less entry for direct-attach.
    let displayOutputs: [PortDisplayOutput]
    @Binding var expanded: Set<TBNodeID>
    let flattenHubs: Bool
    /// TB-tunneled PCIe nodes attributed to this port. Two modes,
    /// driven by `showIntermediateHubs` (the same toggle that surfaces
    /// raw USB hub chains):
    ///   - off (default): flat list of leaf `.endpoint` devices (eGPU,
    ///     TB SSD, capture card). Usually empty on Apple Silicon docks
    ///     because storage is tunneled over USB, not PCIe.
    ///   - on: a single PCIe root bridge (the "Thunderbolt PCIe Slot N"
    ///     allocated to this TB controller) with its full bridge
    ///     subtree underneath — so the user can see every kernel
    ///     artefact on the PCIe path, idle slots included.
    /// `PCIBranch` handles both shapes natively.
    var pcieEndpoints: [PCINode] = []

    var body: some View {
        let selectionID = PhysicalPortSelector.id(for: port)
        let device = port.connectedDevice
        // When the user has chosen to hide intermediate hubs, expand any
        // top-level hub roots into their non-hub descendants so cascaded
        // dock internals don't appear as nested rows under the port.
        let roots = flattenedUSBRoots(port.usbDeviceRoots, flattenHubs: flattenHubs)

        if device == nil && roots.isEmpty && displayOutputs.isEmpty && pcieEndpoints.isEmpty {
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
                    // When a TB device is attached the dock owns the
                    // tunneled USB endpoints, the PCIe endpoints (eGPU
                    // enclosures, TB SSDs), *and* the DP/HDMI outputs —
                    // every active function adapter on the dock router
                    // lives there. Surface them all as children of the
                    // device row so the tree reads as "USB-C Port → Dock
                    // → everything the dock provides". Hubs are still
                    // flattened away when the toggle is off, so a busy
                    // 14-port dock reads as actual peripherals, not the
                    // dock-internal hub chain.
                    DeviceBranch(device: device,
                                 expanded: $expanded,
                                 flattenHubs: flattenHubs,
                                 usbRoots: roots,
                                 pcieEndpoints: pcieEndpoints,
                                 displayOutputs: displayOutputs)
                } else {
                    // No TB device on this port — render USB roots, PCIe,
                    // and displays directly under the port row (USB-only
                    // dock, direct-attach monitor over USB-C alt mode,
                    // etc.). PCIe-without-TB-device shouldn't happen on a
                    // USB-C port, but render defensively if it does.
                    ForEach(roots, id: \.id) { dev in
                        USBBranch(node: dev, depth: 0, expanded: $expanded, flattenHubs: flattenHubs)
                    }
                    ForEach(pcieEndpoints) { ep in
                        PCIBranch(node: ep, expanded: $expanded)
                    }
                    ForEach(displayOutputs) { output in
                        DisplayOutputBranch(output: output, expanded: $expanded)
                    }
                }
            } label: {
                PortRow(port: port).tag(selectionID)
            }
            .tag(selectionID)
        }
    }
}

/// One DP/HDMI output row. Renders each attributed display directly under
/// the port (or under the dock device row), with the dock adapter port
/// number folded into the display row's subtitle when applicable. The
/// previous design had an intermediate "Display Output N · DP/HDMI ·
/// adapter port N" wrapper row, but that row carried no information the
/// display row couldn't carry — the user has to drill into the display
/// for anything actionable, and the kernel can't disambiguate DP vs HDMI
/// on the dock anyway. So we flatten.
///
/// Empty outputs (an active DP/HDMI adapter on the dock with no display
/// the heuristic could attribute) render nothing — the dock row's PCIe
/// / USB lists already make the dock's existence obvious.
private struct DisplayOutputBranch: View {
    let output: PortDisplayOutput
    @Binding var expanded: Set<TBNodeID>

    var body: some View {
        ForEach(output.displays, id: \.id) { d in
            DisplaySidebarRow(display: d, adapter: output.adapter).tag(d.id)
        }
    }
}

private struct DeviceBranch: View {
    let device: ConnectedDevice
    @Binding var expanded: Set<TBNodeID>
    let flattenHubs: Bool
    /// USB device roots tunneled through this TB device's TB controller.
    /// Only the top-level device in a daisy chain is populated — the kernel
    /// doesn't tell us which sub-dock in a chain is hosting a given USB
    /// endpoint (they all enumerate under one host xHCI), so attributing
    /// them to the first dock is the best we can do without speculation.
    /// Daisy-chained sub-`DeviceBranch`es receive an empty list.
    var usbRoots: [TBNode] = []
    /// TB-tunneled PCIe endpoints attributed to this device, surfaced
    /// alongside the USB tree. Empty for daisy-chained sub-devices for the
    /// same reason as `usbRoots`.
    var pcieEndpoints: [PCINode] = []
    /// DP/HDMI outputs attributed to this device. Each one is an active
    /// DP/HDMI function adapter on the dock router with the display panel
    /// nested below — same payload as the port-level rendering, just
    /// reparented under the device. Empty for daisy-chained sub-devices.
    var displayOutputs: [PortDisplayOutput] = []

    var body: some View {
        let hasChildren = !device.daisyChained.isEmpty
            || !usbRoots.isEmpty
            || !pcieEndpoints.isEmpty
            || !displayOutputs.isEmpty
        if !hasChildren {
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
                    DeviceBranch(device: child,
                                 expanded: $expanded,
                                 flattenHubs: flattenHubs)
                }
                // Displays come first inside the device row — they're
                // physically the dock's outputs and visually quieter than
                // a long USB peripheral list, so leading with them keeps
                // the row's "what's connected through this dock" overview
                // legible at a glance.
                ForEach(displayOutputs) { output in
                    DisplayOutputBranch(output: output, expanded: $expanded)
                }
                ForEach(usbRoots, id: \.id) { dev in
                    USBBranch(node: dev,
                              depth: 0,
                              expanded: $expanded,
                              flattenHubs: flattenHubs)
                }
                ForEach(pcieEndpoints) { ep in
                    PCIBranch(node: ep, expanded: $expanded)
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
                if let loc = port.locationLabel {
                    Text(loc)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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

/// Build the TB-port → USB-device-roots map used by the Thunderbolt
/// sidebar tree to nest the tunneled USB devices under the function
/// adapter port that's providing them. Only the *host-side* USB Adapter
/// ports on a depth-0 Mac Host Router get the devices grafted — those
/// are the IOKit endpoint where the tunneled xHCI actually enumerates;
/// the dock-side adapter ports are the other end of the tunnel.
private func tbProvidedUSBMap(ports: [PhysicalPort]) -> [TBNodeID: [TBNode]] {
    var out: [TBNodeID: [TBNode]] = [:]
    for p in ports where !p.usbDeviceRoots.isEmpty {
        for adapter in activeHostUSBAdapters(under: p.controller) {
            out[adapter.id] = p.usbDeviceRoots
        }
    }
    return out
}

/// For each TB controller, find the "Thunderbolt PCIe Slot N" root that's
/// allocated alongside it in the IOKit registry. Apple Silicon allocates
/// the TB controller and its corresponding TB PCIe downstream root port as
/// adjacent IORegistry entries — the slot's registry ID is the closest one
/// *greater than* the TB controller's. This is the only stable association
/// the kernel publishes; there's no explicit cross-reference between the
/// two services, so we lean on the allocation order. Returns a map keyed
/// by the TB controller's `TBNodeID`.
private func tbControllerPCIeSlotMap(controllers: [TBNode],
                                     pcieRoots: [PCINode]) -> [TBNodeID: PCINode] {
    let slots = pcieRoots
        .filter { $0.slotName?.contains("Slot-") == true }
        .sorted { $0.id.raw < $1.id.raw }
    let ctrls = controllers.sorted { $0.id.raw < $1.id.raw }
    var out: [TBNodeID: PCINode] = [:]
    // Walk both sorted lists in lockstep, consuming each slot once a
    // controller claims it. Registry allocation doesn't strictly
    // interleave (this MBP allocates controllers 0xBEC, 0xBF0, 0xC8B
    // and slots 0xC07, 0xCAA, 0xCC6) — a naive "first slot with a
    // greater id" pairs two controllers with the same slot and orphans
    // another.
    var slotIndex = 0
    for c in ctrls {
        while slotIndex < slots.count, slots[slotIndex].id.raw <= c.id.raw {
            slotIndex += 1
        }
        guard slotIndex < slots.count else { break }
        out[c.id] = slots[slotIndex]
        slotIndex += 1
    }
    return out
}

/// Collect every endpoint device (kind `.endpoint`) under a PCIe subtree.
/// Used to surface the TB-tunneled NVMe / ethernet / capture cards on a
/// dock without surfacing the chain of dock-internal bridges that wrap
/// them — bridges are kernel-side topology, endpoints are the device the
/// user cares about.
private func pcieEndpointDescendants(of root: PCINode) -> [PCINode] {
    var out: [PCINode] = []
    var stack = [root]
    while let n = stack.popLast() {
        if n.kind == .endpoint { out.append(n) }
        stack.append(contentsOf: n.children)
    }
    return out
}

/// Find USB function adapter ports (`"USB Adapter"` / `"USB Gen T Adapter"`)
/// directly under this TB controller's Mac Host Router that have an active
/// hop table. The active hop count is the kernel-authoritative signal that
/// a USB tunnel is currently terminated on that adapter — picking the
/// active one avoids attaching the dock's USB devices to an idle USB Gen T
/// adapter sitting next to the live USB Adapter.
private func activeHostUSBAdapters(under controller: TBNode) -> [TBNode] {
    var out: [TBNode] = []
    guard let macHostRouter = findRootSwitchInController(controller) else { return [] }
    for child in macHostRouter.children where child.kind == .port {
        let desc = child.properties["Description"]?.asString ?? ""
        if desc == "USB Adapter" || desc == "USB Gen T Adapter" {
            if case let .array(arr)? = child.properties["Hop Table"], !arr.isEmpty {
                out.append(child)
            }
        }
    }
    return out
}

/// Locate the depth-0 switch (Mac Host Router) within a TB controller's
/// subtree. Used by the USB-attribution map to find host-side adapters.
private func findRootSwitchInController(_ controller: TBNode) -> TBNode? {
    var stack = controller.children
    while !stack.isEmpty {
        let n = stack.removeFirst()
        if n.kind == .switch, (n.properties["Depth"]?.asUInt ?? 0) == 0 {
            return n
        }
        stack.append(contentsOf: n.children)
    }
    return nil
}

private struct ControllerBranch: View {
    let node: TBNode
    @Binding var expanded: Set<TBNodeID>
    let flattenHubs: Bool
    /// Map keyed by TB function-adapter port IDs to the USB device roots
    /// tunneled through them. Forwarded down to `FullTopologyRow` so the
    /// graft applies wherever the matching node lives in the subtree.
    var providedUSB: [TBNodeID: [TBNode]] = [:]

    var body: some View {
        // Skip `.other` wrapper kexts (DPConnectionManager, IPService, etc.)
        // and promote their meaningful descendants up — same recursion the
        // deeper rows use, so nothing in the IOKit tree is hidden.
        let kids = promotedChildren(of: node, flattenHubs: flattenHubs)
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(node.id) },
                set: { isOn in
                    if isOn { expanded.insert(node.id) } else { expanded.remove(node.id) }
                }
            )
        ) {
            ForEach(kids, id: \.id) { child in
                FullTopologyRow(node: child, depth: 1, expanded: $expanded, flattenHubs: flattenHubs, providedUSB: providedUSB)
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
    let flattenHubs: Bool

    var body: some View {
        // USB host controllers wrap each port in an `.other` kext (e.g.
        // `AppleUSB20XHCIARMPort`) whose child is the real `IOUSBHostDevice`.
        // A flat filter would drop the wrapper *and* the device with it —
        // recurse through wrappers and promote real USB nodes up. Interfaces
        // are hidden here and shown only in the device's detail view.
        let kids = promotedUSBChildren(of: node, flattenHubs: flattenHubs)
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
                    USBBranch(node: child, depth: depth + 1, expanded: $expanded, flattenHubs: flattenHubs)
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
/// When `flattenHubs` is true, `.usbHub` nodes are also treated as pass-through
/// wrappers so cascaded dock internals don't bury the leaf devices.
private func promotedChildren(of node: TBNode, flattenHubs: Bool = false) -> [TBNode] {
    var out: [TBNode] = []
    for c in node.children {
        if c.kind == .other {
            out.append(contentsOf: promotedChildren(of: c, flattenHubs: flattenHubs))
        } else if flattenHubs && c.kind == .usbHub {
            out.append(contentsOf: promotedChildren(of: c, flattenHubs: flattenHubs))
        } else {
            out.append(c)
        }
    }
    return out
}

/// Same recursion as `promotedChildren` but also hides USB interfaces — they
/// don't carry their own subtree worth navigating and the device detail view
/// surfaces them in a dedicated section.
private func promotedUSBChildren(of node: TBNode, flattenHubs: Bool = false) -> [TBNode] {
    var out: [TBNode] = []
    for c in node.children {
        if c.kind == .other {
            out.append(contentsOf: promotedUSBChildren(of: c, flattenHubs: flattenHubs))
        } else if c.kind == .usbInterface {
            continue
        } else if flattenHubs && c.kind == .usbHub {
            out.append(contentsOf: promotedUSBChildren(of: c, flattenHubs: flattenHubs))
        } else {
            out.append(c)
        }
    }
    return out
}

/// Expand top-level USB roots when hub-flattening is on: any root that's
/// itself a hub gets replaced by its non-hub descendants, so a port's row
/// reads as `[leaf, leaf, …]` instead of `[hub → hub → leaf]`. Used by
/// `PortBranch` since the roots come from `PhysicalPort.usbDeviceRoots`
/// (computed once in `TopologyMapper` and not aware of this preference).
private func flattenedUSBRoots(_ roots: [TBNode], flattenHubs: Bool) -> [TBNode] {
    guard flattenHubs else { return roots }
    var out: [TBNode] = []
    for r in roots {
        if r.kind == .usbHub {
            out.append(contentsOf: promotedUSBChildren(of: r, flattenHubs: true))
        } else {
            out.append(r)
        }
    }
    return out
}

private struct FullTopologyRow: View {
    let node: TBNode
    let depth: Int
    @Binding var expanded: Set<TBNodeID>
    var flattenHubs: Bool = false
    /// TB function-adapter port → tunneled USB device roots. When this
    /// node's ID is present, the row appends the USB devices as additional
    /// children so the Thunderbolt tree reads as "TB controller → switch →
    /// USB Adapter port → device hub → actual devices". Empty for non-TB
    /// trees (the internal-hardware bus rows pass this through unset).
    var providedUSB: [TBNodeID: [TBNode]] = [:]

    var body: some View {
        let kids = promotedChildren(of: node, flattenHubs: flattenHubs)
        let extraUSB = providedUSB[node.id] ?? []
        // Disclosure when the kernel-side children exist OR when we have
        // a USB graft to surface (an inactive port with attached devices
        // would otherwise render as a leaf and hide the tunneled list).
        if kids.isEmpty && extraUSB.isEmpty {
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
                    FullTopologyRow(node: child, depth: depth + 1, expanded: $expanded, flattenHubs: flattenHubs, providedUSB: providedUSB)
                }
                // Tunneled USB roots come last so the kernel-published TB
                // structure (which the user already understands) stays
                // visually above the grafted-in subtree.
                ForEach(extraUSB, id: \.id) { dev in
                    USBBranch(node: dev,
                              depth: depth + 1,
                              expanded: $expanded,
                              flattenHubs: flattenHubs)
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

// MARK: - Display row

private struct DisplaySidebarRow: View {
    let display: DisplayInfo
    /// Optional dock-side DP/HDMI function adapter that this display is
    /// routed through. When non-nil, the adapter's chassis port number is
    /// appended to the subtitle so the user can see which dock jack the
    /// display is wired to without an intermediate sidebar row.
    var adapter: TBNode? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: display.iconSymbol)
                .foregroundStyle(display.isConnected ? .blue : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.title).lineLimit(1)
                if let s = subtitleText, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Idle").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitleText: String? {
        var parts: [String] = []
        if let s = display.subtitle, !s.isEmpty { parts.append(s) }
        if let adapter,
           let n = adapter.properties["Port Number"]?.asUInt {
            parts.append("dock port \(n)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
