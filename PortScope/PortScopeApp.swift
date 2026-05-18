//
//  PortScopeApp.swift
//  PortScope
//

import SwiftUI

@main
struct PortScopeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .portScopeRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let portScopeRefresh = Notification.Name("io.zenla.portscope.refresh")
}
