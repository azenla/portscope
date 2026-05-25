# CLAUDE.md

Guidance for Claude Code working in this repo.

## Project

PortScope is a macOS-only SwiftUI app (target `macOS 26.5`, Swift 5, default actor isolation `MainActor`) that introspects host hardware buses via IOKit. Covers Thunderbolt (controllers / routers / ports / adapters / hop tables / tunnels / bandwidth), USB (controllers / hubs / devices / interfaces), and a unified **Physical Device** sidebar section organised into labelled subgroups: a **Power** subgroup at the top (Internal Battery + MagSafe + the desktop AC PSU, whichever exist on this host), then USB-C, USB-A, HDMI, SD Card, and Ethernet — each with their own collapsible subheader. Per-receptacle data comes from `IOAccessoryManager` (transports, USB-PD voltage/current, plug orientation, DisplayPort HPD, cable e-marker) plus dedicated scanners for the non-USB-C receptacles. **Power Input** always means power entering the Mac (USB-PD sink on laptops via `IOPortFeaturePowerIn`, or `AppleSmartBattery.PowerTelemetryData` on desktops); **Power Output** always means power the Mac is sourcing to attached devices (per-device sink allocations + xHCI port wrappers). Use those terms consistently in CLI and UI. **Displays / Bluetooth / PCIe / Internal Hardware** are separate top-level sections gated by Settings toggles. HDMI and SD Card receptacles are always rendered on chassis that ship them; their *operating mode* reflects attachment (HDMI: `ConnectionActive` / `HDMI_HPD` / live DisplayPort transport; SD: `IOMedia` descendant under `pcie-sdreader`). Per-receptacle chassis labels (e.g. "Right Front USB-C Port · Thunderbolt 5") come from a static catalogue keyed by `hw.model` (see "Adding a new Mac model" below).

Inside each USB-C / USB-A port, the sidebar also nests **what's attached** to that receptacle so the user doesn't have to cross-reference the top-level Displays / etc. sections. External displays attributed to the port hang off each active DP/HDMI function adapter on the dock's TB router (`Display Output 1 · DP / HDMI · adapter port 12`); USB-Ethernet adapters surface a synthesised Ethernet card on the port detail (BSD name, MAC, link speed, driver kext) so the user doesn't have to dig through `IOUSBHostDevice → IOUSBHostInterface → driver kext → IOEthernetInterface` to read live state. The display↔port attribution is a heuristic (see `displaysAttributed(to:allPorts:allDisplays:)` in `Models/DisplayModels.swift`) because the IOService plane doesn't expose a clean link on Apple Silicon — strict topology isn't the goal; surfacing what's there is.

## Build / run

Xcode project uses `PBXFileSystemSynchronizedRootGroup` — **just drop new `.swift` files anywhere under `PortScope/`**, no `project.pbxproj` editing.

```sh
xcodebuild -project PortScope.xcodeproj -scheme PortScope -configuration Debug -destination 'platform=macOS' build
```

Bundle lives under `~/Library/Developer/Xcode/DerivedData/PortScope-*/Build/Products/Debug/PortScope.app`. Tests live in `PortScopeTests/` (Swift Testing — formatters, catalogue integrity, BCD/speed mapping, etc.) and `PortScopeUITests/` (XCUITest a11y-element smoke checks). Run with `xcodebuild … test -only-testing:PortScopeTests` for fast iteration.

## CLI dump mode — use this to check your assumptions

The app binary is **dual-mode**. No args → GUI; `--pretty` / `--json` → runs the same scanners synchronously, prints to stdout, exits. **Prefer this over `ioreg` / `system_profiler`** — it goes through the same scanner + classifier pipeline the UI uses, so what you see is exactly what the GUI sees.

```sh
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/PortScope-*/Build/Products/Debug/PortScope.app | head -1)
BIN="$APP/Contents/MacOS/PortScope"

"$BIN" --pretty                  # physical ports only (auto TTY)
"$BIN" --pretty --buses          # + raw TB / USB / PCIe trees
"$BIN" --pretty --hubs           # un-flatten intermediate USB hubs
"$BIN" --pretty --no-color       # plain text, pipe-safe
"$BIN" --json | jq .             # physical_ports + accessories (default)
"$BIN" --json --buses | jq .     # + thunderbolt, usb, pcie
"$BIN" --json --all --buses      # everything: + bluetooth, displays, internal_hardware
"$BIN" --simple                  # tab-separated port summary, one line per receptacle
"$BIN" --simple | column -t -s$'\t'   # human-readable alignment
```

The CLI flags mirror the three Settings toggles, all default off:

- **`--buses` / `-b`** → **Show Hardware Buses**. Without it, `thunderbolt` / `usb` / `pcie` keys are absent from JSON (the pretty tree skips those sections entirely). The bare default emits only `physical_ports` + `accessories` — the user-facing roll-up.
- **`--all` / `-a`** → **Show All Devices**. Without it, `bluetooth` / `displays` / `internal_hardware` keys are absent. Independent of `--buses`. When inspecting anything internal (Wi-Fi, battery, SoC coprocessors) **don't forget `--all`**.
- **`--hubs`** → **Show Intermediate USB Hubs**. By default cascaded hub chains (dock internals where every USB-C port goes through 3–5 generic "USB2.0 Hub" rows before reaching real devices) are flattened away both in the sidebar and in the CLI tree / JSON: `.usbHub` nodes are treated as pass-through wrappers and their non-hub descendants are spliced up. Pass `--hubs` to see the raw hub-of-hubs chain. `--simple` ignores it.

