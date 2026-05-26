# IOService-Updates — proposed sidebar additions & data-model work

Companion to `design/IOService-M3Max-MacBookPro.md` and `design/IOService-M5Max-MacBookPro.md`. Both are field guides over a single IOService export per machine; the obvious next question is *"now that we know what's in there, what should PortScope actually surface?"*. This file answers that, split into **High / Medium / Low** by how user-visible the win is vs. how much work it takes to wire up. Probe quotes throughout are taken live from this host (M5 Max, `J716cAP`, build `25F71`).

The two source docs agree on most of the silicon catalogue (M3 Max → T6031, M5 Max → T6050). The substantive deltas — **Exclaves**, **Apple-first-party Wi-Fi**, **Thunderbolt 5 / CIO80 PHY**, **`AppleProcessorTrace`**, and **TSN networking** — are M5-only and so any new surface needs to degrade cleanly on M3.

Existing scanners already classify everything we want into kinds & groups: the gap is mostly *not surfacing it*, not *not seeing it*. `NodeFormatter.socCoprocessorTitle` + `InternalHardwareScanner.categorise` are the single biggest leverage points — every "show this in the sidebar" win below ultimately threads through them.

---

## High priority

### H1 · Camera detail view (currently the worst miss)

`AppleH13CamIn` (M3) / `AppleH16CamIn` (M5) is a *goldmine* and PortScope shows none of it. Live on this host:

```
ISPFirmwareVersion = "5.502"
ISPFirmwareLinkDate = "Apr 27 2026 - 21:14:34"
FrontCameraModuleSerialNumString = "DNMHQ901SHW000124B"
FrontCameraExpected = Yes
FrontCameraActive = No
FrontCameraStreaming = No
IOExclaveProxy = Yes               ← M5 only: routed through Exclaves
IOReportLegend = { … rich counters … }
```

The current "Cameras" sidebar row is a USB-style summary. Add a dedicated `CameraDetailView` that promotes the ISP front-end to a hero card with firmware version, link date, module serial, active/streaming state, and (on M5) an Exclave-isolated badge. The IOReport legend has labelled per-event counters (`Total Interrupts`, `ISPCPU Commands Sent`, `ISP_CPU_PS On Time (ms)`, etc.) which can drop into the Developer Details disclosure using the existing `PropertyTableView` pattern.

**Effort:** new scanner pass + view, ~200 LOC. No new model types — wrap properties in a small `CameraISPInfo` struct.

### H2 · HDCP role/capability per Display

`AppleSEPHDCPManager` publishes **14 channels** matching the live external-display count + headroom. Each `AppleHDCPInterface` carries decodable state:

```
HDCPChannel = 7
HDCPRole = "Transmitter"              ← active output
HDCPTransport = 1                     ← 0 = DP, 1 = HDMI/eDP
HDCPCapabilityMask = 2                ← 1 = 1.x, 2 = 2.x, 3 = both
HDCPTXCapabilities = { Protocols = (1, 2) }
HDCPRXCapabilities = { Protocols = (1, 2) }   ← downstream sink advertising support
```

Map channels to displays via the DCP pipeline that holds each interface. Surface as a one-liner under each `DisplayDetailView`: **"HDCP: 2.x active (downstream supports 1.x + 2.x)"** or **"HDCP: TX 2.x capable, no active session"** for idle outputs. Today users have no way to know whether a given monitor link is content-protected. This is a question we get on every dock-with-HDCP-monitor user thread.

**Effort:** `HDCPState` model on `Display`, scanner pass walking `AppleHDCPInterface` siblings of each `AppleDCPExpert` / `dcpext0–3`, one card in `DisplayDetailView`.

### H3 · Trusted Accessory inventory under Touch ID / Bluetooth

`AppleTrustedAccessoryManager` (= `sep-endpoint,stac`) anchors a child tree of `AppleTrustedAccessory` entries — Apple's authenticated-accessory pipeline. Live sample:

```
AppleTrustedAccessory:
  VendorID = 1452                   ← Apple
  ProductIDArray = (666, 671, 801, 802)   ← Magic Keyboard family PIDs
  AccessoryReady = Yes
  DeviceUsagePairs = ({"DeviceUsagePage"=65280,"DeviceUsage"=77})
  +-o AppleMesaAccessory            ← Touch ID Magic Keyboard
```

