# PortScope Design Research

Notes for redesigning PortScope to "Apple Design Award finalist" caliber. Concrete tokens, opinionated. Written against macOS 26 (Tahoe) and the Liquid Glass design language unveiled at WWDC25.

---

## 1. Genre exemplars

### System Information.app — closest analog, also cautionary tale

**Steal:** two-column NavigationSplitView; detail pane as a real sortable `Table` (not a card grid); no hero card on selection.
**Reject:** typographic flatness (every value same weight/size/color), mixed all-caps + sentence-case headers, 1990s control-panel density.

### About This Mac (macOS 14+)

**Steal:** the LabeledContent rhythm — two-column "key …… value" list, labels `.secondary`, values primary at the same point size. That contrast carries the whole design. No section headers below ~6 properties. One quiet hero (chassis illustration); everything else is text.

### Disk Utility

**Steal:** the single prominent capacity band — ~10 pt segmented horizontal bar with numbers on the bar itself. The most graphical element in the app. PortScope's bandwidth / PD visualizations should look like this, not sliver-tiles in a grid.

### Things 3 (macOS 26 update)

**Steal:** 28–30 pt sidebar rows, 13 pt regular text, 16 pt icons as the only saturated thing in the sidebar. Sections collapse on header click. Tahoe update added "a touch of glass in the sidebar that lets a hint of color shine through" — restrained Liquid Glass. One brand accent (yellow), muted blue/red/green only for status. Never more than three saturated swatches on screen at once.

### DaisyDisk

**Steal:** the discipline that **one** iconic visualization carries the app's identity (the sunburst) and everything else is quiet typography. Pick *one* hero — likely a per-port "what is attached where" canvas — and let the rest stay quiet.

### Raycast (honorable mention)

**Steal:** three-tone surface ladder (sidebar / content / card) of near-blacks, 6–10 pt radii, 1 pt hairline borders, no saturated chrome. The antidote to PortScope's Christmas-tree problem.

---

## 2. Apple HIG synthesis for an inspector app on macOS 26

- **Sidebar width: 225–275 pt min, 350–400 pt max.** PortScope's 280 pt is fine.
- **Two sidebar levels max.** Section → row. Deeper hierarchy belongs in the detail pane.
- **Lightweight rows:** one icon, one title, at most one short secondary line.
- **Don't fight `.listStyle(.sidebar)`** — it applies `NSVisualEffectView.Material.sidebar` automatically. No custom background; no hard sidebar/detail divider.
- **macOS 26 sidebars are inset, floating, Liquid Glass.** Use `backgroundExtensionEffect()` so content flows behind. Glass on sidebar and toolbar only — never on content cards (reads as layout error).
- **No tinted sidebar icons in Tahoe.** Monochrome SF Symbols, hierarchical rendering. Color is for status, not ornament.
- **Use mini/small/medium controls** (rounded rectangles) for dense inspectors. Large/x-large (capsules) are for touch-friendly layouts.
- **Concentric radii:** inner = outer − padding. SwiftUI's concentric shapes do this automatically.
- **Scroll edge effects** replace hard dividers. Use the *hard* variant on macOS under pinned text.
- **Express hierarchy through layout and typographic weight** — not borders or saturated colors.

---

## 3. Design language proposal

### 3.1 Typography

All SF Pro. SF Mono only where digits/hex need to align (MACs, BSD names, hex IDs).

| Token | Use | Size | Weight |
|---|---|---|---|
| display | Detail-pane port name | 22 pt | Semibold |
| title | Section banner ("Thunderbolt 5") | 17 pt | Semibold |
| subtitle | Subgroup labels | 13 pt | Semibold |
| body | Default, sidebar primary | 13 pt | Regular |
| bodyEmphasized | Selected row, key values | 13 pt | Medium |
| label | Left half of LabeledContent | 13 pt | Regular, `.secondary` |
| caption | Sidebar secondary line | 11 pt | Regular |
| captionEmphasized | Pill text | 11 pt | Medium |
| section | Sidebar headers ("Power") | 11 pt | Semibold, sentence case, tracking +0.3 |
| mono | Hex IDs, MACs, BSD names | 12 pt | Regular SF Mono |

Rules:

