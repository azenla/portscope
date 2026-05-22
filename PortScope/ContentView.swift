//
//  ContentView.swift
//  PortScope
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = PortScopeViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
        } detail: {
            detail
        }
        .frame(minWidth: 980, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        if let sel = vm.selection {
            if PhysicalPortSelector.isPortID(sel),
               let port = TopologyMapper.physicalPorts(from: vm.snapshot).first(where: { PhysicalPortSelector.id(for: $0).raw == sel.raw }) {
                // Built-in non-USB receptacles get curated, connector-specific
                // detail pages. The unified `PhysicalPortDetailView` is built
                // around USB-C semantics (USB-PD profiles, alt-mode transports,
                // cable e-markers) which don't apply to a kettle-cord PSU,
                // a plain RJ-45, an HDMI jack, or an SD slot. Everything else
                // — USB-C, USB-A, MagSafe, and the `.other` long tail —
                // still uses the unified view.
                switch port.connector {
                case .acPower:
                    ACPowerDetailView(port: port,
                                      onNavigate: { vm.select($0) })
                        .id(sel)
                case .ethernet:
                    EthernetDetailView(port: port,
                                       onNavigate: { vm.select($0) })
                        .id(sel)
                case .hdmi:
                    HDMIDetailView(port: port,
                                   onNavigate: { vm.select($0) })
                        .id(sel)
                case .sdCard:
                    SDCardDetailView(port: port,
                                     onNavigate: { vm.select($0) })
                        .id(sel)
                case .usbC, .usbA, .magsafe, .other:
                    PhysicalPortDetailView(port: port,
                                           displays: displaysForPort(port),
                                           onNavigate: { vm.select($0) })
                        .id(sel)
                }
            } else if MagSafeSelector.isMagSafeID(sel),
                      let magsafe = vm.snapshot.internalHardware.magsafe {
                ScrollView {
                    MagSafeView(accessory: magsafe)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 620)
                .id(sel)
            } else if BluetoothSelector.isControllerID(sel),
                      let controller = vm.snapshot.bluetooth.controller {
                ScrollView {
                    BluetoothControllerView(controller: controller,
                                            snapshot: vm.snapshot.bluetooth,
                                            onNavigate: { vm.select($0) })
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 620)
                .id(sel)
            } else if BluetoothSelector.isDeviceID(sel),
                      let device = findBluetoothDevice(id: sel) {
                ScrollView {
                    BluetoothDeviceView(device: device)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 620)
                .id(sel)
            } else if let display = vm.snapshot.displays.displays.first(where: { $0.id == sel }) {
                DisplayDetailView(display: display).id(sel)
            } else if let pciNode = findPCINode(id: sel, in: vm.snapshot.pcie.roots) {
                PCIDeviceView(node: pciNode,
                              ancestors: vm.ancestors(of: sel),
                              onNavigate: { vm.select($0) })
                    .id(sel)
            } else if let node = vm.node(for: sel) {
                DetailView(
                    node: node,
                    onNavigate: { vm.select($0) },
                    parentLookup: { vm.parent(of: $0) },
                    tbContextForUSB: { id in vm.usbSnapshot.tbContext[id] },
                    ancestors: vm.ancestors(of: sel)
                )
            } else {
                emptyState
            }
        } else {
            emptyState
        }
    }

    private func displaysForPort(_ port: PhysicalPort) -> [DisplayInfo] {
        let allPorts = TopologyMapper.physicalPorts(from: vm.snapshot)
        return displaysAttributed(to: port,
                                  allPorts: allPorts,
                                  allDisplays: vm.snapshot.displays.displays)
    }

    private func findBluetoothDevice(id: TBNodeID) -> BluetoothDevice? {
        let all = vm.snapshot.bluetooth.connected + vm.snapshot.bluetooth.paired
        return all.first { BluetoothSelector.id(for: $0).raw == id.raw }
    }

    private func findPCINode(id: TBNodeID, in roots: [PCINode]) -> PCINode? {
        for r in roots {
            if r.id == id { return r }
            if let f = findPCINode(id: id, in: r.children) { return f }
        }
        return nil
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Select a port or device",
            systemImage: "bolt.horizontal.circle",
            description: Text("Pick something from the sidebar to inspect.")
        )
    }
}

#Preview {
    ContentView()
}
