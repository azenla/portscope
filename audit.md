# PortScope UI Audit Report

## 1. Pattern Inventory (30+ entries)

### Hero Cards (8 variants)
1. **DetailView.swift:94–117** — Generic TBNode hero: 64pt circular icon background, title, subtitle, StatusPill
2. **PhysicalPortDetailView.swift:65–90** — Physical port hero: icon, title, device/status subtitle, mode badge, accessory badges, power callout (top-right)
3. **DisplayViews.swift:177–208** — Display hero: larger 76pt icon circle, title, subtitle, Active pill when connected
4. **BluetoothViews.swift:96–124** — BT controller hero: icon, "Bluetooth" title, chipset subtitle, inline counts (connected/paired)
5. **BluetoothViews.swift:274–300** — BT device hero: category icon, device name, subtitle, Connected pill
6. **PCIViews.swift:135–157** — PCIe hero: icon circle, title, subtitle with vendor/class
7. **BuiltInPortViews.swift:45–80** — AC power hero: bold bolt.fill, title, location, status, right-aligned W/V/A trio
8. **BuiltInPortViews.swift:211–241** — Ethernet hero: cable icon, title, link state, right-aligned negotiated speed

### Stat Grids & Tiles (5 entry points)
9. **DetailView.swift:1114–1125** — StatGrid: adaptive LazyVGrid (minimum 220pt), no fixed columns
10. **DetailView.swift:1127–1173** — StatCell: icon (22pt) + label (caption, secondary) + value (callout) + eye icon for isSecret:true
11. **PhysicalPortDetailView.swift:113–172** — Port stats: conditional by connector type (USB-C shows power input, USB-A does not)
12. **DisplayViews.swift:62–111** — Display stats: engine, type, status, resolution, refresh, color depth, accuracy index, modes, HDR
13. **BluetoothViews.swift:24–49** — BT controller stats: address, chipset, firmware, transport, vendor ID, product ID, state, discoverable

### Section Cards (SectionCard building block)
14. **DetailView.swift:1179–1197** — Container: title + icon header, secondary background, 10pt rounded corners, 14pt padding
15. **DetailView.swift:367–396** — AdapterBreakdown: categorizes router ports by Description (lane / hostInterface / displayPort / usb / pcie / inactive)
16. **DetailView.swift:565–595** — UpstreamLinkCard: link speed + lane count + optional BandwidthBar
17. **PhysicalPortDetailView.swift:178–198** — "What's happening on this port": prose explanation + optional BandwidthBar when TB
18. **PhysicalPortDetailView.swift:238–247** — "Active Transports": TransportChipsRow + legend text

### Status Pills & Badges (3 types)
19. **DetailView.swift:119–159** — StatusPill: dot + label + capsule; colors green/blue/secondary by node kind and Depth
20. **PhysicalPortDetailView.swift:616–628** — ModeBadge: mode.color dot + label + mode.color capsule background
21. **PhysicalPortDetailView.swift:630–665** — AccessoryBadges: multiple chips (Display, Active cable, Optical, plug count)

### Chips & Tags (4 types)
22. **DetailView.swift:489–523** — AdapterChip: "Port N" + optional trailing label (speed/Active/Unused), highlight on speed > 0
23. **DetailView.swift:847–858** — Tag: colored rounded rectangle, e.g. "hop 5", "port 3"
24. **PhysicalPortDetailView.swift:719–786** — TransportChip: icon + label + state badge (· live / · ready), state-dependent opacity
25. **PhysicalPortDetailView.swift:949–957** — Display badge row: resolution, refresh, color depth, HDR as capsules

### Breadcrumbs & Navigation
26. **BreadcrumbBar.swift:13–62** — Horizontal scrollable chip row: icon + title per ancestor, chevron separators, tappable

### Bandwidth & Progress (1 unified pattern)
27. **DetailView.swift:986–1055** — BandwidthBar: two-tone progress (orange reserved + yellow max planned), legend, % label, overage warning

### Disclosure Controls (2 types)
28. **SidebarView.swift:509–533** — DisclosureChevron: rotating chevron (0°–90°), two size variants (section / subgroup)
29. **SidebarView.swift:543–578** — collapsibleSubgroup: inline header with chevron + optional icon + uppercase title

