# WhatCable learnings for PortScope

> **License scope.** All material referenced here was studied exclusively from the
> **MIT-licensed** portions of WhatCable
> (<https://github.com/darrylmorley/whatcable>),
> **Copyright (c) 2026 Darryl Morley**, MIT licence. The subdirectory
> `Sources/WhatCablePlugins/` is proprietary in upstream WhatCable (Pro
> features — power metering, licence, cable diagnostics view, liquid
> detection) and was **not read, copied, or referenced** during this
> survey, even though only a `Bootstrap.swift` stub is present in the
> public clone. Every concrete idea below cites the WhatCable file and
> line it came from so attribution stays attached if any code is
> eventually ported.
>
> Any code ported from WhatCable must:
> 1. Carry the MIT copyright notice in the source file header, and
> 2. Carry a comment near the ported logic citing the original
>    WhatCable file path (e.g. `// adapted from
>    Sources/WhatCableCore/USBPDVDO.swift in whatcable (MIT,
>    Copyright (c) 2026 Darryl Morley)`).
>
> Where this document quotes ideas only (decision-tree shape, key
> names, encoded bit positions defined by public USB-PD / Thunderbolt
> specs), no attribution comment is strictly required, but a project-
> level credit in `README.md` or `CREDITS.md` is the polite default.
>
> Source studied (MIT only): `Sources/WhatCable/`,
> `Sources/WhatCableAppKit/`, `Sources/WhatCableCLI/`,
> `Sources/WhatCableCore/`, `Sources/WhatCableDarwinBackend/`,
> `Sources/WhatCableWidget/`.
>
> Source deliberately not studied (proprietary):
> `Sources/WhatCablePlugins/`.

---

## 0. Executive summary

PortScope and WhatCable are independently-arrived-at takes on a similar
problem — reading USB-C / TB state from IOKit and making it useful.
PortScope's strengths are breadth (every receptacle on every chassis,
ten subsystem scanners, curated detail views, Mac model catalogue);
WhatCable's strengths are depth on the one subsystem it covers
(USB-PD VDO decoding, e-marker trust signals, a plain-English
bottleneck verdict, per-lane TB speed math, per-port live PD telemetry).

The single biggest gap PortScope can close by referencing WhatCable is
**decoding the PD Discover Identity VDOs**. PortScope already reads
the surface fields (`SOPVID` / `SOPPID` / `ActiveCable`) but doesn't
touch the `Metadata.VDOs` array that carries cable speed class, current
rating, max VBUS voltage, EPR capability, optical vs copper, retimer vs
redriver, etc. Everything WhatCable does on top of that — trust
signals, bottleneck verdict, e-marker-vs-CIO cross-check — flows from
that decode.

The other genuinely novel ideas are:

- **Per-lane TB speed × width math** (TB3 / TB4 / TB5 asymmetric).
- **`UsbIOPort` registry-path parent walk** for USB→port mapping, with
  the SPMI `hpm` / `atc` / `usb-drd` ancestor as fallback.
- **`AppleT*TypeCPhy` PHY services** for per-lane "this lane carries
  CIO, that lane carries DP" assignment.
- **`IOPortTransportState{USB3,DisplayPort,CIO}` services** PortScope
  doesn't currently consume — independent USB3 generation, active DP
  link with EDID, TB-controller cable assessment.
- **A "what is the bottleneck" plain-English diagnostic engine**
  (`ChargingDiagnostic` + `DataLinkDiagnostic`).
- **Per-key `IORegistryEntryCreateCFProperty` reads** instead of bulk
  `IORegistryEntryCreateCFProperties` to avoid `IOCFUnserializeBinary`
  process-abort on services torn down mid-read. This is a real crash
  hazard PortScope is currently exposed to.
- **Per-service `kIOGeneralInterest` notifications** to catch property
  changes (PD renegotiation, TB link state) without waiting for the
  2-second power poll.

The recommendation is **selective lifting, not wholesale rearchitecture**.
WhatCable's eight-`@Published`-array model is the wrong shape for
PortScope's snapshot semantics, but several focused borrowings are
clean wins.

---

## 1. USB-PD VDO / e-marker decoding (biggest gap)

### 1.1 What WhatCable does

`Sources/WhatCableCore/USBPDVDO.swift` is a pure-Swift bitfield decoder
for the four Discover Identity VDOs PortScope cares about: ID Header
(VDO[0]), Cert Stat (VDO[1]), Cable VDO (VDO[3]), Active Cable VDO 2
(VDO[4]). Each decoder takes a `UInt32` and returns a typed struct; the
file includes a `vdoFromData(_:)` helper for the little-endian 4-byte
IOKit blob format.

Key bitfield offsets and encodings, attributed to WhatCable
`Sources/WhatCableCore/USBPDVDO.swift`:

- **ID Header (`decodeIDHeader`, L45–54).** USB-comm host=bit31,
  USB-comm device=bit30, modal=bit26, UFP product type=bits29..27 (3
  bits), DFP product type=bits25..23 (3 bits), VID=bits15..0. The
  8-value `ProductType` enum (L10–32) distinguishes passive cable (3),
  active cable (4), AMA (5), VPD (6) — the cable-vs-non-cable
  discriminator before decoding VDO[3].
- **Cable VDO passive/active (`decodeCableVDO`, L193–298).**
  Speed=bits2..0 (table at L58–84: 0=USB 2.0, 1..2=USB 3.2 Gen1/2,
  3=USB4 Gen3 / 40Gbps, 4=USB4 Gen4 / 80Gbps). VBUS-through=bit4.
  Current=bits6..5 (0=default, 1=3A, 2=5A). Max VBUS=bits10..9
  (0=20V, 1=30V, 2=40V, 3=50V; L161–169 + L275–281). Cable
  Termination=bits12..11 (validity flips between passive `{00,01}`
  and active `{10,11}` — L251–264). Latency=bits16..13 (4-bit, table
  L176–190 mapping ~10ns/m, with active-only optical codes
  `0b1001=1000ns` and `0b1010=2000ns`). EPR Capable=bit17. VDO
  Version=bits23..21 (passive: only `000` legal; active: `000/010/011`
  legal — L241–249).
- **Active Cable VDO 2 (`decodeActiveCableVDO2`, L394–425).** Max op
  temp=bits31..24 (°C), shutdown temp=bits23..16, U3/CLd idle
  power=bits14..12 (8-level table L334–356, 50 µW to >10 mW), U3→U0
  via U3S=bit11, physical connection (copper/optical)=bit10, active
  element (re-driver/re-timer)=bit9. **Important polarity trick
  (L405–419):** the USB4/USB3.2/USB2 "supported" bits at 8/4/5 are
  *inverted* in the spec — 0 means supported — and the file rewrites
  them to the natural `true=supported` polarity. USB2 hub
  hops=bits7..6, two-lane=bit3, optically isolated=bit2,
  asymmetric=bit1, gen2-or-higher=bit0.
- **Cert Stat (`decodeCertStat`, L439–442).** Whole 32-bit VDO is
  the USB-IF XID; `isPresent` is `xid != 0`.
- **Decode warnings (L114–135).** Six-case `DecodeWarning` enum
  surfaces spec-reserved values per cable type, plus an explicit
  contradiction check at L271–273: passive cable with EPR-Capable
  bit set but Max VBUS encoding=0 (20V) — EPR requires 48V/50V.

`Sources/WhatCableCore/USBPDSOP.swift` is the wrapping model.
The `USBPDSOP` struct pairs an IOKit registry id with the parsed PD
endpoint (port partner SOP, near-end e-marker SOP', far-end e-marker
SOP''), parent port type/number, VID/PID/bcdDevice, raw VDOs, and
Specification Revision. Two details worth borrowing:

- **VDO index map (L47–78).** ID Header at VDO[0], Cert Stat at
  VDO[1] (cable endpoints only), Cable VDO at VDO[3], Active Cable
  VDO 2 at VDO[4] (only when `idHeader.ufpProductType ==
  .activeCable`). Crucially, **whether to decode VDO[3] as active vs
  passive is taken from VDO[0]'s UFP product type, not from a separate
  flag** (L64–66).
- **PD spec revision interpretation (L95–101).** Maps the IOKit
  `Specification Revision` int: `2` = PD 2.0, `3` = PD 3.0, `1` =
  placeholder-with-empty-Metadata (returns nil rather than fabricating
  a version), `0` = unset. The 2-bit SpecRev header **cannot encode
  PD 3.1**; EPR PDOs are the only signal that distinguishes PD 3.1
  (commented L99–101).

### 1.2 What PortScope is missing

PortScope reads `SOPVID` / `SOPPID` / `SOPMfgString` / `ActiveCable`
in `Services/AccessoryScanner.swift` but never decodes any VDO. The
raw VDOs are present in IOKit's nested `Metadata` dict on each
`IOPortTransportComponentCCUSBPDSOP*` service under key `"VDOs"`
(array of 4-byte little-endian `Data` blobs). Reading that array is
the single highest-leverage change.

Once decoded, PortScope can surface (none of these are currently shown):