- **Body is 13 pt on macOS.** Don't drop below 11 pt — fastest way to lose the "engineery" look.
- **Use weight, not size, for in-column hierarchy.** 13 pt Semibold label + 13 pt Regular value beats 13/11 same-weight.
- **SF Mono only for tabular data.** "Thunderbolt USB 3.1 Controller" is prose — SF Pro. Mono-ing every technical string makes the app look like a terminal.

### 3.2 Color

Dark-first. System semantic colors throughout.

**Chrome (no color):** window background = default; sidebar = `Material.sidebar`; cards = `Color(NSColor.controlBackgroundColor)`; tiles inside cards = `Color(NSColor.underPageBackgroundColor)`; dividers = `Color(NSColor.separatorColor)` used sparingly. Prefer whitespace.

**Accent:** **`Color.accentColor` (system), not a custom blue.** Highest-leverage native-feel choice. Apply to: sidebar selection, primary buttons, active progress fill, the active status dot. Nothing else.

**Status palette (the *only* saturated color allowed):**

| State | Color | Use |
|---|---|---|
| Active / Link Up | `.green` | Live data, tunnel up, link negotiated |
| Idle / Reserved | `.secondary` | Adapter present, no traffic |
| Disabled | `.tertiary` | "Port is inactive" |
| Warning | `.orange` | USB 2.0 fallback on USB 3 cable, undervolt |
| Error | `.red` | Cable e-marker mismatch, parse failure |
| Power Input | `.yellow` | Mac is sinking power |
| Power Output | `.blue` (not accent) | Mac is sourcing power |

**Drop per-bus tinting.** Bus identity is conveyed by section heading + SF Symbol; color is reserved for status. This kills the Christmas-tree effect.

**SF Symbols: hierarchical, single tint.** Not multicolor, not palette. Uniform visual weight across the sidebar.

### 3.3 Material & surface stack

```
L0  Window         system default
L1  Sidebar        Material.sidebar (via .sidebar list style)
L2  Detail         clear
L3  Card           controlBackgroundColor, 10 pt radius
L4  Tile (in card) underPageBackgroundColor, 6 pt radius
```

**Radii:** window 10, card 10, tile 6, pill = half height, buttons system default. No custom-radius buttons.

**Borders & shadows:** no shadows on cards (looks like dirt on translucent dark). Hairline 1 pt borders only where two same-value surfaces abut; usually radius + value contrast is enough.

**No 1 pt divider between sidebar and detail** — macOS 26 dissolves that split. Use `backgroundExtensionEffect()`.

### 3.4 Spacing rhythm

Base unit **4 pt**. Tokens: xs 4 / s 8 / m 12 / l 16 / xl 24 / xxl 32.

- Sidebar row height: **28 pt single-line, 36 pt two-line.**
- Sidebar indent per nest level: 16 pt (system default).
- Detail pane horizontal padding: 20 pt.
- Card padding: 16 pt all sides.
- Tile padding: 12 pt all sides.
- Tile min width: 140 pt via `LazyVGrid(GridItem(.adaptive(minimum: 140), spacing: 8))`. Drop tiles before reducing padding.
- Between top-level sections in detail: 24 pt.

### 3.5 Iconography

- **SF Symbols, hierarchical, medium weight.** `.symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)` for inactive sidebar; `.foregroundStyle(.tint)` for selected and status-bearing.
- Sizes: sidebar row 16 pt; hero card 28 pt; pill 11 pt.
- **One symbol per row, on the left, vertically centered.** Section headers get no icon — "Power" is enough.
- **Custom symbols only for connector silhouettes** (USB-A, USB-C, MagSafe, HDMI, SD, RJ-45 — six total). SF Symbols' built-in cable family is weak for these. Build a hierarchical-render-compatible set; nothing else custom.

### 3.6 Motion

- Disclosure: 0.2 s easeInOut (SwiftUI default).
- Sidebar selection: no animation. Detail content swaps with 120 ms opacity crossfade.
- Hot-plug rescan: row insertion animates with 200 ms opacity. No pulse, no glow, no wiggle.
- **No springs, no scale-ins, no slide-ups.** System Information, Disk Utility, Activity Monitor don't animate. Inspector apps are read-only; motion implies state change, which here is misleading.

