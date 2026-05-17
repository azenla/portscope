//
//  TopologyMapper.swift
//  Boltprobe
//
//  Translates the raw IOKit trees (Thunderbolt + USB) into the simplified
//  user-facing topology: physical USB-C / Thunderbolt ports → connected
//  devices → daisy-chained devices, plus the USB devices reached through
//  each port.
//

import Foundation

/// One physical USB-C / Thunderbolt port on the Mac. Backed by the
/// controller's "active" lane adapter (or port 1 if no device is plugged in).
struct PhysicalPort {
    let number: Int
    let id: TBNodeID
    /// Host-side lane adapter on the root switch. Use this for static info
    /// like link speed / width (the link negotiates the same numbers on both
    /// sides).
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
    let attachedUSBDevices: [TBNode]
    /// Tunnel summaries on the port's connected router (active tunnels by class).
    let tunnels: [PortTunnel]
    /// Per-receptacle runtime state from `IOAccessoryManager`, when available.
    /// Carries transport state, USB-PD power, plug orientation, displayport
    /// HPD, cable e-marker info — the data that doesn't show up in the
    /// Thunderbolt or USB IOKit families.
    let accessory: PortAccessoryInfo?

    /// The lane node to query for bandwidth allocations. Prefers `linkLane`
    /// (sees all tunnels through the link) and falls back to `laneAdapter`
    /// (host-side, used when nothing is connected).
    var bandwidthLane: TBNode { linkLane ?? laneAdapter }
}

struct PortTunnel: Hashable {
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
    /// Subtitle shown beneath the port in the sidebar.
    var statusLabel: String {
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
            if let s, s > 0 { return "USB · \(usbSpeedShortLabel(s))" }
            return "USB"
        case .displayOnly: return "Display"
        case .unknown: return "Link up"
        }
    }
}

extension ConnectedDevice {
    var shortTitle: String {
        return routerNode.properties["Device Model Name"]?.asString
            ?? routerNode.properties["Device Vendor Name"]?.asString
            ?? title
    }
}

enum TopologyMapper {
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
        let usbCAccessories = snapshot.accessories.filter {
            if case .usbC = $0.connector { return true }
            return false
        }

        guard !usbCAccessories.isEmpty else {
            // No HPM data — number ports by TB controller iteration order.
            return tbPorts.enumerated().map { idx, p in
                PhysicalPort(
                    number: idx + 1,
                    id: p.id, laneAdapter: p.laneAdapter, linkLane: p.linkLane,
                    controller: p.controller,
                    connectedDevice: p.connectedDevice, mode: p.mode,
                    attachedUSBDevices: p.attachedUSBDevices, tunnels: p.tunnels,
                    accessory: nil
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
            if let tb {
                out.append(PhysicalPort(
                    number: acc.portNumber,
                    id: tb.id, laneAdapter: tb.laneAdapter, linkLane: tb.linkLane,
                    controller: tb.controller,
                    connectedDevice: tb.connectedDevice, mode: refineMode(tb.mode, with: acc),
                    attachedUSBDevices: tb.attachedUSBDevices, tunnels: tb.tunnels,
                    accessory: acc
                ))
            } else {
                // HPM port with no matching TB controller (rare; fall back to a
                // synthetic stub that still surfaces the receptacle in the UI).
                let stub = synthLane(accessoryID: acc.id)
                out.append(PhysicalPort(
                    number: acc.portNumber,
                    id: acc.id, laneAdapter: stub, linkLane: nil,
                    controller: stub,
                    connectedDevice: nil, mode: modeFromAccessory(acc),
                    attachedUSBDevices: [], tunnels: [],
                    accessory: acc
                ))
            }
        }
        // Append any leftover TB controllers (uncommon: HPM count < TB count).
        for (i, tb) in remainingTB.enumerated() {
            out.append(PhysicalPort(
                number: out.count + i + 1,
                id: tb.id, laneAdapter: tb.laneAdapter, linkLane: tb.linkLane,
                controller: tb.controller,
                connectedDevice: tb.connectedDevice, mode: tb.mode,
                attachedUSBDevices: tb.attachedUSBDevices, tunnels: tb.tunnels,
                accessory: nil
            ))
        }
        return out
    }

    /// Upgrade an inferred mode when accessory data clarifies it. E.g. a port
    /// the TB tree thinks is empty might actually be carrying DisplayPort
    /// alt-mode to a connected monitor.
    private static func refineMode(_ mode: PhysicalPortMode,
                                   with acc: PortAccessoryInfo) -> PhysicalPortMode {
        switch mode {
        case .empty, .unknown:
            return modeFromAccessory(acc)
        default:
            return mode
        }
    }

    private static func modeFromAccessory(_ acc: PortAccessoryInfo) -> PhysicalPortMode {
        if acc.carriesThunderbolt { return .thunderbolt(linkSpeed: 0) }
        if acc.activeTransports.contains(.usb3) { return .usbOnly(speed: nil) }
        if acc.carriesDisplay { return .displayOnly }
        if acc.connection.isConnected { return .unknown }
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
        let tunnels = connected.map { summariseTunnels(in: $0.routerNode) } ?? []
        let mode = inferMode(lane: lane, connectedDevice: connected, usbDevices: usbDevices)

        return PhysicalPort(
            number: number,
            id: lane.id,
            laneAdapter: lane,
            linkLane: linkLane,
            controller: controller,
            connectedDevice: connected,
            mode: mode,
            attachedUSBDevices: usbDevices,
            tunnels: tunnels,
            accessory: accessory
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

    /// Summarise the active tunnels on a router by adapter class.
    private static func summariseTunnels(in router: TBNode) -> [PortTunnel] {
        var totals: [PortTunnel.Kind: (reserved: UInt64, max: UInt64, count: Int)] = [:]
        for child in router.children where child.kind == .port {
            let desc = child.properties["Description"]?.asString ?? ""
            guard let kind = tunnelKind(for: desc) else { continue }
            let reserved = child.properties["Required Bandwidth Allocated"]?.asUInt ?? 0
            let maxBw = child.properties["Maximum Bandwidth Allocated"]?.asUInt ?? 0
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
