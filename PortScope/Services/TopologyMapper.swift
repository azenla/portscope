//
//  TopologyMapper.swift
//  PortScope
//
//  Translates the raw IOKit trees (Thunderbolt + USB) into the simplified
//  user-facing topology: physical USB-C / Thunderbolt ports → connected
//  devices → daisy-chained devices, plus the USB devices reached through
//  each port.
//

import Foundation

/// One physical chassis receptacle on the Mac — usually a USB-C / Thunderbolt
/// port backed by a TB lane adapter, but also covers built-in USB-A jacks on
/// desktops (no TB lane, just the USB host controller behind them).
struct PhysicalPort {
    let number: Int
    let id: TBNodeID
    /// What kind of receptacle this is. Drives sidebar grouping and the
    /// detail-view title. USB-C is the default; USB-A is set when the port
    /// is built from a `Port-USB-A@N` IOPort accessory.
    let connector: PortConnectorType
    /// Host-side lane adapter on the root switch. Use this for static info
    /// like link speed / width (the link negotiates the same numbers on both
    /// sides). For non-TB ports (USB-A) this is a synthetic stub.
    let laneAdapter: TBNode
    /// Lane port immediately above the connected switch — the "peer lane".
    /// When a device is connected, this is where the kernel aggregates
    /// `Link Bandwidth`, `Required Bandwidth Allocated`, and
    /// `Maximum Bandwidth Allocated` for all the tunnels flowing through
    /// the link. The host-side `laneAdapter` only sees host-local tunnels
    /// and would under-report. Nil when nothing is connected.
    let linkLane: TBNode?
    let controller: TBNode
    let connectedDevice: ConnectedDevice?
    /// Inferred operating mode of the port. Drives the badge/colour in the UI.
    let mode: PhysicalPortMode
    /// USB devices reachable through this port (flat list, hubs included).
    /// Used for stats and the "via this port" overview card.
    let attachedUSBDevices: [TBNode]
    /// Top-level USB hubs/devices reachable through this port, each carrying
    /// its full IOKit subtree. The sidebar uses this to render the real bus
    /// hierarchy instead of a flat list.
    let usbDeviceRoots: [TBNode]
    /// Tunnel summaries on the port's connected router (active tunnels by class).
    let tunnels: [PortTunnel]
    /// Per-receptacle runtime state from `IOAccessoryManager`, when available.
    /// Carries transport state, USB-PD power, plug orientation, displayport
    /// HPD, cable e-marker info — the data that doesn't show up in the
    /// Thunderbolt or USB IOKit families.
    let accessory: PortAccessoryInfo?
    /// What the Mac is sourcing on this receptacle right now: per-device
    /// allocations + port-level current ceilings. Nil when we can't see a
    /// matching xHCI port wrapper for the receptacle.
    let sourcePower: PortSourcePower?

    /// The lane node whose `Link Bandwidth` to read for this port's link
    /// capacity. On Apple Silicon TB5 hardware the dock-side peer lane
    /// (`linkLane`) often reports `Link Bandwidth = 0` while the host-side
    /// lane (`laneAdapter`) carries the canonical 800 / 1200 (100 Mb/s
    /// units). Prefer whichever endpoint actually publishes the number; fall
    /// back to the host side when both are zero.
    ///
    /// **Don't read `Required/Maximum Bandwidth Allocated` from this lane.**
    /// The lane port publishes an outer-wrapper partial aggregate that
    /// disagrees with the function-adapter sum (e.g. lane shows `4 / 402`
    /// while the dock's actual reservations sum to `314 / 922`). Use
    /// `bandwidthSummary` instead — it sums from `tunnels`, which is the
    /// kernel-authoritative source.
    var bandwidthLane: TBNode {
        if let link = linkLane, (link.properties["Link Bandwidth"]?.asUInt ?? 0) > 0 {
            return link
        }
        if (laneAdapter.properties["Link Bandwidth"]?.asUInt ?? 0) > 0 {
            return laneAdapter
        }
        return linkLane ?? laneAdapter
    }

    /// Canonical bandwidth picture for this port. `linkBandwidth` is the
    /// negotiated link capacity (100 Mb/s units, full-duplex aggregate);
    /// `reserved` / `max` are summed from the per-category `tunnels`
    /// entries, which themselves come from the connected router's function
    /// adapters — the only kernel field that's actually consistent across
    /// TB controller generations.
    var bandwidthSummary: PortBandwidthSummary {
        let cap = bandwidthLane.properties["Link Bandwidth"]?.asUInt ?? 0
        let reserved = tunnels.reduce(UInt64(0)) { $0 + $1.reservedBandwidth }
        let maxBw = tunnels.reduce(UInt64(0)) { $0 + $1.maxBandwidth }
        return PortBandwidthSummary(linkBandwidth: cap,
                                    reserved: reserved,
                                    max: maxBw,
                                    perTunnel: tunnels)
    }
}

/// Bandwidth roll-up for one physical port. Capacity from the lane, reserved
/// / max from the connected router's function adapters.
struct PortBandwidthSummary {
    let linkBandwidth: UInt64       // 100 Mb/s units; 0 if link is down
    let reserved: UInt64            // Σ Required Bandwidth Allocated
    let max: UInt64                 // Σ Maximum Bandwidth Allocated
    let perTunnel: [PortTunnel]

    var hasLink: Bool { linkBandwidth > 0 }
    var hasReservation: Bool { reserved > 0 || max > 0 }
    /// True when the kernel's planned ceiling exceeds the link's capacity
    /// — the bandwidth bar marks this in red. The TB scheduler relies on
    /// tunnels not peaking simultaneously, so this is informational, not
    /// a failure.
    var planExceedsCapacity: Bool { linkBandwidth > 0 && max > linkBandwidth }