Omitted keys are *absent*, not null — `jq .thunderbolt` returns `null` rather than an empty object.

Diagnostic recipes:

```sh
"$BIN" --json | jq '.physical_ports[0]'                              # port 1 summary
"$BIN" --json | jq '.accessories[0].raw_properties'                  # raw HPM props
"$BIN" --json --buses | jq '.thunderbolt.controllers[].class'        # Type5 vs Type7
"$BIN" --json --buses | jq '.usb.tb_context'                         # USB→TB cross-link map
"$BIN" --json --all   | jq '.internal_hardware.soc_coprocessors[].title'
```

When `ioreg` and the CLI dump disagree, **trust the CLI dump** — the difference between "what the kernel exposes" and "what PortScope's pipeline produces" is usually the bug.

Source: `Services/SnapshotDumper.swift` + `PortScopeApp.swift` (`PortScopeMain` enum). Don't re-add `@main` to `PortScopeApp` — `PortScopeMain.main()` decides whether to call `PortScopeApp.main()` based on argv.

## Entitlements

`PortScope/PortScope.entitlements` sets `com.apple.security.app-sandbox = false`. Sandbox is intentionally **off** so `IOServiceAddMatchingNotification`, full registry reads, and `Process` spawns (for `system_profiler`) work. Don't re-enable `ENABLE_APP_SANDBOX` without moving everything IOKit-touching into a helper — TB hot-plug notifications and Bluetooth data break under the sandbox.

## Architecture

Data flow: **IOKit → Scanners → SystemSnapshot → ViewModel → SwiftUI views**.