### Data Tables (3 layouts)
30. **PhysicalPortDetailView.swift:825–862** — PDOTable: Grid with voltage/current/power columns, winning option marked
31. **PhysicalPortDetailView.swift:377–402** — Power allocation table: device, allocated mA, capability mA, estimated W
32. **PropertyTableView.swift:81–167** — Property rows: key (240pt fixed) + value, collapsible for data/array/dictionary

---

## 2. What's Working

- **Consistent icon vocabulary** — SidebarView.swift:734–750 (PortRow), 800–810 (ControllerBranch), 987–1001 (FullTopologyRow) all use node.kind.sfSymbol + node.kind.accentColor; SF Symbols vocabulary is consistent across sections
- **Responsive hero layout** — HStack(alignment: .center, spacing: 16) used in DetailView.swift:98, PhysicalPortDetailView.swift:66, DisplayViews.swift:181, BluetoothViews.swift:101, PCIViews.swift:139; scales well from 620pt min width
- **Breadcrumb navigation** — BreadcrumbBar.swift:23–35 provides fast escape from deep nodes; horizontal scroll for long chains
- **Adaptive stat grids** — StatGrid.swift:1116 uses LazyVGrid with .adaptive(minimum: 220); no fixed column count avoids whitespace waste
- **Unified disclosure language** — DisclosureChevron.swift:509–533 reused by collapsibleSection and collapsibleSubgroup; consistent animation (0.18s easing) across all collapse affordances
- **Selection routing by type** — ContentView.swift:22–101 cleanly dispatches PhysicalPort → ACPowerDetailView/EthernetDetailView/HDMIDetailView/SDCardDetailView/PhysicalPortDetailView based on connector enum; avoids multi-dispatch bugs
- **Status badge clarity** — StatusPill (DetailView.swift:134–158) uses color + dot + label to signal state; colors are semantically appropriate (green = active, blue = built-in, gray = idle)
- **Transport chip state progression** — PhysicalPortDetailView.swift:719–786 TransportChip elegantly shows 4 states (active / provisioned / supported / unavailable) with color gradients, not icons alone

---

## 3. What's Confusing (10+ friction points)

1. **SidebarView.swift:1025–1036 (MagSafeRow subtitle)** — "Idle · 1 plug events" reads as two equal facts separated by the dot, but they're conceptually different (state vs event counter). The dot overloads the operator.

2. **SidebarView.swift:738–740 (PortRow statusLabel composition)** — StatusLabel includes both state ("Connected") and capability ("Thunderbolt Gen 2"), e.g. "Connected · Thunderbolt Gen 2". Users might confuse which is current state and which is capability.

3. **PhysicalPortDetailView.swift:101–108 (mode switch subheadline)** — When mode is .unknown, the user sees "Link up" which is vague. Does "Link up" mean "negotiating" or "unknown device type"?

4. **DetailView.swift:599–609 (PortView dispatch)** — Function adapter vs lane adapter layout divergence is internal to the View. User sees "DP or HDMI Adapter" in sidebar but doesn't know a different detail layout awaits.

5. **DetailView.swift:753–755 (FunctionAdapterPortView Status stat)** — Shows "Status: Active" when hopTable is non-empty. New users see "Active Tunnels: 0" and wonder why Status isn't "Idle".

6. **SidebarView.swift:759–770 (DeviceRow icon)** — Uses shippingbox.fill (purple) for all connected devices (docks, mice, keyboards, drives, displays). No visual distinction between a dock and a USB keyboard.

7. **PhysicalPortDetailView.swift:117–129 (bandwidth lane comments vs UI)** — buildStats() reads lane from bandwidthLane (peer side) or laneAdapter (host side) but the UI doesn't explain why.

8. **DetailView.swift:464–470 (AdapterCategoryRow redundancy)** — Title "Thunderbolt Lane Adapters (7)" shows count, then a pill also shows "(7)". Reading the title + seeing the pill feels redundant.

9. **SidebarView.swift:261–279 (Bluetooth subgroup count consistency)** — "Connected (4)" embeds count inline, but Displays section uses flat "Displays" header (no count). Inconsistent pattern.

10. **PhysicalPortDetailView.swift:39–40 (displays card title)** — Card title is "Display" (singular) used both for zero-display ports and single-display ports. Header title doesn't reflect zero-display state.

---

## 4. What's Bloated (8+ info-dense areas)

1. **DetailView.swift:648–701 (laneAdapterContent full view)** — Three nested SectionCards (Bandwidth Allocation, Link Negotiation grid, Active Tunnels). When the link is down (currentSpeed = 0), the Link Negotiation card renders with all fields as "—", wasting space.