### 3.7 Section headers

**Sentence case, `.secondary` gray, 11 pt Semibold, tracking +0.3 — not uppercase.** PortScope's current ALL-CAPS POWER / USB-C / USB-A is the 10.7 Cocoa convention. Apple has moved on (About This Mac, Settings refresh, Things 3, NetNewsWire, 2025 ADA finalists all use sentence case).

```swift
Text("Power")
  .font(.system(size: 11, weight: .semibold))
  .foregroundStyle(.secondary)
  .textCase(nil)     // override .sidebar's default uppercasing
  .tracking(0.3)
```

No divider line under the header. Whole header row is the hit target for collapse (`.contentShape(Rectangle())`), not just the chevron.

---

## 4. Component patterns

### 4.1 Sidebar row — one line by default, two when there's a real story

Today every row is two lines, so nothing stands out. Instead:

- **Empty port** → one line: "Left Rear USB-C Port"
- **Charging only** → one line + yellow status dot
- **Device attached** → two lines: device name + "USB 1.1 · 1.5 Mbps" in 11 pt secondary
- **Display attached** → two lines: monitor model + "DP via TB"

**Status indicator:** 6 pt colored circle on the *right edge*, not on the icon. Apple Mail's unread-dot pattern. The connector icon stays neutral hierarchical.

Nested children (USB tree, attributed displays): `OutlineGroup` with the default 16 pt indent and default chevron. No custom drawing.

### 4.2 Hero card

Replace the colored circular hero + status pill with a quieter row:

```
[28 pt symbol]  Left Rear USB-C Port              [• Active]
                Thunderbolt 5 · USB4 · DisplayPort 1.4
```

Symbol in accent color, title 22 pt Semibold, subtitle 13 pt secondary, one pill top-right. 32 pt top padding, hairline separator below. No card background.

### 4.3 Property display — `LabeledContent` vs Tile vs `Table`

The single most consequential decision.

- **`LabeledContent` two-column rows** for detail panes with ≤ 12 scalar properties. Power Input, USB-PD profile, link status, MAC info — most PortScope detail panes belong here.
- **Tile grids** only for at-a-glance dashboards where each tile has its own iconography and the user is scanning, not reading.
- **`Table` with sortable columns** for property bags > 12 rows or genuinely tabular data: hop tables, timing modes, USB device lists.

```
Connector         USB-C
Role              Host
Cable             Apple TB5 Pro, 1 m, e-marker
Plug orientation  A
Bandwidth         80 / 80 Gb/s symmetric
```

does the work of 5 tiles in a third of the space, more legibly.

### 4.4 Status pill

One per hero, capsule 18 pt tall: 6 pt dot · 8 pt gap · 11 pt Medium label. Background `tint.opacity(0.15)`, foreground `tint`. **Never stack pills.** If you need "+ DP", append to the subtitle.

### 4.5 Progress / capacity

- **Lane adapters (real bandwidth):** single 6 pt segmented bar with `accentColor` fill on `quaternaryLabelColor` track, label below in 11 pt secondary.
- **Function adapters with active tunnel:** no bar. Show "Active · *N* hops" as text; hop table below as `Table`.
- **Function adapters idle:** "No active tunnels" in tertiary text. No chart.
- **Power Input wattage:** Disk-Utility-style — 10 pt tall band, numbers in 13 pt Medium on the bar.

**Never two progress bars side-by-side.** They get visually compared, which is rarely the intent. If you need to show two quantities use a single stacked segmented bar.

### 4.6 Long capability lists (the 37 timing modes)

Default: collapse to "27 supported timing modes" inside a disclosure that opens a `Table` with columns *Resolution / Refresh / Color depth / Default*. Sortable. Default mode gets a `checkmark.seal.fill` in `.tint`; all other rows leave the column blank.

**No empty-circle bullets.** They read as interactive checkboxes. Mark only what's special.

---

## 5. Sidebar IA — eight principles for "what's plugged into my Mac"

1. **Sidebar is a noun catalog, not a tree explorer.** Each row is one *thing the user can point to on their desk.* A USB-C port is a noun. An intermediate xHCI controller is not — hide it.

