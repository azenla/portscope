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
        if let request = CLIRequest.from(CommandLine.arguments) {
            runCLI(request: request)
            return
        }
        PortScopeApp.main()
    }

    private static func runCLI(request: CLIRequest) {
        let snapshot: SystemSnapshot = {
            let tb = ThunderboltScanner.scan()
            let usb = USBScanner.scan()
            let accessories = AccessoryScanner.scan() + SDCardScanner.scan()
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
        }()
        let output: String
        switch request.format {
        case .json:
            output = SnapshotDumper.json(snapshot,
                                         showBuses: request.showBuses,
                                         showAll: request.showAll)
        case .pretty(let forceColor):
            let isTTY = isatty(fileno(stdout)) != 0
            output = SnapshotDumper.pretty(snapshot,
                                           useColor: forceColor ?? isTTY,
                                           showBuses: request.showBuses,
                                           showAll: request.showAll)
        case .simple:
            output = SnapshotDumper.simple(snapshot)
        }
        FileHandle.standardOutput.write(Data(output.utf8))
        if !output.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
        exit(0)
    }
}

/// One invocation's worth of CLI options. The format selects the output
/// renderer; `showBuses` adds the raw Thunderbolt / USB / PCIe trees and
/// `showAll` adds Bluetooth / Displays / Internal Hardware. Both default
/// off, matching the GUI's default sidebar — bare invocation shows only
/// the Physical Ports view and the accessory roll-up.
private struct CLIRequest {
    enum Format {
        case pretty(forceColor: Bool?)
        case json
        case simple
    }
    let format: Format
    let showBuses: Bool
    let showAll: Bool

    static func from(_ argv: [String]) -> CLIRequest? {
        var pretty = false
        var json = false
        var simple = false
        var showBuses = false
        var showAll = false
        var forceColor: Bool? = nil
        for arg in argv.dropFirst() {
            switch arg {
            case "--pretty", "--dump", "-p": pretty = true
            case "--json", "-j": json = true
            case "--simple", "-s": simple = true
            case "--buses", "-b": showBuses = true
            case "--all", "-a": showAll = true
            case "--color", "--colour": forceColor = true
            case "--no-color", "--no-colour": forceColor = false
            case "--help", "-h":
                let usage = """
                PortScope — system snapshot inspector

                Default (no flags): launch the GUI.

                CLI dump modes (write to stdout, then exit):
                  --pretty | -p     Colourful tree view with emoji.
                  --json   | -j     Stable JSON dump (jq-friendly).
                  --simple | -s     Tab-separated port summary, one line per
                                    receptacle. Shell-script friendly.

                Modifiers (all default off — match the GUI sidebar):
                  --buses  | -b     Include raw Thunderbolt, USB, and PCIe
                                    bus trees. Default: Physical Ports only.
                                    Ignored by --simple.
                  --all    | -a     Include Bluetooth, Displays, and Internal
                                    Hardware sections. Ignored by --simple.
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
        if simple { return CLIRequest(format: .simple, showBuses: showBuses, showAll: showAll) }
        if json { return CLIRequest(format: .json, showBuses: showBuses, showAll: showAll) }
        if pretty { return CLIRequest(format: .pretty(forceColor: forceColor), showBuses: showBuses, showAll: showAll) }
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

        Settings {
            SettingsView()
        }
    }
}

/// The Preferences window. Houses persistent toggles that gate which
/// sidebar sections are visible.
private struct SettingsView: View {
    @AppStorage(SidebarVisibility.showBusesKey) private var showBuses: Bool = false
    @AppStorage(SidebarVisibility.showAllDevicesKey) private var showAllDevices: Bool = false

    var body: some View {
        Form {
            Toggle("Show Hardware Buses", isOn: $showBuses)
            Text("Show the raw Thunderbolt, USB, and PCIe bus trees in the sidebar. The Physical Ports section is always visible.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show All Devices", isOn: $showAllDevices)
                .padding(.top, 8)
            Text("Also show Bluetooth, Displays, and Internal Hardware in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Stable keys for the persistent sidebar-visibility preferences. The
/// sidebar reads each via `@AppStorage` so the UI updates live when the
/// Settings window toggles them.
enum SidebarVisibility {
    /// Gates Thunderbolt / USB / PCIe sections (the bus trees). Default off,
    /// so a fresh launch shows only the high-level Physical Ports view.
    static let showBusesKey = "showBuses"
    /// Gates Displays / Bluetooth / Internal Hardware. Default off.
    static let showAllDevicesKey = "showAllDevices"
}

extension Notification.Name {
    static let portScopeRefresh = Notification.Name("io.zenla.portscope.refresh")
}
