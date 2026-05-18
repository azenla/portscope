//
//  PortScopeApp.swift
//  PortScope
//
//  Dual-mode entry point. When launched with no CLI args, runs as a
//  normal SwiftUI app; when launched with `--pretty` or `--json`, runs
//  scanners synchronously, prints the snapshot, and exits without
//  opening a window. The same binary inside `PortScope.app/Contents/
//  MacOS/PortScope` does both jobs.
//

import SwiftUI
import Foundation
import Darwin

@main
enum PortScopeMain {
    static func main() {
        if let mode = CLIMode.from(CommandLine.arguments) {
            runCLI(mode: mode)
            return
        }
        PortScopeApp.main()
    }

    private static func runCLI(mode: CLIMode) {
        // Scanners are MainActor-isolated. We're already on the main
        // thread of a freshly-launched process (`@main` runs there), so
        // it's safe to call them directly via `MainActor.assumeIsolated`.
        let snapshot: SystemSnapshot = MainActor.assumeIsolated {
            let tb = ThunderboltScanner.scan()
            let usb = USBScanner.scan()
            let accessories = AccessoryScanner.scan()
            let internalHardware = InternalHardwareScanner.scan(accessories: accessories)
            let bluetooth = BluetoothScanner.scan()
            let displays = DisplayScanner.scan()
            let pcie = PCIScanner.scan()
            return SystemSnapshot(
                tb: tb, usb: usb, accessories: accessories,
                internalHardware: internalHardware,
                bluetooth: bluetooth, displays: displays, pcie: pcie,
                capturedAt: Date()
            )
        }
        let output: String
        switch mode {
        case .json:
            output = SnapshotDumper.json(snapshot)
        case .pretty(let forceColor):
            let isTTY = isatty(fileno(stdout)) != 0
            output = SnapshotDumper.pretty(snapshot, useColor: forceColor ?? isTTY)
        }
        FileHandle.standardOutput.write(Data(output.utf8))
        if !output.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
        exit(0)
    }
}

/// CLI modes the entry point recognises.
private enum CLIMode {
    case pretty(forceColor: Bool?)
    case json

    static func from(_ argv: [String]) -> CLIMode? {
        var pretty = false
        var json = false
        var forceColor: Bool? = nil
        for arg in argv.dropFirst() {
            switch arg {
            case "--pretty", "--dump", "-p": pretty = true
            case "--json", "-j": json = true
            case "--color", "--colour": forceColor = true
            case "--no-color", "--no-colour": forceColor = false
            case "--help", "-h":
                let usage = """
                PortScope — system snapshot inspector

                Default (no flags): launch the GUI.

                CLI dump modes (write to stdout, then exit):
                  --pretty | -p     Colourful tree view with emoji.
                  --json   | -j     Stable JSON dump (jq-friendly).

                Modifiers:
                  --color / --no-color
                                    Force ANSI colour on/off (default: auto-detect TTY).
                  -h, --help        Show this help.
                """
                FileHandle.standardOutput.write(Data((usage + "\n").utf8))
                exit(0)
            default:
                // Ignore unknown args (Xcode injects its own when launching
                // the bundle via `open`) so they don't suppress GUI mode.
                continue
            }
        }
        if json { return .json }
        if pretty { return .pretty(forceColor: forceColor) }
        return nil
    }
}

/// The original SwiftUI App, now reached via `PortScopeApp.main()` from
/// the `PortScopeMain` entry point above when no CLI dump flag is passed.
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