2. **Group by chassis location, not by bus.** "Left rear port," not "controller 2 root hub port 3." PortScope already does this. Keep the bus tree behind `Show Hardware Buses`.

3. **One level of grouping.** Sections (Power / USB-C / USB-A / HDMI / SD / Ethernet) → rows. Deeper hierarchy → disclosure *inside the row*, not nested subsections.

4. **Empty ports are first-class rows.** A user wants to know which of their four USB-C ports is free. Show them all, with a subdued style (tertiary symbol, no status dot) for the empty ones.

5. **Status before name before metadata.** Scan order: right-edge status dot → left connector icon → human label → secondary tech metadata.

6. **Secondary line is the most user-meaningful fact, not the most technical one.** "Logitech MX Master" on top; "Mouse, USB 1.1" below — not the hex VID/PID. Hex goes in Developer Details.

7. **Three top-level sections by default, six when buses are on.** Physical Device + Displays + Bluetooth covers 95% of the "what's plugged in" question. Buses and Internal Hardware are opt-in via Settings — PortScope already gets this right.

8. **`.searchable(text:, placement: .sidebar)` once row count > 20.** Docked Macs with flattened USB trees easily exceed that.

---

## 6. Anti-patterns

1. **Per-bus accent coloring.** TB blue / USB green / displays orange = Christmas tree. One accent for selection, status colors for status, neutral everywhere else.

2. **All-caps section headers.** Tahoe-era macOS has moved to sentence case across Apple's own apps. ALL CAPS reads as 2015 Cocoa.

3. **Tile-grid-everything.** Four cards across with one number each looks like a Heroku dashboard. Use `LabeledContent` for property bags.

4. **Two-line sidebar rows everywhere.** Every row fighting for attention = no row standing out. Reserve the second line for rows that have something to say.

5. **Drawing your own sidebar background.** Defeats Liquid Glass.

6. **Hard 1 pt divider between sidebar and detail.** macOS 26 floats the sidebar; that border re-creates the split the OS is trying to dissolve.

7. **IOKit class names in user-facing UI.** `AppleT8142USBXHCI`, registry IDs, hex device IDs all live behind Developer Details. PortScope's CLAUDE.md already enforces this — extend it consistently.

8. **Progress bars for non-quantitative state.** A 100 Mb/s placeholder reservation rendered as a sliver of an 80 Gb/s bar lies visually. Use text ("Active · 4 hops") when the number is meaningless.

9. **Empty-circle bullets in long lists.** They look interactive. Use a real `Table`.

10. **Custom button radii, shadows, borders.** SwiftUI's macOS 26 defaults are correct. Custom styling is the fastest way to look non-native.

11. **Monospaced everything-technical.** SF Mono for hex/MACs/IDs only. Prose set in SF Pro.

12. **Animated state transitions on read-only data.** Springs imply mutation. They make the inspector feel like a toy.

---

## 7. Inspirations gallery

- macStories — [2025 Apple Design Awards Winners and Finalists](https://www.macstories.net/news/2025-apple-design-awards-winners-and-finalists-announced/)
- Apple Newsroom — [A delightful and elegant new software design](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)
- Apple Developer — [WWDC25 #356: Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)
- Apple Developer — [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- Mario Aguzman — [Sidebar Guidelines](https://marioaguzman.github.io/design/sidebarguidelines/)
- TrozWare — [SwiftUI for Mac 2025](https://troz.net/post/2025/swiftui-mac-2025/)
- Linear — [How we redesigned the Linear UI (Part II)](https://linear.app/now/how-we-redesigned-the-linear-ui)
- Cultured Code — [Things Big and Small](https://culturedcode.com/things/blog/2023/09/things-big-and-small/)
- bjango — [iStat Menus](https://bjango.com/mac/istatmenus/)
- Apple — [Disk Utility User Guide](https://support.apple.com/guide/disk-utility/welcome/mac)
- Apple Developer — [Inspectors in SwiftUI (WWDC23)](https://developer.apple.com/videos/play/wwdc2023/10161/)

---

## The highest-leverage change

If only one thing changes: **drop per-tile color tints and replace tile-grid-everything with `LabeledContent` two-column rows.** That swap alone moves the app from "engineery dashboard" to About-This-Mac quality. Typography, materials, motion are polish on top.
