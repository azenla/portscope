# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Boltprobe is a macOS-only SwiftUI app (target `macOS 26.5`, Swift 5, default actor isolation = `MainActor`) that introspects the host's hardware buses via IOKit. The original focus was Thunderbolt — controllers, routers (switches), ports, adapters, downstream PCIe/USB devices, hop tables / tunnels, and bandwidth allocations — and it has since expanded to a full USB explorer (host controllers, hubs, devices, interfaces with bandwidth / speed / class info), a unified **Physical Ports** view that reports each USB-C port's live operating mode, and **per-receptacle accessory state** pulled from `IOAccessoryManager` (active transports CC / USB 2 / USB 3 / CIO / DisplayPort, USB-PD voltage and current, plug orientation, displayport HPD, cable e-marker VID/PID/manufacturer).

## Build / run

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — **just drop new `.swift` files anywhere under `Boltprobe/` and they're picked up automatically**, no `project.pbxproj` editing needed.

```sh
xcodebuild -project Boltprobe.xcodeproj -scheme Boltprobe -configuration Debug -destination 'platform=macOS' build
```

Built bundle lives under `~/Library/Developer/Xcode/DerivedData/Boltprobe-*/Build/Products/Debug/Boltprobe.app`. Launch with `open path/to/Boltprobe.app`. There are no tests.

## Entitlements

`Boltprobe/Boltprobe.entitlements` sets `com.apple.security.app-sandbox = false`. The sandbox is intentionally **off** so `IOServiceAddMatchingNotification` and full IOKit registry reads work. Don't re-enable `ENABLE_APP_SANDBOX` in `project.pbxproj` without also moving everything that touches IOKit into a helper or exception list — TB hot-plug notifications break under the sandbox.

## Architecture

Data flow is one direction: **IOKit → Scanners → SystemSnapshot → View Model → SwiftUI views**. There are three scanners (Thunderbolt, USB, Accessory). TB and USB produce `TBNode` trees through a single shared builder + formatter so node metadata stays consistent; the accessory scanner is shape-different (one struct per physical receptacle, not a tree) and gets merged into `PhysicalPort` by `TopologyMapper`.

### Services

- `Services/IORegBridge.swift` — generic IOKit shim. Converts CF types (`CFString`, `CFNumber`, `CFData`, `CFArray`, `CFDictionary`, `CFBoolean`) into the `IORegValue` enum so the rest of the app stays Foundation-only. Also wraps `io_name_t` reads, `IORegistryEntryCreateCFProperties`, child/parent traversal, and class matching. Anything that calls `IOServiceMatching` / `IORegistryEntryGetChildIterator` lives here.

- `Services/NodeFormatter.swift` — **central source of truth for classify / label / preferred-order logic**. `classify(_:)` maps IOKit class names to `TBNodeKind`; `refineKind(_:props:)` flips `.usbDevice` → `.usbHub` when `bDeviceClass == 0x09`; `makeLabels(...)` produces human title/subtitle; `preferredOrder(for:keys:)` returns the property-key ordering used in the Developer details table. Both scanners go through this — **don't add classify/label logic in the scanners themselves**.

- `Services/NodeBuilder.swift` — recursive `IORegistry entry → TBNode tree` builder. Used by both `ThunderboltScanner` and `USBScanner`. Children are sorted by `Port Number` (when present), then title.

- `Services/ThunderboltScanner.swift` — matches `IOThunderboltController`, recurses through children via `NodeBuilder`, produces a `TBSnapshot`. Also collects PCIe/USB devices whose IOService-plane ancestor chain crosses a TB switch with `Depth > 0` (the external-device heuristic) into flat `pcieDevicesOverTB` / `usbDevicesOverTB` lists.

- `Services/USBScanner.swift` — matches `IOUSBHostController` / `AppleUSBHostController` / `IOUSBController`, dedupes by entry ID, recurses via `NodeBuilder`, produces a `USBSnapshot`. **For each controller, walks parents looking for a `IOThunderboltSwitch` ancestor and records the mapping in `USBSnapshot.tbContext: [TBNodeID: TBNodeID]`** so USB detail views can cross-link into the TB tree (used by `TBLinkCard`).

