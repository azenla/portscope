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
            let gen = props["Generation"]?.asUInt.map { "Apple Silicon gen \($0)" }
            return ("Thunderbolt Host Controller", gen)

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
            if let v = props["kUSBControllerVersion"]?.asUInt {
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
    /// (AppleT8112USBXHCI etc.) from the title and surface them in the subtitle.
    private static func controllerFriendlyName(class cls: String,
                                               name: String,
                                               props: [String: IORegValue]) -> String {
        if let model = props["model"]?.asString { return model }
        if let provider = props["IOClass"]?.asString { return provider }
        if cls.contains("XHCI") { return "USB xHCI Host Controller" }
        if cls.contains("EHCI") { return "USB eHCI Host Controller" }
        if cls.contains("OHCI") { return "USB oHCI Host Controller" }
        return name.isEmpty ? "USB Host Controller" : name
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
