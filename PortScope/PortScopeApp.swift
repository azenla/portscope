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
            // TB / USB / accessories always scan — they're what `--simple`
            // and the bare default emit, and they're fast (no `Process`
            // spawns). The other scanners are gated on the flags that
            // would surface their data in the dump:
            //   * `bluetooth` spawns `system_profiler SPBluetoothDataType`
            //     and routinely takes 10+ seconds. Only meaningful when
            //     `--all` is set (output gates the `bluetooth` key the
            //     same way).
            //   * `displays` is moderate but only emitted under `--all`.
            //   * `pcie` is cheap but only emitted under `--buses`.
            //   * `InternalHardwareScanner` always runs (used by the
            //     Physical Device summary), but its heavy `SystemInfo`
            //     half is gated by `includeHeavyHostInfo: request.showAll`.
            let tb = ThunderboltScanner.scan()
            let usb = USBScanner.scan()
            let accessories = AccessoryScanner.scan()
                + SDCardScanner.scan()
                + PowerInputScanner.scan()
                + EthernetScanner.scan()
            let internalHardware = InternalHardwareScanner.scan(
                accessories: accessories,
                includeHeavyHostInfo: request.showAll
            )
            let bluetooth = request.showAll
                ? BluetoothScanner.scan()
                : BluetoothSnapshot.empty
            let displays = request.showAll
                ? DisplayScanner.scan()
                : DisplaySnapshot.empty
            let pcie = request.showBuses
                ? PCIScanner.scan()
                : PCISnapshot.empty
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
                                         showAll: request.showAll,
                                         showHubs: request.showHubs)
        case .pretty(let forceColor):
            let isTTY = isatty(fileno(stdout)) != 0
            output = SnapshotDumper.pretty(snapshot,
                                           useColor: forceColor ?? isTTY,
                                           showBuses: request.showBuses,
                                           showAll: request.showAll,
                                           showHubs: request.showHubs)
        case .simple:
            output = SnapshotDumper.simple(snapshot)
        }
        FileHandle.standardOutput.write(Data(output.utf8))
        if !output.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
        exit(0)
    }
}

/// One invocation's worth of CLI options. The format selects the output
/// renderer; `showBuses` adds the raw Thunderbolt / USB / PCIe trees,
/// `showAll` adds Bluetooth / Displays / Internal Hardware, and
/// `showHubs` un-flattens the chains of intermediate USB hubs that the
/// default view hides. All three default off, matching the GUI sidebar.
private struct CLIRequest {
    enum Format {
        case pretty(forceColor: Bool?)
        case json
        case simple
    }
    let format: Format
    let showBuses: Bool
    let showAll: Bool
    let showHubs: Bool