- `Services/AccessoryScanner.swift` — matches `AppleHPMInterfaceType10` (one instance per physical USB-C / MagSafe receptacle), reads per-port runtime state from `IOAccessoryManager`, and walks the port's `Power In → USB-PD` children to capture USB-PD `WinningPowerSourceOption` + offered PDOs and the Apple "Brick ID" PDO when a charger is identifying itself. Returns `[PortAccessoryInfo]` sorted by `PortNumber`. **This is the only place the app touches IOAccessory plane data**; it surfaces signal information (active transports, plug orientation, displayport HPD, cable e-marker VID/PID/manufacturer string) that is invisible to the Thunderbolt and USB IOKit families.

- `Services/IORegMonitor.swift` — hot-plug notifications. Registers `IOServiceAddMatchingNotification` for both `kIOMatchedNotification` and `kIOTerminatedNotification` against TB controller/switch/port/local-node/USB-Type-2-adapter classes, `IOUSBHostController` / `IOUSBHostDevice`, **and `AppleHPMInterfaceType10`** (so cable insertions, USB-PD renegotiation, and alt-mode entry all fire a rescan). Then posts a debounced `Notification.Name` that triggers `BoltprobeViewModel.rescan()`.

- `Services/TopologyMapper.swift` — derives the **simplified user-facing topology** (`PhysicalPort` → optional `ConnectedDevice` → daisy-chained devices) from a snapshot. Each `PhysicalPort` carries an inferred `mode: PhysicalPortMode` (`.thunderbolt(speed)` / `.usbOnly(speed?)` / `.empty` / `.unknown`), the flat list of `attachedUSBDevices` reachable through the port's connected router, `tunnels: [PortTunnel]` summarising DP/USB/PCIe reserved+max bandwidth, and an optional `accessory: PortAccessoryInfo` for the receptacle's HPM state.

  Knows about Apple-Silicon specifics: each TB host controller maps to one physical USB-C port (the controller's root switch has paired lane adapters on Port@1/@2 that form one dual-link physical port), and the dock switch is **two** levels below the host's lane adapter (`host lane → peer lane → dock switch`), so `downstreamSwitch(of:)` BFS-descends through peer-port wrappers to find it.

  **Numbering** comes from `AppleHPMInterfaceType10.PortNumber` when accessory data is available (1, 2, 3 as etched on the chassis). The HPM-to-TB-controller pairing is a two-pass heuristic: ports with `TransportsActive` containing `CIO` first claim a TB controller that has a downstream router; remaining HPM ports get the leftover controllers in order. Without HPM data (e.g. on Intel hosts) the mapper falls back to TB-controller iteration order.

### Models

- `Models/TBModels.swift` — `TBNode` (one entry in the topology tree, identifiable by IORegistry entry ID), `TBNodeKind` (covers TB and USB kinds: `.controller`, `.switch`, `.port`, `.usbController`, `.usbHub`, `.usbDevice`, `.usbInterface`, `.appleFabric`, etc.), `TBAdapterType`, `TBSnapshot`. Also the shared TB formatters: `tbLinkSpeedLabel`, `tbGenerationShortLabel`, `tbBandwidthLabel`. **`TBNode` is used for any IOKit-derived entity, not just TB** — the name predates the USB expansion.

- `Models/USBModels.swift` — `USBSpeed` (with `rateMbps`, `rateLabel`, `accentColor`), `USBDeviceClass`, formatters (`usbSpeedLabel`, `usbBcdVersion`, `usbDeviceClassLabel`), `USBSnapshot` (with `tbContext` map), `PhysicalPortMode`, and the top-level **`SystemSnapshot { tb, usb, accessories, capturedAt }`** that the view model owns.

- `Models/AccessoryModels.swift` — `PortAccessoryInfo` (per-physical-receptacle struct), `USBPDProfile` (winning + offered + brick-ID PDOs), `USBPDOption` (a single fixed-voltage PDO with volt / current / power labels), `USBCTransport` (`.cc / .usb2 / .usb3 / .cio / .displayPort / .other`), `PlugOrientation`, `AccessoryConnection` ("Device" / "Host" / "Audio Adapter" / "Debug" / none), `PortConnectorType` (`.usbC / .magsafe / .other`), and `displayPortPinAssignmentLabel(_:)` for the USB-IF Type-C alt-mode pin assignments A..F.

  `PhysicalPortMode` (in `USBModels.swift`) is `.empty | .thunderbolt(linkSpeed) | .usbOnly(speed?) | .displayOnly | .unknown` — `.displayOnly` is used when a port is carrying only DisplayPort alt-mode (no TB tunnel, no USB SuperSpeed pair active).

### ViewModel

- `ViewModels/BoltprobeViewModel.swift` — `@MainActor ObservableObject`. Owns the `SystemSnapshot`, runs both scanners off-main via `Task.detached`, debounces hot-plug rescans, and exposes selection plus `node(for:)` / `parent(of:)` lookups. `selectionRoots` walks **TB controllers + USB controllers + TB-tunneled PCIe/USB flat lists**, so both sidebar trees resolve.

  **`PhysicalPortSelector`** (also in this file) mints synthetic `TBNodeID`s (high bits `0xC0DE_C0DE_…`) for "Physical Port N" sidebar rows so they don't collide with real registry entry IDs. `ContentView` checks `PhysicalPortSelector.portNumber(id)` first when dispatching the detail view.

### Views

- `Views/SidebarView.swift` — three-section nav:
  1. **Physical Ports** — rows labelled `USB-C Port N` with a mode-coloured icon and live status (`Thunderbolt · TB5 · ×2`, `USB · USB 3.0`, `Empty`). Expanding reveals the connected TB device and up to 6 USB devices reachable through that port.
  2. **Thunderbolt** — TB host controllers each expand into the full raw tree via `FullTopologyRow`. The controller's own row carries an enriched subtitle (`Connected · <vendor> <model>` when a depth>0 router lives downstream, else `No external device`) and auto-expands when an external host is attached. Both the controller row and the deeper rows share the file-scope `promotedChildren(of:)` helper, which drops `.other` wrapper kexts (DPConnectionManager / IPService / IOService shims) and recursively promotes their meaningful descendants up — so nothing in the IOKit tree is hidden.
  3. **USB** — USB host controllers expand into hubs/devices. `.usbInterface` and `.other` children are hidden in this section to keep it clean (interfaces appear in the device's detail view).

- `Views/DetailView.swift` — kind-specific summary cards. Dispatches on `TBNodeKind`: `.controller` → `ControllerView`, `.switch` → `RouterView`, `.port` → `PortView`, `.usbController` → `USBControllerView`, `.usbHub` → `USBHubView`, `.usbDevice` → `USBDeviceView`, `.usbInterface` → `USBInterfaceView`. Hosts the **`Developer details` disclosure** at the bottom that embeds `PropertyTableView` for the raw IORegistry dump. Receives both a `parentLookup` closure (for `RouterView.findUpstreamLane()`) and a **`tbContextForUSB`** closure that resolves a USB controller's TB switch ancestor; `DetailView.ancestorTBContext(for:)` walks parents to find the enclosing USB controller, then queries the closure.

- `Views/USBViews.swift` — `USBControllerView` / `USBHubView` / `USBDeviceView` / `USBInterfaceView`, plus shared building blocks: `USBLinkRateCard` (log-scale capsule bar so 1.5 Mb/s isn't invisible against 20 Gb/s), `TBLinkCard` (cross-link button into the TB tree when `tbContext` is non-nil), `USBDeviceTreeCard`, `USBDeviceRow`, `InterfacesCard`.

- `Views/PhysicalPortDetailView.swift` — shown when the selection is a `PhysicalPortSelector` synthetic ID. Hero header with mode badge + accessory badges (display / active cable / optical / plug count) + a USB-PD wattage callout in the top-right when power is flowing. Stat grid (operating mode, link speed, lane width, link capacity, power-in, plug orientation, TB device count, USB device count), mode-explanation prose, TB bandwidth bar in TB mode, **Active Transports** card with chips for CC / USB 2 / USB 3 / Thunderbolt-USB4 / DisplayPort showing active vs provisioned vs supported, **Connector & Cable** card with cable type + e-marker VID/PID/manufacturer + lifetime plug & overcurrent counts, **USB Power Delivery** card with a big winning-PDO display + full PDO table (winner marked with a yellow checkmark), **DisplayPort Alt-Mode** card with HPD state and pin-assignment label, then the existing tunnels / USB / connected-TB-device / Jump-to cards.

- `Views/DiagramView.swift` — sheet-based visual topology. Takes a full `SystemSnapshot` and iterates `TopologyMapper.physicalPorts(from:)` so port numbering and mode info come from the same source as the sidebar. Uses SwiftUI's `anchorPreferences` pattern: every node (`MacBlock`, `PortBox`, `RouterBox`, `AdapterGroupRow`) reports its bounds via `.diagramAnchor(id)`, then the container's `backgroundPreferenceValue(NodeAnchorKey)` reads those anchors and draws connection lines and per-category tunnel paths. `PortBox` label says `USB-C Port N`; rendering still focuses on the TB side — USB-only ports show an empty/connected box but no router or tunnel paths.

- `Views/PropertyTableView.swift` — generic key/value renderer for the Developer-details disclosure. Filterable, expandable rows for `Data`/array/dict values, includes a hex+ASCII dump for `Data`. Uses `TBNode.formatValue(_:_:)` which knows how to pretty-print both TB keys (`Adapter Type`, `Link Bandwidth`, `Current Link Speed`) and USB keys (`bcdUSB`, `bDeviceClass`, `Device Speed`, `idVendor`, `idProduct`).

## Things that bit me — read before "fixing"

- **`Adapter Type` integer codes vary by chip vendor.** Apple's `IOThunderboltSwitchType7` uses one encoding; Intel's `IOThunderboltSwitchIntelJHL9580` (in third-party TB5 docks) **swaps the codes for DP/HDMI and PCIe**. Don't categorize adapters by `Adapter Type`. Use the kernel's `Description` string (`"PCIe Adapter"`, `"DP or HDMI Adapter"`, `"USB Adapter"`, `"USB Gen T Adapter"`, `"Thunderbolt Port"`, `"Port is inactive"`, `"Thunderbolt Native Host Interface Adapter"`) — it's authoritative across all vendors. `TBAdapterType` (Apple-encoded) is still around but is for labelling only, not categorisation.

- **Bandwidth fields are in 100 Mb/s units, not 10 Mb/s.** `Link Bandwidth = 800` is 80 Gb/s, `= 1200` is 120 Gb/s (TB5 asymmetric tx). `tbBandwidthLabel(raw)` divides by 10 — don't change it.

- **The host's "upstream lane adapter for the dock" is the *parent* of the dock switch in the IOService plane, not one of its children.** `RouterView` calls `parentLookup(node.id)` and walks up looking for a port whose `Description` is `"Thunderbolt Port"`. Aggregating `Required Bandwidth Allocated` across the dock's own lane-adapter children gives the wrong answer (it sees the dock's downstream TB ports, not the host uplink).

- **Recursive SwiftUI `some View` functions don't compile** — Swift can't infer the opaque type when a function returns `some View` and recursively contains itself. Use a separate struct instead (see `SidebarNodeRow`, `FullTopologyRow`, `DeviceBranch`, `PortBranch`).

- **`Sendable` won't synthesise on `IORegValue`** because `case dictionary([(String, IORegValue)])` uses a tuple-in-array that doesn't conform. The data types deliberately don't claim `Sendable`; everything is used on `@MainActor` (or the scanner copies values into the snapshot before bouncing back to main).

- **Don't show IOKit class names or IORegistry entry IDs in the main UI.** The user view should read like a Thunderbolt utility, not an ioreg viewer. Class names, raw `Adapter Type` numbers, `IOClass`/`IOProviderClass`, registry paths, etc. belong in the Developer details disclosure only. Specifically: `AppleT8142USBXHCI` → "Thunderbolt USB 3.1 Controller", `AppleT6050USBXHCIAUSS` → "Internal USB 4.0 Controller", `IOThunderboltControllerType7.Generation = 45` is a kernel revision number not a TB spec generation — don't surface it. `NodeFormatter.controllerFriendlyName` keys off the `IONameMatch` token (`usb-drd,t8142` / `usb-auss,t6050`) + `UsbHostControllerProtocolRevision` string, not the class name.

- **`SOPVID` / `SOPPID` come back as 2-byte little-endian `Data` blobs**, not numbers. `AccessoryScanner.readDataAsUInt` parses them; don't assume `IORegValue.asUInt` will work for these keys. They identify the USB-PD SOP partner (the cable's e-marker chip, or the attached device if there's no e-marker).

- **`Transports*` arrays are arrays of strings.** Members observed so far: `"CC"` (USB-PD configuration channel), `"USB2"`, `"USB3"`, `"CIO"` (cooperative I/O — the bundle carrying Thunderbolt / USB4), `"DisplayPort"`. `USBCTransport.init(_:)` maps the strings; anything unrecognised falls into `.other(String)` so the chip row still renders it.

- **Don't trust port number = TB controller iteration order.** On Apple Silicon the canonical physical port number lives in `AppleHPMInterfaceType10.PortNumber` (1, 2, 3 as labelled on the chassis), and the TB controllers come back in an unrelated order. `TopologyMapper.physicalPorts(from: SystemSnapshot)` pairs them by a two-pass heuristic (CIO-active HPM ports first claim TB controllers with downstream devices); when accessory data is absent the mapper falls back to TB-controller iteration order with a warning that numbering may not match chassis labels.

- **TB-tunneled USB controllers appear in two trees.** A `IOUSBHostController` that lives beneath a `IOThunderboltSwitch` shows up both (a) as a deep descendant inside the TB controller's tree and (b) as a top-level controller in `USBSnapshot.controllers`. They share the same `TBNodeID`. This is intentional — each view surfaces the right context. The cross-link from the USB side is built by `USBScanner` recording `tbContext[usbControllerID] = tbSwitchID` at scan time; `DetailView.ancestorTBContext(for:)` walks parents from any USB hub/device up to its enclosing controller to look it up.

- **Add new IOKit-classifiable kinds in `NodeFormatter.classify`, not the scanners.** Both scanners use `NodeBuilder.build` which calls into `NodeFormatter`. Adding a kind in only one scanner means the other won't recognise it. Same for `makeLabels` and `preferredOrder` — they live in `NodeFormatter` and dispatch on `TBNodeKind`, not class name.

- **USB host controllers wrap every port in an `.other` kext (`AppleUSB20XHCIARMPort`, `AppleUSB30XHCIARMPort`).** Real `IOUSBHostDevice` nodes are the *children* of those wrappers, not direct children of the controller. A flat `filter { $0.kind != .other }` drops the wrapper *and* the device with it — the same trap exists below every hub (`AppleUSB20Hub → AppleUSB20HubPort → IOUSBHostDevice`). The sidebar uses `promotedUSBChildren(of:)` to recurse through wrappers; do the same anywhere you walk a USB subtree.

- **USB devices on a TB-tunneled dock are NOT children of the dock's TB switch.** On Apple Silicon the dock's USB hub appears as a regular `IOUSBHostDevice` enumerated under the host's per-port `usb-drd<N>` xHCI (`AppleT*USBXHCI` with `IONameMatch = "usb-drd,…"`). Walking the dock's `IOThunderboltSwitch` children finds zero USB devices — there's no PCIe-tunneled xHCI under the switch in IOService plane, only the lane and adapter ports. `TopologyMapper.usbDevicesByPort(in:)` instead maps each `usb-drd<N>` controller to a physical port via `locationID >> 24` (drd0 → Port 1, drd1 → Port 2, drd2 → Port 3). The Internal USB 4.0 controller (`IONameMatch = "usb-auss,t6050"`) is the FaceTime cam / internal jacks and doesn't belong to a chassis port — filter it out.

- **TB function adapters often report `Required Bandwidth Allocated = 1` on an active tunnel.** That's 100 Mb/s — a placeholder, not an actual reservation. DP adapters in particular don't statically reserve TB bandwidth (the stream is allocated dynamically). `Maximum Bandwidth Allocated` carries the planned bandwidth for USB/PCIe but is also 1 for DP. The authoritative "tunnel is up" signal is `Hop Table` being non-empty. `AdapterChip` renders such adapters as "Active" instead of misleading "100 Mb/s" — don't add bandwidth bars or numeric labels for function adapters without checking `max(required, maxAlloc) >= 10` first.

- **`PhysicalPortMode.usbOnly` wins over `.displayOnly` whenever any USB pair is active.** A 5-in-1 USB-C hub drives DisplayPort *and* a USB hub simultaneously; `TransportsActive` in that case is `("CC","USB2","DisplayPort")`. Don't gate the USB classification on `usb3` alone — many hubs (Anker, UGREEN) enumerate over USB 2.0. `modeFromAccessory` checks `usb2 || usb3 || !usbDevices.isEmpty` and only falls through to `.displayOnly` when nothing USB is present. `statusLabel` appends `+ DP` to the USB label when `accessory.carriesDisplay` is true, so the sidebar still tells the user a display is attached.

- **Physical Port sidebar rows use synthetic IDs.** `PhysicalPortSelector` packs the port number into the high bits of a `TBNodeID` so the row tag doesn't collide with real registry entry IDs. `ContentView.detail` checks `PhysicalPortSelector.portNumber(sel)` *first* and dispatches to `PhysicalPortDetailView` before falling through to `vm.node(for: sel)` and the regular `DetailView`. Don't reuse the lane adapter's ID here — that selection should navigate to the lane adapter's `PortView`, not the unified port view.
