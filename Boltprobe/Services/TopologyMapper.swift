//
//  TopologyMapper.swift
//  Boltprobe
//
//  Translates the raw IOKit tree into the simplified user-facing topology:
//  physical Thunderbolt ports → connected devices → daisy-chained devices.
//

import Foundation

/// One physical USB-C / Thunderbolt port on the Mac. Backed by the controller's
/// "active" lane adapter (or port 1 if no device is plugged in).
struct PhysicalPort {
    let number: Int
    /// IORegistry entry of the lane adapter we represent. Used for selection
    /// so the detail view renders bandwidth + link negotiation for that port.
    let id: TBNodeID
    let laneAdapter: TBNode
    let controller: TBNode
    let connectedDevice: ConnectedDevice?
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
    /// Subtitle shown beneath the port in the sidebar. Keep it short — the
    /// connected device name appears as a child row, so don't repeat it.
    var statusLabel: String {
        guard connectedDevice != nil else { return "Empty" }
        let speed = laneAdapter.properties["Current Link Speed"]?.asUInt ?? 0
        let width = laneAdapter.properties["Current Link Width"]?.asUInt ?? 0
        var parts: [String] = ["Connected"]
        if speed > 0 { parts.append(tbGenerationShortLabel(speed)) }
        if width > 0 { parts.append("×\(width)") }
        return parts.joined(separator: " · ")
    }
}

extension ConnectedDevice {
    /// Short title used in port subtitles.
    var shortTitle: String {
        return routerNode.properties["Device Model Name"]?.asString
            ?? routerNode.properties["Device Vendor Name"]?.asString
            ?? title
    }
}

enum TopologyMapper {
    /// Build the simplified topology from a TBSnapshot.
    static func physicalPorts(from snapshot: TBSnapshot) -> [PhysicalPort] {
        var out: [PhysicalPort] = []
        for (idx, controller) in snapshot.controllers.enumerated() {
            guard let port = makePort(number: idx + 1, controller: controller) else { continue }
            out.append(port)
        }
        return out
    }

    private static func makePort(number: Int, controller: TBNode) -> PhysicalPort? {
        guard let root = findRootSwitch(in: controller) else { return nil }

        // Find lane adapters on the root switch (paired into one physical port).
        let lanes = root.children.filter { isLaneAdapter($0) }
        // Prefer the one with a downstream switch (= active port), else lowest port number.
        let active = lanes.first(where: { downstreamSwitch(of: $0) != nil })
        let chosen = active ?? lanes.sorted(by: portOrder).first
        guard let lane = chosen else { return nil }

        let connected = downstreamSwitch(of: lane).map { describe(device: $0) }

        return PhysicalPort(
            number: number,
            id: lane.id,
            laneAdapter: lane,
            controller: controller,
            connectedDevice: connected
        )
    }

    private static func findRootSwitch(in node: TBNode) -> TBNode? {
        for c in node.children {
            if c.kind == .switch, (c.properties["Depth"]?.asUInt ?? 0) == 0 {
                return c
            }
            // Root switch can sit beneath an NHI port. Recurse one level.
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

    /// Recursively describe a connected router and its daisy chain.
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

        // Daisy-chained = any switch below this one's lane adapters.
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