This is *the* place we'd learn that the user has a Touch ID Magic Keyboard paired and authenticated by SEP. The chained `AppleMesaAccessory` under the trusted entry tells us SEP has Mesa-style fingerprint capability over this peripheral. Surface as a Section under **Touch ID** ("Authenticated Apple Accessories: 1") that expands into product-ID-resolved rows. Reuse `MacPortCatalog`-style static lookup keyed on `(VendorID, ProductID)` so an Apple Pencil, Magic Trackpad, AirPods firmware bridge, etc. each render with a real name instead of a hex PID.

**Effort:** new `TrustedAccessoryScanner`, a small VID/PID table seeded from the Apple HID enumeration, one view.

### H4 · Exclave-isolation badge (M5+, future-proof for M6)

`IOExclaveProxy` + the seven named proxies (`ANEExclaveProxy`, `ExclaveSEPManagerProxy`, `SecureRTBuddyProxy(AOP-EXCLAVE)`, `isp-exclave-proxy`, `isp-exclave-s-proxy`, plus `mapper-*-exclave` DARTs) are the new secure-world boundary. The existing coprocessor cards have *no* way to communicate "this engine is hardware-isolated from the kernel."

Two complementary surfaces:

1. **Per-engine badge** in detail views — Camera / ANE / AOP / SEP / DCP rows pick up a small lock-shield "Exclave-isolated" pill when the matching proxy exists. Heuristic: check for the exclave-companion DART (e.g. `mapper-dcp-exclave`, `mapper-isp-piodma0-exclave`) since some proxies expose almost no properties (`ANEExclaveProxy` is literally `{}` — its presence *is* the signal).
2. **Top-level "Secure World" section** behind Show All Devices, listing every `IOExclaveProxy`-tagged node + the `CheerF25F71.UniversalMacExclaveOS` cryptex graft so the user can see "what's inside the exclave."

Make this generation-aware: M3 has none of these, so the badge & section both fall away cleanly on T6031 hosts. The flag is published as `"IOExclaveProxy" = Yes` on the node properties dict — trivial to read via `IORegBridge`.

**Effort:** new `TBNodeKind.exclaveProxy`, scanner that emits an `ExclaveInventory`, badge wiring in three detail views.

### H5 · Security posture panel in System Info

Right now PortScope's About-this-Mac panel has chip / cores / RAM / OS / build but says *nothing* about the security stance — which is one of the most-asked questions on M-series machines. The plumbing is all already in `IOService`:

| Property | Source | Meaning |
|---|---|---|
| `BootPolicy` matched | `IOResources` | Secure boot policy module is loaded |
| `AppleLockdownMode` present | `IOResources` | Lockdown Mode capability available |
| `AppleMobileFileIntegrity` present | `IOResources` | AMFI enforcing code signing |
| `AppleSystemPolicy` present | `IOResources` | Gatekeeper / system policy enforcement |
| `EndpointSecurityDriver` present | `IOResources` | ES framework live |
| `ExclaveSEPManagerProxy` present (M5+) | exclave | SEP is exclave-isolated |
| `AppleS8000AESAccelerator` present | resource | HW AES for storage encryption |
| `RTBuddyEntropyEndpoint` (M5+) | RTKit | Hardware TRNG endpoint |

Render as a single card with chips (Lockdown Mode • Boot Policy • AMFI • System Policy • Exclave SEP • Hardware AES • Hardware Entropy). Each chip is present/absent, no live state needed for the headline read. The richer Boot Policy mode (Full / Reduced / Permissive) requires reading `nvram` `boot-args`/`securemode` and may need a separate disclosure.

**Effort:** `SystemInfoSnapshot.security: SecurityPosture?`, scanner pass over a handful of `IOServiceMatching` calls, ~50 LOC of view.

### H6 · NFC chip surface (Stockholm)

This was the surprise of the audit. `AppleStockholmControl` matches `"nfc,primary,gpio"` with `"nfc.log" = Yes` — there is a working **NFC reader** on the MacBook Pro chassis. Used internally for hardware authentication / repair-mode handoff, not exposed to user apps, but it's a piece of silicon the user has and PortScope is the kind of tool that should tell them about it.

Add under Internal Hardware → Radios (or alongside Wi-Fi/BT in the sidebar): "**NFC Reader** · Apple Stockholm". Single row; no live state needed at first pass. The same chip exists on every MBP since the 2021 redesign.

**Effort:** trivial. One entry in `NodeFormatter.exactCoprocessor` (`"stockholm-control"` or matching by class name) plus optional category bump.

### H7 · Generational metadata + chip-name lookup

