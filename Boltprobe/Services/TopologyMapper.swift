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
    let laneAdapter: TBNode
    let controller: TBNode
    let connectedDevice: ConnectedDevice?
    /// Inferred operating mode of the port. Drives the badge/colour in the UI.
    let mode: PhysicalPortMode
    /// USB devices reachable through this port (flat list, hubs included).
    let attachedUSBDevices: [TBNode]
    /// Tunnel summaries on the port's connected router (active tunnels by class).
    let tunnels: [PortTunnel]
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
    /// Build the simplified topology from a TB-only snapshot.
    /// Kept for callers that haven't been moved to SystemSnapshot.
    static func physicalPorts(from snapshot: TBSnapshot) -> [PhysicalPort] {
        var out: [PhysicalPort] = []
        for (idx, controller) in snapshot.controllers.enumerated() {
            guard let port = makePort(number: idx + 1, controller: controller) else { continue }
            out.append(port)
        }
        return out
    }

    static func physicalPorts(from snapshot: SystemSnapshot) -> [PhysicalPort] {
        return physicalPorts(from: snapshot.tb)
    }

    private static func makePort(number: Int, controller: TBNode) -> PhysicalPort? {
        guard let root = findRootSwitch(in: controller) else { return nil }

        let lanes = root.children.filter { isLaneAdapter($0) }
        let active = lanes.first(where: { downstreamSwitch(of: $0) != nil })
        let chosen = active ?? lanes.sorted(by: portOrder).first
        guard let lane = chosen else { return nil }

        let connected = downstreamSwitch(of: lane).map { describe(device: $0) }
        let usbDevices = connected.map { collectUSBDevices(under: $0.routerNode) } ?? []
        let tunnels = connected.map { summariseTunnels(in: $0.routerNode) } ?? []
        let mode = inferMode(lane: lane, connectedDevice: connected, usbDevices: usbDevices)

        return PhysicalPort(
            number: number,
            id: lane.id,
            laneAdapter: lane,
            controller: controller,
            connectedDevice: connected,
            mode: mode,
            attachedUSBDevices: usbDevices,
            tunnels: tunnels
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
        var stack = laneAdapter.children
        while !stack.isEmpty {
            let n = stack.removeFirst()
            if n.kind == .switch { return n }
            if n.kind == .port { stack.append(contentsOf: n.children) }
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
