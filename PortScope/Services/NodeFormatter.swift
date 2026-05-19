//
//  NodeFormatter.swift
//  PortScope
//
//  Centralised classification, label, and property-ordering logic. Both
//  ThunderboltScanner and USBScanner use this to turn raw IORegistry entries
//  into TBNode metadata.
//

import Foundation

nonisolated enum NodeFormatter {
    /// Map an IORegistry class name (plus optional node name) to a TBNodeKind.
    /// Wrapper kext classes (DPConnectionManager, IPService, IPPort, etc.) fall
    /// to `.other` so the topology views can hide them and promote descendants.
    ///
    /// The `name` is consulted for `AppleARMIODevice` instances, where the
    /// class alone doesn't tell us whether the device is an i2c controller, an
    /// SPI controller, GPIO, DART, etc. The `device_type` IORegistry property
    /// would be more authoritative but isn't available at classify time.
    static func classify(_ cls: String, name: String = "") -> TBNodeKind {
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
        if cls == "AppleARMIODevice" {
            if name.hasPrefix("i2c") { return .i2cBus }
            if name.hasPrefix("spi") || name.hasPrefix("qspi") { return .spiBus }
            if socCoprocessorTitle(for: name) != nil { return .socCoprocessor }
            return .other
        }
        if cls == "AppleARMIICDevice" || cls == "AppleARMSPIDevice" { return .busDevice }
        if cls == "AppleSmartBatteryManager" { return .batteryManager }
        if cls == "AppleSmartBattery" { return .battery }
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
            let vendor = usbVendorName(props)
            let speed = props["Device Speed"]?.asUInt
                ?? props["kUSBCurrentSpeed"]?.asUInt
            let portCount = props["Number of Ports"]?.asUInt
            var sub: [String] = []
            if let v = vendor, !v.isEmpty { sub.append(v) }
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

        case .i2cBus:
            return (i2cBusTitle(name: name), i2cBusSubtitle(name: name, props: props))

        case .spiBus:
            return (spiBusTitle(name: name), spiBusSubtitle(name: name, props: props))

        case .busDevice:
            return busDeviceLabels(name: name, props: props)

        case .socCoprocessor:
            return (socCoprocessorTitle(for: name) ?? name,
                    socCoprocessorSubtitle(name: name, props: props))

        case .batteryManager:
            return ("Battery Manager", "AppleSmartBatteryManager")

        case .battery:
            let serial = props["Serial"]?.asString
            let device = props["DeviceName"]?.asString
            var sub: [String] = []
            if let d = device, !d.isEmpty { sub.append(d) }
            if let s = serial, !s.isEmpty { sub.append("S/N \(s)") }
            return ("Internal Battery", sub.isEmpty ? nil : sub.joined(separator: " · "))

        case .domain:
            return ("Thunderbolt Domain", nil)
        case .other:
            return (name, nil)
        }
    }

    // MARK: - Internal bus labels

    private static func i2cBusTitle(name: String) -> String {
        // "i2c1" → "I²C Bus 1"
        if let n = name.dropFirst(3).first, n.isNumber {
            return "I²C Bus \(String(name.dropFirst(3)))"
        }
        return name.uppercased()
    }

    private static func i2cBusSubtitle(name: String, props: [String: IORegValue]) -> String? {
        // Pull the address from the entry name suffix `@91014000` when present.
        return mmioAddress(props: props).map { "MMIO 0x\($0)" }
    }

    private static func spiBusTitle(name: String) -> String {
        // "spi2" → "SPI Bus 2", "qspi" → "Quad SPI"
        if name == "qspi" { return "Quad SPI" }
        if name.hasPrefix("spi"), let n = name.dropFirst(3).first, n.isNumber {
            return "SPI Bus \(String(name.dropFirst(3)))"
        }
        return name.uppercased()
    }

    private static func spiBusSubtitle(name: String, props: [String: IORegValue]) -> String? {
        return mmioAddress(props: props).map { "MMIO 0x\($0)" }
    }

    private static func mmioAddress(props: [String: IORegValue]) -> String? {
        guard case let .array(arr) = props["IODeviceMemory"], let first = arr.first else { return nil }
        // IODeviceMemory[0] is an array containing a single dict: {address, length}.
        if case let .array(inner) = first, let dict = inner.first, case let .dictionary(kv) = dict {
            for (k, v) in kv where k == "address" {
                if let addr = v.asUInt { return String(format: "%X", addr) }
            }
        }
        if case let .dictionary(kv) = first {
            for (k, v) in kv where k == "address" {
                if let addr = v.asUInt { return String(format: "%X", addr) }
            }
        }
        return nil
    }

    /// Best-effort human label for a single i2c/SPI slave. The entry name is
    /// usually `<function>@<address>` (e.g. `audio-speaker@38`, `atcrt0@18`).
    /// We split on `@` and translate the function prefix into something readable.
    private static func busDeviceLabels(name: String, props: [String: IORegValue]) -> (String, String?) {
        let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
        let function = parts.first ?? name
        let address = parts.count > 1 ? parts[1] : nil

        let title = busDeviceFriendlyName(function)
        var sub: [String] = []
        if let a = address { sub.append("0x\(a.uppercased())") }
        if title != function { sub.append(function) }
        return (title, sub.isEmpty ? nil : sub.joined(separator: " · "))
    }

    // MARK: - SoC coprocessor identification

    /// Pretty name for the named blocks Apple exposes as `AppleARMIODevice`
    /// children of the SoC fabric. Returns nil for anything we don't have a
    /// friendly label for; callers use the nil return as the "not a
    /// coprocessor" signal so DARTs / GPIO blocks / DMA controllers / dispXX
    /// stay in the bulk-of-the-tree noise bin instead of cluttering the
    /// Internal Hardware section.
    ///
    /// The names listed here have been stable across every Apple Silicon
    /// generation observed in the wild (M1 → M5). When a device-tree entry
    /// has an index suffix (e.g. `dcpext3`, `ane0`, `jpeg1`) the prefix
    /// match strips it so all instances surface with the same label.
    static func socCoprocessorTitle(for name: String) -> String? {
        if let exact = exactCoprocessor[name] { return exact }
        for (prefix, label) in coprocessorPrefixes where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            if suffix.isEmpty || suffix.allSatisfy(\.isNumber) {
                if suffix.isEmpty { return label }
                return "\(label) \(suffix)"
            }
        }
        return nil
    }

    private static let exactCoprocessor: [String: String] = [
        "sep": "Secure Enclave Processor",
        "aop": "Always-On Processor",
        "pmp": "Power Management Processor",
        "smc": "System Management Controller",
        "ans": "NAND Storage Controller",
        "wlan": "Wi-Fi Subsystem",
        "bluetooth": "Bluetooth Subsystem",
        "dcp": "Display Coprocessor",
        "gfx-asc": "GPU Coprocessor",
        "isp0": "Image Signal Processor",
        "ane0": "Apple Neural Engine",
        "avd0": "Video Decoder",
        "mcc": "Memory Cache Controller",
        "sgx": "Graphics (SGX)",
        "pmgr": "Power Manager",
        "aic": "Interrupt Controller"
    ]

    /// Name-prefix table. The numeric tail (when present) becomes part of the
    /// label — e.g. `dcpext0` → "Display Coprocessor 0".
    private static let coprocessorPrefixes: [(String, String)] = [
        ("dcpext", "Display Coprocessor"),
        ("ave",    "Video Encoder"),
        ("jpeg",   "JPEG Codec"),
        ("scaler", "Image Scaler"),
        ("dispext","Display Engine"),
        ("disp",   "Display Engine"),
        ("ane",    "Apple Neural Engine"),
        ("isp",    "Image Signal Processor"),
        ("avd",    "Video Decoder")
    ]

    private static func socCoprocessorSubtitle(name: String,
                                               props: [String: IORegValue]) -> String? {
        // The device-tree name is the canonical identifier the Apple
        // platform team uses for the block; surface it verbatim so a curious
        // user can grep the public Asahi / device-tree docs for the same
        // token. Append the MMIO base address when we can dig it out, so
        // the row tells the user where the block lives physically.
        var bits: [String] = [name]
        if let mmio = mmioAddress(props: props) {
            bits.append("MMIO 0x\(mmio)")
        }
        return bits.joined(separator: " · ")
    }

    private static func busDeviceFriendlyName(_ function: String) -> String {
        // Pretty names for the function strings Apple uses in the device tree.
        // Keep the original token as a fallback so unknown slaves still render.
        switch function {
        case "audio-speaker": return "Audio Speaker"
        case "audio-speaker-left-woofer-1": return "Audio · Left Woofer 1"
        case "audio-speaker-left-woofer-2": return "Audio · Left Woofer 2"
        case "audio-speaker-left-tweeter": return "Audio · Left Tweeter"
        case "audio-speaker-right-woofer-1": return "Audio · Right Woofer 1"
        case "audio-speaker-right-woofer-2": return "Audio · Right Woofer 2"
        case "audio-speaker-right-tweeter": return "Audio · Right Tweeter"
        case "audio-codec-output": return "Audio Codec (headphone)"
        case "audio-codec-input": return "Audio Codec (mic)"
        case "atcrt0": return "USB-C Retimer 0"
        case "atcrt1": return "USB-C Retimer 1"
        case "atcrt2": return "USB-C Retimer 2"
        case "pcon0": return "Power Controller 0"
        case "pcon1": return "Power Controller 1"
        case "sd-card": return "SD Card Controller"
        case "mesa": return "Touch ID Sensor"
        case "dp855", "dp825": return "Display Panel TCON"
        case "tcon": return "Display Panel TCON"
        case "als": return "Ambient Light Sensor"
        case "accel": return "Accelerometer"
        case "magsafe": return "MagSafe Controller"
        case "smc": return "System Management Controller"
        default: return function
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
    /// human-meaningful spec, so we elide it. The class name carries the
    /// internal "Type" suffix that Apple uses to differentiate chip families
    /// (`IOThunderboltControllerType5` = M1/M2 family / T6000-class TB4
    /// hosts; `IOThunderboltControllerType7` = M3+/TB5 hosts; future
    /// silicon will likely bump it again). Surface it as a short hint
    /// alongside the user-client API revision so two different chassis
    /// distinguish themselves in the sidebar.
    private static func controllerSubtitle(class cls: String,
                                           props: [String: IORegValue]) -> String? {
        var parts: [String] = []
        if let typeLabel = thunderboltControllerTypeLabel(class: cls) {
            parts.append(typeLabel)
        } else {
            parts.append("Apple-designed")
        }
        if let uc = props["User Client Version"]?.asUInt {
            parts.append("API v\(uc)")
        }
        return parts.joined(separator: " · ")
    }

    /// Map the `IOThunderboltControllerType<N>` suffix to a short hint.
    /// We don't claim a spec generation (the mapping isn't 1:1) — we just
    /// surface the family number so M1 / M3 / M5 controllers don't all
    /// read identically in the sidebar.
    private static func thunderboltControllerTypeLabel(class cls: String) -> String? {
        let prefix = "IOThunderboltControllerType"
        guard cls.hasPrefix(prefix) else { return nil }
        let suffix = cls.dropFirst(prefix.count)
        if suffix.isEmpty { return nil }
        return "Apple TB Controller (Type \(suffix))"
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
        case .socCoprocessor:
            priorities = [
                "name", "device_type", "compatible",
                "IONameMatch", "IONameMatched", "IOClass", "IOProviderClass",
                "AAPL,phandle", "reg", "IODeviceMemory",
                "interrupts", "interrupt-parent", "interrupt-controller",
                "clock-gates", "power-gates", "iommu-parent",
                "function-parent", "phandle"
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
