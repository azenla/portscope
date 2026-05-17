//
//  NodeFormatter.swift
//  Boltprobe
//
//  Centralised classification, label, and property-ordering logic. Both
//  ThunderboltScanner and USBScanner use this to turn raw IORegistry entries
//  into TBNode metadata.
//

import Foundation

enum NodeFormatter {
    /// Map an IORegistry class name to a TBNodeKind. Wrapper kext classes
    /// (DPConnectionManager, IPService, IPPort, DPInAdapter*, etc.) fall to
    /// `.other` so the topology views can hide them and promote descendants.
    static func classify(_ cls: String) -> TBNodeKind {
        if cls == "IOThunderboltLocalNode" { return .localNode }
        if cls.contains("ThunderboltControllerType")
            || (cls.contains("ThunderboltController") && !cls.contains("Apple")) {
            return .controller
        }
        if cls.contains("ThunderboltSwitch") { return .switch }
        if cls == "IOThunderboltPort" { return .port }
        if cls == "IOEthernetInterface" { return .networkIf }
        if cls == "IOPCIBridge" { return .pcieBridge }
        if cls == "IOPCIDevice" { return .pcieDevice }
        if cls == "IOUSBHostInterface" || cls == "IOUSBInterface" { return .usbInterface }
        if cls == "IOUSBHostDevice" || cls == "IOUSBDevice" { return .usbDevice }
        // Port wrappers inside an xHCI controller (e.g. `AppleUSBXHCIAUSSPort`)
        // share the "USBXHCI" infix but are *not* host controllers — they are
        // individual port nodes within a controller. Don't classify them as
        // controllers or they show up as fake "USB Host Controller" rows.
        if cls.hasSuffix("Port") || cls.contains("XHCIPort") || cls.contains("Port@") {
            return .other
        }
        if cls.contains("USBHostController")
            || cls == "AppleUSBXHCI"
            || cls.contains("USBXHCI")
            || cls.contains("AppleEmbeddedUSBHost")
            || cls.contains("USBHostController")
            || cls == "IOUSBController" {
            return .usbController
        }
        if cls.contains("AppleFabricController") || cls.contains("AppleFabricEndpoint") {
            return .appleFabric
        }
        return .other
    }

    /// Re-classify a TBNode after seeing its properties — used to flip
    /// `usbDevice` into `usbHub` when bDeviceClass == 0x09.
    static func refineKind(_ kind: TBNodeKind, props: [String: IORegValue]) -> TBNodeKind {
        if kind == .usbDevice {
            if let cls = props["bDeviceClass"]?.asUInt, cls == USBDeviceClass.hub.rawValue {
                return .usbHub
            }
        }
        return kind
    }

