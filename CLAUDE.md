# CLAUDE.md

Guidance for Claude Code working in this repo.

## Project

PortScope is a macOS-only SwiftUI app (target `macOS 26.5`, Swift 5, default actor isolation `MainActor`) that introspects host hardware buses via IOKit. Covers Thunderbolt (controllers / routers / ports / adapters / hop tables / tunnels / bandwidth), USB (controllers / hubs / devices / interfaces), a unified **Physical Ports** view with live operating mode + accessory state from `IOAccessoryManager` (transports, USB-PD voltage/current, plug orientation, DisplayPort HPD, cable e-marker), **USB-C PD output** sourced from per-device sink allocations + xHCI port wrappers, and **Displays / Bluetooth / PCIe / Internal Hardware** sections.

## Build / run

Xcode project uses `PBXFileSystemSynchronizedRootGroup` — **just drop new `.swift` files anywhere under `PortScope/`**, no `project.pbxproj` editing.

```sh
xcodebuild -project PortScope.xcodeproj -scheme PortScope -configuration Debug -destination 'platform=macOS' build
```

Bundle lives under `~/Library/Developer/Xcode/DerivedData/PortScope-*/Build/Products/Debug/PortScope.app`. No tests.

## CLI dump mode — use this to check your assumptions

The app binary is **dual-mode**. No args → GUI; `--pretty` / `--json` → runs the same scanners synchronously, prints to stdout, exits. **Prefer this over `ioreg` / `system_profiler`** — it goes through the same scanner + classifier pipeline the UI uses, so what you see is exactly what the GUI sees.

```sh
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/PortScope-*/Build/Products/Debug/PortScope.app | head -1)
BIN="$APP/Contents/MacOS/PortScope"

"$BIN" --pretty                  # physical ports only (auto TTY)
"$BIN" --pretty --buses          # + raw TB / USB / PCIe trees
"$BIN" --pretty --no-color       # plain text, pipe-safe
"$BIN" --json | jq .             # physical_ports + accessories (default)
"$BIN" --json --buses | jq .     # + thunderbolt, usb, pcie
"$BIN" --json --all --buses      # everything: + bluetooth, displays, internal_hardware
```

The CLI flags mirror the two Settings toggles, both default off:

- **`--buses` / `-b`** → **Show Hardware Buses**. Without it, `thunderbolt` / `usb` / `pcie` keys are absent from JSON (the pretty tree skips those sections entirely). The bare default emits only `physical_ports` + `accessories` — the user-facing roll-up.
- **`--all` / `-a`** → **Show All Devices**. Without it, `bluetooth` / `displays` / `internal_hardware` keys are absent. Independent of `--buses`. When inspecting anything internal (Wi-Fi, battery, SoC coprocessors) **don't forget `--all`**.

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

Seven scanners run per refresh in `Services/`: `ThunderboltScanner`, `USBScanner`, `AccessoryScanner`, `InternalHardwareScanner`, `BluetoothScanner`, `DisplayScanner`, `PCIScanner`. TB and USB share `NodeBuilder` (recursive `IORegistry → TBNode`) and `NodeFormatter` (classify / label / preferred-key-order — **add classify/label logic here, not in scanners**). `IORegBridge` is the generic CF-to-Swift IOKit shim. `IORegMonitor` posts debounced rescan notifications on hot-plug. `TopologyMapper` derives the simplified user-facing `PhysicalPort` topology with mode inference, accessory merge-in, and `PortSourcePower` rollup.

Models in `Models/`: `TBNode` / `TBNodeKind` is used for **any** IOKit-derived entity (name predates USB expansion). `SystemSnapshot { tb, usb, accessories, internalHardware, bluetooth, displays, pcie, capturedAt }` is the top-level type the ViewModel owns. Subsystem-specific snapshots (`BluetoothSnapshot`, `DisplaySnapshot`, `PCISnapshot`, `InternalHardwareSnapshot`) and per-port types (`PhysicalPort`, `PortAccessoryInfo`, `PortSourcePower`, `USBPDProfile`) live in their respective `*Models.swift` files.

ViewModel: `PortScopeViewModel` is `@MainActor ObservableObject`, scans off-main via `Task.detached`. `PhysicalPortSelector` / `BluetoothSelector` mint synthetic `TBNodeID`s (high bits `0xC0DE_…` and `0xB7E0_…/0xB7E1_…`) so sidebar rows that don't map to a registry entry don't collide with real entry IDs. `ContentView.detail` checks synthetic-ID predicates first, then PCINode / DisplayInfo lookups, then `vm.node(for:)`.

Views in `Views/`: `SidebarView` is seven sections (Physical Ports, Thunderbolt, USB, Displays, Bluetooth, PCIe, Internal Hardware). **Physical Ports is the only section visible by default.** Two independent Settings toggles gate the rest, both default off: `@AppStorage("showBuses")` (**Show Hardware Buses**) reveals Thunderbolt / USB / PCIe; `@AppStorage("showAllDevices")` (**Show All Devices**, mirrored by CLI `--all`) reveals Displays / Bluetooth / Internal Hardware. `DetailView` dispatches on `TBNodeKind` and hosts the **Developer details** disclosure (raw IORegistry dump via `PropertyTableView`). `PhysicalPortDetailView` is the unified per-port view used when selection is a `PhysicalPortSelector` synthetic ID.

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