    static func from(_ argv: [String]) -> CLIRequest? {
        var pretty = false
        var json = false
        var simple = false
        var showBuses = false
        var showAll = false
        var showHubs = false
        var forceColor: Bool? = nil
        for arg in argv.dropFirst() {
            switch arg {
            case "--pretty", "--dump", "-p": pretty = true
            case "--json", "-j": json = true
            case "--simple", "-s": simple = true
            case "--buses", "-b": showBuses = true
            case "--all", "-a": showAll = true
            case "--hubs", "--show-hubs": showHubs = true
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
                  --hubs            Show intermediate USB hubs. By default the
                                    sidebar/tree hides cascaded hub chains and
                                    promotes their leaf devices up so dock
                                    internals don't bury what's attached.
                                    Ignored by --simple.
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
        if simple { return CLIRequest(format: .simple, showBuses: showBuses, showAll: showAll, showHubs: showHubs) }
        if json { return CLIRequest(format: .json, showBuses: showBuses, showAll: showAll, showHubs: showHubs) }
        if pretty { return CLIRequest(format: .pretty(forceColor: forceColor), showBuses: showBuses, showAll: showAll, showHubs: showHubs) }
        return nil
    }
}

/// Stable window identifiers used by `openWindow(id:)` from the More
/// menu. Centralised so the menu and the scene definitions agree.
enum PortScopeWindowID {
    static let simplifiedTopology = "io.zenla.portscope.simplifiedTopology"
    static let detailedTopology   = "io.zenla.portscope.detailedTopology"
    static let hardwareSensors    = "io.zenla.portscope.hardwareSensors"
}

/// The original SwiftUI App, now reached via `PortScopeApp.main()` from
/// the `PortScopeMain` entry point above when no CLI dump flag is passed.
struct PortScopeApp: App {
    /// One shared view model across every window — the main inspector,
    /// the topology windows, and the sensors window all read the same
    /// snapshot + selection state. Lifted from ContentView so it
    /// outlives the main window's lifecycle and so secondary windows
    /// can pull it from the environment without re-scanning.
    @StateObject private var vm = PortScopeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
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

        // Secondary windows — opened via the More menu in SidebarView.
        // Each is a single Window (not a WindowGroup), so re-opening
        // brings the existing one to the front instead of spawning a
        // duplicate. They share the main window's view model via the
        // environment so they always see the latest snapshot.
        //
        // `restorationBehavior(.disabled)` keeps these out of macOS's
        // window-state restoration: if the user quit with one of them
        // open, the next launch starts with the main inspector only,
        // and the secondary window stays closed until the user reopens
        // it from the More menu. Without this, a topology window left
        // open across quit/launch would re-appear unprompted on every
        // start.

        Window("Simplified Thunderbolt Topology",
               id: PortScopeWindowID.simplifiedTopology) {
            SimplifiedTopologyWindowHost()
                .environmentObject(vm)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("Detailed Thunderbolt Topology",
               id: PortScopeWindowID.detailedTopology) {
            DetailedTopologyWindowHost()
                .environmentObject(vm)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("Hardware Sensors",
               id: PortScopeWindowID.hardwareSensors) {
            HardwareSensorsView()
                .environmentObject(vm)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Window hosts

/// Adapter that reads the shared view model from the environment so the
/// simplified Thunderbolt topology window always renders against the
/// latest snapshot.
private struct SimplifiedTopologyWindowHost: View {
    @EnvironmentObject private var vm: PortScopeViewModel
    var body: some View {
        DiagramView(snapshot: vm.snapshot)
    }
}

/// Same wrapper for the detailed topology window.
private struct DetailedTopologyWindowHost: View {
    @EnvironmentObject private var vm: PortScopeViewModel
    var body: some View {
        DetailedThunderboltTopologyView(snapshot: vm.snapshot)
    }
}

/// The Preferences window. Houses persistent toggles that gate which
/// sidebar sections are visible.
private struct SettingsView: View {
    @AppStorage(SidebarVisibility.showBusesKey) private var showBuses: Bool = true
    @AppStorage(SidebarVisibility.showAllDevicesKey) private var showAllDevices: Bool = false
    @AppStorage(SidebarVisibility.showIntermediateHubsKey) private var showIntermediateHubs: Bool = false
    @AppStorage(SidebarVisibility.showBuiltinDevicesKey) private var showBuiltinDevices: Bool = true

    var body: some View {
        Form {
            Toggle("Show Hardware Buses", isOn: $showBuses)
            Text("Show the raw Thunderbolt, USB, and PCIe bus trees in the sidebar. On by default. The Physical Ports section is always visible.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show All Devices", isOn: $showAllDevices)
                .padding(.top, 8)
            Text("Also show Bluetooth, Displays, and Internal Hardware in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show Built-in Devices", isOn: $showBuiltinDevices)
                .padding(.top, 8)
            Text("Show the internal battery and built-in display in the Physical Device section. On by default — turn off to focus the list on receptacles you can plug into.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show Intermediate Hubs & Bridges", isOn: $showIntermediateHubs)
                .padding(.top, 8)
            Text("Show the full chain of cascaded USB hubs (dock internals, hub-of-hubs) and the Thunderbolt PCIe Slot bridges under each TB-capable port. By default these are flattened away so leaf devices appear directly under the port they're attached to and idle PCIe slots are hidden.")
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
    /// Gates Thunderbolt / USB / PCIe sections (the bus trees). Default
    /// ON — these are the raw IOKit-derived hierarchies most users
    /// actually want when they launch a hardware-inspector. Toggle off
    /// to focus on the high-level Physical Ports view.
    static let showBusesKey = "showBuses"
    /// Gates Displays / Bluetooth / Internal Hardware. Default off.
    static let showAllDevicesKey = "showAllDevices"
    /// When off (the default), USB hubs in the sidebar are treated as
    /// pass-through wrappers (like `.other` IOService kexts): their non-hub
    /// descendants are promoted up so cascaded dock internals don't bury the
    /// actual leaf devices. PCIe attribution under each physical port is
    /// flattened the same way — only leaf `.endpoint` devices are
    /// surfaced, and idle "Thunderbolt PCIe Slot" bridges are hidden. Flip
    /// on to see the raw hub-of-hubs chain AND the PCIe slot bridge with
    /// its full subtree under each TB-capable port.
    static let showIntermediateHubsKey = "showIntermediateHubs"
    /// Gates the chassis-built-in non-port devices in the Physical Device
    /// section: the internal battery (laptops) and the built-in display
    /// (laptop lid / iMac panel). Default ON — these are part of the
    /// chassis the user is looking at, so they belong in the default
    /// view. Toggle off to focus the list on receptacles you can plug
    /// into.
    static let showBuiltinDevicesKey = "showBuiltinDevices"
}

extension Notification.Name {
    static let portScopeRefresh = Notification.Name("io.zenla.portscope.refresh")
}