    /// Human title + subtitle for a node.
    static func makeLabels(class cls: String,
                           name: String,
                           location: String?,
                           kind: TBNodeKind,
                           props: [String: IORegValue]) -> (String, String?) {
        switch kind {
        case .controller:
            return (controllerTitle(class: cls, props: props),
                    controllerSubtitle(class: cls, props: props))

        case .switch:
            let depth = props["Depth"]?.asUInt ?? 0
            if depth == 0 {
                return ("Mac Host Router", "Built-in Thunderbolt root")
            }
            let model = props["Device Model Name"]?.asString
            let vendor = props["Device Vendor Name"]?.asString
            let title: String
            if let m = model, let v = vendor {
                title = "\(v) \(m)"
            } else if let m = model {
                title = m
            } else {
                title = "Thunderbolt Router"
            }
            return (title, "Depth \(depth) · external device")

        case .port:
            let n = props["Port Number"]?.asUInt ?? 0
            let desc = props["Description"]?.asString ?? "Port"
            let title = "Port \(n) — \(humanAdapter(desc))"
            let speed = props["Current Link Speed"]?.asUInt ?? 0
            var bits: [String] = []
            if speed > 0 {
                bits.append(tbGenerationShortLabel(speed))
            } else if desc == "Port is inactive" {
                bits.append("Inactive")
            }
            if let w = props["Current Link Width"]?.asUInt, w > 0 { bits.append("×\(w)") }
            return (title, bits.isEmpty ? nil : bits.joined(separator: " · "))

        case .localNode:
            return ("Local Node", "This Mac on the TB fabric")

        case .usbBus:
            return ("USB Host Bus", "Provided over Thunderbolt")

        case .pcieBridge:
            return ("PCIe Bridge", nil)

        case .pcieDevice:
            let model = props["IOName"]?.asString ?? props["model"]?.asString
            return (model ?? "PCIe Device", nil)

        case .usbController:
            let title = controllerFriendlyName(class: cls, name: name, props: props)
            let portCount = props["Number of Ports"]?.asUInt
                ?? props["NumberOfPorts"]?.asUInt
            var sub: [String] = []
            // Prefer the protocol revision string ("3.1", "4.0"), since that
            // matches what most users know. Fall back to the BCD-encoded
            // `kUSBControllerVersion` field if needed.
            if let s = props["UsbHostControllerProtocolRevision"]?.asString {
                sub.append("xHCI \(s)")
            } else if let v = props["kUSBControllerVersion"]?.asUInt {
                sub.append("xHCI \(usbBcdVersion(v))")
            }
            if let c = portCount { sub.append("\(c) ports") }
            return (title, sub.isEmpty ? nil : sub.joined(separator: " · "))

        case .usbHub:
            let product = usbProductName(props) ?? "USB Hub"
            let speed = props["Device Speed"]?.asUInt
                ?? props["kUSBCurrentSpeed"]?.asUInt
            let portCount = props["Number of Ports"]?.asUInt
            var sub: [String] = []
            if let s = speed, s > 0 { sub.append(usbSpeedShortLabel(s)) }
            if let c = portCount { sub.append("\(c) ports") }
            return (product, sub.isEmpty ? nil : sub.joined(separator: " · "))

        case .usbInterface:
            let cls = props["bInterfaceClass"]?.asUInt
            let name = props["kUSBInterfaceString"]?.asString
                ?? props["USB Interface Name"]?.asString
                ?? props["Product Name"]?.asString
            let label = name ?? "Interface \(props["bInterfaceNumber"]?.display ?? "")"
            let cat = cls.map { usbDeviceClassLabel($0) }
            return (label, cat)

        case .usbDevice:
            let product = usbProductName(props)
            let vendor = usbVendorName(props)
            let speed = props["Device Speed"]?.asUInt
                ?? props["kUSBCurrentSpeed"]?.asUInt
            var sub: [String] = []
            if let v = vendor, !v.isEmpty { sub.append(v) }
            if let s = speed, s > 0 { sub.append(usbSpeedShortLabel(s)) }
            return (product ?? "USB Device", sub.isEmpty ? nil : sub.joined(separator: " · "))

        case .networkIf:
            let bsd = props["BSD Name"]?.asString
            let isThunderbolt = cls == "IOEthernetInterface" && (props["IOMediaIcon"] == nil)
            let title = isThunderbolt ? "Thunderbolt Networking" : "Network Interface"
            return (title, bsd.map { "Interface \($0)" })

        case .appleFabric:
            return (name, cls)

        case .domain:
            return ("Thunderbolt Domain", nil)
        case .other:
            return (name, nil)
        }
    }

    /// Translate the kernel's "Description" string into a short human label.
    static func humanAdapter(_ description: String) -> String {
        switch description {
        case "Thunderbolt Port": return "Lane Adapter"
        case "Port is inactive": return "Inactive"
        case "Thunderbolt Native Host Interface Adapter": return "Native Host Interface"
        case "DP or HDMI Adapter": return "Display Adapter"
        case "USB Adapter": return "USB Adapter"
        case "USB Gen T Adapter": return "USB Gen-T Adapter"
        case "PCIe Adapter": return "PCIe Adapter"
        default: return description.isEmpty ? "Port" : description
        }
    }

    /// Pretty-name a USB host controller. We hide implementation class names
    /// (AppleT8142USBXHCI, AppleT6050USBXHCIAUSS, etc.) from the title and
    /// translate them into human terms based on `IONameMatch` tokens and the
    /// USB protocol revision.
    private static func controllerFriendlyName(class cls: String,
                                               name: String,
                                               props: [String: IORegValue]) -> String {
        // `IONameMatch` follows the pattern `usb-<kind>,<silicon>`:
        //   usb-drd,t8142   → dual-role-device USB-C controller on a T-series TB chip
        //   usb-auss,t6050  → "all USB SuperSpeed" controller built into the SoC fabric
        //   usb-host,...    → generic host controller
        let nameMatch = props["IONameMatch"]?.asString
            ?? props["IONameMatched"]?.asString
            ?? ""
        let proto = props["UsbHostControllerProtocolRevision"]?.asString
        let revLabel = proto.map { " \($0)" } ?? ""

        if nameMatch.hasPrefix("usb-drd") {
            // Per-Thunderbolt-port USB-C controller (one per TB receptacle on Apple Silicon).
            return "Thunderbolt USB\(revLabel) Controller"
        }
        if nameMatch.hasPrefix("usb-auss") {
            // SoC-internal USB SuperSpeed root (drives FaceTime cam, internal peripherals,
            // and on desktops the rear / front USB-A jacks).
            return "Internal USB\(revLabel) Controller"
        }
        if nameMatch.hasPrefix("usb-host") {
            return "USB\(revLabel) Host Controller"
        }
        // Fallback heuristics by class name. Hide the chip family token.
        if cls.contains("XHCI") { return "USB\(revLabel) Host Controller" }
        if cls.contains("EHCI") { return "USB 2.0 Host Controller" }
        if cls.contains("OHCI") { return "USB 1.1 Host Controller" }
        return name.isEmpty ? "USB Host Controller" : name
    }

