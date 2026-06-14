# CLAUDE.md

Guidance for Claude Code working in this repo.

## Project

PortScope is a macOS-only SwiftUI app (target `macOS 26.5`, Swift 5, default actor isolation `MainActor`) that introspects host hardware buses via IOKit. It surfaces Thunderbolt (controllers / routers / ports / adapters / hop tables / tunnels / bandwidth), USB (controllers / hubs / devices / interfaces), and a unified **Physical Device** sidebar section organised into subgroups (Power, USB-C, USB-A, HDMI, SD Card, Ethernet). Per-receptacle data comes from `IOAccessoryManager` (transports, USB-PD voltage/current, plug orientation, DP HPD, cable e-marker) plus dedicated scanners for the non-USB-C receptacles. **Power Input** = power entering the Mac (USB-PD sink on laptops via `IOPortFeaturePowerIn`, or `AppleSmartBattery.PowerTelemetryData` on desktops); **Power Output** = power the Mac is sourcing (per-device sink allocations + xHCI port wrappers). Use those terms consistently. Per-receptacle chassis labels come from a static catalogue keyed by `hw.model` (see "Adding a new Mac model" below).

External displays / USB-Ethernet adapters / TB-attached devices nest under the receptacle they're plugged into, not under the top-level Displays/PCIe sections. Display↔port attribution is a heuristic (see `displaysAttributed(to:allPorts:allDisplays:)`) — strict topology isn't possible on Apple Silicon; surfacing what's there is.

The app is deliberately scoped to **port/bus introspection**: Physical Ports, Thunderbolt, USB, PCIe, Displays, Ethernet, and chassis power (battery + MagSafe in the Power subgroup). The old "Show All Devices" mode (Bluetooth, System Overview, GPU/Storage/Memory/Wi-Fi/Cameras/Audio/Touch ID/Input/HID/NVRAM sections, SoC coprocessors, I²C/SPI buses, `system_profiler` spawns) was removed — don't reintroduce host-inventory features here.

## Build / run

Xcode project uses `PBXFileSystemSynchronizedRootGroup` — **just drop new `.swift` files anywhere under `PortScope/`**, no `project.pbxproj` editing.

```sh
xcodebuild -project PortScope.xcodeproj -scheme PortScope -configuration Debug -destination 'platform=macOS' build
xcodebuild … test -only-testing:PortScopeTests   # Swift Testing
```

Bundle lives under `~/Library/Developer/Xcode/DerivedData/PortScope-*/Build/Products/Debug/PortScope.app`.

## CLI dump mode — use this to check your assumptions

The app binary is **dual-mode**. No args → GUI; `--pretty` / `--json` → runs the same scanners synchronously, prints to stdout, exits. **Prefer this over `ioreg` / `system_profiler`** — same pipeline as the GUI.

```sh
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/PortScope-*/Build/Products/Debug/PortScope.app | head -1)
BIN="$APP/Contents/MacOS/PortScope"

"$BIN" --pretty                  # physical ports + displays (auto TTY)
"$BIN" --pretty --buses          # + raw TB / USB / PCIe trees
"$BIN" --json --buses | jq .
"$BIN" --simple                  # tab-separated port summary
```

CLI flags mirror the Settings toggles, all default off:

- `--buses` / `-b` → Show Hardware Buses (reveals `thunderbolt` / `usb` / `pcie` keys).
- `--hubs` → Show Intermediate USB Hubs (un-flattens cascaded hub chains). Display-only — affects sidebar/CLI rendering, not data.

`physical_ports`, `accessories`, and `displays` are always emitted.

Omitted keys are *absent*, not null. When `ioreg` and the CLI dump disagree, **trust the CLI dump** — the difference is usually the bug.

Source: `Services/SnapshotDumper.swift` + `PortScopeApp.swift` (`PortScopeMain` enum). Don't re-add `@main` to `PortScopeApp` — `PortScopeMain.main()` decides GUI vs CLI based on argv.

## Entitlements

`PortScope/PortScope.entitlements` sets `com.apple.security.app-sandbox = false`. Sandbox is intentionally **off** so `IOServiceAddMatchingNotification` and full registry reads work. Don't re-enable `ENABLE_APP_SANDBOX` without moving everything IOKit-touching into a helper — TB hot-plug notifications break under the sandbox.

