//
//  ContentView.swift
//  Boltprobe
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = BoltprobeViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
        } detail: {
            DetailView(
                node: vm.selection.flatMap { vm.node(for: $0) },
                onNavigate: { vm.select($0) },
                parentLookup: { vm.parent(of: $0) }
            )
        }
        .frame(minWidth: 980, minHeight: 600)
    }
}

#Preview {
    ContentView()
}