2. **DetailView.swift:295–324 (RouterView stats grid)** — All 6 stats always render (Vendor, Model, TB Gen, Depth, Firmware, UID). For a built-in (depth 0) router, Vendor/Model/Firmware are repetitive boilerplate.

3. **PhysicalPortDetailView.swift:257–299 (connectorCableCard)** — Shows Connector + Connection + (USB-C only) Cable Type + Cable E-Marker + Plug Events + Overcurrent. For USB-A, only Connector + Connection render, making the card sparse. For USB-C without e-marker, the e-marker row says "Not reported".

4. **PhysicalPortDetailView.swift:386–402 (per-device power allocation table)** — Each sink gets 4 columns (Device, Allocated mA, Capability mA, Estimated W). The "Estimated W" column (allocated mA × 5V / 1000) is mathematically redundant.

5. **DisplayViews.swift:21–30 (TimingModes section)** — A 37-mode display renders 37 rows, each with icon + label + optional badge. The section is a wall of text.

6. **DetailView.swift:454–487 (AdapterCategoryRow with many inactive ports)** — When a category has 18 inactive lane adapters, the FlowChips grid wraps and fills the screen vertically. Most inactive ports are noise.

7. **PropertyTableView.swift:26–72** — Shows all IORegistry properties by default, filterable but not grouped by semantic type. Users see 100+ rows.

8. **SidebarView.swift:296–333 (internalHardwareSection)** — Renders all I²C buses, SPI buses, coprocessor groups (10–20 items). Coprocessor subgroups are individually collapsible AND wrapped in an outer Hardware section, creating double nesting.

---

## 5. Inconsistencies (5+ visual/behavioral inconsistencies)

1. **Icon sizing in heroes** — DetailView.swift:104 size 30; PhysicalPortDetailView.swift:72 size 28; DisplayViews.swift:186 size 30; BluetoothViews.swift:107 size 30. Inconsistent.

2. **Circular background sizes** — DetailView.swift:100 uses 64pt; DisplayViews.swift:183 uses 76pt; BluetoothViews.swift:102 uses 76pt; PCIViews.swift:143 uses 76pt. Inconsistent (64pt vs 76pt).

3. **Badge formatting redundancy** — StatusPill (DetailView.swift:124–130) and ModeBadge (PhysicalPortDetailView.swift:624–626) use identical structure (.padding(horizontal 8, vertical 3) + capsule + background.opacity(0.12)). AccessoryBadges (line 660–663) also identical. Suggests a shared BadgeView component.

4. **Subtitle styling** — PortRow (SidebarView.swift:739–740) uses .caption2 + .secondary + .lineLimit(1). DisplaySidebarRow (line 1160–1164) uses identical on main line, then falls through to plain .secondary "Idle" on no subtitle. The fallback reads differently.

5. **Disclosure header structure** — collapsibleSection (SidebarView.swift:351–369) and collapsibleSubgroup (line 557–573) use identical HStack(spacing: 6) structure. DetailView DeveloperDisclosure header (line 1082–1094) uses a different button structure without consistent spacing.

---

## 6. Sidebar Row Variant Catalog (10+ row types)

| Row Type | File:Line | Icon | Subtitle | Selection ID | Disclosure | Notes |
|----------|-----------|------|----------|--------------|------------|-------|
| **PortRow** | SidebarView.swift:729–752 | port.mode.symbol (colored) | statusLabel + locationLabel | PhysicalPortSelector.id(port) | if device/roots/displays | Auto-expand on content |
| **DeviceRow** | SidebarView.swift:754–773 | shippingbox.fill (purple) | device.subtitle (vendor·model) | device.id | if daisyChained | No status |
| **ControllerBranch** | SidebarView.swift:777–845 | node.kind.sfSymbol | connectedDeviceTitle OR "No external device" | node.id | always | Auto-expand if attached host |
| **USBBranch** | SidebarView.swift:849–896 | node.kind.sfSymbol | node.subtitle | node.id | if children | Depth-aware indentation |
| **FullTopologyRow** | SidebarView.swift:956–1003 | node.kind.sfSymbol | node.subtitle | node.id | if children | Generic tree row |
| **MagSafeRow** | SidebarView.swift:1007–1037 | powerplug.fill (green/gray) | "Idle · N plug events" OR "Charging · X W" | MagSafeSelector.id | none | Synthetic ID |
| **BatteryRow** | SidebarView.swift:1039–1078 | battery.NN.percent icon | "X% · Charging/On AC/On battery" | battery.id | none | Dynamic glyph |
| **BluetoothControllerRow** | SidebarView.swift:1093–1118 | dot.radiowaves.left.and.right | "On/Off · Chipset" | BluetoothSelector.controllerID | none | Synthetic ID |
| **BluetoothDeviceRow** | SidebarView.swift:1120–1145 | device.category.symbol | "connected" badge + minorType + RSSI | BluetoothSelector.id(device) | none | Inline status |
| **DisplaySidebarRow** | SidebarView.swift:1150–1168 | display.iconSymbol | resolution + refresh OR "Idle" | display.id | none | No expansion |
| **DisplayOutputRow** | SidebarView.swift:670–699 | display (pink) | "DP / HDMI · adapter port N" | adapter.id | if displays | Dock DP/HDMI output |
| **PCIBranch** | SidebarView.swift:1172–1211 | node.kind.symbol | node.subtitle | node.id | if children | Depth indentation |