    /// Fraction (0...1) of link capacity actively reserved.
    var reservedFraction: Double {
        guard linkBandwidth > 0 else { return 0 }
        return min(Double(reserved) / Double(linkBandwidth), 1.0)
    }

    /// Fraction (0...1) of link capacity planned at peak.
    var maxFraction: Double {
        guard linkBandwidth > 0 else { return 0 }
        return min(Double(max) / Double(linkBandwidth), 1.0)
    }
}

nonisolated struct PortTunnel: Hashable {
    enum Kind: Hashable { case displayPort, usb, pcie }
    let kind: Kind
    let reservedBandwidth: UInt64
    let maxBandwidth: UInt64
    let adapterCount: Int

    var label: String {
        switch kind {
        case .displayPort: return "DisplayPort / HDMI"
        case .usb: return "USB"
        case .pcie: return "PCIe"
        }
    }
    var symbol: String {
        switch kind {
        case .displayPort: return "display"
        case .usb: return "cable.connector"
        case .pcie: return "square.stack.3d.up"
        }
    }
}

/// A Thunderbolt device (router) attached over the fabric. Recursive so we can
/// represent daisy-chained devices.
struct ConnectedDevice {
    let id: TBNodeID
    let title: String
    let subtitle: String?
    let routerNode: TBNode
    let daisyChained: [ConnectedDevice]
}

extension PhysicalPort {
    /// CLI / sidebar title. Generic numbered form — chassis-specific
    /// detail (location + spec) lives on the separate `locationLabel`
    /// line so the title stays predictable across Macs. SD Card uses
    /// "Slot" since "Port" reads oddly for a card receptacle, and HDMI /
    /// MagSafe stay singular because every Mac that ships them only
    /// ships one.
    var cliTitle: String {
        switch connector {
        case .hdmi: return "HDMI Port"
        case .sdCard: return "SD Card Slot"
        case .magsafe: return "MagSafe 3 Port"
        case .acPower: return "Power Input"
        case .ethernet:
            // Ethernet receptacles are numbered too on Macs that ship
            // more than one (Mac Pro back I/O card). For the typical
            // single-jack case the suffix reads as noise, so drop it.
            return number > 1 ? "Ethernet Port \(number)" : "Ethernet Port"
        default: return "\(connector.label) Port \(number)"
        }
    }

    /// Chassis-relative label sourced from `MacPortLocations.json`, e.g.
    /// "Rear (rightmost) · Thunderbolt 4". Nil when the running host's
    /// `hw.model` isn't catalogued or this particular receptacle has no
    /// entry — the title stands on its own in that case.
    var locationLabel: String? {
        guard let d = MacPortCatalog.current.descriptor(for: connector, portNumber: number) else {
            return nil
        }
        if let cap = d.capability, !cap.isEmpty {
            return "\(d.location) · \(cap)"
        }
        return d.location
    }

    /// Capability blurb from the catalog (e.g. "Thunderbolt 4"). Nil when
    /// the host isn't in the catalog or the receptacle has no spec'd
    /// capability (some entries omit the field).
    var catalogCapability: String? {
        MacPortCatalog.current.descriptor(for: connector, portNumber: number)?.capability
    }

    /// Just the catalog location string (e.g. "Right Front") without
    /// the trailing capability. Used when the capability is rendered on
    /// its own line elsewhere.
    var catalogLocation: String? {
        MacPortCatalog.current.descriptor(for: connector, portNumber: number)?.location
    }

    /// Subtitle shown beneath the port in the sidebar.
    var statusLabel: String {
        // Connector-specific labels for non-USB/TB receptacles. AC Power
        // and Ethernet don't share USB / TB / DP mode semantics — surface
        // their own measured-power / link-state strings instead.
        switch connector {
        case .acPower:
            if let pd = accessory?.usbPD?.winning, pd.maxPowerMW > 0 {
                let w = String(format: "%.1f W", Double(pd.maxPowerMW) / 1000.0)
                let v = String(format: "%.1f V", Double(pd.voltageMV) / 1000.0)
                return "Drawing \(w) · \(v)"
            }
            return accessory?.connectionActive == true ? "Connected" : "Empty"
        case .ethernet:
            let active = accessory?.connectionActive == true
            let mbps = accessory?.registryProperties["LinkSpeedMbps"]?.asUInt ?? 0
            if active, mbps > 0 { return "Linked · \(ethernetSpeedLabel(mbps))" }
            if active { return "Linked" }
            return "Unplugged"
        case .sdCard:
            return accessory?.connectionActive == true ? "Card inserted" : "Empty"
        case .hdmi:
            return mode == .empty ? "Empty" : "Display"
        default:
            break
        }
        switch mode {
        case .empty: return "Empty"
        case .thunderbolt:
            var parts: [String] = ["Thunderbolt"]
            let speed = laneAdapter.properties["Current Link Speed"]?.asUInt ?? 0
            let width = laneAdapter.properties["Current Link Width"]?.asUInt ?? 0
            if speed > 0 { parts.append(tbGenerationShortLabel(speed)) }
            if width > 0 { parts.append("×\(width)") }
            return parts.joined(separator: " · ")
        case .usbOnly(let s):
            var parts: [String] = ["USB"]
            if let s, s > 0 { parts.append(usbSpeedShortLabel(s)) }
            if accessory?.carriesDisplay == true { parts.append("+ DP") }
            return parts.joined(separator: " · ")
        case .displayOnly: return "Display"
        case .charging(let w):
            if let w, w > 0 { return "Charging · \(w) W" }
            return "Charging"
        case .unknown: return "Link up"
        }
    }
}