## Architecture

Data flow: **IOKit → Scanners → SystemSnapshot → ViewModel → SwiftUI views**.

Scanners in `Services/` (full list: `ThunderboltScanner`, `USBScanner`, `AccessoryScanner`, `SDCardScanner`, `PowerInputScanner`, `EthernetScanner`, `InternalHardwareScanner` (battery + MagSafe only), `DisplayScanner`, `PCIScanner`, plus sensors). TB and USB share `NodeBuilder` (recursive `IORegistry → TBNode`) and `NodeFormatter` (classify / label / preferred-key-order — **add classify/label logic here, not in scanners**). `IORegBridge` is the generic CF-to-Swift IOKit shim. `IORegMonitor` posts debounced rescan notifications on hot-plug. `TopologyMapper` derives the user-facing `PhysicalPort` topology. `MacPortCatalog` loads `Resources/MacPortLocations.json` for chassis-relative receptacle labels.

In addition to the on-demand full rescan, the ViewModel runs a **2-second `refreshPower()` poll** that re-scans only the per-port accessory state plus the battery subtree, carrying over `tb` / `usb` / `displays` / `pcie` from the previous snapshot. Don't slip a heavy scanner into the refresh path.

Models in `Models/`: `TBNode` / `TBNodeKind` is used for **any** IOKit-derived entity (name predates USB expansion). `SystemSnapshot { tb, usb, accessories, internalHardware, displays, pcie, capturedAt }` is the top-level type the ViewModel owns (`internalHardware` is just `{ batteryManager, magsafe }`). Per-subsystem snapshots and per-port types live in their respective `*Models.swift` files.

ViewModel: `PortScopeViewModel` is `@MainActor ObservableObject`, scans off-main via `Task.detached`. **Owned by `PortScopeApp` as `@StateObject`** and injected via `.environmentObject(...)` so the main window and the secondary topology / sensors windows share one snapshot + selection. Synthetic selectors (`PhysicalPortSelector` / `MagSafeSelector`) mint synthetic `TBNodeID`s (high bits like `0xC0DE_…`) so sidebar rows that don't map to a registry entry don't collide with real entry IDs. `ContentView.detail` checks synthetic-ID predicates first; `port.connector ∈ {.acPower, .ethernet, .hdmi, .sdCard}` route to curated views in `BuiltInPortViews.swift`, while `.usbC / .usbA / .magsafe / .other` flow through the unified `PhysicalPortDetailView`.

Views in `Views/`: `SidebarView` is the main window. Three independent `@AppStorage` toggles: `showBuses` (default ON), `showBuiltinDevices` (default ON — battery / built-in display rows in Physical Device), `showIntermediateHubs` (default off — *display-only* — controls hub flattening in sidebar/CLI). The sidebar threads a `flattenHubs = !showIntermediateHubs` boolean through the recursion. The Displays section is always visible.

**Subgroups** (Power / USB-C / USB-A / HDMI / SD Card / Ethernet inside Physical Device) are real `Section`s with a chevron Button as the header, namespaced collapse state. **Never `withAnimation` on toggle** — animating row inserts inside a sidebar `List` causes text bleed-through between cells.

**Secondary windows** (Simplified Thunderbolt Topology = `DiagramView`; Detailed Thunderbolt Topology = `DetailedThunderboltTopologyView`; Hardware Sensors = `HardwareSensorsView`) are real macOS `Window` scenes in `PortScopeApp`, opened via `@Environment(\.openWindow)` from the More menu. Each is a single Window (re-opening focuses the existing one), shares the VM via environment, and the user can move / resize / minimize them independently of the main window.

**No `… and N more` truncation anywhere in the UI.** The detail view scrolls, so length isn't a real constraint. Capping the list hides exactly the device the user came to find. If a future refactor brings back a cap, replace it with proper pagination or filtering.