    /// Title for a Thunderbolt host controller. All current Apple Silicon TB
    /// controllers report `IOThunderboltControllerType7`, which is the kernel
    /// class — useless to the user. We say "Thunderbolt Host Controller" and
    /// let the subtitle carry the spec version.
    private static func controllerTitle(class cls: String,
                                        props: [String: IORegValue]) -> String {
        return "Thunderbolt Host Controller"
    }

    /// Subtitle for a Thunderbolt host controller. The `Generation` IORegistry
    /// field is an internal kernel revision number (1, 45, …) and isn't a
    /// human-meaningful spec, so we elide it. Surface the highest TB spec
    /// generation we can observe from the controller's child router instead.
    private static func controllerSubtitle(class cls: String,
                                           props: [String: IORegValue]) -> String? {
        // For now we don't have child props at label-time. Hint at the family
        // ("Apple-designed") and the user client API revision when present,
        // which at least changes meaningfully across chip generations.
        let uc = props["User Client Version"]?.asUInt
        if let uc { return "Apple-designed · API v\(uc)" }
        return "Apple-designed Thunderbolt host"
    }

    static func usbProductName(_ props: [String: IORegValue]) -> String? {
        return props["kUSBProductString"]?.asString
            ?? props["USB Product Name"]?.asString
            ?? props["Product Name"]?.asString
            ?? props["IOClass"]?.asString
    }

    static func usbVendorName(_ props: [String: IORegValue]) -> String? {
        return props["kUSBVendorString"]?.asString
            ?? props["USB Vendor Name"]?.asString
            ?? props["Vendor Name"]?.asString
    }

    static func preferredOrder(for kind: TBNodeKind, keys: [String]) -> [String] {
        let priorities: [String]
        switch kind {
        case .controller:
            priorities = [
                "Generation", "User Client Version", "Thunderbolt Version",
                "TMU Mode", "CLx SW Objection", "JTAG Device Count",
                "Using Bus Power"
            ]
        case .switch:
            priorities = [
                "Device Vendor Name", "Device Model Name",
                "Vendor ID", "Device ID", "UID",
                "Thunderbolt Version", "Depth", "Route String",
                "Upstream Port Number", "Max Port Number",
                "Firmware Version", "EEPROM Revision",
                "Min Required TMU Mode", "Buffer Allocation Request",
                "DROM", "FW Counters"
            ]
        case .port:
            priorities = [
                "Port Number", "Description", "Adapter Type",
                "Thunderbolt Version",
                "Current Link Speed", "Current Link Width",
                "Target Link Speed", "Target Link Width",
                "Supported Link Speed", "Supported Link Width", "Supported Link Modes",
                "Link Bandwidth",
                "Required Bandwidth Allocated", "Maximum Bandwidth Allocated",
                "Lane", "Dual-Link Port", "Dual-Link Port RID",
                "Max In Hop ID", "Max Out Hop ID", "Max Credits",
                "Bus Power", "CLx State",
                "Vendor ID", "Device ID", "Revision ID",
                "Hop Table",
                "Socket ID", "Micro Type", "Micro Version", "Micro Route String", "Micro Address",
                "TRM Policy", "TRM Transport ID", "TRM Hash Set",
                "TRM Transport Active 0", "TRM Transport Active 1",
                "TRM Transport Restricted", "TRM Identification Restricted"
            ]
        case .usbController:
            priorities = [
                "kUSBControllerVersion", "Number of Ports", "NumberOfPorts",
                "PCI Vendor ID", "PCI Device ID",
                "Bus Number", "Built-In", "Companion",
                "model", "IOClass", "IOProviderClass"
            ]
        case .usbHub, .usbDevice:
            priorities = [
                "kUSBProductString", "kUSBVendorString", "kUSBSerialNumberString",
                "USB Product Name", "USB Vendor Name",
                "idVendor", "idProduct", "bcdDevice", "bcdUSB",
                "bDeviceClass", "bDeviceSubClass", "bDeviceProtocol",
                "Device Speed", "kUSBCurrentSpeed", "kUSBHubSpeed",
                "PortNum", "USB Address", "locationID", "sessionID",
                "Bus Current", "Bus Power Available", "Operating Bus Current (mA)",
                "Number of Ports", "Built-In",
                "kUSBContainerID"
            ]
        case .usbInterface:
            priorities = [
                "bInterfaceNumber", "bAlternateSetting",
                "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol",
                "kUSBInterfaceString", "bNumEndpoints"
            ]
        default:
            priorities = []
        }
        var seen = Set<String>()
        var ordered: [String] = []
        for k in priorities where keys.contains(k) && !seen.contains(k) {
            ordered.append(k); seen.insert(k)
        }
        for k in keys.sorted() where !seen.contains(k) {
            ordered.append(k); seen.insert(k)
        }
        return ordered
    }
}