Ten scanners run per full refresh in `Services/`: `ThunderboltScanner`, `USBScanner`, `AccessoryScanner` (incl. HDMI via `AppleHDMIPortController`), `SDCardScanner` (synthesises a card-present accessory when `IOMedia` lives under `pcie-sdreader`), `PowerInputScanner` (synthesises a desktop AC PSU accessory from `AppleSmartBattery.PowerTelemetryData` when `BatteryInstalled = No`), `EthernetScanner` (one accessory per `IOBuiltin == true` `IOEthernetInterface` whose parent isn't TB/USB-tunneled), `InternalHardwareScanner`, `BluetoothScanner`, `DisplayScanner`, `PCIScanner`. The accessory list passed into the snapshot is `AccessoryScanner.scan() + SDCardScanner.scan() + PowerInputScanner.scan() + EthernetScanner.scan()`. TB and USB share `NodeBuilder` (recursive `IORegistry → TBNode`) and `NodeFormatter` (classify / label / preferred-key-order — **add classify/label logic here, not in scanners**). `IORegBridge` is the generic CF-to-Swift IOKit shim. `IORegMonitor` posts debounced rescan notifications on hot-plug. `TopologyMapper` derives the simplified user-facing `PhysicalPort` topology with mode inference, accessory merge-in, and `PortSourcePower` rollup. `MacPortCatalog` loads `Resources/MacPortLocations.json` once and resolves `(connector, port_number)` → chassis-relative label + capability for the running host's `hw.model`. `USBEthernetSynth` walks a USB device subtree and pairs each `IOEthernetInterface` with its carrier driver kext (the controller holding `IOMACAddress` / `IOLinkStatus` / `IOActiveMedium`) so the per-port and per-device ethernet cards can share one structured `USBEthernetAdapterInfo`.

In addition to the on-demand full rescan (user refresh button + debounced `IORegMonitor` hot-plug rescan), the ViewModel runs a **2-second `refreshPower()` poll** that re-scans only the per-port accessory state (`AccessoryScanner` / `SDCardScanner` / `PowerInputScanner` / `EthernetScanner`) plus the `AppleSmartBatteryManager` subtree, then rebuilds `SystemSnapshot` carrying over `tb` / `usb` / `bluetooth` / `displays` / `pcie` / the static parts of `internalHardware` from the previous snapshot. That keeps the Power Input wattage / battery % / link-state values ticking forward without spawning `system_profiler` or re-walking every `AppleARMIODevice` on the cadence. Don't slip a heavy scanner into the refresh path.

Models in `Models/`: `TBNode` / `TBNodeKind` is used for **any** IOKit-derived entity (name predates USB expansion). `SystemSnapshot { tb, usb, accessories, internalHardware, bluetooth, displays, pcie, capturedAt }` is the top-level type the ViewModel owns. Subsystem-specific snapshots (`BluetoothSnapshot`, `DisplaySnapshot`, `PCISnapshot`, `InternalHardwareSnapshot`) and per-port types (`PhysicalPort`, `PortAccessoryInfo`, `PortSourcePower`, `USBPDProfile`) live in their respective `*Models.swift` files.

ViewModel: `PortScopeViewModel` is `@MainActor ObservableObject`, scans off-main via `Task.detached`. `PhysicalPortSelector` / `BluetoothSelector` mint synthetic `TBNodeID`s (high bits `0xC0DE_…` and `0xB7E0_…/0xB7E1_…`) so sidebar rows that don't map to a registry entry don't collide with real entry IDs. `ContentView.detail` checks synthetic-ID predicates first; when the selection is a `PhysicalPortSelector` ID it then dispatches on `port.connector` — `.acPower / .ethernet / .hdmi / .sdCard` route to the dedicated curated views in `BuiltInPortViews.swift`, while `.usbC / .usbA / .magsafe / .other` still flow through the unified `PhysicalPortDetailView`. Selections that aren't physical-port IDs fall through to MagSafe / Bluetooth / Display / PCI lookups, then to `vm.node(for:)`.

Views in `Views/`: `SidebarView` shows Thunderbolt, USB, Displays, Bluetooth, PCIe, Internal Hardware as top-level sections; the **Physical Device** group renders as a flat sequence of subgroup Sections (Power, USB-C, USB-A, HDMI, SD Card, Ethernet) rather than a single wrapping Section — that's the only way SwiftUI's sidebar `List` manages cell identity cleanly across the 2-second power-poll refresh (nested `Section` inside `Section` doesn't render properly, and a flat `Button + rows` sequence leaks text between cells during diffing — the visible "SD Card Slot" ghosted into the HDMI row). Three independent Settings toggles, all default off: `@AppStorage("showBuses")` (**Show Hardware Buses**, mirrored by CLI `--buses`) reveals Thunderbolt / USB / PCIe; `@AppStorage("showAllDevices")` (**Show All Devices**, mirrored by CLI `--all`) reveals Displays / Bluetooth / Internal Hardware; `@AppStorage("showIntermediateHubs")` (**Show Intermediate USB Hubs**, mirrored by CLI `--hubs`) is *display-only* — it doesn't reveal a section, it controls whether cascaded USB hubs are flattened away. Internally the sidebar/CLI thread a `flattenHubs = !showIntermediateHubs` boolean through `USBBranch` / `ControllerBranch` / `FullTopologyRow` / `promotedUSBChildren` / `flattenedUSBRoots` so the recursion stays in "flatten" terms even though the UI says "show". Subgroups (Power / USB-C / USB-A / HDMI / SD Card / Ethernet inside Physical Device; Buses + each SoC coprocessor category inside Internal Hardware; Connected + Paired inside Bluetooth) are all driven by the shared `collapsibleSubgroup` helper — each one is a real `Section` with a chevron Button as the header, **never `withAnimation` on toggle** (animating row inserts inside a sidebar `List` reproduces the same ghosting bug). Subgroup collapse state lives on `SidebarView` as a namespaced `Set<String>` (`physical:Power`, `ih:Buses`, `bt:Connected`, …) so subgroup titles can't collide with top-level section names. `DetailView` dispatches on `TBNodeKind` and hosts the **Developer details** disclosure (raw IORegistry dump via `PropertyTableView`); curated built-in-port views build a synthetic `TBNode` from the accessory's `registryProperties` to reuse `PropertyTableView` for their own Developer Details disclosure.

**No `… and N more` truncation anywhere in the UI.** The detail view scrolls, so length isn't a real constraint — list every attached device in "USB Devices via This Port", every entry in "What's using this link", every display, every adapter chip. Capping the list with a "more" row hides exactly the device the user came to find (the busy-dock case). If a future refactor brings back a cap, replace it with proper pagination or filtering instead.

**Everything provided through a TB device nests under that device's sidebar row, not under the port.** When a USB-C port has a connected TB device (e.g. an Anker dock), `PortBranch` passes the port's hub-flattened USB roots, TB-tunneled PCIe endpoints, and display outputs into `DeviceBranch` so the tree reads as "USB-C Port → Anker Dock → everything the dock provides." Display outputs render first (quieter, fewer rows, anchored to the dock's physical jacks), then USB peripherals, then PCIe. Hubs still get flattened away when the toggle is off, so a busy 14-port dock reads as actual devices, not the dock-internal hub chain. Direct-attach displays / USB devices (no TB device on the port) still render directly under the port row. Daisy-chained sub-devices stay collapsed and don't receive the USB/PCIe/display lists — the kernel can't tell us which dock in a chain hosts a given endpoint (they all enumerate under one host xHCI), so we attribute everything to the top-level device.

`PortDisplayOutput` / `displayOutputsAttributed(to:allPorts:allDisplays:)` (in `Models/DisplayModels.swift`) walks the connected dock router for active DP/HDMI function adapters (Description = `"DP or HDMI Adapter"` with non-empty `Hop Table`) and pairs each one with an external display by sort order. Direct-attach panels (no dock) get a single adapter-less output that renders the display straight under the port. `PortView` (in `DetailView.swift`) branches on adapter kind: lane / NHI / inactive keep the original Current/Target/Supported link-negotiation layout; DP/HDMI/USB/PCIe function adapters route to `FunctionAdapterPortView`, which surfaces hop count + hop table + "Negligible" reservation label in the placeholder case (see Things-that-bit-me). `StatusPill` likewise uses `Hop Table` non-empty for function adapters and `Current Link Speed` for lane adapters — don't unify them.

**PCIe attribution to a TB controller uses registry-allocation-order proximity.** Apple Silicon allocates each TB controller (`IOThunderboltControllerType7`) and its corresponding "Thunderbolt PCIe Slot N" downstream root port as adjacent IORegistry entries — the slot's registry ID is the closest one *greater than* the TB controller's. `tbControllerPCIeSlotMap` in `SidebarView` leans on that allocation order because the kernel doesn't publish an explicit cross-reference between the two services. The pairing is per-host and stable across reboots; if you see PCIe attribution land on the wrong port, suspect a hardware-revision change to that order. Endpoints under each slot are collected by `pcieEndpointDescendants`, which walks the bridge tree and only keeps `.endpoint`-kind nodes — bridges are kernel-side topology, only NVMe / eGPU / capture-card endpoints reach the sidebar. On most Apple Silicon docks today the endpoint list is empty (storage tunnels over USB, not PCIe), but the wiring is there for users who plug in real TB-PCIe gear.

**The Thunderbolt sidebar tree (toggled on via Show Hardware Buses) also grafts the tunneled USB tree under the active host-side USB Adapter port.** `tbProvidedUSBMap` walks each TB controller's depth-0 Mac Host Router for function adapter ports whose `Description == "USB Adapter"` or `"USB Gen T Adapter"` AND whose `Hop Table` is non-empty — those are the IOKit endpoint where the tunneled xHCI actually enumerates. Idle USB Gen T adapters sitting next to the live USB Adapter don't double-attach because of the Hop Table check. `FullTopologyRow` consumes the map: when a row's node ID is present, it appends the USB roots after the kernel-published children via the standard `USBBranch` (so hub flattening keeps working). Dock-side USB Adapter ports are the *other end* of the tunnel and don't get the graft — the kernel enumerates devices on the host side, not the dock side.

## Adding a new Mac model to the port-location catalogue

When Apple ships a new Mac (or you discover one missing from the catalogue), add it to `PortScope/Resources/MacPortLocations.json` so PortScope renders "Right Front USB-C Port · Thunderbolt 5" instead of the generic "USB-C Port 3" fallback. The procedure:

1. **Get the chassis identifier.** On the target Mac: `sysctl -n hw.model` → e.g. `Mac17,12`. This is the JSON key. *Mac Pro tower & rack share one `hw.model`* (`MacPro7,1` for Intel, `Mac14,8` for M2 Ultra) — leave both shapes under the same key and use a generic location like `"Top/Front (left)"`.

2. **Pull the kernel's per-receptacle data.** Build PortScope (`xcodebuild …` — see "Build / run") and run the CLI on that Mac:
   ```sh
   "$BIN" --json | jq '.accessories[] | {connector, port_number, raw: .raw_properties.PortTypeDescription}'
   ```
   This gives you the authoritative `port_number` the kernel assigns each USB-C / USB-A / HDMI receptacle. *Trust this number; don't guess from Apple's spec page.* Plug a USB device into each port one at a time and re-run to confirm which physical position is `port_number = 1`, `= 2`, etc. — Apple's chassis numbering scheme is not documented and varies by SoC.

3. **Cross-check against Apple's tech-spec page.** `support.apple.com/en-us/<6-digit-id>` for the model lists ports under "Connections and Expansion". Mirror Apple's wording in `capability` — `"Thunderbolt / USB 4"` (M1, M2, M3 base, M4 base on iMac/MBA), `"Thunderbolt 4"` (Pro/Max chassis pre-M4), `"Thunderbolt 5"` (M4 Pro/Max, M3/M4 Ultra Studio, M4 Pro Mac mini). The kernel doesn't emit those strings; they only come from this catalogue.

4. **Pick chassis-relative location strings.** Convention:
   - **Laptops:** `"Left Rear"`, `"Left Center"`, `"Left Front"`, `"Right Rear"`, `"Right Center"`, `"Right Front"` (`Center` only when ≥3 ports per side).
   - **Desktops with back-only ports** (Mac mini Intel, iMac, pre-2024 Mac mini): `"Rear (left)"`, `"Rear (left-center)"`, `"Rear (right-center)"`, `"Rear (right)"`, plus `"Rear (leftmost)"` / `"Rear (rightmost)"` when there are 5+ adjacent ports.
   - **Mac Studio / 2024 Mac mini** (front + rear): prefix `"Front (left)"` / `"Front (right)"` / `"Rear (left)"` / `"Rear (right)"` etc.
   - **Mac Pro tower/rack**: `"Top/Front (left)"` for the chassis-top TB pair (top on tower, front on rack) since one `hw.model` covers both form factors.
   The `MacPortDescriptor.title` formula is `<location> <kind> Port` (`SD Card Slot` for sd-card), so make sure the location reads naturally with that suffix.

5. **Drop the entry into the JSON, build, and verify.** The bundle's `Resources/` is part of the `PBXFileSystemSynchronizedRootGroup`, so editing the JSON is enough — no `project.pbxproj` change needed. Rebuild and run:
   ```sh
   "$BIN" --json | jq '.host'                       # confirm marketing_name resolves
   "$BIN" --pretty                                  # eyeball every receptacle's title + Spec line
   ```
   If `marketing_name` comes back null, the JSON key doesn't match what `sysctl hw.model` returned on this host. If `Spec:` is missing on a receptacle but Apple says the port has a known capability, you forgot to add `"capability"`.

6. **Update [the research source list in the catalogue's `$doc`](#) and Apple URLs** if you trawled a new spec page — future-you will want the same citations. The catalogue intentionally has no fallback for unknown `port_number` values, so a partial entry (e.g. listing USB-C ports 1 & 2 but not 3 on a 3-port chassis) silently makes port 3 render with the generic "USB-C Port 3" fallback. Cover the full receptacle set.

When two `hw.model` identifiers map to the same chassis with the same port layout (M3 Max 14" splits as `Mac15,7` and `Mac15,8`; M3 Max 16" splits as `Mac15,9` and `Mac15,11`), duplicate the entry under both keys. There's no inheritance keyword — keep it explicit so a future redesign of one identifier doesn't silently corrupt the other.

**MacBook Pro chassis is consistent since 2021.** Every 14" and 16" MacBook Pro from M1 Pro (2021) onward — including all M5 Pro / M5 Max — shares one physical port layout, and the kernel numbers ports the same way on each. LEFT side rear→front: MagSafe 3, USB-C (kernel port 1, right next to MagSafe), USB-C (kernel port 2), 3.5 mm headphone. RIGHT side rear→front: HDMI, USB-C (kernel port 3 — the lone right-side TB, sandwiched between HDMI and the SD slot), SDXC. The left-side pair shares one HPM chip (so the kernel numbers them 1 and 2 first); the right-side lone port is on its own HPM and comes out as 3. The only catalogued exception is the M3 base (`Mac15,3`), which omits the lone right-side TB so its kernel ports 1/2 are the only USB-Cs on the chassis. When adding a new generation (M6, M7, …) you can re-use the M5 Max entry verbatim and just swap the capability string — don't reverse-engineer the side mapping from scratch.

## Things that bit me — read before "fixing"

- **`Adapter Type` integer codes vary by chip vendor and Apple controller generation.** Type7 (M3+/TB5), Type5 (M1/M2 — swaps PCIe/USB/DP codes!), Intel JHL95xx all permute. Use the kernel's `Description` string (`"PCIe Adapter"`, `"DP or HDMI Adapter"`, `"USB Adapter"`, `"USB Gen T Adapter"`, `"Thunderbolt Port"`, `"Port is inactive"`, `"Thunderbolt Native Host Interface Adapter"`) — authoritative across vendors. `TBAdapterType` only decodes the universally-stable codes (`0` inactive, `1` lane, `2` NHI); everything else is `.unknown(rawValue)` deliberately.

- **Accessory class hierarchy differs by host generation.** M3+/TB5 → `AppleHPMInterfaceType10/11`. M1/M2/T6000 → `AppleTCControllerType10/11` (identical property schema). `AccessoryScanner.hpmClasses` matches all four. Type11 = MagSafe, Type10 = USB-C. **Empty on Intel hosts.** Likewise the TB USB tunnel adapter is `AppleThunderboltUSBType2DownAdapter` on Type7 hosts and `AppleThunderboltUSBDownAdapter` (no `Type2` suffix) on Type5 — `IORegMonitor` watches both. Strip either and you silently lose half the Mac fleet.

- **Bandwidth fields are in 100 Mb/s units, not 10 Mb/s.** `Link Bandwidth = 800` is 80 Gb/s, `= 1200` is 120 Gb/s (TB5 asymmetric tx). `tbBandwidthLabel(raw)` divides by 10.

- **The host's "upstream lane adapter for the dock" is the *parent* of the dock switch in the IOService plane, not a child.** `RouterView` walks up via `parentLookup` looking for a port whose `Description == "Thunderbolt Port"`. Aggregating bandwidth across the dock's own lane-adapter children gives the wrong answer (those are the dock's downstream ports).

- **Recursive SwiftUI `some View` functions don't compile.** Use a separate struct (see `SidebarNodeRow`, `FullTopologyRow`, `DeviceBranch`, `PortBranch`).

- **`Sendable` won't synthesise on `IORegValue`** because `case dictionary([(String, IORegValue)])` uses a tuple-in-array. Data types deliberately don't claim `Sendable`; everything's `@MainActor` or copied into the snapshot before bouncing back to main.

- **Don't show IOKit class names or registry IDs in the main UI.** Belongs in Developer details only. `AppleT8142USBXHCI` → "Thunderbolt USB 3.1 Controller"; `AppleT6050USBXHCIAUSS` → "Internal USB 4.0 Controller". `IOThunderboltControllerType7.Generation = 45` is a kernel revision, **not** a TB spec generation — don't surface it. `NodeFormatter.controllerFriendlyName` keys off `IONameMatch` (`usb-drd,t8142` / `usb-auss,t6050`) + `UsbHostControllerProtocolRevision`, not class name.

- **`SOPVID` / `SOPPID` come back as 2-byte little-endian `Data` blobs**, not numbers. Use `AccessoryScanner.readDataAsUInt`; `IORegValue.asUInt` won't work. They identify the USB-PD SOP partner (cable e-marker, or device when no e-marker).

- **`Transports*` arrays are arrays of strings.** Observed: `"CC"`, `"USB2"`, `"USB3"`, `"CIO"`, `"DisplayPort"`. Unknown → `.other(String)`.

- **Don't trust port number = TB controller iteration order.** Chassis port number lives in `AppleHPMInterfaceType10.PortNumber`; TB controllers come back unrelated. `TopologyMapper.physicalPorts` pairs them via a two-pass heuristic (CIO-active HPM ports claim TB controllers with downstream devices first). Without HPM data (Intel) it falls back to TB iteration order with a warning.

- **TB-tunneled USB controllers appear in two trees** — once as a descendant of the TB controller, once as a top-level entry in `USBSnapshot.controllers`, sharing the same `TBNodeID`. Intentional. `USBScanner` records `tbContext[usbControllerID] = tbSwitchID` for the cross-link.

- **Add new IOKit-classifiable kinds in `NodeFormatter.classify`, not the scanners** — both scanners use `NodeBuilder.build` which calls into `NodeFormatter`. Same for `makeLabels` and `preferredOrder`.

- **`IOPCIDevice.IOName` is shared across every PCI bridge** (`pci-bridge` for all of them). Use the device-tree `name` property (a `Data` blob, not a string — needs `unwrapData`). `PCIScanner.makeLabels` falls through `name` → `IOName` → title.

- **`IOPCIExpressLinkStatus` saturates to 0xF / 0x3F on bridges with no negotiated link.** Decoded naively → "Gen 15 ×63". `PCIScanner.decodeLinkStatus` filters speeds outside 1..6 and widths outside `{1,2,4,8,12,16,32}` and returns nil.

- **`IOMFBDisplayRefresh` is NOT the panel's refresh range** — those keys are internal DCP pacing knobs (MBP XDR reports ~5.6–28 Hz here, but the panel does 24–120). Use `TimingElements[*].VerticalAttributes.PreciseSyncRate` (16.16 fixed-point Hz; `7864320 / 65536 = 120 Hz`).

- **Bluetooth data must come from `system_profiler SPBluetoothDataType -xml`**, not IOKit. `IOBluetoothHCIController` has almost nothing useful — chipset name, firmware, paired devices, RSSI, battery levels all live behind SP. Requires sandbox off (`Process` spawn). SP schema is mostly stable but Apple has reshuffled keys before (`device_minorType`, `device_batteryLevelLeft`, …).

- **The `compatible` IORegistry property is an array of device-tree match strings** (e.g. `("jpeg,t8110jpeg", "s5l8920x")`). Use `prettyCompatibleString` (in `Models/TBModels.swift`) for display — joins with " · ". Some kernel paths serialise it as a NUL-separated `Data` blob; `prettyCompatibleString` handles both.

- **`AAPL,slot-name` is a NUL-terminated `Data` blob, not a CFString.** `props["AAPL,slot-name"]?.asString` returns nil — fall through to `unwrapData`. Same trap for `name` on PCI bridges.

- **`SoCCoprocessorGroup` categories key off device-tree name prefix.** `matches(name:prefix:)` accepts exact match or prefix-followed-by-digits — `disp0` matches `disp` but `disp` doesn't grab `dispext0`. Unknown names go to `.other` rather than being dropped, so new silicon doesn't go silent.

- **USB host controllers wrap every port in an `.other` kext** (`AppleUSB20XHCIARMPort`, `AppleUSB30XHCIARMPort`). Real `IOUSBHostDevice` nodes are children of those wrappers. Same below hubs (`AppleUSB20Hub → AppleUSB20HubPort → IOUSBHostDevice`). A flat `filter { $0.kind != .other }` drops the wrapper *and* the device. Use `promotedUSBChildren(of:)`.

- **USB devices on a TB-tunneled dock are NOT children of the dock's TB switch.** The dock's USB hub enumerates under the host's per-port `usb-drd<N>` xHCI (`IONameMatch = "usb-drd,…"`). `TopologyMapper.usbDevicesByPort` maps each `usb-drd<N>` to a physical port via `locationID >> 24` (drd0 → Port 1, etc.). The Internal USB 4.0 controller (`IONameMatch = "usb-auss,t6050"`) is the FaceTime cam / internal jacks — filter it out.

- **TB function adapters often report `Required Bandwidth Allocated = 1` on an active tunnel** — that's 100 Mb/s, a placeholder. DP adapters don't statically reserve TB bandwidth. The authoritative "tunnel is up" signal is `Hop Table` non-empty. `AdapterChip` renders as "Active" instead of misleading "100 Mb/s"; don't add bandwidth bars for function adapters without checking `max(required, maxAlloc) >= 10`.

- **`PhysicalPortMode.usbOnly` wins over `.displayOnly` whenever any USB pair is active.** Many hubs (Anker, UGREEN) enumerate over USB 2.0 only, so don't gate on `usb3`. `modeFromAccessory` checks `usb2 || usb3 || !usbDevices.isEmpty`. `statusLabel` appends `+ DP` when `accessory.carriesDisplay`.

- **Physical Port sidebar rows use synthetic IDs.** `PhysicalPortSelector` packs port number into the high bits of a `TBNodeID`. `ContentView.detail` checks `PhysicalPortSelector.portNumber(sel)` *first* before falling through to `vm.node(for: sel)`. Don't reuse the lane adapter's ID — that selection should go to the lane adapter's `PortView`, not the unified port view.

- **Apple Silicon doesn't publish source-side USB-PD PDOs in IORegistry.** When the Mac sources power, there's no `IOPortFeaturePowerOut` subtree — `FeaturesSupported` lists only `Power In`. The sink side is visible: each `IOUSBHostDevice` publishes `UsbPowerSinkAllocation` / `UsbPowerSinkCapability` / `kUSBConfigurationCurrentOverride`, and each `AppleUSB[23]0XHCIARMPort` wrapper publishes `kUSBWakePortCurrentLimit` / `kUSBSleepPortCurrentLimit`. `TopologyMapper.usbDevicesByPort` rolls both into `PortSourcePower`. Wattage is **always computed at the USB-C default 5 V** — a PD-fast-charge sink may pull more if it negotiated higher voltage; the UI calls this out. The `outputProfile` slot and `IOPortFeaturePowerOut` matcher are wired for the day Apple publishes source PDOs — don't strip them.

- **`IOAccessoryUSBConnectString` is the USB *role*, not "is anything attached".** A power-only PD partner (wall charger) reads `"None"` while `ConnectionActive = true` and a winning PD contract is published under `IOPortFeaturePowerIn`. Treating `connection == .none` as "empty" makes a charging port read as Empty in the UI. `PortAccessoryInfo.connectionActive` is the kernel's authoritative attached signal; `connection` only tells you what USB role (`Device` / `Host` / `Audio Adapter` / `Debug` / `None`) was negotiated. `modeFromAccessory` emits `.charging(watts:)` when `usbPD.winning` exists with no data transports active, and UI sites (`PhysicalPortDetailView`'s Connection row, cable-type label) gate on `connectionActive` rather than `connection.isConnected`.

- **`TBNode.==` must compare `properties`, not just `id`.** SwiftUI's view diffing uses `Equatable` to decide whether to re-evaluate a child view's body. An id-only equality made `BatteryView(node:)` freeze on whichever snapshot it was first rendered with — the periodic `refreshPower()` produces a new `TBNode` with the same id but updated properties, and SwiftUI saw "no change". The sidebar happened to update because its enclosing `List` re-renders for other reasons. Equality now compares `id + properties`; `hash` stays id-only (Hashable allows collisions); `children` are deliberately excluded so diffing doesn't recurse the full IOKit tree on every compare.

- **`AppleSmartBattery` exists on desktops too** — as a power-telemetry endpoint, not as a real battery. Apple Silicon desktops publish the service with `BatteryInstalled = false` so that `PowerInputScanner` can read live wattage/voltage/current out of its `PowerTelemetryData` dict. Don't render a battery row, BatteryView hero, or "0% · On battery" subtitle without first checking `BatteryInstalled == true` — the Mac mini / iMac / Studio / Pro will otherwise grow a phantom 0% battery in any UI that assumes "service present ⇒ pack present".

- **Built-in non-USB receptacles get curated detail views, not `PhysicalPortDetailView`.** That unified view is built around USB-C semantics (USB-PD profile cards, alt-mode transport chips, cable e-markers, plug orientation, displayport HPD). None of that applies to a kettle-cord AC PSU, a plain RJ-45, an HDMI jack, or an SD slot — pushing them through it makes the Mac mini's Power Input look like a USB-C-PD partner and the Ethernet jack look like a USB device. `ContentView.detail` dispatches on `port.connector` to `ACPowerDetailView` / `EthernetDetailView` / `HDMIDetailView` / `SDCardDetailView` (all in `BuiltInPortViews.swift`); only `.usbC / .usbA / .magsafe / .other` reach `PhysicalPortDetailView`. When you add a new built-in connector class to the chassis, write its curated view, add it to the dispatch, and don't expand the unified view.

- **`PowerTelemetryData.Accumulated*` totals are milliwatt-seconds (mJ).** Looks like a raw counter — isn't. `AccumulatedWallEnergyEstimate = 1_900_161_437` is ~528 Wh, the energy drawn from the wall since boot. `ACPowerDetailView.formatEnergyMilliWattSeconds` does the `mJ / 3_600_000 = Wh` conversion. Same denomination for `AccumulatedSystemEnergyConsumed`, `AccumulatedAdapterEfficiencyLoss`, etc. Don't render these as milliwatts.

- **Ethernet's `IOMACAddress` is a "0x…" hex string, not a `Data` blob.** Hex string, twelve characters, no separators (`"0x00c5850fbdcb"`). `EthernetDetailView.prettifyMAC` strips the prefix and inserts colons. `Driver_Version`, `FirmwareVersionString`, and `BSD Name` are plain strings. `IOActiveMedium` is a packed `IFM_*` word published as a hex string (see `EthernetScanner.decodeMediumSpeedMbps`) — don't try to read it as a number.

- **USB-Ethernet adapters publish state across two IOService levels, not one.** Hierarchy is `IOUSBHostDevice → IOUSBHostInterface → vendor driver kext → IOEthernetInterface`. The `IOEthernetInterface` only carries `BSD Name`; `IOMACAddress` / `IOLinkStatus` / `IOActiveMedium` live on its parent (the driver kext, e.g. `AppleUSBNCMData`, `LRCRTL8156`). `USBEthernetSynth.findUSBEthernetAdapters(in:)` walks down looking for the interface and treats whichever TBNode owns it as the controller. Don't look for the controller by class-name pattern — there are too many vendor kexts.

- **Don't label every `IOEthernetInterface` lacking `IOMediaIcon` as "Thunderbolt Networking".** USB-Ethernet drivers also don't set `IOMediaIcon`, so the Realtek RTL8156 in a TB dock was showing up as TB networking in the bus tree. `NodeFormatter` now uses `IOBuiltin` ("Built-in Network Interface" vs "Network Interface") and leaves carrier-specific labelling ("USB 10/100/1G/2.5G LAN") to the per-port detail view, which can walk the subtree and look at the enclosing USB device's product name.

- **DP/HDMI function adapters need their own detail view.** The original `PortView` was designed for lane adapters (Current/Target/Supported link speed, link-negotiation card, full bandwidth bar) and made a live DP output read as "Inactive · 100 Mb/s reserved" — exactly backwards. Function adapters (`Description` in `{"DP or HDMI Adapter", "USB Adapter", "USB Gen T Adapter", "PCIe Adapter"}`) route to `FunctionAdapterPortView`, which shows Active/Idle from `Hop Table` non-empty, skips the link-negotiation card entirely, treats `max(Required, Maximum) < 10` as "Negligible (no static reservation)" rather than painting a 100 Mb/s sliver against the link, and falls back to "no active tunnels" when the hop table is empty. `StatusPill` matches: function adapters get Active/Idle, lane adapters get Link Up/Inactive, "Port is inactive" gets Disabled.

- **External-display attribution to a physical port is a heuristic, not a topology walk.** The IOService plane doesn't expose a clean `dispext0 → TB lane` link on Apple Silicon. `displaysAttributed(to:allPorts:allDisplays:)` uses runtime signals instead — `acc.carriesDisplay` (DP alt-mode) for direct-attach, or any `displayPort` entry in `port.tunnels` for TB-tunneled. Rules: 1 DP-carrying port → all externals go to it; N ports = N externals → 1:1 by sort order (port-number ASC, dispext-name ASC); otherwise show every external under every DP-carrying port. `portCarriesAnyDisplay(_:)` includes the tunnel branch because TB-docked displays never fire alt-mode HPD — the host-side accessory reports CIO + USB2, not DisplayPort. Don't gate on `acc.carriesDisplay` alone or you'll miss every dock-routed monitor.

- **`AppleUSB20Hub` / `AppleUSB30Hub` are `.other` kexts, not `.usbHub` nodes.** Apple's internal root-hub kexts have their own class names that don't match `IOUSBHostDevice`, so they classify as `.other` and the GUI sidebar's `promotedUSBChildren` already treats them as wrappers (recurse + splice). The `--hubs` / `showIntermediateHubs` flag toggles flattening of the *kind-`.usbHub`* nodes specifically (proper IOUSBHostDevice hubs with `bDeviceClass == 0x09`); the `.other` wrappers stay flattened either way. JSON dump preserves the raw tree by default but respects the flag too via `flattenedChildrenForJSON` / `flattenedRootsForJSON` in `SnapshotDumper`.

- **USB device "speed" has two numbers and they often disagree.** `bcdUSB` is the protocol version the device declares (0x0200 = USB 2.0, 0x0320 = USB 3.2); `kUSBCurrentSpeed` is the rate the link actually negotiated. A USB 3.2 SSD reading "USB 3.0 SuperSpeed" is *downgraded* — usually because of an intermediate USB 2.0 hub or a USB-A cable. `usbCapabilityFromBCD(_:)` in `Models/USBModels.swift` maps bcdUSB to the peak `USBSpeed` for that protocol; `usbIsDowngraded(bcdUSB:currentSpeed:)` is the strict comparison used by the UI. Every USB site that shows speed (device detail, hub detail, `USBDeviceRow`, `usbEndpointSubtitle` in the tunnel-consumer breakdown) renders both numbers when they differ — the row gets a small orange "↓ vs USB 3.2" pill and the Link Rate card draws the capability ceiling as a translucent backdrop with the negotiated rate as the solid fill. **HID devices (mice / keyboards) get a softer "this is by design" note** instead of a downgrade warning when they declare USB 2.0 but run at Full Speed — they have no high-speed endpoints regardless, and a warning there cries wolf.

- **The port-detail "What's using this link" card runs through `TunnelBreakdownList` + `tunnelConsumers(forPort:displays:)` in `DetailView.swift`.** Per-tunnel-class rows (DP / USB / PCIe with reserved+max bandwidth) get a sub-list of *what's actually carrying that traffic*: displays attributed to the port for DP, every meaningful USB endpoint for USB (hubs and BillBoards filtered out by `isMeaningfulUSBEndpoint`). The kernel doesn't publish per-device tunnel reservations, so consumer rows show device name + subtitle (vendor, speed, downgrade if any) without a hard wattage. The whole card lives under the bandwidth bar in `PhysicalPortDetailView.modeCard`.

- **`BandwidthBar` shows reserved as a solid fill and peak planned as a slim marker — never as a parallel fill, never with a red "exceeds capacity" stroke.** The kernel sums per-adapter `Maximum Bandwidth Allocated` to produce a worst-case "peak planned" that routinely exceeds link capacity on a busy dock (DP × 2 + USB + PCIe maxes total > 80 Gb/s on TB5). The TB scheduler arbitrates so tunnels never all peak together; painting the overshoot in red made every active dock look broken. The current design: orange fill = `reserved` (real commitment), 2-px yellow tick at the `max` position (peak the scheduler has budgeted), tiny tertiary line of explanatory caption text when peak > capacity. Don't reintroduce a "Planned bandwidth exceeds link capacity by N" alarm — that's the normal state of an actively-used dock.

- **`DiagramView` wraps ports into multiple rows based on available width.** Each row has its own trunk descender + horizontal bus line off the Mac block — see `PortRowGroup` and the `columnsPerRow` calculation in `topology(availableWidth:)`. A single horizontal row at fixed 300 px per column overflowed the sheet on 4+ TB chassis (Mac Studio, Mac Pro) and the rightmost port read as clipped. Horizontal scroll is intentionally gone; only vertical scroll remains. When tuning the layout, keep the per-row width inside the sheet's `minWidth: 1100` budget — `interior = available - 56 (28 px padding each side)`.
