//
//  PCIScanner.swift
//  PortScope
//
//  Walk every `IOPCIDevice` and build a topology of root bridges +
//  downstream bridges + endpoints. On Apple Silicon the root bridges live
//  directly under `IOPlatformExpertDevice`; endpoints hang off the bridges.
//

import Foundation
import IOKit

nonisolated enum PCIScanner {
    static func scan() -> PCISnapshot {
        var rawNodes: [io_registry_entry_t: TBNode] = [:]
        var parents: [TBNodeID: TBNodeID?] = [:]
        var byID: [TBNodeID: TBNode] = [:]

        // First pass: enumerate every IOPCIDevice service so we have all of
        // them in hand, indexed by registry entry id.
        let services = IORegBridge.services(matchingClass: "IOPCIDevice")
        defer { services.forEach { IOObjectRelease($0) } }

        for svc in services {
            guard let node = NodeBuilder.build(from: svc) else { continue }
            rawNodes[svc] = node
            byID[node.id] = node
        }

        // Second pass: for each device, find its parent in the IOService
        // plane and check whether that parent is itself an IOPCIDevice. If
        // so we record the link; otherwise the device is a root.
        for svc in services {
            guard let node = rawNodes[svc] else { continue }
            var parentSvc = IORegBridge.parent(of: svc)
            var parentPCIID: TBNodeID? = nil
            // Walk up at most ~8 levels — Apple's tree has shim wrappers
            // between the parent IOPCIDevice and the child.
            var hop = 0
            while let p = parentSvc, hop < 12 {
                if let cls = IORegBridge.className(of: p), cls == "IOPCIDevice",
                   let pid = IORegBridge.entryID(of: p),
                   byID[TBNodeID(raw: pid)] != nil {
                    parentPCIID = TBNodeID(raw: pid)
                    IOObjectRelease(p)
                    break
                }
                let next = IORegBridge.parent(of: p)
                IOObjectRelease(p)
                parentSvc = next
                hop += 1
            }
            parents[node.id] = parentPCIID
        }

        // Build PCINode trees recursively rooted at devices with no parent.
        let roots = byID.values
            .filter { parents[$0.id] ?? nil == nil }
            .sorted { sortKey(for: $0) < sortKey(for: $1) }

        let pciRoots: [PCINode] = roots.map { root in
            buildPCINode(node: root, byID: byID, parents: parents, depth: 0)
        }
        return PCISnapshot(roots: pciRoots)
    }

    // MARK: - Build

    private static func buildPCINode(node: TBNode,
                                     byID: [TBNodeID: TBNode],
                                     parents: [TBNodeID: TBNodeID?],
                                     depth: Int) -> PCINode {
        // Recurse into children: anything whose recorded parent is this id.
        let childIDs = parents.compactMap { (k, v) -> TBNodeID? in
            v == node.id ? k : nil
        }
        let childNodes = childIDs.compactMap { byID[$0] }
            .sorted { sortKey(for: $0) < sortKey(for: $1) }
        let children = childNodes.map {
            buildPCINode(node: $0, byID: byID, parents: parents, depth: depth + 1)
        }

        let props = node.properties
        let vendor: UInt16? = parseLittleEndian16(props["vendor-id"])
        let device: UInt16? = parseLittleEndian16(props["device-id"])
        let subVendor: UInt16? = parseLittleEndian16(props["subsystem-vendor-id"])
        let subDevice: UInt16? = parseLittleEndian16(props["subsystem-id"])
        let (cls, sub, prog) = parseClassCode(props["class-code"])
        let isBuiltIn = (props["built-in"] != nil)

        // Link info — `IOPCIExpressLinkStatus` packs current speed/width:
        //   bits 0-3  = current speed (1..6)
        //   bits 4-9  = current width (1..16)
        // `IOPCIExpressLinkCapabilities` packs max speed/width similarly:
        //   bits 0-3  = max speed
        //   bits 4-9  = max width
        let (curSpeed, curWidth) = decodeLinkStatus(props["IOPCIExpressLinkStatus"]?.asUInt)
        let (maxSpeed, maxWidth) = decodeLinkStatus(props["IOPCIExpressLinkCapabilities"]?.asUInt)

        let bdf = props["pcidebug"]?.asString
        // The IORegistry encodes `AAPL,slot-name` as a NUL-terminated UTF-8
        // data blob rather than a CFString — fall through to `asDataString`
        // so we recognise "Slot- 0..2" on the TB downstream root ports.
        let slot = props["AAPL,slot-name"]?.asString
            ?? props["AAPL,slot-name"]?.asDataString

        let kind = classify(node: node, hasPCIChildren: !children.isEmpty, depth: depth)
        let (title, subtitle) = makeLabels(
            node: node, kind: kind, vendor: vendor, device: device,
            subVendor: subVendor, slotName: slot
        )

        return PCINode(
            backingID: node.id,
            node: node,
            kind: kind,
            title: title,
            subtitle: subtitle,
            vendorID: vendor,
            deviceID: device,
            subsystemVendorID: subVendor,
            subsystemDeviceID: subDevice,
            classCode: cls,
            subclassCode: sub,
            progIF: prog,
            linkSpeed: curSpeed,
            linkWidth: curWidth,
            maxLinkSpeed: maxSpeed,
            maxLinkWidth: maxWidth,
            bdf: bdf,
            slotName: slot,
            isBuiltIn: isBuiltIn,
            children: children
        )
    }

    private static func sortKey(for node: TBNode) -> (String, String, UInt64) {
        // `IOName` alone isn't a stable sibling order — every bridge shares
        // "pci-bridge", so dictionary iteration would leak through and the
        // dumper's byte-identical-output contract breaks. Tie-break on the
        // device-tree `name` / slot name (unique per bridge) and finally
        // the registry entry id.
        let n = node.properties["IOName"]?.asString ?? node.title
        let dt = (node.properties["name"]?.asString)
            ?? node.properties["name"]?.asDataString
            ?? node.properties["AAPL,slot-name"]?.asString
            ?? node.properties["AAPL,slot-name"]?.asDataString
            ?? ""
        return (n, dt, node.id.raw)
    }

    // MARK: - Classification + labelling

    private static func classify(node: TBNode, hasPCIChildren: Bool, depth: Int) -> PCIKind {
        // class-code base 0x06 = Bridge device.
        if let cc = parseClassCode(node.properties["class-code"]).0, cc == 0x06 {
            return depth == 0 ? .rootBridge : .bridge
        }
        if hasPCIChildren { return depth == 0 ? .rootBridge : .bridge }
        return .endpoint
    }

    private static func makeLabels(node: TBNode,
                                   kind: PCIKind,
                                   vendor: UInt16?,
                                   device: UInt16?,
                                   subVendor: UInt16?,
                                   slotName: String?) -> (String, String?) {
        // The device-tree `name` is unique per bridge ("pci-bridge0",
        // "pcic0-bridge", "wlan", "bluetooth-pcie", "pcie-sdreader") while
        // `IOName` is a class hint that's often shared across instances
        // ("pci-bridge" for *every* bridge), so we prefer `name` for the
        // routing. Data-blob names come back as UTF-8 with a trailing NUL.
        let dtName = (node.properties["name"]?.asString)
            ?? node.properties["name"]?.asDataString
            ?? node.properties["IOName"]?.asString
            ?? node.title

        if kind == .endpoint {
            let (cls, sub2, prog) = parseClassCode(node.properties["class-code"])
            let friendly = friendlyEndpoint(dtName: dtName,
                                            ioName: node.properties["IOName"]?.asString ?? "",
                                            vendor: vendor,
                                            cls: cls, sub: sub2, prog: prog)
            let vendorName = vendor.flatMap(pciVendorName)
            var sub: [String] = []
            if let vendorName { sub.append(vendorName) }
            if let v = vendor, let d = device {
                sub.append(String(format: "%04X:%04X", v, d))
            }
            return (friendly, sub.isEmpty ? nil : sub.joined(separator: " · "))
        }

        if kind == .rootBridge || kind == .bridge {
            let slot = slotName ?? ""
            if !slot.isEmpty {
                // The Apple Silicon Thunderbolt downstream root ports are
                // tagged "Slot- 0..2" (note the space after "Slot-"). On
                // Intel Macs `AAPL,slot-name` marks real expansion slots
                // ("Slot-1", "x16 slot", …), so the Thunderbolt branding
                // is gated on the exact Apple Silicon pattern; anything
                // else surfaces the raw slot name as the label.
                if slot.hasPrefix("Slot- ") {
                    let n = slot.dropFirst("Slot- ".count).trimmingCharacters(in: .whitespaces)
                    return ("Thunderbolt PCIe Slot \(n)", "Apple Silicon root port")
                }
                return (slot, nil)
            }
            let isBuiltIn = node.properties["built-in"] != nil
            return (humaniseBridgeName(dtName, isBuiltIn: isBuiltIn), nil)
        }
        return (dtName, nil)
    }

    private static func humaniseBridgeName(_ name: String, isBuiltIn: Bool) -> String {
        if name.hasPrefix("pci-bridge") {
            // Dock-internal PCI-to-PCI bridges (several hops down a TB
            // tunnel) also publish a "pci-bridge…" device-tree name —
            // only the chassis' own root bridges deserve "Host".
            guard isBuiltIn else { return "PCIe Bridge" }
            let n = name.dropFirst("pci-bridge".count)
            return n.isEmpty ? "PCIe Host Bridge" : "PCIe Host Bridge \(n)"
        }
        if name.hasPrefix("pcic") && name.contains("-bridge") {
            return "Thunderbolt Root Port"
        }
        return "PCIe Bridge"
    }

    private static func friendlyEndpoint(dtName: String, ioName: String, vendor: UInt16?,
                                         cls: UInt8?, sub: UInt8?, prog: UInt8?) -> String {
        // Map device-tree names to user-facing labels. The names below come
        // from Apple's device tree and have been stable across silicon
        // generations.
        switch dtName {
        case "wlan", "wlan-pcie":
            return "Wi-Fi Adapter"
        case "bluetooth-pcie":
            return "Bluetooth Adapter"
        case "pcie-sdreader":
            return "SD Card Reader"
        default: break
        }
        if dtName.contains("nvme") || ioName.contains("nvme") { return "NVMe SSD Controller" }
        if dtName.contains("ethernet") { return "Ethernet Adapter" }
        // Unrecognised device-tree name: fall back to the PCI class label
        // ("Wireless Controller", "SD Host Controller", …) so chassis with
        // novel names still get something better than a generic title. The
        // vendor name stays in the subtitle either way.
        if let cls { return pciClassLabel(cls, sub, prog) }
        return "PCIe Device"
    }

    // MARK: - Property parsing

    /// Decode IOPCI link status / capabilities words. PCIe currently
    /// defines link speeds 1..6 (Gen 1..6) and widths 1, 2, 4, 8, 12, 16, 32 —
    /// anything outside those bands is the bridge advertising "no link"
    /// with a saturated field (typically 0xF / 0x3F) which we suppress so
    /// the UI doesn't show "Gen 15 ×63".
    private static func decodeLinkStatus(_ raw: UInt64?) -> (UInt64?, UInt64?) {
        guard let raw else { return (nil, nil) }
        let speed = raw & 0xF
        let width = (raw >> 4) & 0x3F
        let speedValid = speed >= 1 && speed <= 6
        let widthValid = [1, 2, 4, 8, 12, 16, 32].contains(width)
        return (speedValid ? speed : nil, widthValid ? width : nil)
    }

    private static func parseClassCode(_ value: IORegValue?) -> (UInt8?, UInt8?, UInt8?) {
        // The kernel publishes `class-code` as a 4-byte data blob in PCI
        // configuration-register order: byte0 = ProgIF, byte1 = Subclass,
        // byte2 = Class, byte3 = padding.
        guard case let .data(d) = value, d.count >= 3 else { return (nil, nil, nil) }
        return (d[2], d[1], d[0])
    }

    private static func parseLittleEndian16(_ value: IORegValue?) -> UInt16? {
        guard case let .data(d) = value, d.count >= 2 else { return nil }
        return UInt16(d[0]) | (UInt16(d[1]) << 8)
    }
}