**Detailed Thunderbolt Topology** (`Views/DetailedThunderboltTopologyView.swift`): Microsoft-Device-Portal-style router/adapter/tunnel view. Host routers (green) across the top, device routers (blue) below their cable, each adapter as a typed pill inside its router, tunnels as colored chips. The downstream tree (displays / USB hubs+devices / PCIe) renders below each device router card as individual blocks. **The USB tree always shows every hub regardless of the Show Intermediate USB Hubs toggle** — that toggle only affects the sidebar / CLI rendering. The tree is flattened up front to a list of `USBTreeRow`s and drawn in a single VStack (no recursive Layout requests — that was hanging on deep dock chains). Pinch zoom via `MagnificationGesture` + width-first auto-fit via `fitScaleFor(content:canvas:)`. **Always pass measured sizes by value into auto-fit** — `@State` writes aren't visible inside the same closure that wrote them.

**Topology data builder** (`DTTBuilder.build(from: snapshot)`): host router lookup walks the controller's full subtree for the first switch with `Depth == 0` (not direct children — Apple nests it through HAL / IPService wrappers). Device routers are nested inside lane ports (host-side port wraps device-side port wraps device switch). USB attribution: walk `snapshot.usb.controllers`, filter to `IONameMatched.hasPrefix("usb-drd")`, match by `locationID >> 24 + 1 == socketID` — `drd0` has top byte 0 but serves chassis Socket 1, etc. Pre-probe the device router title and use it to filter dock self-references (hub-chip vendors like `VIA Labs` + "Docking" in the title).

## Adding a new Mac model to the port-location catalogue

When Apple ships a new Mac, add to `PortScope/Resources/MacPortLocations.json`:

1. `sysctl -n hw.model` → JSON key (e.g. `Mac17,12`). Mac Pro tower & rack share one key.
2. Get authoritative port numbers from the CLI: `"$BIN" --json | jq '.accessories[] | {connector, port_number}'`. Plug a device into each port to confirm physical position. Don't guess from Apple's spec page.
3. Cross-check Apple's tech-spec page for capability strings: `"Thunderbolt / USB 4"` (M1, M2, M3 base, M4 base on iMac/MBA), `"Thunderbolt 4"` (pre-M4 Pro/Max), `"Thunderbolt 5"` (M4 Pro/Max+, M3/M4 Ultra Studio).
4. Location strings: laptops use `"Left Rear/Center/Front"`, `"Right Rear/Center/Front"` (Center only when ≥3 ports/side); back-only desktops use `"Rear (left/right/etc.)"`; Studio / 2024 mini use `"Front (left)"` etc.; Mac Pro uses `"Top/Front (left)"`.
5. The `MacPortDescriptor.title` formula is `<location> <kind> Port` (`SD Card Slot` for sd-card). Verify with `"$BIN" --json | jq '.host'` (marketing_name should resolve) and `"$BIN" --pretty` (eyeball receptacle titles).

Duplicate the entry for both `hw.model` keys when one chassis maps to two identifiers (M3 Max 14" = `Mac15,7`+`Mac15,8`; M3 Max 16" = `Mac15,9`+`Mac15,11`). No inheritance keyword.

**MacBook Pro chassis is consistent since M1 Pro (2021)** — every 14" / 16" MBP shares one physical port layout. LEFT side rear→front: MagSafe 3, USB-C (kernel port 1), USB-C (kernel port 2), 3.5mm. RIGHT side rear→front: HDMI, USB-C (kernel port 3), SDXC. M3 base (`Mac15,3`) is the only exception — drops the lone right-side TB. New generations (M6+) can re-use the M5 Max entry verbatim with the capability string swapped.

## Things that bit me — read before "fixing"

### Thunderbolt encoding gotchas

- **`Adapter Type` integer codes permute across vendors** (Type5 vs Type7 vs Intel JHL95xx). Use the kernel's `Description` string instead — `"PCIe Adapter"`, `"DP or HDMI Adapter"`, `"USB Adapter"`, `"USB Gen T Adapter"`, `"Thunderbolt Port"` (lane), `"Port is inactive"`, `"Thunderbolt Native Host Interface Adapter"`. `TBAdapterType` only decodes the universally-stable codes (`0` inactive, `1` lane, `2` NHI).