---

## 7. Detail View Building Blocks by Type

### **PhysicalPortDetailView.swift** (USB-C/USB-A/MagSafe port)
Blocks: Hero (icon, title, mode + accessory badges, power callout) · Stats (mode, link speed/width, capacity, power, device counts) · "What's happening" card (prose + BW bar) · "Active Transports" card (chips) · "Connector & Cable" card (USB-C only) · "Power Input" card (PDO table) · "Power Output" card (allocation table) · "Displays" card (conditional) · "Ethernet" card (conditional) · "Active Tunnels" card · "USB Devices" card (capped 20) · "Connected TB Device" card · "Jump to" card

Friction: Power/Ethernet cards render conditionally but no clear UI signals what triggers them

### **DisplayDetailView.swift** (Display engine)
Blocks: Hero (76pt icon, title, subtitle, Active pill) · Stats (engine name, type, status, resolution, refresh, color depth, accuracy, modes, HDR) · Timing Modes card (37 rows) · "About this Engine" info card · DeveloperDisclosureCard

Friction: Timing Modes section is a wall of text for a 37-mode display

### **BluetoothControllerView.swift** (Bluetooth chipset)
Blocks: Hero · Stats (address, chipset, firmware, transport, vendor ID, product ID, state, discoverable) · "Supported Profiles" card (chips) · "Connected" section · "Paired" section

Friction: Supported Profiles are raw service names; no legend

### **BluetoothDeviceView.swift** (BT device)
Blocks: Hero · Stats (address, type, connection, IDs, firmware, RSSI) · Battery card (per-component bars) · Advertised Services card (UUIDs in chips)

Friction: Services render as opaque UUIDs

### **PCIDeviceView.swift** (PCIe endpoint)
Blocks: BreadcrumbBar · Hero · Stats (role, class, vendor, device, subsystem, BDF, slot, link) · Downstream Devices card (conditional) · DeveloperDisclosureCard

Friction: PCI class code (0x03:0x00) is not user-readable

### **DetailView.swift** (TB controllers, routers, ports, lanes, local node, generic devices)
Blocks vary by node kind:
- **Controller:** Stats · External device name · Built-in Adapter Breakdown
- **Router:** Stats · Uplink-to-Host card · Adapter Breakdown by category
- **Port (lane):** Stats · Bandwidth Allocation card (when live) · Link Negotiation grid · Active Tunnels (hop table)
- **Port (function adapter):** Stats · optional Bandwidth Allocation · Active Tunnels section
- **Local node:** Stats (domain UUID)
- **Generic device:** Prose explanation

Friction: Link Negotiation grid shows all fields as "—" when link is down; FunctionAdapterPortView Status stat can contradict Active Tunnels count.

---

## Summary

The codebase demonstrates good separation of concerns (DetailView for generic IOKit nodes, PhysicalPortDetailView for ports, DisplayDetailView for displays, BuiltInPortViews for specialized connectors). Reusable components (StatGrid, SectionCard, DisclosureChevron, BreadcrumbBar) reduce duplication.

**Key friction points:**
- Subtitle composition (dot separator overloaded; state vs spec unclear)
- Device icons (no distinction by type in sidebar)
- Null/empty state handling ("Not reported" rows, empty grids)
- Icon/card sizing inconsistencies (64pt vs 76pt circles, 28pt vs 30pt icons)
- Information density (timing modes, power allocation, adapter categories all potentially large lists)