// MARK: - Vendor lookup

/// Hand-rolled subset of the PCI Vendor Database. Covers the IDs we expect
/// to see on Macs without pulling in a multi-megabyte lookup table.
nonisolated func pciVendorName(_ vendor: UInt16) -> String? {
    switch vendor {
    case 0x106B: return "Apple"
    case 0x14E4: return "Broadcom"
    case 0x17A0: return "Genesys Logic"
    case 0x144D: return "Samsung"
    case 0x1B4B: return "Marvell"
    case 0x8086: return "Intel"
    case 0x10DE: return "NVIDIA"
    case 0x1002: return "AMD"
    case 0x10EC: return "Realtek"
    case 0x1217: return "O2 Micro"
    case 0x1B73: return "Fresco Logic"
    case 0x1B85: return "Avago / OCZ"
    case 0x1AB8: return "Parallels"
    case 0x1234: return "QEMU"
    case 0x15AD: return "VMware"
    case 0x1AF4: return "Red Hat / Virtio"
    case 0x1C5C: return "SK hynix"
    case 0x1CC1: return "ADATA"
    case 0x2646: return "Kingston"
    case 0x1A03: return "ASPEED"
    default: return nil
    }
}

/// Decode a PCI base-class code to a user-readable label. Subset of the
/// PCI-SIG class-code table — covers what shows up on Apple silicon.
nonisolated func pciClassLabel(_ cls: UInt8, _ sub: UInt8?, _ progIF: UInt8?) -> String {
    switch cls {
    case 0x00: return "Unclassified"
    case 0x01:
        switch sub {
        case 0x06: return "SATA Controller"
        case 0x08: return "NVMe Controller"
        default:   return "Mass Storage"
        }
    case 0x02:
        switch sub {
        case 0x00: return "Ethernet Controller"
        case 0x80: return "Network Controller"
        default:   return "Network"
        }
    case 0x03: return "Display Controller"
    case 0x04: return "Multimedia"
    case 0x05: return "Memory Controller"
    case 0x06:
        switch sub {
        case 0x00: return "Host Bridge"
        case 0x04: return "PCI-to-PCI Bridge"
        default:   return "Bridge"
        }
    case 0x07: return "Communication"
    case 0x08:
        switch sub {
        case 0x05: return "SD Host Controller"
        default:   return "System Peripheral"
        }
    case 0x09: return "Input Device"
    case 0x0A: return "Docking Station"
    case 0x0B: return "Processor"
    case 0x0C:
        switch sub {
        case 0x03: return "USB Controller"
        case 0x05: return "SMBus"
        default:   return "Serial Bus"
        }
    case 0x0D: return "Wireless Controller"
    case 0x0E: return "Intelligent I/O"
    case 0x0F: return "Satellite Communications"
    case 0x10: return "Encryption"
    case 0x11: return "Signal Processing"
    case 0x12: return "Processing Accelerator"
    case 0xFF: return "Vendor-Specific"
    default:   return String(format: "Class 0x%02X", cls)
    }
}
