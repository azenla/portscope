//
//  ThunderboltPeerModels.swift
//  PortScope
//
//  Surface Thunderbolt-networking peers (Mac-to-Mac, Mac-to-Linux, Mac-to-PC
//  TB Bridge). When two hosts are linked over a TB cable without any
//  intervening dock/device, each kernel publishes an
//  `IOThunderboltXDomainLink` under the lane that's carrying the link. The
//  link node names the remote endpoint (Vendor / Device / Domain UUID /
//  Hop ID range); the matching `AppleThunderboltIPService` subtree below
//  the same controller's local-node carries the BSD interface (en6, en2,
//  …) plus link speed and active state. Together they tell the user
//  "there is a Linux machine called `glass` on TB port 2 and we're talking
//  to it over en6 at 80 Gb/s," which is otherwise invisible — the kernel
//  doesn't dress XDomain peers up as a TB switch or a USB device, so
//  PortScope's other passes don't see them.
//

import Foundation

/// A Thunderbolt-networking peer attached on this physical port. Built by
/// walking the port's TB controller subtree for an `IOThunderboltXDomainLink`
/// node (the peer descriptor) and the controller's `AppleThunderboltIPService`
/// (the host-side network interface). Absent (`nil` on `PhysicalPort`) when
/// the controller has no XDomain link up.
nonisolated struct ThunderboltPeer: Hashable {
    /// `Device Name` from the XDomainLink — the peer's hostname when the
    /// remote kernel publishes one (`glass` on a Linux host, the Mac's
    /// `ComputerName` on a peer Mac). Nil on peers that don't advertise
    /// one.
    let deviceName: String?
    /// `Vendor Name` from the XDomainLink — typically `"Linux"` /
    /// `"Apple Inc."` / `"Microsoft"`. Strong enough on its own to badge
    /// the row when `deviceName` is missing.
    let vendorName: String?
    /// `Vendor ID` from the XDomainLink — the USB-IF VID published by the
    /// remote kernel (0x1D6B for Linux, 0x05AC for Apple, etc.). Kept in
    /// raw form so the detail view can print it in hex.
    let vendorID: UInt64?
    /// `Device ID` from the XDomainLink. Combined with `vendorID` this is
    /// the (vendor, device) tuple the remote kernel advertised at link
    /// negotiation.
    let deviceID: UInt64?
    /// `Domain UUID` from the XDomainLink — globally unique handle for the
    /// peer's TB domain. Same identifier the local node uses for itself,
    /// so two Macs see each other's domain UUID swapped.
    let domainUUID: String?
    /// `Max Hop ID` from the XDomainLink (path-routing range allocated to
    /// this peer link, surfaced as a developer detail).
    let maxHopID: UInt64?
    /// BSD name of the matching network interface on this Mac
    /// (`en2`, `en6`, …). Drives the "Interface" row in the detail view
    /// and is what the user types into `ifconfig` / Network preferences.
    let interfaceBSDName: String?
    /// IOMACAddress published on `AppleThunderboltIPPort`, stored as
    /// printable bytes ("36:58:BB:A1:D2:84"). Apple stores this as a
    /// `"0x…"` hex string in IOKit; we normalise to colon-separated form.
    let interfaceMAC: String?
    /// `IOLinkSpeed` from `AppleThunderboltIPPort` (bits/sec). For a
    /// TB5 cross-link the kernel publishes 80 000 000 000 — divide by
    /// 1e9 to get the marketing speed.
    let interfaceLinkSpeedBps: UInt64?
    /// `IOLinkStatus` bit 0 — true when the network interface is up.
    /// Independent of the XDomain link itself (which can stay
    /// established while the interface is down for configuration).
    let interfaceLinkActive: Bool
    /// `Thunderbolt IP Connection State` from `AppleThunderboltIPConnection`
    /// — 1 when the peer's IP service has finished handshaking. Same
    /// signal `system_profiler SPThunderboltDataType` reports as
    /// "Connected" for a TB Bridge peer.
    let ipConnectionUp: Bool
    /// `Thunderbolt IP Transmitter State` from
    /// `AppleThunderboltIPTransmitter` — 1 when packets are flowing.
    /// Mostly informational; the kernel sets it whenever the XDomain
    /// service exposes a `network` Service Key.
    let ipTransmitterUp: Bool
}

extension ThunderboltPeer {
    /// "Linux · glass" / "Apple Inc. · Alex's Mac" / "Linux peer" depending on
    /// which fields the remote published. Used as the hero line in the
    /// detail view's TB Networking card.
    var displayTitle: String {
        switch (vendorName, deviceName) {
        case let (v?, n?): return "\(v) · \(n)"
        case (let v?, nil): return "\(v) peer"
        case (nil, let n?): return n
        case (nil, nil):    return "Thunderbolt peer"
        }
    }

    /// "80 Gb/s" / "40 Gb/s" / nil. Caller decides whether to render the
    /// row when nil — typically yes, with "—" as the value.
    var linkSpeedLabel: String? {
        guard let bps = interfaceLinkSpeedBps, bps > 0 else { return nil }
        let gbps = Double(bps) / 1_000_000_000.0
        if gbps >= 10 { return String(format: "%.0f Gb/s", gbps) }
        return String(format: "%.1f Gb/s", gbps)
    }
}

