//
//  BoltprobeApp.swift
//  Boltprobe
//

import SwiftUI

@main
struct BoltprobeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .boltprobeRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let boltprobeRefresh = Notification.Name("io.zenla.boltprobe.refresh")
}