`NodeFormatter.controllerFriendlyName` already keys off `IONameMatch`, but the *SoC name string* surfaced under About-this-Mac is currently inferred elsewhere. Both audit docs identify the SoC unambiguously from class names:

- T6031 / G15 / `AppleH15PlatformErrorHandler` / `AppleMCA2Cluster_T603x` → **M3 Max**
- T6050 / G17 / `AppleSoCErrorHandler` / `AppleT6050MemCacheController` / `AppleProcessorTraceT6050` → **M5 Max**

Add a tiny `SoCIdentifier` lookup that maps the **first matching class** in a probe list to a `(family, codename, marketing)` tuple. The class-name match is more reliable than `sysctl hw.model` because Apple sometimes ships the same model code across two silicon revisions (Mac Pro is the classic example). The lookup is one-shot per scan.

Side benefits, all enabled by the same `SoCIdentifier`:

- **Processor Trace capability**: presence of `AppleProcessorTraceT6050` → "Hardware instruction trace: supported". M5+ only.
- **GPU architecture**: `AGXAcceleratorG15X` → "Apple G15", `…G17X` → "Apple G17". (Already partially derivable, but explicit chip-arch lookup is clearer than "AGX family-9".)
- **Memory cache controller class** → tells you whether you're on `T603x` / `T605x` system-cache silicon.

**Effort:** small data table + lookup helper. Touches `SystemInfoSnapshot` only.

---

## Medium priority

### M1 · gPTP / AVB / Time-sync visibility

`IOTimeSyncgPTPManager` is present on both M3 and M5 with a per-platform `TemperatureSensor` lookup baked in (it picks which PMU thermal channel to read for clock-drift compensation). `IOAVBNub` exposes a 64-bit `EntityID` — the AVB / IEEE-1722 entity identifier this Mac uses on the network. Useful for users doing Pro Audio over Thunderbolt or AVB-class networked audio. One small card under Networking would cover it.

### M2 · AOP voice trigger state

`AppleAOPVoiceTriggerController` (M3) / `AOPVoiceTriggerService` (M5) is the always-on "Hey Siri" / Voice Control pipeline. It runs even when the main CPUs are asleep, on the AOP. Today it's hidden — surface as a row inside the existing AOP coprocessor detail: "Voice Trigger: active (Hey Siri)" or "Voice Trigger: idle".

### M3 · SoC fault handler rename + last-fault disclosure

`AppleH15PlatformErrorHandler` (M3) was renamed to **`AppleSoCErrorHandler`** on M5. The class still publishes panic/wake/sleep action codes via `IOPlatformPanicAction = 1000` etc. Add to the Security & Power group with a one-line subtitle. Not a feature; just makes sure it doesn't disappear silently on a future Mac generation.

### M4 · Display panel TCON identification

The internal display's timing-controller chip is published as `AppleParadeDP855TCON` (M3 16″ / M5 16″ both). M3 14″ uses `AppleParadeDP825TCON`. `AppleTCONComponent` × 6 hangs as sub-modules. Surface under the internal-display detail row as **"Panel TCON: Parade DP855"** — gives a hint for users debugging panel-side issues (refresh, mini-LED dimming zone behaviour) since the TCON dictates what the panel can advertise back over EDID.

### M5 · Apple USB SuperSpeed (AUSS) controller (M5)

`AppleT6050USBXHCIAUSS` + `AppleUSBXHCIAUSSPort × 15` is new on M5 — a dedicated *internal* SuperSpeed host independent of the external `usb-drd*` xHCIs. This is what enumerates the FaceTime camera / internal Touch ID transport / etc. on M5. M3 didn't have it (used the regular `usb-auss,t6050` path under a single AUSS controller). Surface in the Internal USB section as a distinct controller so the user can see internal USB is on its own xHCI now.

### M6 · Catalogue gaps in `NodeFormatter.exactCoprocessor`

The M3/M5 walks turn up several device-tree names that don't have entries in the existing table and silently fall into "Other Coprocessors":

| Name | Suggested label | Notes |
|---|---|---|
| `auss-cpu0` | Apple USB SuperSpeed Coprocessor | M5 new |
| `iop-aop2-nub` / `aop2` | Always-On Processor 2 | M5 new — second AOP |
| `iop-gfx1-nub` | GPU Coprocessor 1 | M5 new — second GFX-ASC |
| `iop-voicetrigger-controller` | Voice Trigger Coprocessor | both |
| `mcc` (already mapped, but check both `mcc` & memcache controllers) | Memory Cache Controller | classnames differ |
| `gfx-asc` | GPU Coprocessor 0 | already mapped to "GPU Coprocessor" — make it 0 to match the new 1 |
| `secure-repair,1` (`AppleSecureRepair`) | Self-Service Repair Endpoint | both |
| `nfc,primary,gpio` (`AppleStockholmControl`) | NFC Reader | both |