/// Translate a raw Mb/s figure into the marketing-style speed label
/// people recognise on Ethernet ports.
nonisolated func ethernetSpeedLabel(_ mbps: UInt64) -> String {
    switch mbps {
    case 10: return "10 Mb/s"
    case 100: return "100 Mb/s"
    case 1_000: return "1 Gb/s"
    case 2_500: return "2.5 Gb/s"
    case 5_000: return "5 Gb/s"
    case 10_000: return "10 Gb/s"
    default:
        if mbps >= 1000 { return String(format: "%.1f Gb/s", Double(mbps) / 1000.0) }
        return "\(mbps) Mb/s"
    }
}

extension ConnectedDevice {
    var shortTitle: String {
        return routerNode.properties["Device Model Name"]?.asString
            ?? routerNode.properties["Device Vendor Name"]?.asString
            ?? title
    }
}

nonisolated enum TopologyMapper {
    /// Build the simplified topology from a TB-only snapshot. Used as a fall
    /// back when no `IOAccessoryManager` data is available.
    static func physicalPorts(from snapshot: TBSnapshot) -> [PhysicalPort] {
        var out: [PhysicalPort] = []
        for (idx, controller) in snapshot.controllers.enumerated() {
            guard let port = makePort(number: idx + 1, controller: controller, accessory: nil) else { continue }
            out.append(port)
        }
        return out
    }

    /// Build the simplified topology from a system snapshot, merging in
    /// `IOAccessoryManager` per-port state. The HPM `PortNumber` field gives
    /// the canonical physical port label (1..N as etched on the chassis), so
    /// when accessory data is available the sidebar numbering follows it
    /// instead of arbitrary TB-controller iteration order.
    static func physicalPorts(from snapshot: SystemSnapshot) -> [PhysicalPort] {
        let tbPorts = snapshot.tb.controllers.compactMap {
            makePort(number: 0, controller: $0, accessory: nil)
        }
        let usbByPort = usbDevicesByPort(in: snapshot.usb)
        let usbCAccessories = snapshot.accessories.filter {
            if case .usbC = $0.connector { return true }
            return false
        }

        guard !usbCAccessories.isEmpty else {
            // No HPM data — number ports by TB controller iteration order.
            return tbPorts.enumerated().map { idx, p in
                let portNumber = idx + 1
                let usb = usbByPort[portNumber]
                return PhysicalPort(
                    number: portNumber,
                    id: p.id,
                    connector: .usbC,
                    laneAdapter: p.laneAdapter, linkLane: p.linkLane,
                    controller: p.controller,
                    connectedDevice: p.connectedDevice, mode: p.mode,
                    attachedUSBDevices: usb?.flat ?? p.attachedUSBDevices,
                    usbDeviceRoots: usb?.roots ?? p.usbDeviceRoots,
                    tunnels: p.tunnels,
                    accessory: nil,
                    sourcePower: usb?.power
                )
            }
        }

        // Match each AppleHPM USB-C port to the best TB controller. Ports with
        // CIO active match the controller whose lane has a downstream switch;
        // remaining ports get assigned in order.
        var remainingTB = tbPorts
        var paired: [(PortAccessoryInfo, PhysicalPort?)] = []

        // Pass 1: TB-active accessory ports claim a TB controller with a downstream device.
        for acc in usbCAccessories where acc.carriesThunderbolt {
            if let idx = remainingTB.firstIndex(where: { $0.connectedDevice != nil }) {
                paired.append((acc, remainingTB.remove(at: idx)))
            } else if let idx = remainingTB.indices.first {
                paired.append((acc, remainingTB.remove(at: idx)))
            } else {
                paired.append((acc, nil))
            }
        }
        // Pass 2: any other accessory ports take remaining TB controllers in order.
        for acc in usbCAccessories where !acc.carriesThunderbolt {
            if let first = remainingTB.first {
                remainingTB.removeFirst()
                paired.append((acc, first))
            } else {
                paired.append((acc, nil))
            }
        }
        // Sort the result back into physical port order.
        paired.sort { $0.0.portNumber < $1.0.portNumber }

        var out: [PhysicalPort] = []
        for (acc, tb) in paired {
            let usb = usbByPort[acc.portNumber] ?? (flat: [], roots: [], power: nil)
            if let tb {
                let refinedMode = refineMode(tb.mode, with: acc, usbDevices: usb.flat)
                out.append(PhysicalPort(
                    number: acc.portNumber,
                    id: tb.id,
                    connector: acc.connector,
                    laneAdapter: tb.laneAdapter, linkLane: tb.linkLane,
                    controller: tb.controller,
                    connectedDevice: tb.connectedDevice, mode: refinedMode,
                    attachedUSBDevices: usb.flat.isEmpty ? tb.attachedUSBDevices : usb.flat,
                    usbDeviceRoots: usb.roots.isEmpty ? tb.usbDeviceRoots : usb.roots,
                    tunnels: tb.tunnels,
                    accessory: acc,
                    sourcePower: usbByPort[acc.portNumber]?.power
                ))
            } else {
                // HPM port with no matching TB controller (rare; fall back to a
                // synthetic stub that still surfaces the receptacle in the UI).
                let stub = synthLane(accessoryID: acc.id)
                out.append(PhysicalPort(
                    number: acc.portNumber,
                    id: acc.id,
                    connector: acc.connector,
                    laneAdapter: stub, linkLane: nil,
                    controller: stub,
                    connectedDevice: nil, mode: modeFromAccessory(acc, usbDevices: usb.flat),
                    attachedUSBDevices: usb.flat,
                    usbDeviceRoots: usb.roots,
                    tunnels: [],
                    accessory: acc,
                    sourcePower: usbByPort[acc.portNumber]?.power
                ))
            }
        }
        // Append any leftover TB controllers (uncommon: HPM count < TB count).
        for (i, tb) in remainingTB.enumerated() {
            let portNumber = out.count + i + 1
            let usb = usbByPort[portNumber]
            out.append(PhysicalPort(
                number: portNumber,
                id: tb.id,
                connector: .usbC,
                laneAdapter: tb.laneAdapter, linkLane: tb.linkLane,
                controller: tb.controller,
                connectedDevice: tb.connectedDevice, mode: tb.mode,
                attachedUSBDevices: usb?.flat ?? tb.attachedUSBDevices,
                usbDeviceRoots: usb?.roots ?? tb.usbDeviceRoots,
                tunnels: tb.tunnels,
                accessory: nil,
                sourcePower: usb?.power
            ))
        }

        // USB-A pass: each `Port-USB-A@N` IOPort accessory becomes one
        // physical port. We cross-link USB devices and per-port power limits
        // by matching the xHCI port wrappers' `UsbIOPort` property against the
        // accessory's IORegistry path. SS + HS companion wrappers share the
        // same `UsbIOPort`, so they merge into a single receptacle naturally.
        let usbAByPath = usbTreeByAccessoryPath(in: snapshot.usb)
        let usbAAccessories = snapshot.accessories.filter {
            if case .usbA = $0.connector { return true }
            return false
        }
        for acc in usbAAccessories {
            let tree = (acc.registryPath.flatMap { usbAByPath[$0] })
                ?? (flat: [], roots: [], power: nil, controller: nil)
            let stub = synthLane(accessoryID: acc.id)
            let mode = modeFromAccessory(acc, usbDevices: tree.flat)
            out.append(PhysicalPort(
                number: acc.portNumber,
                id: acc.id,
                connector: .usbA,
                laneAdapter: stub, linkLane: nil,
                controller: tree.controller ?? stub,
                connectedDevice: nil, mode: mode,
                attachedUSBDevices: tree.flat,
                usbDeviceRoots: tree.roots,
                tunnels: [],
                accessory: acc,
                sourcePower: tree.power
            ))
        }

        // MagSafe pass: power-only receptacle. No TB, no USB tree — the only
        // signal is `usbPD.winning` when a charger is attached. Prepend so it
        // sorts above the data ports in CLI output, matching the GUI sidebar
        // which renders MagSafe at the top of Physical Ports.
        let magsafeAccessories = snapshot.accessories.filter {
            if case .magsafe = $0.connector { return true }
            return false
        }
        var magsafePorts: [PhysicalPort] = []
        for acc in magsafeAccessories {
            let stub = synthLane(accessoryID: acc.id)
            let mode = modeFromAccessory(acc, usbDevices: [])
            magsafePorts.append(PhysicalPort(
                number: acc.portNumber,
                id: acc.id,
                connector: .magsafe,
                laneAdapter: stub, linkLane: nil,
                controller: stub,
                connectedDevice: nil, mode: mode,
                attachedUSBDevices: [],
                usbDeviceRoots: [],
                tunnels: [],
                accessory: acc,
                sourcePower: nil
            ))
        }

        // HDMI pass: `AppleHDMIPortController` publishes one entry per
        // built-in HDMI jack. We surface the receptacle whenever the
        // chassis has one, regardless of whether a cable is seated —
        // it's a physical port and should appear in the list the same
        // way USB-C and USB-A do. Mode reflects attachment so the badge
        // colour still differentiates "empty" from "driving a display".
        let hdmiAccessories = snapshot.accessories.filter {
            if case .hdmi = $0.connector { return true }
            return false
        }
        var hdmiPorts: [PhysicalPort] = []
        for acc in hdmiAccessories {
            let stub = synthLane(accessoryID: acc.id)
            let mode: PhysicalPortMode = hdmiIsAttached(acc) ? .displayOnly : .empty
            hdmiPorts.append(PhysicalPort(
                number: acc.portNumber,
                id: acc.id,
                connector: .hdmi,
                laneAdapter: stub, linkLane: nil,
                controller: stub,
                connectedDevice: nil, mode: mode,
                attachedUSBDevices: [],
                usbDeviceRoots: [],
                tunnels: [],
                accessory: acc,
                sourcePower: nil
            ))
        }

        // SD Card pass: `SDCardScanner` emits an accessory entry whenever
        // the reader hardware exists. Card-present (IOMedia descendant)
        // shows as "Card inserted" via the mode; empty slot reads as
        // "Empty". This matches the HDMI behaviour — the receptacle is
        // visible on every chassis that has it.
        let sdAccessories = snapshot.accessories.filter {
            if case .sdCard = $0.connector { return true }
            return false
        }
        var sdPorts: [PhysicalPort] = []
        for acc in sdAccessories {
            let stub = synthLane(accessoryID: acc.id)
            // `connectionActive` is the scanner-set flag for media
            // present; map directly to the operating mode.
            let mode: PhysicalPortMode = acc.connectionActive
                ? .usbOnly(speed: nil)
                : .empty
            sdPorts.append(PhysicalPort(
                number: acc.portNumber,
                id: acc.id,
                connector: .sdCard,
                laneAdapter: stub, linkLane: nil,
                controller: stub,
                connectedDevice: nil,
                mode: mode,
                attachedUSBDevices: [],
                usbDeviceRoots: [],
                tunnels: [],
                accessory: acc,
                sourcePower: nil
            ))
        }

        // AC Power + Ethernet passes — both come from synthetic accessory
        // entries planted by their dedicated scanners. They live at the
        // top of the port list (power) and bottom (ethernet) respectively,
        // matching where the user looks for them in product photography.
        let acPowerPorts = snapshot.accessories.compactMap { acc -> PhysicalPort? in
            guard case .acPower = acc.connector else { return nil }
            let stub = synthLane(accessoryID: acc.id)
            return PhysicalPort(
                number: acc.portNumber,
                id: acc.id,
                connector: .acPower,
                laneAdapter: stub, linkLane: nil,
                controller: stub,
                connectedDevice: nil,
                mode: acc.connectionActive ? .charging(watts: nil) : .empty,
                attachedUSBDevices: [],
                usbDeviceRoots: [],
                tunnels: [],
                accessory: acc,
                sourcePower: nil
            )
        }
        let ethernetPorts = snapshot.accessories.compactMap { acc -> PhysicalPort? in
            guard case .ethernet = acc.connector else { return nil }
            let stub = synthLane(accessoryID: acc.id)
            return PhysicalPort(
                number: acc.portNumber,
                id: acc.id,
                connector: .ethernet,
                laneAdapter: stub, linkLane: nil,
                controller: stub,
                connectedDevice: nil,
                mode: acc.connectionActive ? .usbOnly(speed: nil) : .empty,
                attachedUSBDevices: [],
                usbDeviceRoots: [],
                tunnels: [],
                accessory: acc,
                sourcePower: nil
            )
        }

        return magsafePorts + acPowerPorts + out + hdmiPorts + sdPorts + ethernetPorts
    }

    /// True when the kernel reports something is actively connected to an
    /// HDMI receptacle. The HDMI port controller exposes:
    ///   * `ConnectionActive` — true when the sink has negotiated successfully
    ///   * `HDMI_HPD` — Hot Plug Detect line; flips on the moment a cable
    ///                  is seated, before any link training completes
    ///   * `TransportsActive` containing `"DisplayPort"` — set once pixels
    ///                  are flowing
    /// Drives the operating mode (empty vs. display-driving) for the HDMI
    /// physical port; the receptacle is rendered regardless.
    private static func hdmiIsAttached(_ acc: PortAccessoryInfo) -> Bool {
        if acc.connectionActive { return true }
        if acc.hpdAsserted { return true }
        if acc.activeTransports.contains(.displayPort) { return true }
        return false
    }

    /// Per-port flat list of every USB device reachable through this port,
    /// plus the top-level USB roots (so the sidebar can render real
    /// hierarchy). On Apple Silicon each `AppleT*USBXHCI` reachable by
    /// `IONameMatch = "usb-drd,…"` is the host-side controller for one USB-C
    /// receptacle, and its `locationID` high byte is the receptacle index —
    /// `drd0 → Port 1`, `drd1 → Port 2`, etc.
    private static func usbDevicesByPort(in snapshot: USBSnapshot) -> [Int: (flat: [TBNode], roots: [TBNode], power: PortSourcePower?)] {
        var flatByPort: [Int: [TBNode]] = [:]
        var rootsByPort: [Int: [TBNode]] = [:]
        var wakeLimitByPort: [Int: UInt64] = [:]
        var sleepLimitByPort: [Int: UInt64] = [:]
        for controller in snapshot.controllers {
            guard let portNumber = physicalPortNumber(forUSBController: controller) else {
                continue
            }
            flatByPort[portNumber, default: []] += allUSBDevices(under: controller)
            rootsByPort[portNumber, default: []] += topLevelUSBDevices(under: controller)
            // Highest-cap port wrapper wins — usually the SS one reports the
            // same number as the HS companion, but if they differ we want
            // the headroom figure, not the conservative one.
            for (w, s) in portCurrentLimits(under: controller) {
                if let w { wakeLimitByPort[portNumber] = max(wakeLimitByPort[portNumber] ?? 0, w) }
                if let s { sleepLimitByPort[portNumber] = max(sleepLimitByPort[portNumber] ?? 0, s) }
            }
        }

        var out: [Int: (flat: [TBNode], roots: [TBNode], power: PortSourcePower?)] = [:]
        let allPorts = Set(flatByPort.keys)
            .union(rootsByPort.keys)
            .union(wakeLimitByPort.keys)
            .union(sleepLimitByPort.keys)
        for portNumber in allPorts {
            let flat = flatByPort[portNumber] ?? []
            let roots = rootsByPort[portNumber] ?? []
            let sinks = flat.compactMap(sinkConsumer(from:))
            let wake = wakeLimitByPort[portNumber]
            let sleep = sleepLimitByPort[portNumber]
            let power: PortSourcePower? = (wake == nil && sleep == nil && sinks.isEmpty)
                ? nil
                : PortSourcePower(wakeLimitMA: wake,
                                  sleepLimitMA: sleep,
                                  sinks: sinks,
                                  outputProfile: nil)
            out[portNumber] = (flat: flat, roots: roots, power: power)
        }
        return out
    }

    /// Build a per-USB-A-receptacle map keyed by the IOAccessory IOPort's
    /// IORegistry path (e.g. `"IOService:/AppleARMPE/port-usb-a-1/Port-USB-A@1"`).
    /// External xHCI controllers (ASMedia ASM3142, etc.) expose one wrapper
    /// per protocol per receptacle (SS + HS companion); both wrappers carry
    /// the same `UsbIOPort` property pointing at the accessory entry, so
    /// merging on that string coalesces the pair back into one physical port.
    /// `usb-drd` (Thunderbolt USB-C) and `usb-auss` (internal SoC USB)
    /// controllers are skipped — their receptacles are already accounted for
    /// by the USB-C / TB topology pass.
    private static func usbTreeByAccessoryPath(in snapshot: USBSnapshot) -> [String: (flat: [TBNode], roots: [TBNode], power: PortSourcePower?, controller: TBNode?)] {
        var flatByPath: [String: [TBNode]] = [:]
        var rootsByPath: [String: [TBNode]] = [:]
        var wakeByPath: [String: UInt64] = [:]
        var sleepByPath: [String: UInt64] = [:]
        var controllerByPath: [String: TBNode] = [:]
        for controller in snapshot.controllers {
            let nameMatch = controller.properties["IONameMatch"]?.asString
                ?? controller.properties["IONameMatched"]?.asString
                ?? ""
            if nameMatch.hasPrefix("usb-drd") || nameMatch.hasPrefix("usb-auss") { continue }
            for wrapper in controller.children where wrapper.kind == .other {
                let cls = wrapper.className
                guard cls.contains("XHCIPort") else { continue }
                guard let path = wrapper.properties["UsbIOPort"]?.asString,
                      !path.isEmpty else { continue }
                flatByPath[path, default: []] += allUSBDevices(under: wrapper)
                rootsByPath[path, default: []] += topLevelUSBDevices(under: wrapper)
                if let w = wrapper.properties["kUSBWakePortCurrentLimit"]?.asUInt {
                    wakeByPath[path] = max(wakeByPath[path] ?? 0, w)
                }
                if let s = wrapper.properties["kUSBSleepPortCurrentLimit"]?.asUInt {
                    sleepByPath[path] = max(sleepByPath[path] ?? 0, s)
                }
                controllerByPath[path] = controller
            }
        }
        var out: [String: (flat: [TBNode], roots: [TBNode], power: PortSourcePower?, controller: TBNode?)] = [:]
        let allPaths = Set(flatByPath.keys)
            .union(rootsByPath.keys)
            .union(wakeByPath.keys)
            .union(sleepByPath.keys)
        for path in allPaths {
            let flat = flatByPath[path] ?? []
            let roots = rootsByPath[path] ?? []
            let sinks = flat.compactMap(sinkConsumer(from:))
            let wake = wakeByPath[path]
            let sleep = sleepByPath[path]
            let power: PortSourcePower? = (wake == nil && sleep == nil && sinks.isEmpty)
                ? nil
                : PortSourcePower(wakeLimitMA: wake,
                                  sleepLimitMA: sleep,
                                  sinks: sinks,
                                  outputProfile: nil)
            out[path] = (flat, roots, power, controllerByPath[path])
        }
        return out
    }

    /// Pull `kUSBWakePortCurrentLimit` / `kUSBSleepPortCurrentLimit` from every
    /// `AppleUSB[23]0XHCIARMPort` wrapper under a USB controller. These port
    /// wrappers live one level below the xHCI controller and appear as
    /// `.other` kind in the tree (`AppleUSB30XHCIARMPort`,
    /// `AppleUSB20XHCIARMPort`).
    private static func portCurrentLimits(under controller: TBNode) -> [(UInt64?, UInt64?)] {
        var out: [(UInt64?, UInt64?)] = []
        var stack = controller.children
        while !stack.isEmpty {
            let n = stack.removeFirst()
            let wake = n.properties["kUSBWakePortCurrentLimit"]?.asUInt
            let sleep = n.properties["kUSBSleepPortCurrentLimit"]?.asUInt
            if wake != nil || sleep != nil {
                out.append((wake, sleep))
            }
            // Don't dive into actual USB devices — the limits live on the
            // port wrappers between the controller and the device.
            if n.kind == .usbDevice || n.kind == .usbHub { continue }
            stack.append(contentsOf: n.children)
        }
        return out
    }

    /// Build a `PortSinkConsumer` from a USB device node when the kernel
    /// has published a sink-side allocation for it. Filters out nodes that
    /// carry no allocation (every interface, plus root hubs, etc.) so the
    /// view only sees "real" sinks.
    private static func sinkConsumer(from node: TBNode) -> PortSinkConsumer? {
        let alloc = node.properties["UsbPowerSinkAllocation"]?.asUInt
        let cap = node.properties["UsbPowerSinkCapability"]?.asUInt
        let cfg = node.properties["kUSBConfigurationCurrentOverride"]?.asUInt
        let primary = alloc ?? cap ?? cfg ?? 0
        guard primary > 0 else { return nil }
        let name = node.properties["USB Product Name"]?.asString
            ?? node.properties["kUSBProductString"]?.asString
            ?? node.title
        return PortSinkConsumer(
            id: node.id,
            name: name,
            allocatedMA: alloc ?? cfg ?? cap ?? 0,
            capabilityMA: cap,
            configCurrentMA: cfg
        )
    }

    /// Top-level USB hubs/devices directly attached to this controller —
    /// recurse through `.other` port wrappers (`AppleUSB20XHCIARMPort` etc.)
    /// but stop at the first real `IOUSBHostDevice`. Each returned node keeps
    /// its full subtree intact so the sidebar can show nested hubs.
    private static func topLevelUSBDevices(under node: TBNode) -> [TBNode] {
        var out: [TBNode] = []
        for c in node.children {
            if c.kind == .usbDevice || c.kind == .usbHub {
                out.append(c)
            } else if c.kind == .other {
                out.append(contentsOf: topLevelUSBDevices(under: c))
            }
        }
        return out
    }

    private static func physicalPortNumber(forUSBController controller: TBNode) -> Int? {
        let nameMatch = controller.properties["IONameMatch"]?.asString
            ?? controller.properties["IONameMatched"]?.asString
            ?? ""
        guard nameMatch.hasPrefix("usb-drd") else { return nil }
        guard let loc = controller.properties["locationID"]?.asUInt else { return nil }
        return Int(loc >> 24) + 1
    }

    /// Walk a USB controller's full subtree (including `.other` port wrappers)
    /// and pull out every USB device / hub. Stable order by sidebar appearance.
    private static func allUSBDevices(under controller: TBNode) -> [TBNode] {
        var out: [TBNode] = []
        var stack = controller.children
        while !stack.isEmpty {
            let n = stack.removeFirst()
            if n.kind == .usbDevice || n.kind == .usbHub {
                out.append(n)
            }
            stack.append(contentsOf: n.children)
        }
        return out
    }

    /// Upgrade an inferred mode when accessory data clarifies it. E.g. a port
    /// the TB tree thinks is empty might actually be carrying DisplayPort
    /// alt-mode to a connected monitor.
    private static func refineMode(_ mode: PhysicalPortMode,
                                   with acc: PortAccessoryInfo,
                                   usbDevices: [TBNode]) -> PhysicalPortMode {
        switch mode {
        case .empty, .unknown:
            return modeFromAccessory(acc, usbDevices: usbDevices)
        default:
            return mode
        }
    }

    private static func modeFromAccessory(_ acc: PortAccessoryInfo,
                                          usbDevices: [TBNode]) -> PhysicalPortMode {
        // HPDAsserted can linger after a display is unplugged. If nothing is
        // currently connected, treat the port as empty regardless of any
        // residual signal state.
        guard acc.connectionActive || acc.detected || !acc.activeTransports.isEmpty else {
            return .empty
        }
        if acc.carriesThunderbolt { return .thunderbolt(linkSpeed: 0) }
        // USB is the primary mode whenever a USB pair is active — even if DP
        // alt-mode is also live (e.g. a 5-in-1 USB-C hub that drives both a
        // display and a few USB devices). Some hubs only enumerate over USB 2,
        // so don't gate on USB3 alone.
        let usbActive = acc.activeTransports.contains(.usb3)
            || acc.activeTransports.contains(.usb2)
            || !usbDevices.isEmpty
        if usbActive {
            let highest = usbDevices.compactMap {
                $0.properties["Device Speed"]?.asUInt ?? $0.properties["kUSBCurrentSpeed"]?.asUInt
            }.max()
            return .usbOnly(speed: highest)
        }
        if acc.activeTransports.contains(.displayPort) { return .displayOnly }
        // Power-only PD partner — e.g. an Apple USB-C wall charger. The kernel
        // sets `IOAccessoryUSBConnectString = "None"` (no USB role) but
        // `ConnectionActive = true` and publishes a winning PD contract under
        // `IOPortFeaturePowerIn`. Without this branch the port reads as Empty
        // even while pulling tens of watts.
        if let winning = acc.usbPD?.winning {
            return .charging(watts: winning.maxPowerMW / 1000)
        }
        // Something is detected but we can't tell what — fall back to Unknown
        // when the kernel says the port is live, else Empty.
        if acc.connectionActive { return .unknown }
        return .empty
    }

    /// Placeholder TBNode used when an HPM port has no matching TB controller.
    private static func synthLane(accessoryID id: TBNodeID) -> TBNode {
        TBNode(id: id, kind: .other, title: "Receptacle", subtitle: nil,
               className: "", properties: [:], propertyOrder: [],
               children: [], registryPath: nil)
    }

    private static func makePort(number: Int, controller: TBNode, accessory: PortAccessoryInfo?) -> PhysicalPort? {
        guard let root = findRootSwitch(in: controller) else { return nil }

        let lanes = root.children.filter { isLaneAdapter($0) }
        let chosen: TBNode?
        var linkLane: TBNode?
        var dockSwitch: TBNode?

        // Prefer a lane whose subtree contains a downstream switch — that's
        // the one carrying live traffic. Capture both the peer lane and the
        // switch in one pass so we don't BFS the same subtree twice.
        if let match = lanes.compactMap({ lane -> (TBNode, TBNode, TBNode)? in
            guard let (peer, sw) = findDownstreamLink(under: lane) else { return nil }
            return (lane, peer, sw)
        }).first {
            chosen = match.0
            linkLane = match.1
            dockSwitch = match.2
        } else {
            chosen = lanes.sorted(by: portOrder).first
        }
        guard let lane = chosen else { return nil }

        let connected = dockSwitch.map { describe(device: $0) }
        let usbDevices = connected.map { collectUSBDevices(under: $0.routerNode) } ?? []
        // Tunnel reservations are published on the *host-side* function
        // adapters — the ones sitting on this controller's root switch.
        // The dock-side function adapters in the connected router carry
        // placeholder values (DP: req=max=1) for the same logical tunnel,
        // so summing from the dock under-reports DP bandwidth by ~30 Gb/s
        // on an active setup. Read from the host root.
        let rootSwitch = findRootSwitch(in: controller)
        let tunnels: [PortTunnel] = connected != nil
            ? (rootSwitch.map { summariseTunnels(in: $0) } ?? [])
            : []
        let mode = inferMode(lane: lane, connectedDevice: connected, usbDevices: usbDevices)

        return PhysicalPort(
            number: number,
            id: lane.id,
            connector: accessory?.connector ?? .usbC,
            laneAdapter: lane,
            linkLane: linkLane,
            controller: controller,
            connectedDevice: connected,
            mode: mode,
            attachedUSBDevices: usbDevices,
            usbDeviceRoots: [],
            tunnels: tunnels,
            accessory: accessory,
            sourcePower: nil
        )
    }

    private static func inferMode(lane: TBNode,
                                  connectedDevice: ConnectedDevice?,
                                  usbDevices: [TBNode]) -> PhysicalPortMode {
        let speed = lane.properties["Current Link Speed"]?.asUInt ?? 0
        if connectedDevice != nil {
            return .thunderbolt(linkSpeed: speed)
        }
        if !usbDevices.isEmpty {
            let highest = usbDevices.compactMap {
                $0.properties["Device Speed"]?.asUInt ?? $0.properties["kUSBCurrentSpeed"]?.asUInt
            }.max()
            return .usbOnly(speed: highest)
        }
        if speed > 0 { return .unknown }
        return .empty
    }

    /// Walk the router's subtree and pull out every USB device (host devices,
    /// hubs, and leaf devices). Used for the per-port USB device list.
    private static func collectUSBDevices(under node: TBNode) -> [TBNode] {
        var out: [TBNode] = []
        var stack = node.children
        while !stack.isEmpty {
            let n = stack.removeFirst()
            if n.kind == .usbDevice || n.kind == .usbHub {
                out.append(n)
            }
            stack.append(contentsOf: n.children)
        }
        return out
    }

    /// Summarise the active tunnels on a router by adapter class. Public
    /// because the detail views need it to render the Uplink card for an
    /// arbitrary router (whichever router the user navigated to) — the
    /// kernel publishes reliable per-tunnel reservations only on the
    /// router's own function adapters, not on either endpoint of the lane.
    static func summariseTunnels(in router: TBNode) -> [PortTunnel] {
        var totals: [PortTunnel.Kind: (reserved: UInt64, max: UInt64, count: Int)] = [:]
        for child in router.children where child.kind == .port {
            let desc = child.properties["Description"]?.asString ?? ""
            guard let kind = tunnelKind(for: desc) else { continue }
            let reserved = child.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
            let maxBw = child.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
            // Only count active adapters — ones with a populated hop table
            // or a non-zero reservation. An idle DP adapter (no hops, req=0)
            // doesn't carry a tunnel and shouldn't inflate "× 4 adapters".
            let active: Bool = {
                if reserved > 0 || maxBw > 0 { return true }
                if case let .array(arr) = child.properties["Hop Table"], !arr.isEmpty {
                    return true
                }
                return false
            }()
            guard active else { continue }
            var entry = totals[kind] ?? (0, 0, 0)
            entry.reserved += reserved
            entry.max += maxBw
            entry.count += 1
            totals[kind] = entry
        }
        return totals
            .filter { $0.value.reserved > 0 || $0.value.max > 0 }
            .map {
                PortTunnel(
                    kind: $0.key,
                    reservedBandwidth: $0.value.reserved,
                    maxBandwidth: $0.value.max,
                    adapterCount: $0.value.count
                )
            }
            .sorted { $0.label < $1.label }
    }

    private static func tunnelKind(for description: String) -> PortTunnel.Kind? {
        switch description {
        case "DP or HDMI Adapter": return .displayPort
        case "USB Adapter", "USB Gen T Adapter": return .usb
        case "PCIe Adapter": return .pcie
        default: return nil
        }
    }

    private static func findRootSwitch(in node: TBNode) -> TBNode? {
        for c in node.children {
            if c.kind == .switch, (c.properties["Depth"]?.asUInt ?? 0) == 0 {
                return c
            }
            for cc in c.children where cc.kind == .switch {
                if (cc.properties["Depth"]?.asUInt ?? 0) == 0 { return cc }
            }
        }
        return nil
    }

    private static func isLaneAdapter(_ node: TBNode) -> Bool {
        guard node.kind == .port else { return false }
        let raw = node.properties["Adapter Type"]?.asUInt ?? 0
        if case .lane = TBAdapterType(rawValue: raw) { return true }
        return false
    }

    /// Descend through any peer-port wrappers to find the next switch downstream.
    /// On Apple Silicon the tree is `host lane → peer lane → dock switch`,
    /// so we need to traverse intermediate port nodes.
    private static func downstreamSwitch(of laneAdapter: TBNode) -> TBNode? {
        findDownstreamLink(under: laneAdapter)?.1
    }

    /// Like `downstreamSwitch` but also returns the immediate parent port
    /// of the switch — the "peer lane". The peer lane is where the kernel
    /// aggregates `Link Bandwidth` and tunnel reservations for the entire
    /// downstream link. Returns `(peerLane, switch)` or nil if no switch.
    private static func findDownstreamLink(under laneAdapter: TBNode) -> (TBNode, TBNode)? {
        // DFS with parent tracking. We want the first switch we hit and the
        // port wrapper directly above it.
        var stack: [(TBNode, TBNode)] = []  // (parent, node)
        for c in laneAdapter.children {
            stack.append((laneAdapter, c))
        }
        while !stack.isEmpty {
            let (parent, n) = stack.removeFirst()
            if n.kind == .switch { return (parent, n) }
            if n.kind == .port {
                for c in n.children { stack.append((n, c)) }
            }
        }
        return nil
    }

    private static func portOrder(_ a: TBNode, _ b: TBNode) -> Bool {
        return (a.properties["Port Number"]?.asUInt ?? 0)
            < (b.properties["Port Number"]?.asUInt ?? 0)
    }

    private static func describe(device router: TBNode) -> ConnectedDevice {
        let vendor = router.properties["Device Vendor Name"]?.asString
        let model = router.properties["Device Model Name"]?.asString
        let title: String
        if let v = vendor, let m = model {
            title = "\(v) \(m)"
        } else if let m = model {
            title = m
        } else {
            title = "Thunderbolt Device"
        }
        let depth = router.properties["Depth"]?.asUInt ?? 0
        let tbGen = router.properties["Thunderbolt Version"]?.asUInt
        var subParts: [String] = []
        if let g = tbGen {
            subParts.append("Spec \((g >> 4) & 0xF).\(g & 0xF)")
        }
        if depth > 0 { subParts.append("hop \(depth)") }
        let subtitle = subParts.isEmpty ? nil : subParts.joined(separator: " · ")

        var chained: [ConnectedDevice] = []
        for child in router.children where isLaneAdapter(child) {
            if let next = downstreamSwitch(of: child), next.id != router.id {
                chained.append(describe(device: next))
            }
        }

        return ConnectedDevice(
            id: router.id,
            title: title,
            subtitle: subtitle,
            routerNode: router,
            daisyChained: chained
        )
    }
}
