# PortScope UI Redesign — Study & Implementation Plan

**Status:** proposal, ready to implement
**Audience:** senior SwiftUI engineer
**Target OS:** macOS 26 (Tahoe), Liquid Glass design language
**Source documents:** `audit.md`, `design-research.md`, `CLAUDE.md`

---

## 1. Executive summary

### Diagnosis (what's wrong now)

- **Tile-grid-everywhere.** Every detail view leads with a `StatGrid` (`DetailView.swift:1114–1125`) of icon + label + value cells, even for sparse cases like a built-in router that prints "Vendor — / Model — / Firmware Not reported" (audit §4 #2, §4 #3, `DetailView.swift:295–324`). The dashboard aesthetic suits Heroku, not an inspector.
- **The sidebar is a typographic monotone.** Every row is a two-line tile (`SidebarView.swift:737–748`, `SidebarView.swift:754–773`), so nothing stands out — empty ports, charging ports, attached devices, and displays all wear the same weight (audit §3 #2, design-research §4.1). A user scanning "which port is free?" gets no fast answer.
- **Hero proportions and icon sizes drift between views.** 64 pt circle on the generic hero (`DetailView.swift:100`), 76 pt on Displays/Bluetooth/PCIe (`DisplayViews.swift:183`, `BluetoothViews.swift:102`, `PCIViews.swift:143`); 28 vs 30 pt symbols inside them (`PhysicalPortDetailView.swift:72`, `DetailView.swift:104`). The app reads as multiple apps glued together (audit §5 #1, §5 #2).
- **Christmas-tree colour.** `node.kind.accentColor` paints every sidebar row icon — TB blue, USB green, PCIe orange — and per-bus tinting bleeds into hero circles and adapter chips (`SidebarView.swift:734–750`, `DetailView.swift:101`, `DetailView.swift:489–523`). The eye has no signal-to-noise; everything is "important" (design-research §3.2, anti-pattern #1).
- **Null-rows pollute every grid.** "Not reported" appears on missing firmware, "—" on absent fields, "0 plug events" on idle MagSafe rows (audit §4 #3, §3 #1, `SidebarView.swift:1025–1036`, `DetailView.swift:309–310`). The user sees absence, not presence.

### Vision (what it should feel like)

- **About-This-Mac in tone, Disk-Utility in graphics budget.** Two-column `LabeledContent` rows for property bags; one Disk-Utility-style segmented capacity band per view, max; no card on the hero, no shadow, no big circle (design-research §1, §4.2, §4.5).
- **Sidebar as a noun catalogue.** Each row is *a thing the user can point to on their desk* (design-research §5 #1). One-line rows by default, two-line only when there's a story to tell (a device is plugged in, a display is attached). Status communicated by a 6 pt right-edge dot, the connector symbol stays neutral hierarchical (design-research §4.1).
- **Sentence-case section headers, no ALL CAPS.** The whole app sheds the 2015 Cocoa look in one pass (design-research §3.7, anti-pattern #2). `Text("Power")` at 11 pt Semibold, tracking +0.3, no divider.
- **Status colour is the only saturated colour on screen.** Drop per-bus tinting; selection uses `Color.accentColor`; status uses the seven semantic colours from design-research §3.2 (green/secondary/tertiary/orange/red/yellow/blue). Connector symbols and section icons are hierarchical-rendered SF Symbols in `.secondary` (design-research §3.5).
- **The detail pane is a list, not a dashboard.** Most detail views are one hero + one `PropertyList` + optional `Table` + optional `DisclosureCard` for raw IORegistry. Cards and tile-grids appear only where the user is genuinely scanning (the adapter breakdown), never where they're reading.

### Top 3 highest-leverage changes

1. **Replace every `StatGrid` with `PropertyList` (LabeledContent rows) unless the screen is genuinely a dashboard.** This is design-research's declared highest-leverage change (see "The highest-leverage change" at end of design-research). It single-handedly drops the engineery-dashboard feel of the entire detail pane. Touches `DetailView.swift:1114–1125`, `DetailView.swift:295–324`, `PhysicalPortDetailView.swift:113–172`, `DisplayViews.swift:62–111`, `BluetoothViews.swift:24–49`.
2. **Make sidebar rows one-line by default with a right-edge status dot.** Eliminates the wall-of-two-line-rows in `SidebarView.swift:729–752` / `:754–773` / `:849–896`. Devices and displays still get two lines (because they have a real second fact); empty ports, charging-only ports, MagSafe, and generic controllers go to one line.
3. **Drop per-bus colour tinting on icons.** Replace `node.kind.accentColor` references at `SidebarView.swift:735`, `SidebarView.swift:760`, `SidebarView.swift:801`, `SidebarView.swift:886`, `SidebarView.swift:988`, `DetailView.swift:101–105` with a single hierarchical `.foregroundStyle(.secondary)`. Status colour (the 6 pt dot, the StatusPill) becomes the only saturated swatch.

---

## 2. Design principles

These are rules an engineer can apply at code-review time. Reject PRs that violate them.

**1. Property lists are the default; tiles are the exception.**
If you find yourself writing `LazyVGrid` with `.adaptive(minimum: …)` for a property bag, stop. Use `PropertyList`. Tile grids are appropriate only when each tile has its own iconography and the user is scanning at-a-glance (the AdapterBreakdown on `RouterView` is the one example in PortScope). Default to `LabeledContent` two-column rows; justify any deviation in the PR description.

**2. Don't render absence.**
If a value is `nil`, `0`, an empty string, "Not reported", or "—", **hide the row**. Never render a label paired with "—". This applies to `LabeledContent`, `PropertyList`, tile cells, hero subtitles, and sidebar secondary lines. The current `Stat(label: "Firmware", value: firmware ?? "Not reported", …)` pattern (`DetailView.swift:310`) is banned. Use `if let firmware { PropertyRow("Firmware", firmware) }`.

**3. Status is the only saturated colour.**
The seven status colours from design-research §3.2 (green / secondary / tertiary / orange / red / yellow / blue) are the only saturated swatches allowed on screen. Selection uses `Color.accentColor`. Per-bus tinting (`node.kind.accentColor` at `Models/TBModels.swift`) is decorative; remove from any UI surface. Status dots, StatusPill backgrounds (at 15% opacity), and the active progress fill carry colour. Nothing else.

**4. Weight before size, layout before decoration.**
Hierarchy in a property row is 13 pt Semibold label + 13 pt Regular value (or vice-versa per About This Mac). Don't drop to 11 pt for emphasis; don't shadow; don't border. If two things need to be visually separated, give them whitespace (24 pt between top-level sections, 16 pt between cards) before reaching for a divider or a background.

**5. One pill, one bar, one hero per view.**
Stacked StatusPills (`PhysicalPortDetailView.swift:79–88`: mode badge + accessory badges + power callout) read as competing claims. Pick the dominant one — usually the mode badge — and append the others to the hero subtitle in text. Same for progress bars: never two side-by-side; combine into a single stacked segmented band (design-research §4.5).

**6. Hide IOKit class names and hex IDs unless explicitly requested.**
Per CLAUDE.md "Things that bit me" — `AppleT8142USBXHCI`, `AAPL,phandle`, `IOPCIExpressLinkStatus` raw values, and bare 64-bit registry IDs live behind `DeveloperDisclosureCard` only. The friendly-name pipeline in `NodeFormatter.swift` is authoritative for user-facing labels. SF Mono is reserved for hex/MACs/BSD names; everything else is SF Pro.

**7. Read-only data does not animate.**
Disclosure chevrons rotate at the SwiftUI default 0.2 s easeInOut. Sidebar selection changes are instantaneous. Detail content swap is a 120 ms opacity crossfade. **No springs, scale-ins, pulses, or wiggles** (design-research §3.6, anti-pattern #12). The current `withAnimation(.easeInOut(duration: 0.18))` in `SidebarView.swift:352` is fine; resist any temptation to add `.spring()` or `.symbolEffect(.bounce)`.

---

## 3. Visual design system — tokens

All of this lives in a single new file `PortScope/DesignSystem/DesignSystem.swift`. Enums namespace the tokens (`PSFont`, `PSSpacing`, `PSRadii`, `PSColor`) so they're easy to grep and short at call sites.

### 3.1 Typography

SF Pro everywhere except where digits/hex need to align. SF Mono is allowed for: MAC addresses (`EthernetScanner`), BSD names (`en0`, `disk4s2`), hex registry IDs, and the inside cells of hop tables / PDO tables.

| Token | Use | Size | Weight | SwiftUI |
|---|---|---|---|---|
| `display` | Detail-pane port title | 22 pt | Semibold | `.system(size: 22, weight: .semibold)` |
| `title` | Section banner ("Thunderbolt 5") | 17 pt | Semibold | `.system(size: 17, weight: .semibold)` |
| `subtitle` | Card title | 13 pt | Semibold | `.system(size: 13, weight: .semibold)` |
| `body` | Sidebar primary, default text | 13 pt | Regular | `.system(size: 13)` |
| `bodyEmphasized` | Selected row label, key values | 13 pt | Medium | `.system(size: 13, weight: .medium)` |
| `label` | Left half of `LabeledContent` | 13 pt | Regular, `.secondary` | `.system(size: 13)` + `.foregroundStyle(.secondary)` |
| `value` | Right half of `LabeledContent` | 13 pt | Regular, `.primary` | `.system(size: 13)` |
| `caption` | Sidebar secondary line | 11 pt | Regular | `.system(size: 11)` |
| `captionEmphasized` | Pill text | 11 pt | Medium | `.system(size: 11, weight: .medium)` |
| `section` | Sidebar / detail section header | 11 pt | Semibold, sentence case, +0.3 | see snippet below |
| `mono` | MACs, BSDs, hex IDs | 12 pt | Regular SF Mono | `.system(size: 12, design: .monospaced)` |

```swift
enum PSFont {
    static let display     = Font.system(size: 22, weight: .semibold)
    static let title       = Font.system(size: 17, weight: .semibold)
    static let subtitle    = Font.system(size: 13, weight: .semibold)
    static let body        = Font.system(size: 13)
    static let bodyEmph    = Font.system(size: 13, weight: .medium)
    static let label       = Font.system(size: 13)              // pair with .secondary
    static let caption     = Font.system(size: 11)
    static let captionEmph = Font.system(size: 11, weight: .medium)
    static let mono        = Font.system(size: 12, design: .monospaced)
}

extension View {
    func psSectionHeader() -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)        // override .listStyle(.sidebar)'s uppercase default
            .tracking(0.3)
    }
}
```

### 3.2 Color

```swift
enum PSColor {
    // Chrome — never use as foreground.
    static let card           = Color(NSColor.controlBackgroundColor)
    static let tile           = Color(NSColor.underPageBackgroundColor)
    static let divider        = Color(NSColor.separatorColor)

    // Status — the only saturated palette allowed.
    static let active         = Color.green     // Link Up, tunnel up, charging in
    static let idle           = Color.secondary // adapter present, no traffic
    static let disabled       = Color.tertiary  // "Port is inactive"
    static let warning        = Color.orange    // USB 2.0 on USB 3 cable, undervolt
    static let error          = Color.red       // e-marker mismatch, parse failure
    static let powerIn        = Color.yellow    // Mac is sinking power
    static let powerOut       = Color.blue      // Mac is sourcing power (NOT accent)
}
```

Window background = default (system). Sidebar background is whatever `.listStyle(.sidebar)` applies (`NSVisualEffectView.Material.sidebar` automatically). **Never override the sidebar background**; doing so defeats Liquid Glass (design-research anti-pattern #5).

### 3.3 Spacing

Base unit **4 pt**, exposed as enum members:

```swift
enum PSSpacing {
    static let xs: CGFloat  = 4
    static let s:  CGFloat  = 8
    static let m:  CGFloat  = 12
    static let l:  CGFloat  = 16
    static let xl: CGFloat  = 24
    static let xxl: CGFloat = 32

    static let sidebarRowSingle: CGFloat = 28   // single-line row
    static let sidebarRowDouble: CGFloat = 36   // two-line row
    static let sidebarIndent:    CGFloat = 16   // system default

    static let detailHPadding:   CGFloat = 20
    static let cardPadding:      CGFloat = 16
    static let tilePadding:      CGFloat = 12
    static let sectionGap:       CGFloat = 24
    static let tileMinWidth:     CGFloat = 140
}
```

Replaces ad-hoc `.padding(24)` (`DetailView.swift:29`), `.padding(16)` (DisplayViews, BluetoothViews), `.padding(.horizontal, 8).padding(.vertical, 3)` (StatusPill, ModeBadge).

### 3.4 Material / surface stack

```
L0  Window          system default              (no background applied)
L1  Sidebar         Material.sidebar            (via .listStyle(.sidebar))
L2  Detail pane     .background(.background)    (clear)
L3  Card            PSColor.card, R = 10        (controlBackgroundColor)
L4  Tile (in card)  PSColor.tile, R = 6         (underPageBackgroundColor)
```

**Do not** put glass on cards. Glass on `L3` reads as a layout error (design-research §3.3). Glass is for the sidebar and the toolbar; everything below sits on the standard control surfaces.

The current `SectionCard` (`DetailView.swift:1179–1197`) uses `Color(NSColor.controlBackgroundColor)` and a 10 pt radius — that's L3, keep it. Replace its 14 pt padding with `PSSpacing.cardPadding` (16).

### 3.5 Corner radii

```swift
enum PSRadii {
    static let card:   CGFloat = 10
    static let tile:   CGFloat = 6
    static let chip:   CGFloat = 4
    // Pills use Capsule(); buttons use system default — no custom radii.
}
```

Concentric — inner radius = outer radius − padding. SwiftUI's concentric shapes do this automatically when nested.

### 3.6 Iconography

- **All SF Symbols, hierarchical render, monochrome.** Replace every `.foregroundStyle(node.kind.accentColor)` in the sidebar (lines 735, 760, 801, 886, 988, 1045) with `.symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)`. Selected rows get `.tint` automatically via List selection.
- **Sizes:** sidebar row 16 pt, hero 28 pt, pill 11 pt, section icon 13 pt.
- **One symbol per row, left-aligned, vertically centred.**
- **Section headers get no icon.** "Power" is enough; drop the `icon: "powerplug.fill"` parameter from `collapsibleSection` calls.
- **Custom connector silhouettes (six total).** Build hierarchical-render-compatible SF Symbols for USB-A, USB-C, MagSafe, HDMI, SD, RJ-45. The current `port.mode.symbol` lookup uses generic SF stuff (`cable.connector`, `display`, `powerplug.fill`) which doesn't distinguish receptacle type. New symbols land in `PortScope/Resources/Symbols.symbolset/` as Xcode symbol assets; nothing else is custom.

### 3.7 Motion

- Disclosure: 0.2 s easeInOut (SwiftUI default — currently `0.18` at `SidebarView.swift:524`; round to 0.2 to match the platform).
- Sidebar selection: no animation.
- Detail content swap: 120 ms opacity crossfade. (Apply via `.animation(.linear(duration: 0.12), value: vm.selection)` at the root of `ContentView.detail`.)
- Hot-plug rescan: row insertion at 200 ms opacity (default `List` animation is fine).
- **Banned:** springs, scale-ins, slide-ups, `.symbolEffect(.bounce)`, pulses, glows, wiggles. Inspector apps are read-only; motion implies state change, which here is misleading (design-research §3.6).

---

## 4. Sidebar information architecture

### 4.1 Current IA — what's wrong

The current sidebar (catalogued in audit §6) has good top-level structure (Physical Device → subgroups Power / USB-C / USB-A / HDMI / SD / Ethernet, plus toggleable Thunderbolt / USB / PCIe / Displays / Bluetooth / Internal Hardware sections), but the *row treatment* defeats it:

- **Every row is two-line.** `PortRow` (`SidebarView.swift:729–752`) shows title + statusLabel + locationLabel — three lines on a port with a location. `DeviceRow`, `ControllerBranch`, `USBBranch`, `FullTopologyRow`, `MagSafeRow`, `BatteryRow`, `BluetoothControllerRow`, `DisplaySidebarRow`, `PCIBranch` — *all* two-line, even when there's nothing in the second line worth reading ("Idle", "No external device", "0 plug events").
- **Per-bus colour tinting.** `Image(systemName: …).foregroundStyle(node.kind.accentColor)` paints every icon (lines 735, 760, 801, 886, 988). Combined with the colored mode symbol on `PortRow` (line 735: `port.mode.color`), every row competes for attention.
- **ALL-CAPS subgroup headers.** `collapsibleSubgroup` (`SidebarView.swift:543–578`) applies `.textCase(.uppercase)` to "Power", "USB-C", "USB-A", etc. This is the single most dated visual element in the app (anti-pattern #2).
- **Inconsistent count formatting.** "Connected (4)" on Bluetooth (`SidebarView.swift:262`), no count on Displays (`SidebarView.swift:243`) (audit §3 #9).
- **No status indicator on the right edge.** Status lives in the secondary subtitle text, buried.

### 4.2 New IA — section list

Three default top-level sections (Physical Device, Displays, Bluetooth — visible when toggles are on per design-research §5 #7; PortScope already does this correctly: keep). Inside Physical Device, six subgroups in chassis order: **Power · USB-C · USB-A · HDMI · SD card · Ethernet**. Each subgroup is collapsible (already true at `SidebarView.swift:419–460`); fix the headers to be sentence case 11 pt Semibold tracking +0.3 (drop `.textCase(.uppercase)` at line 569).

Section header treatment:

```swift
Text("Power")
  .font(.system(size: 11, weight: .semibold))
  .foregroundStyle(.secondary)
  .textCase(nil)
  .tracking(0.3)
```

No divider line beneath. The whole header row is the collapse hit target (already true via `.contentShape(Rectangle())` at line 572 — keep).

### 4.3 Row variant gallery

Four variants. The rule (design-research §4.1): **one line by default, two when there's a real story.**

#### Variant A — empty port (one line, neutral)

```
  USB-C  Left Rear USB-C Port
```

- 16 pt connector symbol, hierarchical, `.secondary`.
- 13 pt title, `.primary`.
- No subtitle, no status dot. Empty ports are first-class rows but visually subdued (design-research §5 #4).

#### Variant B — charging-only port (one line, yellow dot)

```
  USB-C  Left Rear USB-C Port                                    •
```

- Yellow right-edge dot (6 pt, 8 pt from right edge), indicating power input.
- No subtitle. The wattage lives in the detail pane.

#### Variant C — device attached (two lines, green dot)

```
  USB-C  Left Rear USB-C Port                                    •
         Anker 568 Hub · USB 3.2 Gen 2
```

- 13 pt title, 11 pt secondary subtitle.
- Green dot = active data link.
- Subtitle is the device name + bus generation, no hex IDs.

#### Variant D — display attached (two lines, green dot, nested under output adapter)

```
  USB-C  Right Front USB-C Port                                  •
         Anker 568 Hub · TB4
   └── Display Output 1                                          •
       DP / HDMI · adapter port 12
       └── LG UltraFine 5K                                       •
           5120 × 2880 · 60 Hz
```

- Nested rows via `OutlineGroup` with default 16 pt indent.
- Display row uses 13 pt title + 11 pt secondary (resolution · refresh).
- Status dot on every active row.

### 4.4 Disclosure / nesting rules

- **Two levels of nesting maximum below a port row:** device, then display/USB-leaf. Deeper hierarchy (a hub-of-a-hub-of-a-hub) is flattened by default (CLAUDE.md "Hide Intermediate USB Hubs"). Don't add a third nesting level.
- **Auto-expand on first render when the row has content** (already implemented at `SidebarView.swift:203–237`; keep).
- **Display Output rows under a USB-C port stay expanded by default** (already done at `SidebarView.swift:219–222`; keep).
- **Chevron position and animation:** `DisclosureChevron` (`SidebarView.swift:509–533`) is correct; standardise rotation timing to 0.2 s (currently 0.18).

### 4.5 Search

`.searchable(text: $vm.searchText, placement: .sidebar)` once total visible row count > 20. On a docked MBP M4 Max with a populated dock, the sidebar already exceeds that threshold. Implementation: filter `physicalDeviceContent` rows by case-insensitive substring match against `port.cliTitle` / `port.statusLabel` / nested device titles. Search bar lives in the sidebar toolbar (sidebar placement, not toolbar placement, so it floats with the sidebar).

### 4.6 Side-by-side ASCII mockup — current vs proposed

Scenario: an M3 Max 14" MBP with an Anker 568 USB-C dock attached to the Left Rear port. Dock has a Logitech MX Master 3S, a USB-A flash drive, and an LG UltraFine 5K attached.

**Current sidebar (today):**

```
─────────────────── PortScope ───────────────────
▼ PHYSICAL DEVICE
  ▼ POWER
    🔌 MagSafe 3 Port
       Idle · 412 plug events
    🔋 InternalBattery
       87% · On AC
  ▼ USB-C
    🔌 Left Rear USB-C Port          ← bright orange icon
       Connected · Thunderbolt 4
       Left Rear
    ▼ 📦 Anker 568                   ← bright purple icon
       USB-C dock · Anker Innovation Ltd
      ├─ 📦 USB2.0 Hub
      ├─ 📦 USB3.0 Hub
      │  ├─ 📦 USB Composite Device
      │  │  Logitech USB Receiver
      │  └─ 📦 Mass Storage Device
      │     Generic Flash Disk
      └─ 🖥 Display Output 1
         DP / HDMI · adapter port 12
         └─ 🖥 LG UltraFine 5K       ← pink icon
            5120 × 2880 · 60.00 Hz
    🔌 Left Front USB-C Port          ← bright orange icon
       Idle
       Left Front
    🔌 Right Rear USB-C Port          ← bright orange icon
       Idle
       Right Rear
    🔌 Right Front USB-C Port         ← bright orange icon
       Idle
       Right Front
  ▼ HDMI
    📺 HDMI Port                      ← bright pink icon
       Idle
```

Twelve rows, eleven of them two-line, eight saturated colours competing.

**Proposed sidebar:**

```
─────────────────── PortScope ───────────────────
Power
  ▼ MagSafe 3 Port
    Internal battery · 87% · On AC

USB-C
  ▼ Left Rear USB-C Port                       •
    Anker 568 Hub · TB4
    ├ Anker 568 Hub
    ├ Logitech MX Master 3S
    ├ Generic Flash Disk
    └ Display Output 1                          •
      DP / HDMI · adapter port 12
      └ LG UltraFine 5K                         •
        5120 × 2880 · 60 Hz
    Left Front USB-C Port
    Right Rear USB-C Port
    Right Front USB-C Port

HDMI
    HDMI Port

  Show: ▾ Thunderbolt   Buses   Internal Hardware
```

Notes on what changed:

- "PHYSICAL DEVICE" header is gone (one top-level section, no need; already handled by `needsTopLevelHeader` at `SidebarView.swift:82`).
- ALL-CAPS subgroup titles → sentence case ("Power", "USB-C") (`SidebarView.swift:569`).
- MagSafe + battery merge into one line under Power (battery hides when not installed — CLAUDE.md "AppleSmartBattery exists on desktops too"). Battery becomes the *subtitle* of MagSafe instead of its own row, because on a laptop they're conceptually the same fact: "how is the Mac being fed power" (open question 9.2 — confirm before merging).
- Empty ports (Left Front, Right Rear, Right Front) are one-line and visually subdued (no dot, hierarchical icon).
- Status dots on the right edge (`•`) replace per-bus icon colour.
- USB hubs flattened (CLAUDE.md default); the dock's internal USB2.0 / USB3.0 hub cascade is hidden.
- Display Output row stays as a real nesting level (it's a kernel entity worth selecting); the display is nested under it.

---

## 5. Detail view templates

### 5.1 Primitives

All live under a new directory `PortScope/Views/DesignSystem/` (separate from the existing `PortScope/Views/` so it's easy to grep "what's in the design system").

| Primitive | File | Responsibility |
|---|---|---|
| `Hero` | `Views/DesignSystem/Hero.swift` | Detail-pane header: 28 pt symbol, 22 pt title, optional 13 pt subtitle, optional single right-aligned StatusPill. No card, no circle. |
| `PropertyList` | `Views/DesignSystem/PropertyList.swift` | Two-column `LabeledContent` rows. Hides any row whose value is nil/empty. Default for every property bag ≤ 12 rows. |
| `PropertyRow` | `Views/DesignSystem/PropertyList.swift` | Single `LabeledContent` with PSColor-styled label/value. |
| `StatusPill` | `Views/DesignSystem/StatusPill.swift` | Refactored from `DetailView.swift:119–159`. One pill per view, capsule, 6 pt dot + 11 pt Medium label. Background `tint.opacity(0.15)`. |
| `Chip` | `Views/DesignSystem/Chip.swift` | Inline small label (transport names, hop tags). Replaces existing `Tag` (`DetailView.swift:847–858`) and `TransportChip` body. |
| `CapacityBar` | `Views/DesignSystem/CapacityBar.swift` | Disk-Utility-style 10 pt segmented bar. Numbers on the bar. Replaces `BandwidthBar` (`DetailView.swift:986–1055`). |
| `ItemList` | `Views/DesignSystem/ItemList.swift` | Wrapper around SwiftUI `Table` with sortable columns. For hop tables, timing modes, USB device lists. Replaces the long ad-hoc `ForEach` lists in `DisplayViews.swift:21–30` and `DetailView.swift:686–700`. |
| `DisclosureCard` | `Views/DesignSystem/DisclosureCard.swift` | Collapsible card. Used for "Developer details" raw IORegistry. Replaces `DeveloperDisclosure` (`DetailView.swift:1082–1094`). |
| `Tile`, `TileGrid` | `Views/DesignSystem/Tile.swift` | The exception. Only used by AdapterBreakdown on the router view, where the user is genuinely scanning at-a-glance. |
| `SectionHeader` | `Views/DesignSystem/SectionHeader.swift` | Sentence-case 11 pt Semibold +0.3 tracking. For both sidebar and detail-pane section labels. |

### 5.2 PropertyList — the workhorse

```swift
struct PropertyList: View {
    let rows: [PropertyRow.Spec]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                if i > 0 { Divider().padding(.vertical, 2) }
                PropertyRow(spec: rows[i])
            }
        }
    }
}

struct PropertyRow: View {
    struct Spec {
        let label: String
        let value: String
        let mono: Bool         // SF Mono only for MACs/BSDs/hex
        let secret: Bool       // show eye toggle (for UIDs)
    }
    let spec: Spec

    var body: some View {
        LabeledContent {
            Text(spec.value)
                .font(spec.mono ? PSFont.mono : PSFont.body)
                .textSelection(.enabled)
        } label: {
            Text(spec.label)
                .font(PSFont.label)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

extension PropertyList {
    /// Builder that automatically skips nil/empty/placeholder values.
    init(@PropertyListBuilder _ build: () -> [PropertyRow.Spec]) {
        self.init(rows: build())
    }
}

@resultBuilder enum PropertyListBuilder {
    static func buildBlock(_ specs: PropertyRow.Spec?...) -> [PropertyRow.Spec] {
        specs.compactMap { $0 }
    }
    static func buildOptional(_ s: [PropertyRow.Spec]?) -> [PropertyRow.Spec] { s ?? [] }
}

extension PropertyRow.Spec {
    init?(_ label: String, _ value: String?, mono: Bool = false, secret: Bool = false) {
        guard let v = value, !v.isEmpty, v != "—", v != "Not reported" else { return nil }
        self.label = label
        self.value = v
        self.mono = mono
        self.secret = secret
    }
}
```

Usage on the router view:

```swift
PropertyList {
    PropertyRow.Spec("Vendor", router.properties["Device Vendor Name"]?.asString)
    PropertyRow.Spec("Model",  router.properties["Device Model Name"]?.asString)
    PropertyRow.Spec("Thunderbolt", tbVersionLabel(router.properties["Thunderbolt Version"]?.asUInt))
    PropertyRow.Spec("Depth",  depth == 0 ? "Built-in" : "\(depth)")
    PropertyRow.Spec("Firmware", shortFirmware(router.properties["Firmware Version"]?.asString))
    PropertyRow.Spec("Unique ID", hex(router.properties["UID"]?.asUInt, width: 16), mono: true, secret: true)
}
```

This replaces `DetailView.swift:295–324` directly. On a built-in (depth-0) router with no firmware, the "Vendor / Model / Firmware" rows simply don't render — the property list is shorter, not full of "—".

### 5.3 Hero spec

```swift
struct Hero: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let status: StatusPill.Status?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PSSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PSFont.display)
                    .textSelection(.enabled)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(PSFont.body)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let status {
                StatusPill(status: status)
            }
        }
        .padding(.bottom, PSSpacing.l)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.5)
        }
    }
}
```

No colored 64/76 pt circle. No accent fill behind the icon. The icon is 28 pt monochrome in `.tint`; the rest is typography. This replaces every hero in `DetailView.swift:94–117`, `PhysicalPortDetailView.swift:65–90`, `DisplayViews.swift:177–208`, `BluetoothViews.swift:96–124`, `BluetoothViews.swift:274–300`, `PCIViews.swift:135–157`, `BuiltInPortViews.swift:45–80`, `BuiltInPortViews.swift:211–241`. **Eight hero implementations collapse to one.**

### 5.4 StatusPill

```swift
struct StatusPill: View {
    enum Status { case active, idle, disabled, warning, error, builtIn,
                       powerIn(String), powerOut(String), custom(String, Color) }
    let status: Status

    var body: some View {
        HStack(spacing: PSSpacing.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(PSFont.captionEmph).foregroundStyle(color)
        }
        .padding(.horizontal, PSSpacing.s)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }

    private var color: Color { /* maps Status → PSColor.{active|idle|…} */ }
    private var label: String { /* "Active", "Idle", "Disabled", "12 W", … */ }
}
```

**One pill per view.** The current PhysicalPortDetailView hero stacks three things (mode badge + accessory badges + power callout, lines 79–88). Pick the dominant one — mode — and append the rest to the hero subtitle as text ("Active · DP · Active cable · 60 W in"). If a port detail needs to communicate four facts, that's a sign the subtitle needs them, not four pills.

### 5.5 Composition rules

| Situation | Use |
|---|---|
| ≤ 12 scalar properties | `PropertyList` |
| > 12 properties or genuinely tabular (hop table, timing modes, USB devices) | `Table` via `ItemList` |
| At-a-glance dashboard (adapter breakdown) | `TileGrid` with `LazyVGrid(.adaptive(minimum: 140))` |
| Bandwidth, capacity, power | `CapacityBar` (max one per view) |
| Single binary state | `StatusPill` (in the hero only) |
| Long raw IORegistry dump | `DisclosureCard` (collapsed by default) |
| Empty / no content for the view | "No active tunnels", "No external device" in `.tertiary` text — no card |

### 5.6 Empty/null handling

Hard rule: **render nothing rather than "—" or "Not reported".** This is the second design principle (§2 #2). Concretely:

- `PropertyRow.Spec.init?` returns `nil` for empty/placeholder values, so the row is simply skipped by the `compactMap` in the builder.
- Hero subtitle: omit if empty (already handled, `DetailView.swift:109–111`).
- StatusPill: omit when no relevant state.
- Cards: don't render the card if its body would be empty. The current `PhysicalPortDetailView` renders an empty "Power Input" card on a port that's not sourcing power — instead, render the card only when at least one of (winning PDO, advertised PDO list, sink wattage) is present.

### 5.7 Detail view template — composed example

Anker 568 router detail (referenced as an exemplar):

```
─────────────────────────────────────────────────────────────────
[breadcrumb] Thunderbolt 4 Controller › Anker 568

🔌  Anker 568                                                  •  Connected
    Anker Innovation Ltd · TB4 · depth 1

────────────────────────────────────────────────────────────────

Vendor                                       Anker Innovation Ltd
Model                                        Anker 568
Thunderbolt                                  Spec 4.0
Depth                                        1
Unique ID                                    0x0123456789ABCDEF      👁

────────────────────────────────────────────────────────────────

Uplink to host
  TB4 · 40 Gb/s · 2 lanes
  ████████░░░░░░░░░░░░░░░░░░░  17 Gb/s reserved · 40 Gb/s max

────────────────────────────────────────────────────────────────

Adapters
  ┌──────────────────┬──────────────────┬──────────────────┐
  │ Lane             │ DisplayPort      │ USB              │
  │ 4 ports          │ 2 ports · 1 live │ 4 ports · 2 live │
  └──────────────────┴──────────────────┴──────────────────┘
  ┌──────────────────┬──────────────────┐
  │ PCIe             │ Inactive         │
  │ 1 port           │ 7 ports          │
  └──────────────────┴──────────────────┘

────────────────────────────────────────────────────────────────

▶ Developer details
```

What changed vs today (`RouterView` at `DetailView.swift:286–325`):
- No 64 pt blue circle wrapping the icon (was at `HeroHeader`, line 98–106).
- Six-cell stat grid → five-row property list. "Firmware" row omitted because Anker doesn't report it. "Built-in / Connected" pill moves to the hero.
- "Uplink to Host" stays but reads as a single bar with text below (current implementation has Label-only at lines 580–586 + separate BandwidthBar — combine).
- AdapterBreakdown stays as a tile grid (this is one of the legitimate dashboard uses). Drop the per-category color tint on the icon; use a single hierarchical tint.

---

## 6. Per-view redesigns

### 6.1 Physical Port — USB-C (dock case)

**Current friction.** `PhysicalPortDetailView.swift:65–90` hero stacks three pill systems (mode badge + accessory badges + power callout). The "What's happening on this port" card (line 178–198) is a prose paragraph that duplicates the mode badge. The connector/cable card (line 257–299) shows "Cable e-marker: Not reported" on USB-C cables without an e-marker (audit §4 #3). Stats (line 113–172) include a "Devices" count tile that's redundant with the device list below.

**Proposed layout.**

```
[breadcrumb] Left Rear USB-C Port

🔌  Left Rear USB-C Port                                       •  Active
    Thunderbolt 4 · Active cable · 60 W in · DP

Connection
  Cable                            Apple TB4 Pro, 1 m
  Cable e-marker                   Apple, 2022
  Plug orientation                 A
  Role                             Host
  Active transports                CIO · USB2 · USB3 · DisplayPort
  Bandwidth                        40 Gb/s · 2 lanes

Power input  ─────────────────────────────  60 W · 20 V · 3 A
  ████████████████████████░░░░░░░░░░░░░░░░  Negotiated · 60 W of 100 W advertised

Power output
  Anker 568 hub                    900 mA · 4.5 W (at 5 V)
  Logitech MX Master 3S            100 mA · 0.5 W
  Generic Flash Disk               500 mA · 2.5 W

What's attached
  Anker 568 (TB router) →

▶ Developer details
```

**Structural changes.**
- Drop "What's happening on this port" card (`PhysicalPortDetailView.swift:178–198`) — the hero subtitle conveys it.
- Drop "Active Transports" card (line 238–247) — merged into the Connection property list as a single row of chips. Use compact comma-and-dot separation, not separate Cards.
- Connector/cable card → "Connection" PropertyList. E-marker row hides when absent.
- Power Input card → single CapacityBar with the numeric label on the bar (Disk Utility pattern, design-research §4.5).
- Power Output table → PropertyList with device-name labels (current implementation at `PhysicalPortDetailView.swift:386–402` has 4 columns; collapse to 2: label = device, value = "900 mA · 4.5 W". Drop the redundant capability column — that's developer-detail territory).
- "Connected TB device" card → single "What's attached" row with a navigation arrow, since the device row already lives in the sidebar.
- USB Devices card capped at 20 → replaced by sidebar nesting (the user already sees devices in the sidebar; no need to duplicate). Drop the card entirely.

### 6.2 Physical Port — USB-A

**Current friction.** Same template as USB-C but the connector/cable card collapses to two rows (no e-marker, no orientation, no PD), and the power input card never renders, leaving a sparse hero.

**Proposed.** Same template as USB-C with cable/power-input rows simply absent.

```
[breadcrumb] Rear USB-A Port

🔌  Rear USB-A Port                                           •  Active
    USB 3.2 Gen 2 · 10 Gb/s · Bus-powered

Connection
  Role                             Host
  Active transports                USB2 · USB3
  Bandwidth                        10 Gb/s

Power output
  USB Audio Interface              500 mA · 2.5 W

What's attached
  USB Audio Interface →

▶ Developer details
```

### 6.3 Physical Port — Empty

**Current friction.** `PhysicalPortDetailView` renders the full template with "Mode: Idle", "Devices: 0", "Power: —", "Cable e-marker: Not reported", etc. — wall of placeholders.

**Proposed.** One-screen empty state:

```
[breadcrumb] Right Front USB-C Port

🔌  Right Front USB-C Port                                  •  Empty
    Thunderbolt 5 · USB4 · DisplayPort 1.4 — nothing connected

Capability
  Generation                       Thunderbolt 5
  Max bandwidth                    120 Gb/s asymmetric
  Power delivery                   100 W in / 5 W out

▶ Developer details
```

Capability data comes from `MacPortLocations.json` (CLAUDE.md). The point of the empty state is to *answer the question "what could I plug in here?"*, not to render zeros.

### 6.4 Physical Port — AC Power (Mac mini)

**Current friction.** `BuiltInPortViews.swift:45–80` has a bold yellow `bolt.fill` icon in a circle and a right-aligned W/V/A trio. Reads as USB-C-PD-like, which is misleading — this is a kettle-cord PSU, not a USB-PD partner.

**Proposed.**

```
[breadcrumb] AC Power

🔌  AC Power                                                  •  61 W

Live telemetry
  Power input                      61.0 W
  Voltage                          120.3 V
  Current                          0.51 A
  Adapter efficiency               92 %

Lifetime energy
  Wall energy drawn                528 Wh
  System energy consumed           487 Wh
  Adapter efficiency loss          41 Wh

▶ Developer details
```

Lifetime energy values converted from mJ (CLAUDE.md "PowerTelemetryData.Accumulated* totals are milliwatt-seconds"). Two PropertyLists separated by a sentence-case header.

### 6.5 Physical Port — Ethernet

**Current friction.** `BuiltInPortViews.swift:211–241` reuses USB-C hero structure with a cable icon.

**Proposed.**

```
[breadcrumb] Ethernet

🔌  Ethernet                                              •  Link Up

Link
  Negotiated speed                 1.0 Gb/s · full duplex
  MAC address                      00:c5:85:0f:bd:cb
  BSD name                         en0
  Driver                           AppleBCMWLANEthernet 4.3.1

▶ Developer details
```

MAC formatted via `prettifyMAC` (CLAUDE.md). Mono only on `00:c5:85:0f:bd:cb` and `en0`.

### 6.6 Physical Port — HDMI

```
[breadcrumb] HDMI

🔌  HDMI                                                  •  Idle

Capability
  Spec                             HDMI 2.1
  Max bandwidth                    48 Gb/s
  Supports                         8K @ 60 Hz, 4K @ 120 Hz, HDR10, Dolby Vision

▶ Developer details
```

When a display is attached the hero pill becomes Active and a "Connected display" row appears; the actual display lives in the sidebar.

### 6.7 Physical Port — MagSafe

```
[breadcrumb] MagSafe 3 Port

⚡  MagSafe 3 Port                                        •  Charging · 96 W

Charging
  Input wattage                    96.2 W
  Voltage                          20.1 V
  Current                          4.78 A
  Cable                            Apple USB-C to MagSafe 3, 2 m

▶ Developer details
```

Unplugged state: pill becomes Idle, the Charging section is replaced by a single line "No charger connected" in `.secondary` text — no card.

### 6.8 USB Device (Logitech mouse)

**Current friction.** `USBDeviceView` (in `DetailView.swift`, the `.usbDevice` branch) uses GenericDeviceView with a StatGrid of vendor/product/USB-spec/speed/serial/location/class — eight tiles for a property bag.

**Proposed.**

```
[breadcrumb] Anker 568 › Logitech USB Receiver

📦  Logitech MX Master 3S                                  •  Active

Device
  Vendor                           Logitech (0x046d)
  Product                          USB Receiver (0xc548)
  USB                              1.1 · 12 Mb/s
  Power                            98 mA at 5 V
  Serial                           —                          ← omitted if absent

Interfaces
  HID                              Mouse, scroll wheel, buttons
  HID                              Consumer control

▶ Developer details
```

PropertyList for scalar device facts; second PropertyList (`Interfaces`) for the protocol stack instead of nested chips.

### 6.9 TB Router (Anker dock detail)

See §5.7 above. Key change: drop the StatGrid (`DetailView.swift:296–316`), replace with PropertyList; keep AdapterBreakdown as the one tile grid; UpstreamLinkCard becomes a single CapacityBar with text below.

### 6.10 TB Lane Adapter (active link)

**Current friction.** `PortView`'s lane-adapter branch (`DetailView.swift:615–702`) has a six-tile StatGrid, a BandwidthBar card, a Link Negotiation 3×3 grid (current/target/supported × speed/width), and an Active Tunnels card. When the link is down, the negotiation grid is all "—" (audit §4 #1).

**Proposed.**

```
[breadcrumb] Anker 568 › Port 12 · Thunderbolt Port

🔌  Port 12 · Thunderbolt Port                            •  Link Up

Link
  Generation                       TB4 · 20 Gb/s per lane
  Width                            2 lanes
  Bus power drawn                  90 mA

Bandwidth  ──────────────────────────────  17 Gb/s of 40 Gb/s
  ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  17 reserved · 32 max planned

Active tunnels (3)
  ┌─────────┬──────┬────────────┬─────────┐
  │ Tunnel  │ Hop  │ Destination│ Counter │
  ├─────────┼──────┼────────────┼─────────┤
  │ 1       │ 7    │ port 14, hop 5 │ 1.2 M  │
  │ 2       │ 8    │ port 14, hop 6 │ 882 k  │
  │ 3       │ 9    │ port 12, hop 3 │ 14 M   │
  └─────────┴──────┴────────────┴─────────┘
```

**Structural changes.**
- StatGrid → 3-row PropertyList.
- BandwidthBar stays but uses the new `CapacityBar` primitive with the numeric on the bar.
- Link Negotiation 3×3 grid → omit when link is down; when up, the data is already in the PropertyList. The Current/Target/Supported triple is developer-detail territory — move to the disclosure card.
- Active Tunnels: replace the per-row HStack of color tags (`DetailView.swift:824–844`) with a sortable `Table` via `ItemList`.

### 6.11 TB Function Adapter (DP/HDMI active)

**Current friction.** `FunctionAdapterPortView` (`DetailView.swift:725–815`) has a six-tile StatGrid where "Status: Active" can sit next to "Active Tunnels: 0" (audit §3 #5). The Reserved Bandwidth tile shows "Negligible (no static reservation)" which is fine but reads oddly in a tile.

**Proposed.**

```
[breadcrumb] Anker 568 › Port 14 · DP or HDMI Adapter

📺  Port 14 · DisplayPort / HDMI                          •  Active · 1 tunnel

Adapter
  Port                             14
  Carries                          DisplayPort (LG UltraFine 5K)
  Reservation                      Negligible (no static reservation)

Active tunnel
  Hop 5 → port 8, hop 3 · counter 2.4 M
```

When idle, the entire body collapses to:

```
📺  Port 14 · DisplayPort / HDMI                          •  Idle

This adapter has no active tunnels — nothing is currently routed through it.
```

No StatGrid, no bandwidth bar (CLAUDE.md: function adapters don't statically reserve TB bandwidth — that 100 Mb/s placeholder lies visually).

### 6.12 External Display (37 timing modes case)

**Current friction.** `DisplayViews.swift:21–30` renders all 37 timing modes as a `ForEach` of icon + label rows. Wall of text (audit §4 #5).

**Proposed.**

```
[breadcrumb] LG UltraFine 5K

🖥  LG UltraFine 5K                                       •  Active

Display
  Engine                           DCP 0
  Type                             External, DisplayPort
  Resolution                       5120 × 2880
  Refresh                          60 Hz
  Color depth                      10 bpc
  HDR                              No

▶ Supported timing modes (37) ─────────────────────────────
   ┌──────────────┬────────┬───────┬─────────┐
   │ Resolution   │ Refresh│ Depth │ Default │
   ├──────────────┼────────┼───────┼─────────┤
   │ 5120 × 2880  │  60.00 │ 10    │   ✓     │
   │ 5120 × 2880  │  59.94 │ 10    │         │
   │ 3840 × 2160  │  60.00 │ 10    │         │
   │ 3840 × 2160  │  59.94 │ 10    │         │
   │ … 33 more rows, sortable by any column                │
   └──────────────┴────────┴───────┴─────────┘

▶ Developer details
```

Timing modes collapse into a disclosure that opens a sortable `Table` (`ItemList`). The default mode gets `checkmark.seal.fill` in `.tint`; all other rows leave the Default column blank (design-research §4.6 — "no empty-circle bullets"). The disclosure title carries the count ("37").

The hero subtitle is dropped (it's the LG UltraFine — the subtitle would just repeat panel info that's already in the PropertyList).

### 6.13 Built-in Display

Same template as External Display with subtitle "Built-in panel" and PropertyList rows for backlight nits, P3 coverage, refresh range derived from `TimingElements[*].VerticalAttributes.PreciseSyncRate` (CLAUDE.md — *not* `IOMFBDisplayRefresh`).

### 6.14 Bluetooth Controller

**Current friction.** `BluetoothViews.swift:24–49` StatGrid of 8 fields. "Supported Profiles" rendered as raw service-name chips (audit §6.4 friction).

**Proposed.**

```
[breadcrumb] Bluetooth

📡  Bluetooth                                              •  On

Controller
  Address                          00:88:65:0e:2a:0b
  Chipset                          Apple Wireless Direct Link
  Firmware                         13.0.0
  Transport                        USB
  Discoverable                     Yes
  Vendor ID                        0x004C
  Product ID                       0x0001

Supported profiles
  Audio · A2DP · AVRCP · HFP · HID · PAN · MAP …
```

Profiles become a single comma-separated wrapped paragraph in `.secondary`, not chips. The chip pattern (`BluetoothViews.swift`) made the profile list look interactive when it's purely informational.

### 6.15 Bluetooth Device

```
[breadcrumb] Bluetooth › AirPods Pro

🎧  AirPods Pro                                            •  Connected

Device
  Address                          a8:5e:0b:12:9c:44
  Type                             Audio · Headphones
  Connection                       Bluetooth Classic + LE
  Firmware                         5E133
  RSSI                             -54 dBm

Battery
  Left earbud                      88 %
  ████████████████████████░░░░
  Right earbud                     90 %
  ████████████████████████░░░░
  Case                             64 %
  ███████████████░░░░░░░░░░░░░

▶ Advertised services (12)
```

Battery bars replace the per-component chips. Services collapse to a disclosure; raw UUIDs live behind it.

### 6.16 PCIe Device

```
[breadcrumb] Apple T2 Coprocessor

📦  Apple T2 Coprocessor                                 •  Active

Device
  Role                             Coprocessor
  Class                            0x108000 (System peripheral)
  Vendor                           Apple (0x106B)
  Device                           0x1801
  Slot                             Built-in
  Link                             Gen 4 · ×4

▶ Developer details
```

Drop the StatGrid (`PCIViews.swift`). The link-status decode (CLAUDE.md "saturates to 0xF / 0x3F on bridges") only renders when valid; otherwise the row is omitted (don't show "Gen 15 ×63" garbage).

### 6.17 Battery

```
[breadcrumb] Internal battery

🔋  Internal battery                                      •  87 % · On AC

Charge
  Current capacity                 87 %
  Cycle count                      142
  Condition                        Normal
  Designed capacity                100 Wh
  Full charge capacity             98 Wh

Live
  Voltage                          12.21 V
  Current draw                     -1.42 A (charging)
  Temperature                      32.8 °C
  Time to full                     38 min

▶ Developer details
```

Two PropertyLists separated by a sentence-case header. The "0% · On battery" subtitle on a desktop (CLAUDE.md — `AppleSmartBattery` exists on desktops as a telemetry endpoint) is **prevented at the sidebar level** by the `BatteryInstalled` check at `SidebarView.swift:63–70`; the detail view is never reached.

### 6.18 Developer Details (raw IORegistry)

`DeveloperDisclosure` (`DetailView.swift:1082–1094`) wraps `PropertyTableView` (`PropertyTableView.swift:81–167`). The table itself is fine; refactor:

- Replace the bespoke key/value rows (`PropertyTableView.swift:81–167`) with a SwiftUI `Table`.
- Filter bar stays at the top.
- Group properties into "Identifiers", "Power", "Bandwidth", "Other" sections via header rows (audit §4 #7 — "users see 100+ rows" without grouping).
- 240 pt fixed key column (current) → flexible with min 200 / max 320, since narrow keys waste space.

---

## 7. Component catalog

### 7.1 New components to build

| Name | Proposed file | Responsibility | Replaces |
|---|---|---|---|
| `PSFont` / `PSSpacing` / `PSRadii` / `PSColor` | `PortScope/DesignSystem/DesignSystem.swift` | Tokens, single source of truth. | scattered `.font(.title2).bold()` (DetailView.swift:108), `.padding(24)` (DetailView.swift:29), `.padding(.horizontal, 8)` (DetailView.swift:128) |
| `Hero` | `Views/DesignSystem/Hero.swift` | One unified hero. | `HeroHeader` (DetailView.swift:94–117), all 8 hero variants enumerated in audit §1. |
| `PropertyList` + `PropertyRow` | `Views/DesignSystem/PropertyList.swift` | Two-column LabeledContent rows. | `StatGrid` (DetailView.swift:1114–1125), `StatCell` (DetailView.swift:1127–1173) used by 5+ views. |
| `StatusPill` (refactored) | `Views/DesignSystem/StatusPill.swift` | One pill per view, status colors only. | StatusPill (DetailView.swift:119–159), ModeBadge (PhysicalPortDetailView.swift:616–628), AccessoryBadges (PhysicalPortDetailView.swift:630–665). |
| `Chip` | `Views/DesignSystem/Chip.swift` | Inline small label. | Tag (DetailView.swift:847–858), TransportChip body (PhysicalPortDetailView.swift:719–786). |
| `CapacityBar` | `Views/DesignSystem/CapacityBar.swift` | Disk-Utility-style 10 pt bar with numbers on the bar. | BandwidthBar (DetailView.swift:986–1055). |
| `ItemList` | `Views/DesignSystem/ItemList.swift` | Sortable `Table` wrapper. | Hop-table ForEach (DetailView.swift:686–700, DetailView.swift:784–800), Timing-modes ForEach (DisplayViews.swift:21–30). |
| `DisclosureCard` | `Views/DesignSystem/DisclosureCard.swift` | Collapsible card with sentence-case header. | DeveloperDisclosure (DetailView.swift:1082–1094). |
| `Tile` / `TileGrid` | `Views/DesignSystem/Tile.swift` | The only legitimate dashboard primitive. | StatGrid only where dashboard semantics genuinely apply (AdapterBreakdown). |
| `SectionHeader` | `Views/DesignSystem/SectionHeader.swift` | Sentence-case 11 pt Semibold +0.3. | ALL-CAPS in collapsibleSubgroup (SidebarView.swift:567–569). |
| `SidebarRow.Empty` / `.Charging` / `.Device` / `.Display` | `Views/Sidebar/SidebarRow.swift` | Four row variants from §4.3. | PortRow (SidebarView.swift:729–752), DeviceRow (754–773), ControllerBranch label (799–809), MagSafeRow (1007–1037), BatteryRow (1039–1078). |
| `StatusDot` | `Views/Sidebar/StatusDot.swift` | 6 pt right-edge dot. | new — replaces buried state in subtitles. |
| Connector symbols set | `Resources/Symbols.symbolset/` | Six custom SF Symbols for USB-A/C/MagSafe/HDMI/SD/RJ-45. | per-connector generic symbols scattered through `port.mode.symbol`. |

### 7.2 Existing components to delete or refactor

| Current file:line | Decision | Why |
|---|---|---|
| `DetailView.swift:1114–1125` (StatGrid) | Refactor (rename to `Tile.Grid`, only used by AdapterBreakdown) | Tile-grid-everywhere is the highest-leverage problem (design-research highest-leverage change). |
| `DetailView.swift:1127–1173` (StatCell) | Delete | Subsumed by Tile primitive; most callers move to PropertyList. |
| `DetailView.swift:94–117` (HeroHeader) | Delete | Replaced by `Hero`. |
| `DetailView.swift:119–159` (StatusPill) | Refactor | New StatusPill with explicit Status enum; drop per-kind dispatch. |
| `DetailView.swift:986–1055` (BandwidthBar) | Refactor → `CapacityBar` | Numbers on the bar, not as separate legend. |
| `DetailView.swift:847–858` (Tag) | Delete | Replaced by `Chip`. |
| `DetailView.swift:1082–1094` (DeveloperDisclosure) | Refactor → `DisclosureCard` | Reuse for any collapsible card. |
| `PhysicalPortDetailView.swift:65–90` (port hero) | Delete | Replaced by `Hero`. |
| `PhysicalPortDetailView.swift:113–172` (port stats) | Refactor → PropertyList | Bag of scalar properties; not a dashboard. |
| `PhysicalPortDetailView.swift:178–198` ("What's happening") | Delete | Information moves to hero subtitle. |
| `PhysicalPortDetailView.swift:238–247` ("Active Transports") | Delete | Merged into Connection PropertyList. |
| `PhysicalPortDetailView.swift:257–299` (connector/cable card) | Refactor → PropertyList | Drop "Not reported" rows; PropertyList builder skips them. |
| `PhysicalPortDetailView.swift:386–402` (power allocation table) | Refactor → PropertyList | 4-column table collapses to label+value; drop "Estimated W" (redundant per audit §4 #4). |
| `PhysicalPortDetailView.swift:616–628` (ModeBadge) | Delete | Merged into StatusPill. |
| `PhysicalPortDetailView.swift:630–665` (AccessoryBadges) | Delete | Information moves to hero subtitle. |
| `PhysicalPortDetailView.swift:719–786` (TransportChip) | Refactor → `Chip` | Generic chip primitive. |
| `DisplayViews.swift:21–30` (timing modes ForEach) | Refactor → `ItemList` | 37-row wall of text → sortable Table behind disclosure. |
| `DisplayViews.swift:62–111` (display stats) | Refactor → PropertyList | Bag of scalars. |
| `DisplayViews.swift:177–208` (display hero) | Delete | Replaced by `Hero`. |
| `BluetoothViews.swift:24–49` (BT controller stats) | Refactor → PropertyList | Bag of scalars. |
| `BluetoothViews.swift:96–124` (BT controller hero) | Delete | Replaced by `Hero`. |
| `BluetoothViews.swift:274–300` (BT device hero) | Delete | Replaced by `Hero`. |
| `BuiltInPortViews.swift:45–80` (AC hero) | Delete | Replaced by `Hero`. |
| `BuiltInPortViews.swift:211–241` (Ethernet hero) | Delete | Replaced by `Hero`. |
| `PCIViews.swift:135–157` (PCIe hero) | Delete | Replaced by `Hero`. |
| `DetailView.swift:295–324` (RouterView StatGrid) | Refactor → PropertyList | See §5.7. |
| `DetailView.swift:565–595` (UpstreamLinkCard) | Refactor | Combine into single CapacityBar + text. |
| `DetailView.swift:454–487` (AdapterCategoryRow + FlowChips) | Refactor | Drop per-category color tint, drop redundant `(7)` pill since title already says "(7)" (audit §3 #8). |
| `SidebarView.swift:543–578` (collapsibleSubgroup) | Refactor | Drop `.textCase(.uppercase)` at line 569. Use SectionHeader. |
| `SidebarView.swift:729–752` (PortRow) | Refactor | One line by default; right-edge status dot; drop `port.mode.color` icon tint. |
| `SidebarView.swift:754–773` (DeviceRow) | Refactor | Drop `.foregroundStyle(.purple)` at line 760. Drop subtitle when redundant. |
| `SidebarView.swift:777–845` (ControllerBranch) | Refactor | Drop `.foregroundStyle(node.kind.accentColor)` at line 801. Subtitle "No external device" → omit entirely (don't render absence). |
| `SidebarView.swift:1007–1037` (MagSafeRow) | Refactor | Subtitle "Idle · 0 plug events" → omit plug-events when 0; merge with battery row on laptops per open question 9.2. |
| `SidebarView.swift:670–699` (DisplayOutputRow) | Refactor | Drop `.foregroundStyle(.pink)` at line 676. Standardise subtitle to "DP / HDMI · adapter port N". |
| `PropertyTableView.swift:81–167` | Refactor | Use SwiftUI `Table`; flexible key column. Add semantic grouping. |
| `BreadcrumbBar.swift:13–62` | Keep (no changes) | Already in line with the design language. |

---

## 8. Implementation phases

Each phase is a self-contained PR. Build in order; don't ship phase 2 without phase 1.

### Phase 1 — Visual primitives & design tokens (1–2 days)

**Goal.** Land the foundation. No user-visible changes except a single demo view consuming the new primitives.

**Files to create.**
- `PortScope/DesignSystem/DesignSystem.swift` — `PSFont`, `PSSpacing`, `PSRadii`, `PSColor`.
- `PortScope/Views/DesignSystem/Hero.swift`
- `PortScope/Views/DesignSystem/PropertyList.swift` (+ `PropertyListBuilder`, `PropertyRow.Spec`)
- `PortScope/Views/DesignSystem/StatusPill.swift` (new version, with `Status` enum)
- `PortScope/Views/DesignSystem/Chip.swift`
- `PortScope/Views/DesignSystem/CapacityBar.swift`
- `PortScope/Views/DesignSystem/ItemList.swift` (wraps `Table`)
- `PortScope/Views/DesignSystem/DisclosureCard.swift`
- `PortScope/Views/DesignSystem/SectionHeader.swift`
- `PortScope/Views/DesignSystem/Tile.swift` (`Tile` + `TileGrid`)

**Files to edit (one demo target).** Pick `RouterView` at `DetailView.swift:286–325` as the proving ground. Rewrite it to use `Hero` + `PropertyList` + a single `Tile.Grid` for AdapterBreakdown.

**Validation.**
- Build: `xcodebuild -project PortScope.xcodeproj -scheme PortScope -configuration Debug -destination 'platform=macOS' build` (CLAUDE.md).
- Run CLI sanity: `"$BIN" --pretty --buses` still emits same data (CLI uses the same scanners; UI changes don't affect it).
- Eyeball check: select an external TB router in the GUI; confirm Hero, PropertyList, AdapterBreakdown render with the new tokens.
- Diff old vs new: old screenshot beside new screenshot; no regressions on data shown.

### Phase 2 — Sidebar IA & row variants (2–3 days)

**Goal.** Replace all sidebar rows with the four-variant system from §4.3. Sentence-case subgroup headers. Right-edge status dots. Drop per-bus colour tinting.

**Files to edit.**
- `PortScope/Views/SidebarView.swift`:
  - **Drop `.textCase(.uppercase)`** at line 569 (in `collapsibleSubgroup`).
  - **Drop `.foregroundStyle(.tertiary)`** + change title font to 11 pt Semibold +0.3 tracking (lines 567–569). Apply via `psSectionHeader()`.
  - **Refactor `PortRow`** (lines 729–752): one-line variant by default, two-line when content; drop `port.mode.color` icon tint, use hierarchical + status dot on right edge.
  - **Refactor `DeviceRow`** (lines 754–773): drop `.foregroundStyle(.purple)`; conditional subtitle.
  - **Refactor `ControllerBranch.label`** (lines 799–809): drop `.foregroundStyle(node.kind.accentColor)`; "No external device" → omit subtitle.
  - **Refactor `USBBranch.label`** (lines 883–895): drop color tint; conditional subtitle.
  - **Refactor `FullTopologyRow.label`** (lines 985–1002): drop color tint.
  - **Refactor `MagSafeRow`** (lines 1007–1037): conditional subtitle (no "0 plug events" when 0).
  - **Refactor `BatteryRow`** (lines 1039–1078): drop per-kind icon color tint; use status dot on right edge for charge state.
  - **Refactor `BluetoothControllerRow`** (lines 1093–1118): drop blue tint; one-line.
  - **Refactor `BluetoothDeviceRow`** (lines 1120–1145): per-device-category symbol stays monochrome; status dot for connection state.
  - **Refactor `DisplaySidebarRow`** (lines 1150–1168): drop `.pink` tint; one-line for built-in, two-line for external with resolution.
  - **Refactor `DisplayOutputRow`** (lines 670–699): drop `.pink` tint.
  - **Refactor `PCIBranch`** (lines 1172–1211): drop color tint.
- `PortScope/Views/SidebarView.swift` (or new file `Views/Sidebar/SidebarRow.swift`): factor the four variants out so changes happen in one place.
- Add `.searchable(text: $vm.searchText, placement: .sidebar)` once row count > 20.

**Validation.**
- CLI: no changes expected; data flow unchanged.
- Eyeball: side-by-side current vs proposed against the Anker dock screenshot in §4.6.
- All four row variants render: empty port, charging port, device-attached, display-attached.
- Test on a Mac with no dock attached (only built-in receptacles) — empty-port rows should be subdued, not blank.

### Phase 3 — Detail view templating sweep (4–5 days)

**Goal.** Every detail view from §6 ported to the template (`Hero` + `PropertyList` + conditional `CapacityBar` / `ItemList` / `DisclosureCard`).

**Files to edit.**
- `PortScope/Views/DetailView.swift`:
  - `ControllerView` (lines 189–282) → PropertyList.
  - `RouterView` (lines 286–325) → PropertyList + AdapterBreakdown (kept) + UpstreamLinkCard (refactored).
  - `PortView` lane-adapter branch (lines 615–702) → PropertyList + CapacityBar + ItemList for hop table.
  - `FunctionAdapterPortView` (lines 725–815) → PropertyList + ItemList for hop table; drop StatGrid, drop BandwidthBar.
  - `LocalNodeView` → PropertyList.
  - `USBControllerView` / `USBHubView` / `USBDeviceView` → PropertyList.
  - `GenericDeviceView` → PropertyList.
  - `BatteryView` (lines 59–60 + linked `BatteryView`) → PropertyList split into "Charge" / "Live" sections per §6.17.
  - `BusView` / `BusSlaveView` / `SoCCoprocessorView` → PropertyList.
- `PortScope/Views/PhysicalPortDetailView.swift`:
  - Hero (lines 65–90) → `Hero`.
  - Stats (lines 113–172) → PropertyList.
  - Drop "What's happening on this port" card (178–198).
  - Drop "Active Transports" card (238–247).
  - Connector/cable card (257–299) → PropertyList "Connection".
  - Power Input card → CapacityBar.
  - Power Output table (386–402) → PropertyList "Power output".
  - "USB Devices" card capped at 20 → drop (sidebar already shows them).
- `PortScope/Views/DisplayViews.swift`:
  - Hero (177–208) → `Hero`.
  - Stats (62–111) → PropertyList.
  - Timing Modes (21–30) → DisclosureCard wrapping ItemList (sortable `Table`).
- `PortScope/Views/BluetoothViews.swift`:
  - Both heroes → `Hero`.
  - Stats → PropertyList.
  - Supported Profiles chip row → paragraph in `.secondary`.
  - Per-component battery → CapacityBar.
- `PortScope/Views/PCIViews.swift`:
  - Hero (135–157) → `Hero`.
  - Stats → PropertyList.
- `PortScope/Views/BuiltInPortViews.swift`:
  - AC hero (45–80) → `Hero`; body → PropertyList with live + lifetime sections.
  - Ethernet hero (211–241) → `Hero`; body → PropertyList.
  - HDMI / SD Card → PropertyList.
- `PortScope/Views/PropertyTableView.swift`:
  - Replace bespoke key/value rows (81–167) with SwiftUI `Table`.
  - Add semantic grouping (Identifiers / Power / Bandwidth / Other).
  - Flexible key column.

**Validation.**
- Every detail view selected → no "—" or "Not reported" anywhere.
- Spot-check: select a built-in TB controller (depth 0) — Vendor/Model/Firmware rows should be absent, not "—".
- Run `"$BIN" --json | jq '.physical_ports[0]'` (CLAUDE.md) — should match what the UI shows; missing fields in JSON should be absent from UI.

### Phase 4 — Polish (2–3 days)

**Goal.** Edge cases, motion, accessibility, light mode.

**Tasks.**
- **Motion sweep.** Confirm no `.spring()`, no `.symbolEffect(.bounce)`, no `.scaleEffect` outside disclosure rotation. Standardise disclosure to 0.2 s easeInOut (currently 0.18 at `SidebarView.swift:524`). Add 120 ms opacity crossfade on detail content (`ContentView.swift:22–101` — wrap the `switch` in a Group with `.animation(.linear(duration: 0.12), value: vm.selection)`).
- **Empty states.** Every section, card, and view has an explicit zero-content treatment: no card, just `.tertiary` prose ("No active tunnels"). No empty cards.
- **Sidebar search.** Implement `.searchable(text: $vm.searchText, placement: .sidebar)` with substring filtering across `port.cliTitle`, `port.statusLabel`, device titles, display names. Threshold: always-visible (let SwiftUI's default behavior handle low-count cases).
- **Accessibility.** Every row has `.accessibilityLabel("Left Rear USB-C Port, active, Anker 568 attached")` instead of relying on the visual subtitle. StatusPill labels include the status word.
- **Light mode pass.** Confirm `PSColor.card` / `PSColor.tile` look right in both modes. Status colors are system semantic and adapt automatically; verify the 15% opacity backgrounds on StatusPill don't read as muddy in light mode.
- **Toolbar.** The diagram button (`SidebarView.swift:147–154`) — confirm with user (open question 9.1) whether to keep, drop, or rethink.
- **Custom connector symbols.** Build six symbol assets in `Resources/Symbols.symbolset/`. Wire through `port.mode.symbol`.

**Validation.**
- Tab through the entire sidebar with VoiceOver — every row announces correctly.
- Switch system to light mode — every view still legible.
- Hot-plug a USB device with the app open — row insertion uses default 200 ms opacity, no jarring movement.
- Resize the window from 800 pt down to 620 pt min — no layout breakage; sidebar stays 280 pt wide.

---

## 9. Open questions

These need a decision from the user before phase 3 begins (they affect detail-view templates).

1. **Diagram view.** The toolbar button at `SidebarView.swift:147–154` opens `DiagramView` from a sheet. Audit doesn't mention it as a friction point but the redesign also doesn't address it. **Question:** keep as-is, drop, or rethink (e.g. embed as a "Topology" tab in the detail pane for a selected router)? Recommendation: drop unless there's evidence users open it. Sheets in inspector apps are unusual.

2. **Power subgroup composition.** Today the sidebar's Power subgroup combines Internal Battery + MagSafe + AC PSU (CLAUDE.md). The proposed §4.6 mockup merges battery into MagSafe's subtitle on laptops. **Question:** keep them as separate rows (current behavior) or merge into one "Power input" row with battery state in the subtitle? Recommendation: separate rows are more honest about what's a physical receptacle (MagSafe) vs an internal state report (battery); revert to current behavior unless you explicitly want the merge.

3. **Custom connector symbols.** §3.6 proposes building six custom SF Symbols (USB-A, USB-C, MagSafe, HDMI, SD, RJ-45). **Question:** invest the design effort, or use SF Symbols approximations (`cable.connector.horizontal`, `display`, `powerplug.fill`)? Recommendation: invest. Half a day of icon design pays dividends — the receptacle is the most user-recognisable thing in the app.

4. **Sidebar `.searchable` threshold.** §4.5 suggests > 20 rows. **Question:** always-on (a search bar even with 5 rows), threshold-gated (only appears > 20), or omit entirely? Recommendation: always-on. The cost is one row of toolbar height; the value to a developer auditing a docked Mac is real.

5. **Per-port StatusPill semantics.** §5.4 says one pill per view, with the dominant status. On a USB-C port that's simultaneously charging (power in 60 W), carrying data (USB3 active), and feeding a display (DP active), the dominant status is debatable. **Question:** prefer "Active" (data) when both data and power are live, or stack two pills (violating the one-pill rule for this specific case)? Recommendation: "Active" with the hero subtitle carrying the rest ("Active · 60 W in · DP"). One pill stays the rule.

6. **Empty port subtitle policy.** §4.3 Variant A shows empty ports with no subtitle. But ports do have a chassis-relative location (`port.locationLabel` like "Left Rear"). **Question:** show the location as a subtitle on empty ports (two-line), or fold the location into the title ("Left Rear USB-C Port") and leave the row truly one-line? Recommendation: fold into title — `port.cliTitle` already includes location (`SidebarView.swift:738`). The third line at `SidebarView.swift:743–748` (separate `locationLabel`) is redundant; drop it.

---

## 10. Risks & trade-offs

### What might feel worse

- **Loss of dashboard density on the TB router page.** Today's `RouterView` (`DetailView.swift:286–325`) packs six tiles into a single screen-width row. A PropertyList of the same data takes more vertical space. Users who liked the at-a-glance density will perceive this as "less information per pixel". Mitigation: keep the AdapterBreakdown TileGrid (the legitimate dashboard) so the page still has visual variety; users get density where it matters.
- **Loss of color cueing in the sidebar.** Removing `node.kind.accentColor` means the user can no longer instantly tell "is this row a TB thing or a USB thing" by color. The section header ("Thunderbolt" / "USB") and the connector symbol carry that info instead, but the recognition is slower at first. Mitigation: the new connector symbols (custom USB-A vs USB-C silhouettes) make the receptacle type unambiguous; users adapt within a session.
- **Sentence-case headers feel less assertive.** ALL-CAPS reads as authoritative ("POWER" feels like a category, "Power" feels like a label). Some users will perceive this as a softening. Mitigation: this is the trade-off the entire industry made post-2023; iOS Settings, About This Mac, Apple Mail, Things 3, Linear, Raycast all use sentence case now. We're aligning with the platform, not deviating.
- **Empty ports are easy to overlook.** Subdued styling (no dot, hierarchical icon) means they read as inactive — which they are, but a user scanning for a free port still has to read the rows individually. Mitigation: the lack of a status dot *is* the "this is empty" signal. We could add a single subtle ◦ (open circle) to empty rows to give them a visual handle, but design-research §4.6 ("no empty-circle bullets") warns against this in lists.

### Reversible decisions

These can be flipped back via a setting or a build flag:

- **One-line vs two-line sidebar rows.** Could be a `@AppStorage("compactSidebar")` toggle if pushback is heavy.
- **Sentence case headers.** A single `psSectionHeader()` call site — flip back to `.textCase(.uppercase)` if needed.
- **Per-bus color tinting.** Single `node.kind.accentColor` lookup; if users insist, restore the tint behind a `showBusColors` toggle.
- **AdapterBreakdown tile colors.** The per-category color (lane=blue, displayPort=pink, etc.) at `DetailView.swift:441–450` — easy to restore.

### Irreversible decisions

- **Deleting eight hero implementations down to one.** Once `Hero` is the single source, restoring the per-view heroes would require recreating them. Mitigation: don't do this. The new `Hero` has all the surface area the old eight needed; if a future view legitimately needs a different layout, it's a new primitive, not a regressed one.
- **Removing "Not reported" / "—" rows from the data path.** The `PropertyRow.Spec.init?` builder skips empty values at compile time. To restore, every call site has to reintroduce the dummy values. Mitigation: this is the right direction; don't reverse it.
- **Custom connector symbols.** Once shipped, removing them creates worse-than-baseline UI. If we ship them, we commit to maintaining six SF Symbols and keeping them rendering correctly across hierarchical, multicolor, and palette variants. Mitigation: gate phase 4 on having a real design pass on the symbols.

### "If users hate X we can revert by..."

- **If users hate sentence-case headers:** `Find Replace` `psSectionHeader()` with the old uppercase implementation in a single file (`SectionHeader.swift`). Five-line revert.
- **If users hate the one-line-default sidebar:** flip `SidebarRow.Empty` and `SidebarRow.Charging` to always render the subtitle. One conditional per row variant.
- **If users hate the removal of "Not reported":** add a `Settings → Show absent fields` toggle that switches `PropertyRow.Spec.init?` from failable to non-failable.
- **If users miss the dashboard density on Router:** restore the StatGrid as a single `Tile.Grid` above the PropertyList. The two coexist (PropertyList becomes "Full details" below); the Tile grid carries the dashboard.
