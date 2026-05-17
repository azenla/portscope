# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Boltprobe is a macOS-only SwiftUI app (target `macOS 26.5`, Swift 5, default actor isolation = `MainActor`) that introspects the host's Thunderbolt subsystem via IOKit. It enumerates controllers, routers (switches), ports, adapters, downstream PCIe/USB devices, hop tables / tunnels, and bandwidth allocations.

## Build / run

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — **just drop new `.swift` files anywhere under `Boltprobe/` and they're picked up automatically**, no `project.pbxproj` editing needed.

```sh
xcodebuild -project Boltprobe.xcodeproj -scheme Boltprobe -configuration Debug -destination 'platform=macOS' build
```

Built bundle lives under `~/Library/Developer/Xcode/DerivedData/Boltprobe-*/Build/Products/Debug/Boltprobe.app`. Launch with `open path/to/Boltprobe.app`. There are no tests.

## Entitlements

`Boltprobe/Boltprobe.entitlements` sets `com.apple.security.app-sandbox = false`. The sandbox is intentionally **off** so `IOServiceAddMatchingNotification` and full IOKit registry reads work. Don't re-enable `ENABLE_APP_SANDBOX` in `project.pbxproj` without also moving everything that touches IOKit into a helper or exception list — TB hot-plug notifications break under the sandbox.

## Architecture

Data flow is one direction: **IOKit → Scanner → Snapshot → View Model → SwiftUI views**.

- `Services/IORegBridge.swift` — generic IOKit shim. Converts CF types (`CFString`, `CFNumber`, `CFData`, `CFArray`, `CFDictionary`, `CFBoolean`) into the `IORegValue` enum so the rest of the app stays Foundation-only. Also wraps `io_name_t` reads, `IORegistryEntryCreateCFProperties`, child/parent traversal, and class matching. Anything that calls `IOServiceMatching` / `IORegistryEntryGetChildIterator` lives here.

- `Services/ThunderboltScanner.swift` — IOKit walker. Matches `IOThunderboltController`, recurses through children, and produces a `TBNode` tree per controller. Also collects PCIe/USB devices whose IOService-plane ancestor chain crosses a TB switch with `Depth > 0` (the external-device heuristic). The scanner does kind classification (`classify(class:)`) and label generation (`makeLabels(...)`) — kept here so the views never need to know IOKit class names.

- `Services/IORegMonitor.swift` — hot-plug notifications. Registers `IOServiceAddMatchingNotification` for both `kIOMatchedNotification` and `kIOTerminatedNotification` against TB controller/switch/port/local-node/USB-Type-2-adapter classes, then posts a debounced `Notification.Name` that triggers `BoltprobeViewModel.rescan()`.

- `Services/TopologyMapper.swift` — derives the **simplified user-facing topology** (`PhysicalPort` → optional `ConnectedDevice` → daisy-chained devices) from the raw `TBSnapshot`. Knows about Apple-Silicon specifics: each TB host controller maps to one physical USB-C port (the controller's root switch has paired lane adapters on Port@1/@2 that form one dual-link physical port), and the dock switch is **two** levels below the host's lane adapter (`host lane → peer lane → dock switch`), so `downstreamSwitch(of:)` BFS-descends through peer-port wrappers to find it.

- `Models/TBModels.swift` — `TBNode` (one entry in the topology tree, identifiable by IORegistry entry ID), `TBNodeKind`, `TBAdapterType`, `TBSnapshot`. Also the shared formatters: `tbLinkSpeedLabel`, `tbGenerationShortLabel`, `tbBandwidthLabel`.

- `ViewModels/BoltprobeViewModel.swift` — `@MainActor ObservableObject`. Owns the snapshot, runs the scanner off-main via `Task.detached`, debounces hot-plug rescans, and exposes selection plus `node(for:)` / `parent(of:)` lookups so the detail view can walk parents.

- `Views/SidebarView.swift` — two-tier nav. Top section ("Thunderbolt Ports") renders the simplified `PhysicalPort → ConnectedDevice` view from `TopologyMapper`. Below it is a "Full Topology" disclosure that renders the raw IOKit tree, **with `kind == .other` wrapper nodes filtered out and their meaningful descendants promoted up** (so `IOEthernetInterface` shows directly under `Local Node` rather than nested inside `AppleThunderboltIPService` → `AppleThunderboltIPPort` → ...).

- `Views/DetailView.swift` — kind-specific summary cards (controller / router / port / etc.), bandwidth bar with overage warning, link-negotiation grid, active-tunnel rows. Hosts the **`Developer details` disclosure** at the bottom that embeds `PropertyTableView` for the raw IORegistry dump. The view is given a `parentLookup` closure to find the upstream lane adapter (which lives *above* the dock switch in the tree, not in its children — see `RouterView.findUpstreamLane()`).

- `Views/DiagramView.swift` — sheet-based visual topology. Uses SwiftUI's `anchorPreferences` pattern: every node (`MacBlock`, `PortBox`, `RouterBox`, `AdapterGroupRow`) reports its bounds via `.diagramAnchor(id)`, then the container's `backgroundPreferenceValue(NodeAnchorKey)` reads those anchors and draws connection lines and per-category tunnel paths.

- `Views/PropertyTableView.swift` — generic key/value renderer for the Developer-details disclosure. Filterable, expandable rows for `Data`/array/dict values, includes a hex+ASCII dump for `Data`.

## Things that bit me — read before "fixing"

- **`Adapter Type` integer codes vary by chip vendor.** Apple's `IOThunderboltSwitchType7` uses one encoding; Intel's `IOThunderboltSwitchIntelJHL9580` (in third-party TB5 docks) **swaps the codes for DP/HDMI and PCIe**. Don't categorize adapters by `Adapter Type`. Use the kernel's `Description` string (`"PCIe Adapter"`, `"DP or HDMI Adapter"`, `"USB Adapter"`, `"USB Gen T Adapter"`, `"Thunderbolt Port"`, `"Port is inactive"`, `"Thunderbolt Native Host Interface Adapter"`) — it's authoritative across all vendors. `TBAdapterType` (Apple-encoded) is still around but is for labelling only, not categorisation.

- **Bandwidth fields are in 100 Mb/s units, not 10 Mb/s.** `Link Bandwidth = 800` is 80 Gb/s, `= 1200` is 120 Gb/s (TB5 asymmetric tx). `tbBandwidthLabel(raw)` divides by 10 — don't change it.

- **The host's "upstream lane adapter for the dock" is the *parent* of the dock switch in the IOService plane, not one of its children.** `RouterView` calls `parentLookup(node.id)` and walks up looking for a port whose `Description` is `"Thunderbolt Port"`. Aggregating `Required Bandwidth Allocated` across the dock's own lane-adapter children gives the wrong answer (it sees the dock's downstream TB ports, not the host uplink).

- **Recursive SwiftUI `some View` functions don't compile** — Swift can't infer the opaque type when a function returns `some View` and recursively contains itself. Use a separate struct instead (see `SidebarNodeRow`, `FullTopologyRow`, `DeviceBranch`, `PortBranch`).

- **`Sendable` won't synthesise on `IORegValue`** because `case dictionary([(String, IORegValue)])` uses a tuple-in-array that doesn't conform. The data types deliberately don't claim `Sendable`; everything is used on `@MainActor` (or the scanner copies values into the snapshot before bouncing back to main).

- **Don't show IOKit class names or IORegistry entry IDs in the main UI.** The user view should read like a Thunderbolt utility, not an ioreg viewer. Class names, raw `Adapter Type` numbers, `IOClass`/`IOProviderClass`, registry paths, etc. belong in the Developer details disclosure only.