- **`Current Link Speed` is a single-value code, NOT a Gen counter.** Per WhatCable's research against Linux `tb_regs.h`, confirmed on this host: `0x2` = TB5/USB4v2 (40 Gb/s/lane), `0x4` = TB4/USB4v1 (20 Gb/s/lane), `0x8` = TB3 (10 Gb/s/lane), `0` = inactive. Combine with `Current Link Width` (bitmask: `0x1`/`0x2`/`0x4` asym TX/`0x8` asym RX). **`Target/Supported Link Speed` use the SAME codes as a bitmask** (`14 = 0x8|0x4|0x2` = TB3+TB4+TB5). **`Target Link Width` uses a DIFFERENT encoding** (`0x1` single, `0x3` dual; NOT a bitmask). PortScope's old `8 = TB5` mapping was wrong.

- **Bandwidth fields are in 100 Mb/s units, not 10 Mb/s.** `Link Bandwidth = 800` → 80 Gb/s, `= 1200` → 120 Gb/s (TB5 asymmetric). `tbBandwidthLabel(raw)` divides by 10.

- **`DisplayPortPinAssignment` is Apple's smaller encoding, not USB-IF spec values.** `0` = no DP, `1` = C (4-lane), `2` = D (2-lane + USB 3), `3` = E (4-lane flipped), `4` = F (2-lane flipped). Old `1=A...6=F` mapping was wrong.

- **TB controller ↔ HPM accessory pairing uses Socket ID match**, not "the controller with a downstream device." Each host-root lane adapter publishes a `Socket ID` string ("1", "2", "3") that matches HPM `PortNumber`. `TopologyMapper.socketIDToTBPort` builds the join.

- **TB function adapters report `Required Bandwidth Allocated = 1` (placeholder 100 Mb/s) on active tunnels**. The authoritative "tunnel is up" signal is `Hop Table` non-empty. Don't add bandwidth bars for function adapters without checking `max(required, max) >= 10`.

- **`BandwidthBar` shows reserved (solid fill) and peak planned (slim marker) — never as a parallel fill, never red.** The kernel's per-adapter `Maximum Bandwidth Allocated` sum routinely exceeds link capacity on a busy dock; the TB scheduler arbitrates so they never all peak. Don't reintroduce a "Planned exceeds capacity" alarm.

- **The host's upstream lane adapter for a dock is the *parent* of the dock switch, not a child.** `RouterView` walks up via `parentLookup` looking for a port with `Description == "Thunderbolt Port"`.

### Accessory / cable / PHY plumbing

- **Accessory class hierarchy differs by host generation.** M3+/TB5 → `AppleHPMInterfaceType10/11`. M1/M2/T6000 → `AppleTCControllerType10/11`. `AccessoryScanner.hpmClasses` matches both plus `Type12/18` (future variants). Type11 = MagSafe, Type10 = USB-C. **Empty on Intel.** TB USB tunnel adapter is `AppleThunderboltUSBType2DownAdapter` (Type7) vs `AppleThunderboltUSBDownAdapter` (Type5) — `IORegMonitor` watches both.

- **`SOPVID` / `SOPPID` come back as 2-byte big-endian `Data` blobs**, not numbers. Use `AccessoryScanner.readDataAsUInt`. Verified on Mac17,6: an Apple Watch charging cable publishes bytes `[0x05, 0xAC]` (Apple = 0x05AC) and an Anker cable `[0x29, 0x1A]` (Anker = 0x291A) — a little-endian read produces unassigned VIDs.

- **`PortAccessoryInfo` carries four sibling-data structs** decoded from dynamic IOKit services that appear/disappear per cable: `cableEmarker` (Discover Identity VDOs), `usb3State` (`IOPortTransportStateUSB3`), `cioState` (`IOPortTransportStateCIO`), `phyState` (`AppleT*TypeCPhy` for per-lane transport + active DP rates). PHY services are keyed by `AppleTypeCPhyID` (0-indexed); HPM `PortNumber` is 1-indexed; lookup uses `phyID == portNumber - 1` for `.usbC` only. All adapted from WhatCable (MIT, Copyright (c) 2026 Darryl Morley) — see `design/WHATCABLE_LEARNINGS.md`.

- **PHY class list is broader than WhatCable upstream.** Plus `T6050`, `T6034`, `T6052`. Extend the list per chassis when adding catalogue entries.

- **DP pixel-clock / tunnel sub-dicts have two layouts** — flat (`{Link Rate, Client}`) or nested by stream (`{PCLK 1: {...}}`). M4 Pro publishes nested on T6050. `parsePhyDPDict` handles both.

