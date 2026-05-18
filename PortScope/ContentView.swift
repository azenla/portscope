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
            if let portNumber = PhysicalPortSelector.portNumber(sel),
               let port = TopologyMapper.physicalPorts(from: vm.snapshot).first(where: { $0.number == portNumber }) {
                PhysicalPortDetailView(port: port,
                                       onNavigate: { vm.select($0) })
                .id(sel)
            } else if let node = vm.node(for: sel) {
                DetailView(
                    node: node,
                    onNavigate: { vm.select($0) },
                    parentLookup: { vm.parent(of: $0) },
                    tbContextForUSB: { id in vm.usbSnapshot.tbContext[id] }
                )
            } else {
                emptyState
            }
        } else {
            emptyState
        }
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
