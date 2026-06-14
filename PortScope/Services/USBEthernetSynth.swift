//
//  USBEthernetSynth.swift
//  PortScope
//
//  USB-attached Ethernet adapters publish their BSD interface several levels
//  below the IOUSBHostDevice — a vendor driver kext (e.g. AppleUSBNCMData,
//  AppleUSBECMData, the Realtek RTL8156 kext) hosts the IOEthernetInterface
//  and carries the IOMACAddress / IOLinkStatus / IOActiveMedium properties.
//  The IOEthernetInterface itself only knows the BSD name. This file walks
//  a TBNode subtree, pairs each ethernet interface with its controller, and
//  produces a flat summary that can be rendered both on the physical-port
//  detail view (per-port roll-up of all USB-Ethernet jacks behind a dock)
//  and on the USB device's own detail page (zoom-in on a single adapter).
//

import Foundation

/// One USB-attached Ethernet adapter beneath a USB device root. Built by
/// walking the IOService subtree for an `IOEthernetInterface` and reading
/// the carrying properties off its parent driver kext (the controller).
nonisolated struct USBEthernetAdapterInfo: Hashable {
    /// IORegistry entry ID of the `IOEthernetInterface` — used both as a
    /// stable identity for ForEach and as a navigation target.
    let interfaceID: TBNodeID
    /// BSD interface name (e.g. `"en7"`). Nil if the kext hasn't published
    /// one yet — unusual but possible right after attach.
    let bsdName: String?
    /// Canonicalised MAC address (`"6C:6E:07:0A:23:36"`) decoded from the
    /// controller's `IOMACAddress`. Nil when the property isn't published.
    let macAddress: String?
    /// Link speed in Mb/s decoded from `IOActiveMedium`'s packed IFM_* word.
    let linkSpeedMbps: UInt64?
    /// `IOLinkStatus & 0x3 == 0x3` — bit 0 (`kIONetworkLinkValid`) only
    /// says the status is meaningful; bit 1 (`kIONetworkLinkActive`) is
    /// the actual link. An adapter with no cable publishes status 1.
    let linkActive: Bool
    /// USB device's title — e.g. `"USB 10/100/1G/2.5G LAN"` — pulled off
    /// the closest enclosing IOUSBHostDevice. Nil when the interface lives
    /// outside a USB subtree (TB-IP bridge, built-in NIC).
    let usbDeviceTitle: String?
    /// USB vendor name (e.g. `"Realtek"`) from the enclosing IOUSBHostDevice.
    let usbVendorName: String?
    /// Best-effort product name. Falls back to the USB device title.
    let productName: String?
    /// Class name of the kext that carries the controller properties
    /// (`"AppleUSBNCMData"`, `"LRCRTL8156"`, etc.).
    let controllerClassName: String?
}

/// Search a USB-device subtree for any IOEthernetInterface and bundle each
/// one with the carrier controller's MAC / link state / speed. The walk
/// tracks the most recent enclosing `IOUSBHostDevice` so the resulting info
/// knows which USB device the interface belongs to. We only emit entries
/// reached through a USB device root — the TB-IP bridge lives on its own
/// IOService branch and shouldn't leak into the per-USB-port summary.
nonisolated func findUSBEthernetAdapters(in roots: [TBNode]) -> [USBEthernetAdapterInfo] {
    var out: [USBEthernetAdapterInfo] = []

    func walk(_ node: TBNode, usbDevice: TBNode?) {
        let nextUSB: TBNode? = {
            switch node.kind {
            case .usbDevice, .usbHub: return node
            default: return usbDevice
            }
        }()
        for child in node.children where child.kind == .networkIf
            && child.className == "IOEthernetInterface" {
            // `node` is the IOEthernetController (the driver kext) — it
            // carries the MAC and link state; `child` is the BSD interface.
            out.append(makeAdapterInfo(controller: node,
                                       iface: child,
                                       usbDevice: nextUSB))
        }
        for c in node.children { walk(c, usbDevice: nextUSB) }
    }

    for root in roots { walk(root, usbDevice: nil) }
    return out
}

nonisolated private func makeAdapterInfo(controller: TBNode,
                                         iface: TBNode,
                                         usbDevice: TBNode?) -> USBEthernetAdapterInfo {
    let cprops = controller.properties
    let iprops = iface.properties
    let bsd = iprops["BSD Name"]?.asString
    let mac = formatMACAddress(cprops["IOMACAddress"] ?? iprops["IOMACAddress"])
    let linkActive = ((cprops["IOLinkStatus"]?.asUInt ?? 0) & 0x3) == 0x3
    let speedMbps = decodeEthernetSpeedMbps(cprops["IOActiveMedium"])
    let usbProps = usbDevice?.properties
    // Prefer `kUSBProductString` over `USB Product Name` — the latter is the
    // sanitised entry-name mirror (slashes → underscores on some devices).
    let productName = (usbProps.flatMap { NodeFormatter.usbProductName($0) })
        ?? usbDevice?.title
    let usbVendor = (usbProps.flatMap { NodeFormatter.usbVendorName($0) })
    return USBEthernetAdapterInfo(
        interfaceID: iface.id,
        bsdName: bsd,
        macAddress: mac,
        linkSpeedMbps: speedMbps,
        linkActive: linkActive,
        usbDeviceTitle: usbDevice?.title,
        usbVendorName: usbVendor,
        productName: productName,
        controllerClassName: controller.className
    )
}

/// IOMACAddress comes in as a "0x…" hex string (e.g. `"0x6c6e070a2336"`)
/// on Apple Silicon drivers — same shape as the built-in jacks. We also
/// handle the Data-blob fallback in case a different driver publishes it
/// that way. Output is the canonical colon-separated uppercase form.
nonisolated func formatMACAddress(_ value: IORegValue?) -> String? {
    if case let .data(d)? = value, d.count >= 6 {
        return d.prefix(6).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
    guard let s = value?.asString else { return nil }
    let hex = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    let chars = Array(hex)
    guard chars.count >= 12 else { return s }
    var out: [String] = []
    var i = 0
    while i < 12 {
        out.append(String(chars[i...(i + 1)]))
        i += 2
    }
    return out.joined(separator: ":")
}

/// Decode IOActiveMedium into Mb/s. The kernel publishes the medium as a
/// hex-formatted string like "00100030" — a packed `IFM_*` word (see
/// `<net/if_media.h>`): bits 5..7 hold the media type (`IFM_ETHER` = 0x20),
/// bits 0..4 the ethernet subtype, the high half options like
/// `IFM_FDX = 0x00100000`. Subtype values come from the macOS SDK header —
/// FreeBSD's `if_media.h` assigns different numbers (10G = 26 there,
/// 21 here). Shared by `EthernetScanner` and the USB-Ethernet synth.
nonisolated func decodeEthernetSpeedMbps(_ value: IORegValue?) -> UInt64? {
    // Newer drivers expose a numeric `Link Speed` directly — prefer it.
    if case let .unsigned(u)? = value, u > 0 { return u }
    guard var s = value?.asString else { return nil }
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
    guard let raw = UInt64(s, radix: 16) else { return nil }
    // Must be an ethernet medium word.
    guard raw & 0xE0 == 0x20 else { return nil }
    switch raw & 0x1F {
    case 3:  return 10       // IFM_10_T
    case 6:  return 100      // IFM_100_TX
    case 16: return 1_000    // IFM_1000_T
    case 21: return 10_000   // IFM_10G_T
    case 22: return 2_500    // IFM_2500_T
    case 23: return 5_000    // IFM_5000_T
    default: return nil
    }
}