- **`IOAccessoryUSBConnectString` is the USB *role*, not "is anything attached".** A wall charger reads `"None"` while `ConnectionActive = true`. Gate UI on `connectionActive`, not `connection.isConnected`.

### USB tree quirks

- **TB-tunneled USB controllers appear in two trees** — once as a descendant of the TB controller, once as a top-level entry in `USBSnapshot.controllers`, sharing the same `TBNodeID`. `USBScanner` records `tbContext[usbControllerID] = tbSwitchID` for the cross-link.

- **USB devices on a TB-tunneled dock are NOT children of the dock's TB switch.** The dock's USB hub enumerates under the host's per-port `usb-drd<N>` xHCI. `TopologyMapper.usbDevicesByPort` maps each `usb-drd<N>` to a physical port via `locationID >> 24`. Off-by-one: `drd<N>`'s locationID top byte is `N`, but it serves chassis Socket `N+1` (drd0 → Socket 1, drd1 → Socket 2). `usb-auss,t6050` is the internal FaceTime cam / SoC USB — filter it out.

- **USB host controllers wrap every port in an `.other` kext** (`AppleUSB20XHCIARMPort`, `AppleUSB30XHCIARMPort`). Real `IOUSBHostDevice` nodes are children of those wrappers. Same below hubs (`AppleUSB20Hub → AppleUSB20HubPort → IOUSBHostDevice`). A flat `filter { $0.kind != .other }` drops the wrapper *and* the device — use `promotedUSBChildren(of:)`.

- **`AppleUSB20Hub` / `AppleUSB30Hub` are `.other` kexts**, not `.usbHub` nodes. The `--hubs` / `showIntermediateHubs` flag toggles flattening of `.usbHub` nodes specifically (proper `IOUSBHostDevice` hubs); the `.other` wrappers stay flattened either way.

- **USB device "speed" has two numbers and they often disagree.** `bcdUSB` is the declared protocol; `kUSBCurrentSpeed` is what was negotiated. A USB 3.2 SSD reading "USB 3.0" is *downgraded* — usually a 2.0 hub or USB-A cable in the path. `usbCapabilityFromBCD(_:)` maps bcdUSB to peak speed; `usbIsDowngraded(bcdUSB:currentSpeed:)` is the comparison. HID devices (mice/keyboards) get a softer "by design" note instead of a downgrade warning when they declare USB 2.0 but run at Full Speed.

- **USB device → physical-port mapping prefers `UsbIOPort` over `locationID >> 24`.** `physicalPortNumber(forUSBController:)` walks `XHCIPort` wrappers looking for a registry path ending in `Port-USB-C@N`. Falls back to `locationID >> 24 + 1`. The `UsbIOPort` value can be CFString or NUL-trimmed Data — both handled by `unwrapDataAsString`.

- **In the Detailed Thunderbolt Topology, suppress dock self-references in the USB leaves.** Hub chips (VIA Labs / Genesys Logic / ASMedia vendor) that advertise themselves as a USB device with "Docking" in their title would otherwise appear as leaves of the dock's own router card. Filter by `(hubChipVendor && titleContainsDocking) || (sharedVendorToken && titleContainsDocking)`. Also suppress placeholder vendor strings — Apple's USB-C Digital AV Adapter publishes literal `"xxxxxxxx"` as its vendor.

### Display / framebuffer / HDCP

- **`IOMFBDisplayRefresh` is NOT the panel's refresh range** (those are DCP pacing knobs). Use `TimingElements[*].VerticalAttributes.PreciseSyncRate` (16.16 fixed-point Hz; `7864320 / 65536 = 120 Hz`).

- **External-display attribution to a physical port is a heuristic.** `displaysAttributed(to:allPorts:allDisplays:)` uses `acc.carriesDisplay` (DP alt-mode) for direct-attach OR any `displayPort` entry in `port.tunnels` for TB-tunneled. Rules: 1 DP-carrying port → all externals go to it; N ports = N externals → 1:1 by sort order; otherwise every external under every DP-carrying port. `portCarriesAnyDisplay` includes the tunnel branch because dock-routed displays never fire alt-mode HPD.

- **DP/HDMI function adapters need their own detail view** (`FunctionAdapterPortView`). The lane-adapter `PortView` made live DP outputs read as "Inactive · 100 Mb/s reserved" — exactly backwards. Active/Idle comes from `Hop Table` non-empty.