- Cable speed class (USB 2.0 / 5 / 10 / 20 / 40 / 80 Gbps) as
  *declared by the cable*, distinct from the negotiated USB3 link.
- Cable current rating (3A / 5A) and computed max wattage at 20V/28V/
  36V/48V/50V — already feeds the charging diagnostic in §7.
- EPR capability flag.
- Active vs passive (from VDO[0]), and for active cables: optical vs
  copper, retimer vs redriver, max operating temperature, thermal
  shutdown temperature, idle power class.
- PD spec revision (PD 2.0 / 3.0; PD 3.1 inferred from EPR PDOs).
- SOP vs SOP' vs SOP'' partitioning (PortScope currently treats the
  e-marker as one entity per port; the cable can have two e-markers,
  one per end, and discovering the far-end e-marker is a signal of
  its own).

### 1.3 Reading-side note (process stability)

`Sources/WhatCableDarwinBackend/USBPDSOPWatcher.swift` reads VDO properties
via per-key `IORegistryEntryCreateCFProperty`, not bulk
`IORegistryEntryCreateCFProperties` (L104–112, comment cites WhatCable
issue #181). The bulk call can abort the process inside
`IOCFUnserializeBinary` when the kernel returns malformed serialised
properties — which happens routinely when a service is being torn down
mid-read. PortScope's `IORegBridge` currently uses the bulk path
everywhere; auditing for this on hot-plug rescans is a strict win.
See §11 for a broader treatment.

### 1.4 Endpoint classification

WhatCable classifies a PD endpoint as SOP / SOP' / SOP'' via a
three-tier fallback at
`Sources/WhatCableDarwinBackend/USBPDSOPWatcher.swift:154–178`:
`ComponentName` / `AddressDescription` string match → IOKit class-name
match (most reliable when ComponentName is absent) →
`TransportTypeDescription`. The MagSafe quirk at L169–176 is worth
preserving: MagSafe's CC transport has no `ComponentName`, and
`TransportTypeDescription == "CC"` should map to SOP' but only via
TransportType (avoid a future `ComponentName="CC"` collision).

### 1.5 Parent-port-key resolution

Same file, L184–192: prefer `ParentBuiltInPortType` /
`ParentBuiltInPortNumber` over `ParentPortType` / `ParentPortNumber`,
then fall back to the low byte of `Priority`. The BuiltIn keys take
priority so PD identity and power data resolve to the same `portKey`
for a given physical port — important when correlating SOP data with
the existing `IOPortFeaturePowerIn` sink. PortScope's accessory
scanner uses a per-port-number scheme but not this hierarchy of
parent keys; worth adopting for any new transport-service reader.

---

## 2. Cable trust signals

### 2.1 What WhatCable does

`Sources/WhatCableCore/CableTrustReport.swift` raises heuristic flags
against an SOP'/SOP'' identity to surface counterfeit / mis-flashed
cables. Wording is carefully hedged ("looks unusual," "common
counterfeit pattern," never "this cable is fake"). Empty report when
nothing fires.

Rules in `init(identity:)` at
`Sources/WhatCableCore/CableTrustReport.swift:18–63`:

- **VID 0x0000 → `zeroVendorID`** (L35–36). Legitimate USB-IF
  members have non-zero VIDs.
- **VID 0xFFFF → intentionally NOT flagged** (L37–38, plus extended
  comment L26–34). It's the PD-spec-defined "vendor opted out of
  USB-IF registration" sentinel. Surfaced via `VendorDB.name` as
  `"No vendor ID assigned (USB-PD spec sentinel)"`
  (`Sources/WhatCableCore/VendorDB.swift:26–28`).
- **VID not in bundled USB-IF list → `vidNotInUSBIFList`**
  (L39–41), gated specifically on `source == "usbif"` (see
  `CableDB.isUSBIFRegistered`,
  `Sources/WhatCableCore/CableDB.swift:36–38`) — usb.ids community
  matches do not count, because community lists routinely include
  fabricated entries.
- All `PDVDO.DecodeWarning` cases (reserved speed/current/latency,
  invalid VDO version, invalid cable termination, EPR-with-20V) are
  promoted into `TrustFlag` (L43–60).

The `TrustFlag` enum (L66–117) defines stable JSON codes, titles, and
hedged detail strings safe for UI.

### 2.2 What PortScope is missing

Nothing in PortScope flags counterfeit signatures. This grafts
naturally onto `AccessoryScanner`'s existing SOP-field plumbing once
PortScope is decoding VDOs (§1).

### 2.3 Vendor DB note

`Sources/WhatCableCore/CableDB.swift` is a SQLite-backed lookup
(~15k entries merged from USB-IF, the community `usb.ids` list, and a
curated set). PortScope already has the `MacPortCatalog` pattern
loading JSON from `Resources/`; if PortScope ever bundles a USB-IF
vendor list, the read-only SQLite + lazy in-memory dict pattern at
`CableDB.swift:50–57` (with the careful "refuse the all-zero key"
defence — issue #161) is a reasonable shape.

The catalogue authoring caveat at
`Sources/WhatCableCore/VendorDB.swift:9–15` is also worth heeding:
manual VID overrides drift out of date (the original `VendorDB` had
HP/AMX swapped on 0x103C). Keep curated overrides empty by default
and treat them as a maintenance burden.

---

## 3. Per-lane Thunderbolt speed + width

### 3.1 What WhatCable does

`Sources/WhatCableCore/IOThunderboltLink.swift` is a model layer for
`IOThunderboltSwitch` and its child `IOThunderboltPort` adapters that
goes much deeper on lane physics than PortScope currently does. The
relevant decodings, attributed to that file:

- `LinkGeneration.from(rawSpeedCode:)` at L57–65. Speed code
  `0x8` = TB3 (10 Gb/s/lane), `0x4` = USB4/TB4 (20 Gb/s/lane),
  `0x2` = TB5 (40 Gb/s/lane). Anchored to Linux's `tb_regs.h`.
  TB5 (`0x2`) confirmed via M5 Pro + UGreen JHL9580 dock (L9–11).
- `SupportedSpeedMask` at L72–97 decodes `Supported Link Speed`
  as a bitmask with the same bits.
- `LinkWidth` at L102–138 decodes `Current Link Width`: bit `0x1`
  single, `0x2` dual, `0x4` asymmetric TX (3T/1R, TB5), `0x8`
  asymmetric RX (1T/3R). `txLanes`/`rxLanes` derived per case.
- `TargetLinkWidth.from(rawValue:)` at L149–156: **different encoding
  from current** — `0x1 = single`, `0x3 = dual`. Inline comment flags
  this footgun ("`0x3` here means negotiated dual lane, NOT
  asymmetric").
- `AdapterType.from(rawValue:)` at L178–191: decodes the full 24-bit
  code, not just the 0/1/2 stable subset PortScope handles. Confirmed
  encodings: `0x0e0101 = dpIn`, `0x0e0102 = dpOut`,
  `0x100101 = pcieDown`, `0x100102 = pcieUp`,
  `0x200101 = usb3Down`, `0x200102 = usb3Up`.
- Switch keys (`IOThunderboltSwitch.from`, L295–350): `Vendor ID`,
  `Device Vendor Name`, `Device Model Name`, `Router ID`, `Depth`,
  `Route String`, `Upstream Port Number`, `Max Port Number`,
  `Firmware Version`, `Thunderbolt Version` (64 = USB4/TB4),
  `Device ID`, `IOPowerManagement.CurrentPowerState` (2 = active,
  0 = sleeping), `FW Counters` / `FW Counters Running Total` (348-byte
  blobs), `DROM`, `Min Required TMU Mode`.
- Port keys (`IOThunderboltPort.from`, L482–551): `Port Number`,
  `Socket ID` (string — pairs with `Port-USB-C@N` chassis name),
  `Description`, `Current Link Speed`, `Current Link Width`,
  `Supported Link Width`, `Target Link Width`, `Target Link Speed`,
  `Link Bandwidth`, `Maximum Bandwidth Allocated`,
  `Required Bandwidth Allocated`, `Buffer Allocation Request`
  (sub-dict with `Max USB3` / `Max PCIe` / `Max HI` / `Min DP Aux`),
  `Max Credits`, `Dual-Link Port`, `Lane`, `CLx State`,
  `Supported Link Speed`, `TRM Policy` (`"Root"` on host).
- Switch-level `Supported Link Speed` is **per-port on Apple Silicon
  M3-M5+**, not on the switch itself — L302–318 ORs together every
  lane port's mask as a fallback.
- `hasActiveLink` (L555–559) gate: lane adapter + active
  `currentWidth` + non-nil `currentSpeed`.

`Sources/WhatCableCore/IOThunderboltLabels.swift` is the rendering
layer. Headline label formula `Up to <perLane> Gb/s × <lanes>` (or
asymmetric `(N TX / M RX)`) at L19–46. Matches
`system_profiler SPThunderboltDataType`.

### 3.2 What PortScope is missing

PortScope reads `Adapter Type` / `Link Bandwidth` / `Description` but
doesn't surface `Current Link Speed` × `Current Link Width` ⇒
"Up to 40 Gb/s × 2" (TB5 dual) vs "Up to 40 Gb/s (3 TX / 1 RX)" (TB5
asymmetric). It also doesn't expose:

- `Buffer Allocation Request` (per-protocol credit reservation).
- `Max Credits`.
- `CLx State` (link-state power management).
- `Dual-Link Port` (pair for dual-lane operation).
- `Lane` (lane number this adapter uses).
- `Min Required TMU Mode`.
- `FW Counters` / `FW Counters Running Total` (348-byte event-counter
  blobs — would need a decoder but the kernel publishes the raw bytes).
- `IOPowerManagement.CurrentPowerState` per switch (sleeping vs active).

The per-lane × width label is the user-facing win; everything else
is for the Developer details disclosure.

### 3.3 Host-port ↔ TB-switch correlation

`Sources/WhatCableCore/IOThunderboltLabels.swift:69–78`
(`ThunderboltTopology.hostRoot(forSocketID:in:)`) walks USB-C port
service name `Port-USB-C@N` → parses `N` → finds the host-root TB
switch whose lane port has `Socket ID == "N"`. This is the canonical
host-port → TB-switch correlation.

PortScope's `tbControllerPCIeSlotMap` in `SidebarView` currently leans
on **registry-allocation-order proximity** (CLAUDE.md explicitly notes
this as a heuristic). The `Socket ID` path is more direct and survives
hardware revisions that change allocation order.

Gate the lookup on `port.carriesData` (L96–99) to avoid the MagSafe
collision called out at L90–95 (issue #195): MagSafe and the
neighbouring USB-C share an `@N` suffix on the same HPM, so without
the gate the lookup leaks USB-C lane state onto MagSafe rows.

`chain(from root:in:)` at L104–125 walks the topology by
`parentSwitchUID` (built once into a `[Int64: [Switch]]` index).
`activeDownstreamLanePort` at L130–139 picks the right link to label
on a downstream switch (skips `upstreamPortNumber`).

---

## 4. USB device → port mapping

### 4.1 What WhatCable does

`Sources/WhatCableDarwinBackend/USBWatcher.swift` builds `USBDevice`
records carrying a `controllerPortName` (`"Port-USB-C@1"`) directly
rather than the locationID-byte heuristic.

The `UsbIOPort` parent-walk at L151–217:

- Walks up to 20 parent hops from each `IOUSBHostDevice` looking for
  the first ancestor with a `UsbIOPort` property.
- That property is a registry-path string (or NUL-trimmed `Data` blob
  — both handled at L202–211) ending in the physical port's service
  name. The last `/`-component is kept if it has the `Port-` prefix
  (L213–217). These are the `usb-drd*-port-hs/ss` nodes that sit
  between the device and the `AppleT*USBXHCI` controller.
- The parent walk also captures `busIndex = (locationID >> 24) & 0xFF`
  from the XHCI ancestor as a fallback (L182–187).

`Sources/WhatCableDarwinBackend/AppleHPMInterfaceWatcher.swift:215–258`
adds the SPMI ancestor fallback for HPM busIndex: walk up to 8 parents
looking for a registry-entry name matching `hpm<N>`, `atc<N>` (M1/M2
era), or `usb-drd<N>` via `busIndex(fromRegistryName:)` at L244–253.
Location-in-plane hex parse is the last fallback (L255–258).

### 4.2 What PortScope is missing

PortScope's CLAUDE.md explicitly calls out this gap:
`TopologyMapper.usbDevicesByPort` maps each `usb-drd<N>` to a physical
port via `locationID >> 24` (drd0 → Port 1, etc.). That works for
direct-attach on M3+ but is the *fallback path* in WhatCable. The
primary `UsbIOPort` walk is more robust — it handles hubs cleanly
(every device under a hub still resolves to the right physical port),
and the SPMI name fallback covers M1/M2 (atc) which the locationID
byte alone doesn't cleanly distinguish.

### 4.3 HPM port ↔ USB device matching

`Sources/WhatCableCore/AppleHPMInterface.swift:219–245`
(`matchingDevices(from: [USBDevice])`) pairs HPM port → USB devices
using `(serviceName | portDescription)` against
`device.controllerPortName`, with `busIndex` (HPM-side) vs `busIndex`
(device-side) compatibility check. The fallback at L241–244 ("USB
carrier present + matching busIndex with no port name") is the
`usb-drd<N>` heuristic PortScope already uses; the primary path is
the named match.

`portNameMatches` at L256–279 is tolerant of base-name match
(`Port-USB-C` vs `Port-USB-C@1`) when bus-indexes are compatible.
`busIndexesAreCompatible` at L293–296 explicitly allows either side
to be nil — important when one of the two services hasn't published
its identity yet.

### 4.4 USB device-side notes

`Sources/WhatCableCore/USBDevice.swift:79–86` — `isRootDevice` check.
Bits 31–24 of `locationID` = bus/controller, bits 23–0 = hub-path
nibbles (one per hop, left-to-right). A root device has exactly one
non-zero nibble in the path. Useful for distinguishing "directly
attached to host port" from "behind a hub." Apple convention since
Snow Leopard, undocumented.

`speedRaw` enum at L60–71: 0 LS, 1 FS, 2 HS, 3 SS (5 Gbps), 4 SS+
(10 Gbps), 5 SS+ Gen 2x2 (20 Gbps).

### 4.5 HPM class list

`Sources/WhatCableDarwinBackend/AppleHPMInterfaceWatcher.swift:21–29`
lists the candidate HPM classes: `AppleHPMInterfaceType10/11/12/18`,
`AppleTCControllerType10/11`, `IOPort`. **`AppleHPMInterfaceType18`
(MacBook Neo / A-series) is not in PortScope's current
`AccessoryScanner.hpmClasses`** (verify against the source — CLAUDE.md
only lists Type10/11). Adding `Type18` is a one-line change but is
required for any A-series Mac the catalogue ends up supporting.

HPM port presence test at `AppleHPMInterface.swift:60–63`:
`PortTypeDescription` ∈ {`"USB-C"`, prefix `"MagSafe"`} AND service
name has `Port-` prefix.

---

## 5. PHY-layer per-lane state

### 5.1 What WhatCable does

`Sources/WhatCableCore/AppleTypeCPhy.swift` plus
`Sources/WhatCableDarwinBackend/AppleTypeCPhyWatcher.swift` watch
`AppleT8132TypeCPhy` (+ T8122/T8112/T6042/T6022/T6002/T6000 variants
— full class list at `AppleTypeCPhyWatcher.swift:18–26`). Each
service represents one physical USB-C port's PHY.

Properties decoded:

- `AppleTypeCPhyID` (port index 0–3) — `AppleTypeCPhyWatcher.swift:128`.
- `AppleTypeCPhyLane` is a dict with sub-keys `"Lane 0"` / `"Lane 1"`
  / etc. Each lane sub-dict has `Transport` (`"CIO"` / `"DisplayPort"`
  / empty), `Power Level` (`"on"` / empty), `Client`
  (`"AppleThunderboltNHIType7"` etc.). Parsed at L131–144.
- `AppleTypeCPhyUSB2` (sub-dict with `Transport` + `Client`) at L147–154.
- `AppleTypeCPhyDisplayPortPclk.Link Rate` (e.g.
  `"5.40Gbps/lane (HBR2)"`) at L157–163.
- `AppleTypeCPhyDisplayPortTunnel` string at L165.

### 5.2 What PortScope is missing

PortScope reads `TransportsActive` from the HPM controller to know
which transports are active — but the *per-lane* assignment ("Lane 0
is CIO, Lane 1 is DP") is only visible via the PHY. `cioLaneCount` /
`dpLaneCount` (`AppleTypeCPhy.swift:48–56`) give the actual count of
lanes carrying each protocol — the authoritative answer for "2-lane
DP-Alt vs 4-lane DP-Alt" on a USB-C port running both CIO and DP
simultaneously.

The HPM controller's `DisplayPortPinAssignment` (decoded in §6) is a
corroborating signal; the PHY tells you the lane state directly.

### 5.3 DisplayPort pin assignment

`Sources/WhatCableCore/DisplayPortLaneConfig.swift:13–56` decodes the
HPM `DisplayPortPinAssignment` integer:

- `0` = no DP
- `1` = Pin Assignment C (4-lane DP)
- `2` = Pin Assignment D (2-lane DP + USB3)
- `3` = Pin Assignment E (4-lane, flipped)
- `4` = Pin Assignment F (2-lane, flipped)

Maps to `.fourLane` / `.twoLane` cases. CLAUDE.md notes PortScope
surfaces DP HPD but doesn't decode 2-lane vs 4-lane — this is the
answer.

`fromPinConfiguration` at L62–69 is deliberately `nil` — Apple's
pin-config dict isn't a reliable inverse.

### 5.4 USB-C pin map (optional, probably overkill)

`Sources/WhatCableCore/USBCPinMap.swift` decodes the HPM
`Pin Configuration` dictionary into the 24 physical USB-C connector
pins (A1–A12, B1–B12). Six keys (`tx1`, `rx1`, `tx2`, `rx2`, `sbu1`,
`sbu2`, each a stringified integer); `dataSignal(from:)` at L191–203
maps `0` = inactive, `1–2` = USB3 SS pair A, `3–4` = USB3 SS pair B,
`5–8` = DP lanes 0–3; `sbuSignal(from:)` at L206–213 maps `0` =
inactive, `1–2` = DP AUX; pin layout `topRow` / `bottomRow` at L147–179.

PortScope doesn't currently expose pin-level signal routing. Probably
overkill for the main UI, but if a "what's actually live on this
connector" view is ever wanted, this is the decoder.

---

## 6. `IOPortTransportState*` services PortScope isn't consuming

A class of dynamic IOKit services that appear when a device is
connected and disappear on unplug. WhatCable consumes four families
PortScope doesn't.

All four use the same cross-service join key: `"<parentPortType>/<parentPortNumber>"`
matching `AppleHPMInterface.portKey`. The join-key helper is duplicated
across `PowerSourceWatcher.swift:111–119`,
`USBPDSOPWatcher.swift:184–192`,
`USB3TransportWatcher.swift:96–102`, and
`TRMTransportWatcher.swift:195–203`. The "BuiltIn" keys take priority
(explicit comment at `USBPDSOPWatcher.swift:181–183`). PortScope
should adopt this single helper and stop re-implementing per-scanner.

### 6.1 `IOPortTransportStateUSB3`

`Sources/WhatCableCore/USB3Transport.swift:11–60`, watcher at
`Sources/WhatCableDarwinBackend/USB3TransportWatcher.swift:82–116`.

Keys: `SuperSpeedSignaling` (1 = Gen 1 / 5 Gbps, 2 = Gen 2 / 10 Gbps;
**`0` is IOKit's "None" sentinel — treat as nil**, see L46–58 note),
`SuperSpeedSignalingDescription`, `DataRole` / `PortDataRole`.

Parent identity via `ParentBuiltInPortType` /
`ParentBuiltInPortNumber` (fallback to `ParentPortType` /
`ParentPortNumber`, then to `Priority & 0xFF`) at L96–102.

**This is the precise USB 3 generation signal**, distinct from
`bcdUSB` (capability) and `kUSBCurrentSpeed` (negotiated speed on the
device). PortScope's existing `usbIsDowngraded` compares the latter
two; the transport-state reading is a third, port-side perspective.

### 6.2 `IOPortTransportStateDisplayPort`

`Sources/WhatCableCore/IOPortTransportStateDisplayPort.swift`,
watcher at
`Sources/WhatCableDarwinBackend/DisplayPortTransportWatcher.swift:118–206`.

Massive payload — every field the kernel publishes for an active DP
link:

- **Link layer:** `lane count`, `max lane count`, `link rate`,
  `link-rate description`, `Tunneled` bool, `HPD_State` +
  description.
- **EDID / monitor identity:** `ManufacturerName`, `ProductName`,
  `ProductID`, `SerialNumber`, `YearOfManufacture`,
  `WeekOfManufacture`, `EDID` blob (full bytes), `DFP Type Description`,
  `BranchDeviceID`, `BranchDeviceOUI`, `SinkCount`, `Role` /
  `RoleDescription`, `TransportType` / `TransportTypeDescription`,
  `TransportDescription`.
- **HDCP:** `AuthorizationRequired` / `Status`,
  `AuthenticationRequired` / `Status`, `HashStatus`.
- **Timing:** `EDIDChanged`, `NominalSignalingFrequenciesHz` array.
- **Parent join:** `ParentPortType`, `ParentPortNumber`,
  `ParentBuiltInPortType`, `ParentBuiltInPortNumber`,
  `ParentPortBuiltIn`.

PortScope's CLAUDE.md notes DP HPD is read via
`IOPortFeatureDisplayPortAlternateMode` — but
`IOPortTransportStateDisplayPort` is the **active-link** view with
lane count, tunneling state, and full EDID, which is strictly richer.

The DisplayPort watcher also publishes
`AsyncStream<DisplayPortUpdate>` (`DisplayPortTransportWatcher.swift:15,
:95`) for per-event consumers — see §11 on architecture.

### 6.3 `IOPortTransportStateUSB2` / `…DisplayPort` / `…USB3` / `…CIO` — TRM properties

`Sources/WhatCableDarwinBackend/TRMTransportWatcher.swift:26–31`
matches all four. TRM = Trust and Restrict Management — the
"this accessory is in limited mode" state.

Keys at L144–175:
- `TRM_State` (0 = Full, 2 = Limited)
- `TRM_StateDescription`
- `TRM_TransportRestricted` / `TRM_TransportSupervised`
- `TRM_IdentificationRestricted`
- `TRM_DeviceLocked`
- `TRM_RelaxedPeriod` (grace period after unlock)
- `TRM_GracePeriodReason` + `…Description`
- `TRM_Profile` (e.g. 2 = "Ask for New Accessories")
- `TRM_ProfileDescription`
- `TRM_CacheMiss`

Per-transport granularity — USB2 can be restricted while DP is
unrestricted. PortScope doesn't surface "this accessory is in
TRM-limited mode" anywhere; this is a one-pill addition.

### 6.4 `IOPortTransportStateCIO` — TB controller's cable assessment

Same file at L177–191, parsed into `CIOCableCapability`
(`Sources/WhatCableCore/CIOCableCapability.swift`). Keys:
`CableGeneration`, `CableSpeed`, `Generation`,
`AsymmetricModeSupported`, `LegacyAdapter`, `LinkTrainingMode`.

This is the TB controller's view of the cable, **independent of the
USB-PD e-marker**. The header doc at L8–19 documents that some active
TB4 cables (CalDigit 2 m) mis-self-report as "passive" in their
e-marker while CIO correctly identifies them — so the e-marker is
not always authoritative.

Notable table at L86–93 (`speedLabel(for:)`): CIO `cableSpeed` codes
confirmed across TB3/TB4/TB5 from real probes — **2 = 20 Gbps (TB3),
3 = 40 Gbps (TB4), 4 = 80 Gbps (TB5)**.

L28–38 warns that `cableGeneration` and `generation` **look like
generation counters but vary per port on the same machine** and do
**not** track TB generation — pass them through raw without deriving
labels.

L41–48 warns `asymmetricModeSupported` is a port-capability
advertisement (`PORT_CS_18.CSA` in the Linux thunderbolt driver), not
"host will actually negotiate asymmetric mode" — Apple Silicon sets
it across the family including Type5 hosts that can't run Gen4.

PortScope doesn't read `IOPortTransportStateCIO` at all. The
e-marker-vs-CIO cross-check unlocks an entire class of "your cable's
e-marker lies" warnings (§7.3).

---

## 7. Plain-English diagnostic verdict

### 7.1 Charging diagnostic

`Sources/WhatCableCore/ChargingDiagnostic.swift:5–28` defines a
`Bottleneck` enum (`noCharger`, `chargerLimit`, `cableLimit`,
`macLimit`, `fine`) plus rendered `summary` + `detail` strings. The
failable init at L31–113 returns `nil` when there is nothing to judge.

**Inputs** (L31–38): the `AppleHPMInterface` port, `[PowerSource]`
(PD PDOs from `IOPortFeaturePowerSource`), `[USBPDSOP]` Discover
Identity responses (cable e-marker is the SOP'/SOP'' entry), optional
`AdapterInfo` (system-wide adapter from
`IOPSCopyExternalPowerAdapterDetails`), a `ChargerWattageSource`, and
`batteryFullyCharged: Bool?`.

**Gating:**
- L39 `PowerSource.preferredChargingSource` — USB-PD wins over Brick ID.
- L47 bails when `port.connectionActive == false`. MagSafe keeps
  cached PDOs around after unplug, so the port flag is the
  authoritative "still attached" signal.

**Decision tree** (comment "Order of suspicion" at L80–83):

| Branch | File:line | Condition |
|--------|-----------|-----------|
| `.cableLimit` | L84–87 | `cableW < chargerW` — cable's e-marker `maxWatts` strictly below charger |
| `.macLimit` | L88–92 | Negotiated PDO is >5W (or >10%) below charger AND below cable — Mac asking for less than offered |
| `.fine` + battery-full | L94–99 | Negotiated within tolerance, `batteryFullyCharged == true` → "Battery full, not charging" |
| `.fine` | L100–103 | Negotiated within tolerance → "Charging well at NW" |
| `.chargerLimit` (system fallback) | L104–107 | No per-port negotiation, only system-wide adapter reading |
| `.chargerLimit` (default) | L108–112 | Charger advertised, negotiation hasn't completed |

**Tolerance band** at L88: `chargerMaxW - max(5, chargerMaxW / 10)`.
Accepts a ~10% rounding gap or 5W absolute, whichever is bigger.

This is **directly portable to PortScope**. PortScope already reads
winning PDO + offered PDOs + cable e-marker maxWatts (the latter once
§1 lands). The verdict is pure arithmetic on top.

### 7.2 Charger wattage source

`Sources/WhatCableCore/ChargerWattageSource.swift:9–86` is the input
resolver. Three cases: `portNegotiated`, `systemAdapterFallback`,
`unknown`.

Decision tree in `resolve(portSources:activePortCount:adapter:)`:

| Step | File:line | Branch |
|------|-----------|--------|
| Brick-ID override | L47–54 | If the only source is "Brick ID" AND exactly one port is active AND `IOPSCopyExternalPowerAdapterDetails().Watts` > brick wattage → use the adapter. Handles a third-party PD brick on MagSafe where the kernel only exposes Brick ID at ~3W but the adapter dict reports the real ~96W. |
| PD takes precedence | L56–59 | Any source with `maxPowerMW > 0` → `.portNegotiated`. |
| PD-present guard | L65–66 | If a USB-PD source exists (even at 0 W) → `.unknown` rather than falling through. Issue #46: on multi-charger Macs, the system adapter could belong to another port. |
| TB-dock fallback | L79–83 | Only one port active AND adapter reports wattage → `.systemAdapterFallback`. Issue #141: TB docks deliver power via paths that bypass per-port PD. |

PortScope currently shows "Power Input" from a single source per port.
The Brick-ID-vs-adapter resolution and the multi-charger guard are
gaps; the `activePortCount` defensive check is a tiny addition.

### 7.3 Data-link diagnostic

`Sources/WhatCableCore/DataLinkDiagnostic.swift:14–88` defines
`Bottleneck { fine, cableLimit, hostLimit, deviceLimit, degraded,
unknownCable, cableContradictsActive }` plus a `Facts` struct that
records every input (`hostGbps`, `cableEmarkerGbps`,
`cableControllerGbps`, `cableGbps` resolved, `deviceGbps`,
`activeGbps`).

**Inputs** (L119–128): port, identities, USB devices, USB3
transports, optional `CIOCableCapability`, TB switch graph, optional
`hostMaxGbps` override.

**Gating:**
- L136 connectionActive guard.
- L143 `port.carriesData` — refuse to diagnose charge-only ports.
- L150–152 only use the USB3 transport if `"USB3" ∈
  transportsActive` — the HPM controller leaves stale USB3 services
  around when actual link is USB 2 (issue #187).

**Active-rate resolution** at L156–158: TB lane speed if
`transportsActive.contains("CIO")` else USB3 signaling generation.
Bail if no active.

**E-marker vs CIO tie-break** at L195–217:
- Both agree (same tier) → take max.
- Disagree → use the one that matches the active link rate; if
  neither matches, CIO wins. `cableSignalConflict` is set.

**Cable/active contradiction** at L234–239: e-marker reports below
active by more than one tier AND no CIO to tiebreak →
`.cableContradictsActive` (L288–293). The "the cable says 10 Gbps but
the link is reading 40 Gbps, something's wrong" verdict.

**Device cap** at L254–265: for a TB partner, use
`partner.supportedSpeed.maxTotalGbps`, falling back to active TB rate.
**Critical**: do NOT use enumerated USB devices behind a TB partner —
a TB dock's internal USB hub IC at 5/10 Gbps does not represent the
dock's actual TB speed (issue #190).

**Floor selection** at L296–310: gather `caps = [(party, value)]`
for cable/host/device, take `min`. If all unknown → `.unknownCable`.

**Degraded detection** at L312–326: `meaningfullySlower(active,
than: expected)` (active < 0.9 × expected, L506–508) → either
`.unknownCable` (if no cable data) or `.degraded`.

**Culprit-priority resolution** at L343–353: when multiple parties
tie at the floor, name them in priority **device → host → cable**.
Rationale at L347–350: only blame the cable when it is the *unique*
floor — otherwise replacing it wouldn't help, so "Cable is limiting
data speed" would mislead.

**Tier matching** at L499–503: `sameTier(a, b) ⟺ 0.9 ≤ a/b ≤ 1.111`.
Tiers are well-separated (0.48 / 5 / 10 / 20 / 40 / 80) so 10% absorbs
rounding.

This is the killer feature for PortScope's per-device downgrade pill.
PortScope already detects downgrade-vs-bcdUSB, but the **culprit
priority** (device > host > cable) and the **e-marker-vs-CIO
conflict** logic are entirely missing. The `Facts` struct shape would
slot under the existing Link Rate card.

### 7.4 Multi-signal port-liveness

`Sources/WhatCableCore/PortLiveness.swift:20–38` —
`isPortLive(port, powerSources, identities, matchingDevices)`. Truth
table:

- Any device or any PD identity → live (L26–27, hard signals from
  terminating watchers).
- Non-MagSafe + `connectionActive` → live (L29–30).
- Power source + `connectionActive` → live (L35; power source alone
  is rejected — issue #47 stale-PDO).
- Else not live.

MagSafe's `connectionActive` is rejected because
`AppleHPMInterfaceType11` keeps it true for several seconds after
unplug.

PortScope's CLAUDE.md already notes `connectionActive` as
authoritative for USB-PD partner detection (the "Empty vs Charging"
fix); the MagSafe-specific override is a gap.

### 7.5 Bullet-list summary engine

`Sources/WhatCableCore/PortSummary.swift:8–29` defines `Status
{ empty, charging, batteryFull, dataDevice, thunderboltCable,
displayCable, unknown }` plus headline, subtitle, and a `[String]`
bullet list.

Bullets are organised into three labelled sections at L96–108:

- **A. Live link / what's plugged in** (L114–227) — TB / USB3 / USB2
  link, DP active, connected device identity from SOP partner or
  FedDetails fallback.
- **B. The cable** (L232–318) — e-marker present? cable speed /
  current / voltage rating, active vs passive, optical, vendor.
- **C. Charging numbers** (L324–358) — charger brand, charger max
  wattage, currently negotiated PDO.

Notable decisions:
- L62–64 `hasUSB3`, `hasUSB2`, `hasTB`, `hasDP` from
  `transportsActive`.
- L71 `pdCapable = supported.contains("CC")` — without CC, no
  Discover Identity. Issue #50: M4 Mac mini front USB-C ports.
- L78–80 `hasEmarker = identities.contains { endpoint ∈ {sopPrime,
  sopDoublePrime} }`. Independent of the port's `ActiveCable` flag
  (passive USB4 / 240W cables also have e-markers).
- L286–300 passive cable + TB active: CIO controller can confirm the
  cable's TB rating even though e-marker says "passive" (because TB
  e-marker speed bits are for USB, not TB).
- L375–381 cable-limit suffix on headline — only emitted when
  `cableW < chargerW`, identical condition to
  `ChargingDiagnostic.cableLimit`.

PortScope's port detail already shows most of these signals
individually; this file is the prose-rendering layer. The grouped
bullet structure (A/B/C) is a clean UI pattern.

---

## 8. Power telemetry deep-dive

### 8.1 `PowerTelemetry.swift` schema

`Sources/WhatCableCore/PowerTelemetry.swift` declares the per-port
telemetry sample shape. `PortPowerSample` (L17–122) fields PortScope
does NOT currently expose:

- L18–20 `portIndex`, `current`, `watts` — basics.
- L21–23 `configuredVoltage`, `configuredCurrent`, `adapterVoltage`
  — distinguishes negotiated vs adapter-side.
- L24–26 `vconnCurrent`, `vconnPower` — VConn (the 5V supply for
  cable e-markers), separated from main rail power.
- L27–28 `filteredPower` (smoothed centiwatts).
- L30 `pdPowerMW` — PD contract wattage.
- L32 `vconnMaxCurrent` — cable's claimed VConn current.
- L34–44 `accumulatedPower`, `accumulatorCount`,
  `accumulatorErrorCount`, plus the same for VConn — lifetime energy
  through each port plus error tally.
- L46 `numLDCMCollisions` — Liquid Detection And Corrosion Mitigation
  collisions, useful for "is this port getting wet?" diagnostics.
- L48–50 `usbSleepPoolPowerMW`, `usbWakePoolPowerMW` — reserved
  sleep/wake budgets.
- L52 `powerState`, L54 `portType`.
- L58–59 `isContractedFallback` — flag for "this sample comes from
  `PortControllerInfo` (no live metering), so voltage is
  unrecoverable."

`CableResistanceEstimate` (L153–172) — linear regression on voltage
drop vs current to estimate cable resistance in milliohms, with
`Status { insufficient, converging, stable, unreliable }`.

`PowerMonitorSnapshot` (L174–191) wraps system + per-port + resistance.

PortScope's `PowerInputScanner` reads only the top-level
`PowerTelemetryData.SystemPowerIn / Voltage / Current`. The kernel
exposes a `PowerOutDetails` array and `PortControllerInfo` array with
per-port live metering — voltage drop, VConn power, error counts,
lifetime energy. The cable-resistance regression is novel and
PortScope-shaped (would slot into the per-port detail).

### 8.2 The 2-second poll, plus the contract-fallback merge

`Sources/WhatCableDarwinBackend/PowerTelemetryWatcher.swift:27–36`
runs a 2-second polling task — same cadence as PortScope's
`refreshPower()`. Confirmation that the cadence is industry-shared,
not arbitrary.

`refresh()` at L46–78:
- Reads `AppleSmartBattery` properties (bulk — see §11).
- Extracts top-level `PowerTelemetryData` for `systemSample`.
- **Merges `PowerOutDetails` (live USB-C metering, no MagSafe) with
  `PortControllerInfo` (contracted, all ports)** at L62–68 — so
  MagSafe ports get a sample with `isContractedFallback = true`,
  voltage 0.

`portPowerSamples(from: PowerOutDetails)` at L161–207 extracts every
per-port field listed in `PowerTelemetry.swift`, plus does the
index-to-portKey resolution.

`portPowerSamplesFromControllerInfo` at L209–249 — for ports without
live metering, decodes the PD contract from
`PortControllerActiveContractRdo` + `PortControllerPortPDO`. The RDO
object-position field is wrong for MagSafe (L225–226), so the
resolution uses fixed-PDO power match against
`PortControllerMaxPower`.

`decodeNegotiatedContract` at L260–298: walks the source PDO list
(each entry is 32 bits), filters to fixed-supply PDOs (bits 31:30 ==
00), decodes voltage (bits 19:10 × 50 mV) and max current (bits 9:0 ×
10 mA), picks the PDO whose power is closest to
`PortControllerMaxPower`. Tie-broken by matching the RDO operating
current, then by highest voltage. **This is how PortScope can render
the negotiated MagSafe contract without a USB-PD source ever
existing.**

Cable resistance regression at L81–159 — least-squares linear fit of
`voltageDrop = (slope × current) + intercept`, with R²
classification: <10 samples → insufficient, <200 mA range →
unreliable, <30 → converging, ≥30 + R²≥0.7 → stable, else unreliable.

`hpmPortKeys()` at L304–343 — walks every HPM controller class
(`AppleHPMInterfaceType10/11/12/18`, `AppleTCControllerType10/11`)
in IOKit traversal order to build the portKey array.

---

## 9. `AppleSmartBattery` schema — full enumeration

`Sources/WhatCableCore/AppleSmartBattery.swift` is the complete IOKit
schema for `AppleSmartBattery`. PortScope reads `BatteryInstalled`,
`ExternalConnected`, and `PowerTelemetryData.{SystemPowerIn,
SystemVoltageIn, SystemCurrentIn}`. Fields the file documents that
PortScope is leaving on the table:

### 9.1 Battery identity (L8–15)

`DeviceName`, `Serial`, `DesignCapacity`, `NominalChargeCapacity`,
`DesignCycleCount`, `GasGaugeFirmwareVersion`.

### 9.2 Battery state extras (L18–32)

`instantAmperage` (vs averaged `amperage`), `virtualTemperature`,
`avgTimeToFull`, `avgTimeToEmpty`, `atCriticalLevel`. PortScope's
`BatteryView` already pulls some of these but not `instantAmperage` /
`virtualTemperature`.

### 9.3 Raw readings (L37–40)

`AppleRawCurrentCapacity`, `AppleRawMaxCapacity`,
`AppleRawBatteryVoltage`, `AppleRawExternalConnected` — pre-smoothed
values useful for diagnostics.

### 9.4 ChargerData struct (L178–210)

- `chargingVoltage`, `chargingCurrent` — what's being delivered to
  the cell *right now*.
- **`notChargingReason` (L181), `slowChargingReason` (L182)** —
  these are the literal **kernel-coded reasons** that would let
  PortScope render "Charging slowly because of X" **without any
  heuristic**. This is the cleanest possible answer for the
  charging-diagnostic feature.
- `timeChargingThermallyLimited` (L186) — duration the SoC throttled
  charging due to heat.
- `vacVoltageLimit` (L187).

### 9.5 PowerTelemetrySystemData (L259–327)

PortScope reads 3 fields; the kernel publishes:

- Instantaneous: `systemLoad`, `batteryPower` (separate from
  systemPowerIn), `wallEnergyEstimate`, `adapterEfficiencyLoss`,
  `systemEnergyConsumed`, `powerTelemetryErrorCount`.
- Accumulated counters (in **milliwatt-seconds** per CLAUDE.md's
  already-documented Pet Peeve):
  `AccumulatedSystemPowerIn`, `AccumulatedSystemLoad`,
  `AccumulatedSystemEnergyConsumed`,
  `AccumulatedWallEnergyEstimate`, `AccumulatedBatteryPower`,
  `AccumulatedBatteryDischarge`, `AccumulatedAdapterEfficiencyLoss`.
- Sample counts for each.

### 9.6 PortControllerInfo array (L330–470)

Per-port-controller stats: `firmware version`, `attach/detach counts`,
`hardResetCount`, `dataRoleSwapCount/FailCount`,
`pwrRoleSwapCount/FailCount`, **`vdoFailCount`** (Discover Identity
failures), **`shortDetectCount`**, `wakeFailCount`,
`sleepCmdFailCount`, **`i2cErrCount`**, `srdyCount/srdoCount` (PD
ping-pong), `activeContractRdo` (the negotiated PDO bitfield),
`portPDOs` (the raw advertised PDO list).

All per-port. The diagnostic counters (`shortDetectCount`,
`vdoFailCount`, `hardResetCount`, `i2cErrCount`) are exactly what a
"how healthy is this port?" view would want to surface. PortScope
currently has no concept of port health counters.

### 9.7 BatteryShutdownReason (L224–256)

Last-shutdown forensics: `shutDownVoltage`, `shutDownTemperature`,
`criticalFlags`, `dataError`.

### 9.8 CarrierMode (L212–222)

### 9.9 Misc

`chargerConfiguration`, `packReserve`, `permanentFailureStatus`,
`batteryCellDisconnectCount` (L44–51).

---

## 10. Top-level cable / adapter model

`Sources/WhatCableCore/CableSnapshot.swift` aggregates everything per
port + system-wide.

`AdapterHVCEntry` / `AdapterInfo` (L7–105) model the system-wide
charger brick from `IOPSCopyExternalPowerAdapterDetails()`. Fields
that aren't in PortScope's current `PowerInputScanner`:

- `hvcMenu` — array of (voltage mV, current mA) entries representing
  the charger's full HVC PDO menu plus the `hvcActiveIndex`.
- `powerTier`, `familyCode`, `adapterID`, `pmuConfiguration`,
  `manufacturer`, `name`, `model`.

CLAUDE.md says PortScope reads `IOPortFeaturePowerIn` and
`PowerTelemetryData` but not `IOPSCopyExternalPowerAdapterDetails()`.
The single CF call exposes the entire HVC menu (every voltage the
charger advertises with the currently-active one highlighted), which
is exactly what users want to see when wondering "could this charger
push 28V if I had an EPR cable?"

`Sources/WhatCableDarwinBackend/SystemPower.swift:9–92` is the parser
for that CF call. `UsbHvcMenu` parsing (V/I pairs the charger
supports) is a clean snippet. L102–118 extension on
`ChargingDiagnostic` is the convenience constructor that fetches the
adapter at the IOKit boundary, keeping the core pure.

---

## 11. IOKit watching architecture

### 11.1 The per-key-read crash fix (issue #181)

This is the single most important reliability lesson. The same
eight-line comment appears in every WhatCable watcher referencing
issue #181:

- `Sources/WhatCableDarwinBackend/AppleHPMInterfaceWatcher.swift:179–186`
- `Sources/WhatCableDarwinBackend/USBPDSOPWatcher.swift:104–110`
- `Sources/WhatCableDarwinBackend/IOThunderboltSwitchWatcher.swift:163–170`
- `Sources/WhatCableDarwinBackend/PowerSourceWatcher.swift:91–93`
- `Sources/WhatCableDarwinBackend/USB3TransportWatcher.swift` (similar pattern)
- `Sources/WhatCableDarwinBackend/TRMTransportWatcher.swift` (similar pattern)
- `Sources/WhatCableDarwinBackend/DisplayPortTransportWatcher.swift` (similar pattern)

The crash: `IORegistryEntryCreateCFProperties` can abort the process
inside `IOCFUnserializeBinary` when the kernel returns malformed
serialised properties — which happens routinely when a service is
being torn down mid-read. The per-key `IORegistryEntryCreateCFProperty`
call has no such failure path.

Bulk fetch is retained only where the consumer enumerates unknown
keys (raw-property dump) or where the service is documented persistent
(`AppleSmartBattery` — explicit carve-out at
`PowerTelemetryWatcher.swift:354–365`).

PortScope's `Services/IORegBridge.swift` uses
`IORegistryEntryCreateCFProperties` everywhere (per CLAUDE.md). Hot-plug
rescans are the dangerous path: a USB device that's been ejected
half a millisecond ago is exactly the failure mode this guards
against. **This is a real, attributable crash hazard PortScope is
currently exposed to.**

The fix is well-scoped: keep the bulk path for the IORegistry-dump
mode (where you genuinely don't know the key list), but use per-key
reads when the scanner knows what keys it's after.

### 11.2 Per-service interest notifications

WhatCable's watchers that care about property changes (link state
moves, PD renegotiation, dock cable plug/unplug) register
`IOServiceAddInterestNotification` with `kIOGeneralInterest` *per
service*, in addition to the matched-notification lifecycle:

- `AppleHPMInterfaceWatcher.swift:138–145` — interest per HPM port,
  fires on PD contract change, transport-active changes, plug/unplug
  signals that don't reissue a matched notification.
- `IOThunderboltSwitchWatcher.swift:335` — interest per TB switch,
  fires on link state changes.
- `AppleTypeCPhyWatcher.swift:185` — interest per PHY, fires on
  lane assignment changes.

PortScope's `IORegMonitor` currently only catches matched and
terminated. A PD-contract change on an already-attached port (e.g.
charger renegotiates from 9V to 20V mid-session) goes unseen until
the 2-second `refreshPower()` poll picks it up via a full accessory
rescan. Adding per-service interest registration for HPM ports + TB
switches is a focused win: ~20 lines per class to add, and turns the
2-second-latency current-state read into a kernel-driven push.

### 11.3 Entry-ID-keyed dedup

`IOThunderboltSwitchWatcher.swift:188, :283–315` keys parent linkage
by **registry entry ID, not mach-port `io_service_t` handle**.
Different IOKit calls return different mach-port handles for the same
registry object; entry-ID dedup keeps lookups stable across them.

This same approach is used for interest-notification dedup in
`AppleHPMInterfaceWatcher.swift:37, :130` —
`interestNotifications: [UInt64: IONotificationPortRef]` keyed by
entryID.

PortScope already uses registry IDs as canonical TBNode identifiers;
extending the same discipline to all hot-plug bookkeeping is consistent.

### 11.4 Cross-service join key (and the "BuiltIn" preference)

A single helper rendering `"<parentPortType>/<parentPortNumber>"` —
duplicated in `PowerSourceWatcher.swift:111–119`,
`USBPDSOPWatcher.swift:184–192`,
`USB3TransportWatcher.swift:96–102`, and
`TRMTransportWatcher.swift:195–203`. WhatCable would benefit from
centralising it; PortScope should centralise from the start when it
adds transport-state readers (§6).

The "BuiltIn" preference (`ParentBuiltInPortType` /
`ParentBuiltInPortNumber` before `ParentPortType` /
`ParentPortNumber` before `Priority & 0xFF`) is documented at
`USBPDSOPWatcher.swift:181–183` — required for power and PD to
resolve to the same port key on the same physical receptacle.

### 11.5 Both class-name families: `IOIOThunderboltSwitch*` vs `IOThunderboltSwitch*`

`Sources/WhatCableDarwinBackend/IOThunderboltSwitchWatcher.swift:22–26,
:308–310` matches both. Apple ships the double-IO prefix on older
macOS / Macs and the single-IO prefix on M5 / macOS 26+. PortScope's
`IORegMonitor` already watches multiple TB classes — should verify
both prefix families are covered (the CLAUDE.md "Things that bit me"
section already calls out the
`AppleThunderboltUSBType2DownAdapter` vs `AppleThunderboltUSBDownAdapter`
suffix split; this is the same kind of trap on a different class).

### 11.6 Should PortScope migrate to per-subsystem watchers?

**No — selective lifting only.**

WhatCable's eight-`@Published`-array model is the wrong shape for
PortScope's snapshot semantics. PortScope's `SystemSnapshot` captures
one consistent moment across ten subsystems; cross-subsystem
invariants (`USB-under-TB graft`, `display-to-port attribution`,
`PCIe slot proximity`) all assume a settled snapshot. Splitting state
into per-watcher `@Published` arrays would cascade through
`TopologyMapper`, `MacPortCatalog`, `displaysAttributed(to:…)`,
`displayOutputsAttributed(to:…)`, and every sidebar view.

The two focused borrowings that **are** clean wins:

1. **Per-service `IOServiceAddInterestNotification`** for HPM ports
   and TB switches, layered on top of the existing `IORegMonitor`
   matched/terminated coverage. Pattern at
   `AppleHPMInterfaceWatcher.swift:129–149`. Keep the 2-second poll
   as backstop and for `PowerTelemetryData` (which doesn't fire
   interest notifications).

2. **Per-key `IORegistryEntryCreateCFProperty`** reads in
   `IORegBridge` for any service that can be torn down mid-read
   (HPM ports, transport states, USB devices). Reserve bulk
   `IORegistryEntryCreateCFProperties` for persistent services
   (`AppleSmartBattery`, internal hardware roots) where the user
   needs all keys.

What's tempting but not worth it:

- Eight `@Published` arrays.
- `AsyncStream<Update>` per subsystem (SwiftUI's `@Published`
  diffing already gives the reactivity).
- Splitting `SystemSnapshot` into eight typed sub-snapshots.

---

## 12. CLI improvements

WhatCable's CLI lives in `Sources/WhatCableCLI/WhatCableCLI.swift`
plus `Sources/WhatCableCore/JSONFormatter.swift` and
`Sources/WhatCableCore/TextFormatter.swift`. Five small lifts worth
considering:

### 12.1 `NO_COLOR` env-var support

`Sources/WhatCableCore/ANSI.swift:8–11` auto-disables on
`NO_COLOR` env var **or** when stdout isn't a TTY. PortScope has
`--no-color` and TTY auto-detection; matching the `NO_COLOR`
convention (<https://no-color.org/>) is three lines.

### 12.2 `--watch` mode

`Sources/WhatCableCLI/WhatCableCLI.swift:156–247`. Three layers:

1. **Provider stream**
   (`Sources/WhatCableDarwinBackend/DarwinSnapshotProvider.swift:106–125`)
   — `AsyncThrowingStream<CableSnapshot, Error>`. A
   `Task { @MainActor in … }` polls once per second, compares to
   `last`, yields only when changed, exits on task cancel.
2. **Signal handling** (L164–179) — `signal(SIGINT, SIG_IGN)` then
   `DispatchSource.makeSignalSource` for both SIGINT and SIGTERM,
   both triggering `watchTask.cancel()`. After the watch task returns,
   `fflush(stdout)`. This guarantees the provider's `onTermination`
   runs and the underlying poller cancels cleanly.
3. **Output diff and screen redraw** (L227–239) — outputs are
   compared as full strings; if changed, `\u{1B}[2J\u{1B}[H`
   clears+homes and the snapshot is reprinted with an ISO timestamp
   header. JSON mode emits **NDJSON** — one self-contained object per
   line — instead of clearing the screen.

PortScope's existing `IORegMonitor` debounce could drive the same
pattern straightforwardly. The cancel/flush dance is the right
reference.

### 12.3 First-class `bottleneck` / `headline` / `subtitle` in JSON

Per-port JSON schema in
`Sources/WhatCableCore/JSONFormatter.swift:70–101`. Charging
and dataLink each become first-class objects with
`{summary, detail, bottleneck, isWarning}` (L499–543), where
`bottleneck` is one of `cableLimit` / `chargerLimit` / `macLimit` /
`degraded` / `cableSignalConflict` / etc.

PortScope's `--json` already separates `physical_ports` from
`thunderbolt`, but doesn't have a single-word bottleneck classifier
or a `headline` / `subtitle` per port. External consumers (the
"scriptable diagnostics" use case) would benefit hugely.

The same `PortSummary` model feeds `TextFormatter` and `JSONFormatter`
so text and JSON cannot drift
(`Sources/WhatCableCore/TextFormatter.swift:67–79`).

### 12.4 `thunderboltSwitchUID` cross-reference

Per-port JSON cites the owning TB switch by UID and the switch is
emitted once at top level
(`Sources/WhatCableCore/JSONFormatter.swift:142–148, :346–378`).
PortScope already emits both `physical_ports` and `thunderbolt.switches`
in JSON; adding the cross-reference UID per port is a one-liner that
makes the JSON noticeably more useful to scripts (no need to re-derive
which switch belongs to which port).

### 12.5 Cable trust flags as JSON codes

`Sources/WhatCableCore/JSONFormatter.swift:253, :312–322` —
`cable.trustFlags[]` is an array of `{code, title, detail}` triples
with stable JSON codes. Lifts directly when §1 + §2 are implemented.

---

## 13. Suggested implementation priority

Rough order, with each item independently mergeable. Numbers in
brackets reference the section above.

| Priority | Item | Effort | Risk |
|----------|------|--------|------|
| 1 | **Per-key reads in `IORegBridge`** for hot-plug-prone services (§11.1) | low | low — strict reliability win, no behaviour change |
| 2 | **Decode `Metadata.VDOs` array** in `AccessoryScanner`; expose cable speed class, current rating, max VBUS, EPR, active vs passive, optical vs copper, retimer/redriver (§1) | medium | low — additive, gated on VDOs being present |
| 3 | **`AppleSmartBattery.ChargerData.notChargingReason` / `slowChargingReason`** surfaced directly on the AC PSU / battery row (§9.4) | low | low — kernel-coded reason strings, no heuristic |
| 4 | **`ChargingDiagnostic` verdict** layered on existing PD plumbing (§7.1) | medium | low — failable init, renders nothing when inputs missing |
| 5 | **`ChargerWattageSource` resolver** for the Brick-ID-vs-adapter case (§7.2) | low | low |
| 6 | **Cable trust signals** on the e-marker surface (§2) | low (after §1) | low — hedged wording avoids accusing users' cables |
| 7 | **`IOPortTransportStateUSB3` reader** for precise USB Gen 1/2 signaling per port (§6.1) | medium | low |
| 8 | **`IOPortTransportStateCIO` reader** for TB-controller cable assessment; enables e-marker-vs-CIO conflict warning (§6.4) | medium | low |
| 9 | **`DataLinkDiagnostic` verdict** with culprit-priority resolution (§7.3) | medium | medium — depends on §1, §6, §7 |
| 10 | **`IOPortTransportStateDisplayPort` reader** for active-link EDID + lane count + tunneling state (§6.2) | medium | low |
| 11 | **Per-lane TB speed × width labels** on lane adapters (§3) | medium | low |
| 12 | **Socket-ID-based host-port ↔ TB-switch correlation**, replacing the registry-allocation-order heuristic (§3.3) | low | medium — verify across every Mac in the catalogue before flipping |
| 13 | **`UsbIOPort` parent walk** in `TopologyMapper`, with locationID byte as fallback (§4) | medium | medium — gated by extensive testing on existing test hosts; locationID currently works |
| 14 | **SPMI ancestor fallback for HPM busIndex** (§4.1) | low | low |
| 15 | **`AppleHPMInterfaceType18` in `AccessoryScanner.hpmClasses`** (§4.5) | trivial | low — verify class actually appears on target hardware first |
| 16 | **`AppleT*TypeCPhy` scanner** for per-lane CIO / DP / USB2 assignment + DP link rate (§5.1) | medium | low |
| 17 | **`DisplayPortPinAssignment` decode** (§5.3) | trivial | low |
| 18 | **`PortControllerInfo` per-port health counters** (`shortDetectCount`, `vdoFailCount`, `hardResetCount`, `i2cErrCount`) on Developer details (§9.6) | medium | low |
| 19 | **`PowerTelemetry` per-port live metering** (`PowerOutDetails` array merge with `PortControllerInfo`) (§8) | medium-high | medium — large schema, many keys |
| 20 | **MagSafe-specific liveness override** (§7.4) | trivial | low |
| 21 | **Per-service `kIOGeneralInterest` notifications** for HPM ports + TB switches (§11.2) | medium | medium — interacts with the existing debounced rescan; needs careful coalescing |
| 22 | **TRM state pill** on accessory detail (§6.3) | low | low |
| 23 | **Cable resistance regression** on per-port detail (§8.1) | medium | low — gated on §19 |
| 24 | **JSON: `bottleneck` field + `thunderboltSwitchUID` cross-ref** (§12.3, §12.4) | low | low |
| 25 | **CLI `--watch` mode** with NDJSON in `--json` mode (§12.2) | medium | low |
| 26 | **`NO_COLOR` env-var support** (§12.1) | trivial | low |
| 27 | **`IOPSCopyExternalPowerAdapterDetails`** + `UsbHvcMenu` parser for system-wide charger view (§10) | low | low |
| 28 | **`USBCPinMap` pin-level signal view** (§5.4) | medium | low — niche, possibly skip |

Items #1, #2, #3, #4, #5, #6, #12, #14, #15, #20, #24, #26, #27 are
the highest-leverage "small change, real user-facing or reliability
benefit" items — a reasonable first wave.

---

## 14. Attribution summary

Every item in §1–§13 can be attributed to specific MIT-licensed
files in WhatCable. The complete file list, all
**Copyright (c) 2026 Darryl Morley, MIT licence**:

**`Sources/WhatCableCore/`**

- `USBPDVDO.swift` — PD Discover Identity VDO decoding (§1)
- `USBPDSOP.swift` — SOP / SOP' / SOP'' model (§1)
- `CIOCableCapability.swift` — TB controller cable assessment (§6.4)
- `CableTrustReport.swift` — counterfeit / trust signals (§2)
- `CableSnapshot.swift` — top-level cable struct (§10)
- `CableReport.swift` — issue-reporter markdown format (§2, niche)
- `VendorDB.swift` — USB-IF VID lookup facade (§2.3)
- `CableDB.swift` — known-cable + vendor SQLite (§2.3)
- `IOThunderboltLink.swift` — per-lane TB speed / width / adapter type (§3)
- `IOThunderboltLabels.swift` — TB label formatter + topology walker (§3)
- `AppleHPMInterface.swift` — HPM port model + USB device matching (§4)
- `AppleTypeCPhy.swift` — PHY model with per-lane assignments (§5)
- `USBCPinMap.swift` — connector pin map (§5.4)
- `USBDevice.swift` — USB device model with locationID conventions (§4.4)
- `USB3Transport.swift` — `IOPortTransportStateUSB3` model (§6.1)
- `TRMTransport.swift` — TRM model (§6.3)
- `IOPortTransportStateDisplayPort.swift` — active DP link model (§6.2)
- `DisplayPortLaneConfig.swift` — pin-assignment 2/4-lane decode (§5.3)
- `ChargingDiagnostic.swift` — charging bottleneck verdict (§7.1)
- `DataLinkDiagnostic.swift` — data-link bottleneck verdict (§7.3)
- `ChargerWattageSource.swift` — charger wattage resolver (§7.2)
- `PortLiveness.swift` — multi-signal port-attached check (§7.4)
- `PortSummary.swift` — bullet-list summary engine (§7.5)
- `PowerSource.swift` — PDO model + portKey join (§4.3, §6)
- `PowerTelemetry.swift` — per-port live telemetry schema (§8.1)
- `AppleSmartBattery.swift` — `AppleSmartBattery` schema (§9)
- `JSONFormatter.swift` — JSON output schema (§12.3, §12.4)
- `TextFormatter.swift` — text output schema (§12.3)
- `ANSI.swift` — ANSI helpers + `NO_COLOR` (§12.1)

**`Sources/WhatCableDarwinBackend/`**

- `IOKitHelpers.swift` — CF→Swift helpers, `wcPortIndex`, `wcPortType` (§6, §11)
- `DarwinSnapshotProvider.swift` — watcher orchestrator (§11)
- `AppleHPMInterfaceWatcher.swift` — HPM port watcher with interest notifications + SPMI fallback (§4, §11)
- `AppleTypeCPhyWatcher.swift` — PHY watcher (§5)
- `USBPDSOPWatcher.swift` — PD VDO watcher (§1, §11)
- `PowerSourceWatcher.swift` — `IOPortFeaturePowerSource` watcher (§11)
- `PowerTelemetryWatcher.swift` — 2-second polling power telemetry + RDO decode + cable resistance regression (§8)
- `AppleSmartBatteryReader.swift` — one-shot AppleSmartBattery reader (§9)
- `USBWatcher.swift` — USB device watcher with `UsbIOPort` walk (§4)
- `IOThunderboltSwitchWatcher.swift` — TB switch watcher, both class-name prefixes, entry-ID parent linkage (§3, §11)
- `DisplayPortTransportWatcher.swift` — active DP link watcher (§6.2)
- `USB3TransportWatcher.swift` — USB3 transport state watcher (§6.1)
- `TRMTransportWatcher.swift` — TRM + CIO transport state watcher (§6.3, §6.4)
- `SystemPower.swift` — `IOPSCopyExternalPowerAdapterDetails` parser (§10)
- `ThunderboltProbe.swift` — raw TB tree dump (niche)

**`Sources/WhatCableCLI/`**

- `WhatCableCLI.swift` — CLI flag dispatch, `--watch` impl, signal handling (§12.2)

**`Sources/WhatCableAppKit/`**

- `CLICommand.swift` — plugin command-protocol shape (orthogonal)

Suggested header for any source file that ports logic from WhatCable:

```swift
// Portions of this file adapted from WhatCable
// (https://github.com/darrylmorley/whatcable), MIT licence,
// Copyright (c) 2026 Darryl Morley. The specific WhatCable source
// files referenced are listed in WHATCABLE_LEARNINGS.md.
```

Plus an inline comment near the ported logic naming the exact source
file (e.g. `// adapted from Sources/WhatCableCore/USBPDVDO.swift`).

---

## 15. Things deliberately not adopted from WhatCable

- **Eight `@Published` arrays as the snapshot model.** PortScope's
  single `SystemSnapshot` is the right shape for its breadth (§11.6).
- **`Sources/WhatCablePlugins/`** — proprietary, not studied.
- **The cable-report-via-GitHub-issue feature** (§2, niche row in
  §10). PortScope's CLAUDE.md emphasises "show what's there", not
  data collection.
- **The bundled SQLite vendor DB.** A bundled JSON list keyed by VID
  is the lighter alternative; the all-zero-key defence (§2.3) is the
  one lesson worth carrying over.
- **The user-curated VID overrides table.** Documented at
  `VendorDB.swift:9–15` as a maintenance hazard that bit upstream;
  PortScope should treat manual overrides the same way.
- **The Linux-port-style approach to USB device→port mapping (via
  typec sysfs).** PortScope is macOS-only by design.
