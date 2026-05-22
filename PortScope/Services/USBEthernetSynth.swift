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
    /// `IOLinkStatus & 0x1` — true when the cable is plugged and the PHY
    /// has negotiated.
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
    let linkActive = ((cprops["IOLinkStatus"]?.asUInt ?? 0) & 0x1) == 0x1
    let speedMbps = decodeEthernetSpeedMbps(cprops["IOActiveMedium"])
    let usbProps = usbDevice?.properties
    let productName = usbProps?["USB Product Name"]?.asString
        ?? usbProps?["kUSBProductString"]?.asString
        ?? usbDevice?.title
    let usbVendor = usbProps?["USB Vendor Name"]?.asString
        ?? usbProps?["kUSBVendorString"]?.asString
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

/// Decode IOActiveMedium into Mb/s. Mirrors the same IFM_* table the
/// built-in `EthernetScanner` uses — both ethernet driver families publish
/// the medium word in the same format. See `<net/if_media.h>`.
nonisolated func decodeEthernetSpeedMbps(_ value: IORegValue?) -> UInt64? {
    if case let .unsigned(u)? = value, u > 0 { return u }
    guard let s = value?.asString, let raw = UInt64(s, radix: 16) else { return nil }
    guard raw & 0xE0 == 0x20 else { return nil }
    switch raw & 0x1F {
    case 3:  return 10
    case 6:  return 100
    case 16: return 1_000
    case 26: return 10_000
    case 29: return 2_500
    case 30: return 5_000
    default: return nil
    }
}