- **HDCP channels can't be reliably attributed per-display.** `AppleSEPHDCPManager` publishes channels with `HDCPRole` / `HDCPTransport` / `HDCPCapabilityMask`, but the channel→display map isn't stable. Render the channel table as host-wide rather than per-display.

### Battery / power

- **`AppleSmartBattery` exists on desktops too** — as a power-telemetry endpoint with `BatteryInstalled = false`. Don't render a battery row or "0% · On battery" subtitle without checking `BatteryInstalled == true`.

- **`AppleSmartBattery.ChargerData` is a nested dict on every Apple Silicon Mac**, including desktops. `ChargingVoltage` / `ChargingCurrent` for live charger output; `NotChargingReason` / `SlowChargingReason` as raw integer bitfields (Apple doesn't publish bit decoders — non-zero is itself the diagnostic signal); `TimeChargingThermallyLimited` and `VacVoltageLimit`.

- **`PowerTelemetryData.AccumulatedWallEnergyEstimate` is in milliwatt-seconds (mJ)** — `/ 3_600_000 = Wh`. **Don't assume the same denomination for other `Accumulated*` counters** — `AccumulatedSystemEnergyConsumed` runs 5+ orders of magnitude larger and isn't documented. **Don't render `SystemEnergyConsumed` (no `Accumulated` prefix) as energy** — that's an instantaneous-power reading in mW.

- **Apple Silicon doesn't publish source-side USB-PD PDOs in IORegistry.** `FeaturesSupported` lists only `Power In`. The sink side is visible via `UsbPowerSinkAllocation` / `UsbPowerSinkCapability` / `kUSBConfigurationCurrentOverride` on each `IOUSBHostDevice`, and `kUSBWakePortCurrentLimit` / `kUSBSleepPortCurrentLimit` on each `AppleUSB[23]0XHCIARMPort` wrapper. Wattage is **always computed at the USB-C default 5 V**.

### Networking

- **Ethernet's `IOMACAddress` is a "0x…" hex string, not a `Data` blob.** Twelve characters, no separators. `IOActiveMedium` is a packed `IFM_*` word published as a hex string.

- **USB-Ethernet adapters publish state across two IOService levels.** `IOUSBHostDevice → IOUSBHostInterface → vendor driver kext → IOEthernetInterface`. `IOEthernetInterface` only carries `BSD Name`; `IOMACAddress` / `IOLinkStatus` / `IOActiveMedium` live on its parent. `USBEthernetSynth.findUSBEthernetAdapters(in:)` walks down and treats whichever TBNode owns the interface as the controller.

- **Don't label every `IOEthernetInterface` lacking `IOMediaIcon` as "Thunderbolt Networking".** USB-Ethernet drivers also don't set `IOMediaIcon`. `NodeFormatter` uses `IOBuiltin` ("Built-in Network Interface" vs "Network Interface") and carrier-specific labelling lives in the per-port detail view.


### IOKit shape gotchas

- **`Sendable` won't synthesise on `IORegValue`** because `case dictionary([(String, IORegValue)])` uses a tuple-in-array. Data types deliberately don't claim `Sendable`; everything's `@MainActor` or copied into the snapshot before crossing actors.

- **`TBNode.==` must compare `properties`, not just `id`.** SwiftUI's view diffing skips re-evaluation when inputs compare equal. The periodic `refreshPower()` produces a new `TBNode` with the same id but updated properties; id-only equality made `BatteryView(node:)` freeze on the original snapshot. `hash` stays id-only; `children` are excluded so diffing doesn't recurse.

- **The `compatible` IORegistry property is an array of device-tree match strings** (e.g. `("jpeg,t8110jpeg", "s5l8920x")`). Use `prettyCompatibleString` for display. Some paths serialise it as a NUL-separated `Data` blob; `prettyCompatibleString` handles both.

- **`AAPL,slot-name` is a NUL-terminated `Data` blob, not a CFString.** `props["AAPL,slot-name"]?.asString` returns nil — fall through to `unwrapData`. Same trap for `name` on PCI bridges.

- **`IOPCIDevice.IOName` is shared across every PCI bridge** (`pci-bridge`). Use the device-tree `name` property (a `Data` blob). `PCIScanner.makeLabels` falls through `name` → `IOName` → title.

- **`IOPCIExpressLinkStatus` saturates to 0xF / 0x3F on bridges with no negotiated link.** Decoded naively → "Gen 15 ×63". `PCIScanner.decodeLinkStatus` filters speeds outside 1..6 and widths outside `{1,2,4,8,12,16,32}`.

- **Recursive SwiftUI `some View` functions don't compile.** Use a separate struct.

- **Don't show IOKit class names or registry IDs in the main UI.** Belongs in Developer details only. `NodeFormatter.controllerFriendlyName` keys off `IONameMatch` + `UsbHostControllerProtocolRevision`, not class name. `IOThunderboltControllerType7.Generation` is a kernel revision, **not** a TB spec generation.

- **Built-in non-USB receptacles get curated detail views**, not `PhysicalPortDetailView`. That unified view is USB-C-shaped (USB-PD profiles, alt-mode chips, e-markers). `ContentView.detail` dispatches on `port.connector` to `ACPowerDetailView` / `EthernetDetailView` / `HDMIDetailView` / `SDCardDetailView`. Only `.usbC / .usbA / .magsafe / .other` reach `PhysicalPortDetailView`.

- **Physical Port sidebar rows use synthetic IDs.** `PhysicalPortSelector` packs port number into the high bits of a `TBNodeID`. `ContentView.detail` checks `PhysicalPortSelector.portNumber(sel)` *first* before falling through to `vm.node(for: sel)`.

- **Add new IOKit-classifiable kinds in `NodeFormatter.classify`**, not the scanners. Same for `makeLabels` and `preferredOrder`.

### SwiftUI layout perf

- **Cache expensive model builds.** SwiftUI re-evaluates `body` on every gesture frame, view update, etc. — building a topology from the snapshot inside `body` walks thousands of IOReg nodes per frame and shows up as `StackLayout.UnmanagedImplementation.resize` storms. Cache via `@State` + `.task(id: snapshot.capturedAt)` so the build runs once per snapshot.

- **Avoid `maxWidth: X + Spacer` expand-then-cap dance** in deep trees. SwiftUI re-proposes sizes through every level. Use `.fixedSize()` on leaf blocks so they size to content, then let a wrapping layout (`FlowChips` / custom `FlowLayout`) handle reflow.

- **Recursive HStack/VStack in a view tree is expensive** for deep hierarchies. The Detailed Thunderbolt Topology USB tree flattens up front (O(N) walk) into a list of `USBTreeRow`s with depth + trunk-bitmap metadata, then renders as a single `VStack` — no recursion in the view body.

- **Auto-fit calculations: pass measured sizes by value into the helper.** SwiftUI defers `@State` writes until the next view pass, so reading `@State contentSize` inside the closure that just wrote it sees the old value. Take both `content` and `canvas` as explicit args.

### HID sensors

- **HID sensor reading needs a per-sensor-type matching dict, not one shared client.** Temperature is `(PrimaryUsagePage 0xff00, PrimaryUsage 0x05)` on event type 15; power is `0xff00 / 0x0a` on type 25; current is `0xff00 / 0x0b` on type 25; ambient light is `0x20 / 0x41` on type 12. A single client with no matching dict returns thousands of services and zero useful events. Open one client per sensor type and merge by `RegistryID`.

- **`com.apple.private.hid.client.event-monitor` doesn't work on third-party builds.** The Monitor-type `IOHIDEventSystemClientCreateWithType(_, 1, _)` is what unlocks live thermal/power/current readings. Without the entitlement the kernel hands back a Simple-type client whose `IOHIDServiceClientCopyEvent` returns nil. AMFI kills any ad-hoc-signed binary that requests it with **exit 137** at exec. Don't reintroduce a post-build re-sign script — it builds but SIGKILLs on launch. Fallback: Simple client + IORegistry battery/PSU.

- **`SensorScanner` emits a row only when there's a live reading.** Discovery-only mode was visual noise. Category (temp/power/current/voltage/energy/light) is derived from the reading's unit string — keep `HIDSensorReader.Reading.unit` consistent (`°C`, `W`, `A`, `V`, `lux`, `Wh`).