Also update `InternalHardwareScanner.categorise`:
- Add `aop2` → `.securityPower`
- Add `gfx-asc` already maps to `.displayAndGraphics`; `gfx1`/`gfx2` will too via the prefix list.
- Add `nfc` to `.radios`.
- Add a new `voicetrigger` token to `.mediaImage` (sits next to ANE since it's an ML inference path).

### M7 · System Cryptex inventory

`AppleAPFSGraft` count grew from 37 → 40 between M3 and M5; the new entries are signed system cryptexes (`MetalToolchainCryptex`, `…SystemCryptex`, and on M5 `CheerF25F71.UniversalMacExclaveOS`). Today the Storage section lumps these in with regular APFS volumes. Pull them into a subsection: "**Signed System Cryptexes** · 3" listed by their cryptex name + signing manifest hash if accessible. The Exclave OS cryptex is *especially* interesting because its presence is itself a generation indicator.

### M8 · Apple Authentication Coprocessor relay (M5)

`AppleAuthCPRelay` + `AppleAuthCPUserClient` are new on M5 — a relay node for AuthCP traffic (the protocol Apple uses to authenticate signed accessories over Lightning/USB-C). Worth tracking as it shows up, but the wire-level meaning is still TBD on macOS; treat as a stub entry under Security & Power until we can say something specific.

### M9 · Time-Sensitive Networking tag for Wi-Fi (M5)

`TSNWiFiInterface` + `TSNUserWiFiControlInterface` are M5 firsts. Add a "**TSN-capable**" chip to the Wi-Fi row when these are present. Pairs naturally with the new gPTP card from M1.

### M10 · MacPortCatalog entry verification for `J716cAP` (M5 Max 16″)

The M5 Max 16″ ships as `Mac17,12` / platform code `J716cAP`. Per the CLAUDE.md "MacBook Pro chassis is consistent since 2021" guidance, port layout should match M4 Max verbatim with just the capability string bumped (TB5 → TB5; same). Worth a confirming `"$BIN" --json | jq '.host'` run on this host (currently does — the host is the dev machine) to make sure marketing_name resolves and Spec strings render correctly. If it doesn't, that's a small `Resources/MacPortLocations.json` addition, not a code change.

---

## Low priority

### L1 · DART / IOMMU summary

The DART tree is the single biggest invisible category in PortScope today — 43 controllers + 157 mappings on M5. Surfacing every one as a node would bury everything else, but a single Internal Hardware "**DMA Isolation**" row with the counts plus a flat list of "engines under DART protection" (ANE / AVD / ISP / ACIO / APCIE) is a one-disclosure win for security-curious users. The mapper-nubs are already pulled by `IORegBridge`; just need a counting pass.

### L2 · IOReport legend decoder

Many nodes publish a public `IOReportLegend` (Touch ID Mesa, ISP, etc.) with labelled channels: `"Total Resets"`, `"ESD Resets"`, `"Power State"`, per-block on-time in ms. These are the same counters `powermetrics` reads. PortScope can render the *legend* (channel names + units) in Developer Details without actually subscribing to the counters — which is a clean, sandbox-safe disclosure. Full counter sampling needs `IOHIDEventSystemClient` for thermal, but legend metadata alone is a free read.

### L3 · CoreCapture channel inventory

`CCIOService × 66` (M5) / `× 50` (M3), `CCLogStream`, `CCPipe` — these are the live log channels for Wi-Fi / Bluetooth / DCP / firmware. A diagnostic disclosure under a new "Telemetry" group in Internal Hardware: "**66 active log channels**" + a developer-only expandable list. Currently invisible.

### L4 · DCP endpoint catalog

65× `DCPEndpointV2` per export — every typed mailbox between kernel and Display Coprocessor. Useful only when debugging a hung pipeline. Already accessible via the raw IORegistry dump in Developer Details, but a curated "DCP Endpoints (65)" disclosure under each `dcpext*` row would be friendlier than the raw tree.

### L5 · AudioDMA channel inventory

M3 has **56** `AudioDMAChannel`s; M5 has **18**. That's a real architectural change — the scheduler design moved from a static large pool to a smaller dynamically-allocated pool with `IOPAudioNode` + `ADMAChannelInterface` glue. Surface as a single row under Audio: "**DMA channels: 18**" with the count diffable across generations. Dev-focused.

### L6 · IOWatchdogTimer status

`AppleARMWatchdogTimer` + `IOWatchdogUserClient` — kernel watchdog. One bit ("armed") + the user-client retain count. Not actionable for most users but a nice dev disclosure under Internal Hardware → Security & Power.

### L7 · Disk image source attribution

`Apple Disk Image Media × 6` (M3) / `× 8` (M5) is currently grouped under Storage. Split into:
- Xcode simulator runtimes (DMG path under `/Library/Developer/CoreSimulator/...`)
- User-mounted images
- System cryptexes (paired with M7)

The path is readable via the registry tree's `IOHDIXController` parent. Just better grouping.

### L8 · `IOHIDPowerSource` (UPS / external battery)

`IOHIDPowerSourceController` matches `Type = PowerPack` HID translation services — used for HID-class UPS devices and certain USB battery packs. Empty today (no UPS attached) but if/when a user plugs one in, it'd show up here. Worth a one-row stub that hides itself when empty.

---

## Data-model improvements (separate from sidebar additions)

These are refactors / new fields that several of the above proposals depend on.

### High

1. **`TBNodeKind.exclaveProxy`** — new enum case in `Models/TBModels.swift`. Classified in `NodeFormatter.classify` when the node's class is `IOExclaveProxy` / `ANEExclaveProxy` / `ExclaveSEPManagerProxy` / `SecureRTBuddyProxy` *or* when `props["IOExclaveProxy"] == Yes`. Required for H4.
2. **`SystemInfoSnapshot.security: SecurityPosture?`** — new struct with `lockdownAvailable`, `bootPolicyMatched`, `amfiActive`, `endpointSecurityActive`, `exclaveSepActive`, `hardwareAESPresent`, `hardwareTRNGPresent` Booleans. Drives H5.
3. **`SystemInfoSnapshot.socIdentifier: SoCIdentifier`** — `(family: "M5 Max", codename: "T6050", gpu: "G17", supportsProcessorTrace: true)`. Class-name lookup table in a new `Services/SoCCatalog.swift`. Powers H7 and lets every existing chip-aware UI bit query a single source of truth.

### Medium

4. **`DisplayHDCPState`** on `Display` — `role: .transmitter | .receiver | .none`, `txCapabilities: HDCPProtocolSet`, `rxCapabilities: HDCPProtocolSet`, `capabilityMask: UInt8`. Decode `HDCPRole` string, `HDCPCapabilityMask` UInt, and the `Protocols` arrays inside `TXCapabilities` / `RXCapabilities`. For H2.
5. **`TrustedAccessoryInfo`** on system snapshot — list of `(vendorID, productIDs, accessoryReady, capability)` rows with a friendly-name lookup. For H3.
6. **`CameraISPInfo`** carried alongside the existing `CameraInfo` — wraps `AppleH13CamIn` / `AppleH16CamIn` properties (firmware version, link date, module serial, expected/active/streaming, `IOExclaveProxy` flag). For H1.
7. **`SystemCryptexInventory`** under `Storage` — list of `(cryptexName, mountPoint, signingHash)` rows pulled from `AppleAPFSGraft` entries whose grafted path looks cryptex-ish. For M7.

### Low

8. **`DARTSummary`** on internal hardware — counters + a `engines: [String]` list of which engines are DMA-isolated. For L1.
9. **`IOReportLegendEntry`** decoder for any node whose `IOReportLegendPublic == Yes`. Read-only; no subscription. For L2.

---

## What deliberately *isn't* in here

- **User-client live counts** (170× `RootDomainUserClient`, etc.). These reflect *activity at capture time*, not hardware. Showing them encourages users to "fix" something that doesn't exist.
- **DCP / AFK endpoint enumeration as a top-level section**. There are 65–93 of these per machine; the value is roughly zero outside DCP debugging. Keep as a dev-disclosure if anything (L4).
- **APFS Volume listing reshuffles**. The current Storage section reads fine; the only worthwhile addition is the cryptex split (M7).
- **Per-process Metal client (`AGXDeviceUserClient × 161`)**. Same reasoning as user-client counts — activity, not hardware.
- **Generic `IOService` / `IOPlatformDevice` wrappers**. These show up in the raw class frequency tables but carry no user-meaningful state.