/// Search a Thunderbolt controller's subtree for an `IOThunderboltXDomainLink`
/// peer descriptor and the matching `AppleThunderboltIPService` interface.
/// Both live inside the same `IOThunderboltControllerType7`:
///
///   * The XDomain link sits below the lane that's carrying the host-to-host
///     fabric: `controller/IOThunderboltPort@N/IOThunderboltSwitchType7/
///     IOThunderboltPort@M/IOThunderboltXDomainLink`. Properties on the
///     link node describe the *peer* (its Vendor / Device / Domain UUID).
///
///   * The IP service sits below the controller's local-node:
///     `controller/IOThunderboltLocalNode/AppleThunderboltIPService/
///     AppleThunderboltIPPort`. Below it we find the `IOEthernetInterface`
///     (BSD name) and `AppleThunderboltIPConnection` (handshake state).
///
/// Returns nil when no XDomain link exists — the controller is idle or
/// driving a dock instead of a peer host. Both passes walk descendants
/// iteratively (no recursion needed: TB depth is bounded).
nonisolated func findThunderboltPeer(in controller: TBNode) -> ThunderboltPeer? {
    guard let link = findDescendant(of: controller, where: { $0.className == "IOThunderboltXDomainLink" }) else {
        return nil
    }

    let deviceName = link.properties["Device Name"]?.asString
    let vendorName = link.properties["Vendor Name"]?.asString
    let vendorID = link.properties["Vendor ID"]?.asUInt
    let deviceID = link.properties["Device ID"]?.asUInt
    let domainUUID = link.properties["Domain UUID"]?.asString
    let maxHopID = link.properties["Max Hop ID"]?.asUInt

    // IP service sits under LocalNode, separate subtree from the XDomain
    // link. Pull the BSD interface details + handshake state from there.
    let ipPort = findDescendant(of: controller, where: { $0.className == "AppleThunderboltIPPort" })
    let interfaceBSDName: String?
    let interfaceMAC: String?
    let interfaceLinkSpeedBps: UInt64?
    let interfaceLinkActive: Bool
    if let ipPort {
        interfaceBSDName = findDescendant(of: ipPort, where: { $0.className == "IOEthernetInterface" })?
            .properties["BSD Name"]?.asString
        interfaceMAC = formatTBPeerMAC(ipPort.properties["IOMACAddress"])
        interfaceLinkSpeedBps = ipPort.properties["IOLinkSpeed"]?.asUInt
        // IOLinkStatus bit 0 = link up. Match the EthernetScanner check.
        let status = ipPort.properties["IOLinkStatus"]?.asUInt ?? 0
        interfaceLinkActive = (status & 0x1) == 0x1
    } else {
        interfaceBSDName = nil
        interfaceMAC = nil
        interfaceLinkSpeedBps = nil
        interfaceLinkActive = false
    }

    let connection = findDescendant(of: controller, where: { $0.className == "AppleThunderboltIPConnection" })
    let transmitter = findDescendant(of: controller, where: { $0.className == "AppleThunderboltIPTransmitter" })
    let ipConnectionUp = (connection?.properties["Thunderbolt IP Connection State"]?.asUInt ?? 0) > 0
    let ipTransmitterUp = (transmitter?.properties["Thunderbolt IP Transmitter State"]?.asUInt ?? 0) > 0

    return ThunderboltPeer(
        deviceName: deviceName,
        vendorName: vendorName,
        vendorID: vendorID,
        deviceID: deviceID,
        domainUUID: domainUUID,
        maxHopID: maxHopID,
        interfaceBSDName: interfaceBSDName,
        interfaceMAC: interfaceMAC,
        interfaceLinkSpeedBps: interfaceLinkSpeedBps,
        interfaceLinkActive: interfaceLinkActive,
        ipConnectionUp: ipConnectionUp,
        ipTransmitterUp: ipTransmitterUp
    )
}

/// BFS down a TBNode subtree for the first node matching `predicate`.
/// Iterative so we can't blow the stack on weirdly deep registry paths
/// (TB depth is bounded but the IP service tree stacks several wrappers).
private nonisolated func findDescendant(of root: TBNode, where predicate: (TBNode) -> Bool) -> TBNode? {
    var stack: [TBNode] = root.children
    while let n = stack.popLast() {
        if predicate(n) { return n }
        stack.append(contentsOf: n.children)
    }
    return nil
}

/// `IOMACAddress` on `AppleThunderboltIPPort` arrives as a 6-byte `Data`
/// blob on Apple Silicon (same shape ethernet drivers publish). Older
/// stacks publish a `"0x…"` hex string — handle both. Output is the
/// canonical colon-separated uppercase form ("36:58:BB:A1:D2:84") so the
/// detail view doesn't have to massage it inline.
private nonisolated func formatTBPeerMAC(_ value: IORegValue?) -> String? {
    if case let .data(d)? = value, d.count >= 6 {
        return d.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    guard var s = value?.asString else { return nil }
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    guard s.count == 12, s.allSatisfy({ $0.isHexDigit }) else { return s }
    var out = ""
    for (idx, ch) in s.uppercased().enumerated() {
        if idx > 0 && idx % 2 == 0 { out.append(":") }
        out.append(ch)
    }
    return out
}
