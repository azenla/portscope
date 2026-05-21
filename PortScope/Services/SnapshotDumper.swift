//
//  SnapshotDumper.swift
//  PortScope
//
//  CLI-side rendering of a `SystemSnapshot`. The host binary exposes two
//  modes — `--pretty` (modern colourful tree with emoji) and `--json`
//  (machine-readable dump). Both walk the same scanner output the GUI
//  consumes, so a dump from CLI matches exactly what the app would show
//  in the sidebar.
//
//  No types in the rest of the app are forced into `Codable` for this —
//  the JSON path emits plain `JSONSerialization`-compatible primitives
//  (Dictionary / Array / String / Number / Bool / NSNull). Adding
//  `Encodable` conformance to `IORegValue` and friends would either drag
//  in tuple-conformance ceremony or be lossy, and we want neither.
//

import Foundation
import Darwin

@MainActor
enum SnapshotDumper {
    // MARK: - JSON

    /// Render a `SystemSnapshot` as a JSON string (UTF-8, pretty-printed,
    /// stable key ordering). Suitable to feed into `jq`, diff against a
    /// previous snapshot, or check assumptions against without touching
    /// `ioreg`. Sorted keys mean the same physical state produces a
    /// byte-identical dump across runs.
    ///
    /// Defaults mirror the GUI sidebar: bare invocation emits only
    /// `physical_ports` (plus `accessories` for the underlying HPM data
    /// and `host` / `captured_at` metadata). `showBuses` adds the raw
    /// `thunderbolt` / `usb` / `pcie` trees; `showAll` adds `bluetooth`
    /// / `displays` / `internal_hardware`. Omitted keys are absent (not
    /// set to null) so consumers don't accidentally inherit stale schema
    /// fields.
    static func json(_ snapshot: SystemSnapshot, showBuses: Bool, showAll: Bool) -> String {
        let root: [String: Any] = snapshotToJSONObject(snapshot, showBuses: showBuses, showAll: showAll)
        let data = (try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func snapshotToJSONObject(_ s: SystemSnapshot, showBuses: Bool, showAll: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "captured_at": ISO8601DateFormatter().string(from: s.capturedAt),
            "host": hostInfoJSON(),
            "physical_ports": TopologyMapper.physicalPorts(from: s).map(physicalPortToJSON(_:)),
            "accessories": s.accessories.map(accessoryToJSON(_:))
        ]
        if showBuses {
            out["thunderbolt"] = [
                "controllers": s.tb.controllers.map(nodeToJSON(_:)),
                "pcie_devices_over_tb": s.tb.pcieDevicesOverTB.map(nodeToJSON(_:)),
                "usb_devices_over_tb": s.tb.usbDevicesOverTB.map(nodeToJSON(_:))
            ]
            out["usb"] = [
                "controllers": s.usb.controllers.map(nodeToJSON(_:)),
                "tb_context": Dictionary(
                    uniqueKeysWithValues: s.usb.tbContext.map { kv -> (String, String) in
                        (String(format: "0x%llX", kv.key.raw),
                         String(format: "0x%llX", kv.value.raw))
                    }
                )
            ]
            out["pcie"] = s.pcie.roots.map(pciNodeToJSON(_:))
        }
        if showAll {
            out["bluetooth"] = bluetoothJSON(s.bluetooth)
            out["displays"] = s.displays.displays.map(displayToJSON(_:))
            out["internal_hardware"] = [
                "battery": s.internalHardware.batteryManager.map(nodeToJSON(_:)) ?? NSNull(),
                "magsafe": s.internalHardware.magsafe.map(accessoryToJSON(_:)) ?? NSNull(),
                "i2c_buses": s.internalHardware.i2cBuses.map(nodeToJSON(_:)),
                "spi_buses": s.internalHardware.spiBuses.map(nodeToJSON(_:)),
                "soc_coprocessor_groups": s.internalHardware.coprocessorGroups.map { g in
                    [
                        "category": g.category.rawValue,
                        "title": g.category.title,
                        "coprocessors": g.coprocessors.map(nodeToJSON(_:))
                    ] as [String: Any]
                },
                "soc_coprocessors": s.internalHardware.socCoprocessors.map(nodeToJSON(_:))
            ]
        }
        return out
    }

    private static func bluetoothJSON(_ bt: BluetoothSnapshot) -> [String: Any] {
        let controller: Any = bt.controller.map { c -> [String: Any] in
            [
                "address": c.address ?? NSNull(),
                "chipset": c.chipset ?? NSNull(),
                "firmware_version": c.firmwareVersion ?? NSNull(),
                "vendor_id": c.vendorID ?? NSNull(),
                "product_id": c.productID ?? NSNull(),
                "transport": c.transport ?? NSNull(),
                "is_on": c.isOn,
                "is_discoverable": c.isDiscoverable,
                "supported_services": c.supportedServices
            ]
        } ?? NSNull()
        return [
            "controller": controller,
            "connected": bt.connected.map(btDeviceJSON(_:)),
            "paired": bt.paired.map(btDeviceJSON(_:))
        ]
    }

    private static func btDeviceJSON(_ d: BluetoothDevice) -> [String: Any] {
        return [
            "name": d.name,
            "address": d.address ?? NSNull(),
            "vendor_id": d.vendorID ?? NSNull(),
            "product_id": d.productID ?? NSNull(),
            "firmware_version": d.firmwareVersion ?? NSNull(),
            "minor_type": d.minorType ?? NSNull(),
            "rssi": d.rssi ?? NSNull(),
            "serial_number": d.serialNumber ?? NSNull(),
            "is_connected": d.isConnected,
            "category": d.category.rawValue,
            "services": d.services,
            "battery_level": d.batteryLevel ?? NSNull(),
            "battery_level_left": d.batteryLevelLeft ?? NSNull(),
            "battery_level_right": d.batteryLevelRight ?? NSNull(),
            "battery_level_case": d.batteryLevelCase ?? NSNull()
        ]
    }

    private static func displayToJSON(_ d: DisplayInfo) -> [String: Any] {
        return [
            "id": String(format: "0x%llX", d.backingID.raw),
            "device_tree_name": d.deviceTreeName,
            "title": d.title,
            "subtitle": d.subtitle ?? NSNull(),
            "is_built_in": d.isBuiltIn,
            "is_connected": d.isConnected,
            "width_pixels": d.widthPixels.map { NSNumber(value: $0) } ?? NSNull(),
            "height_pixels": d.heightPixels.map { NSNumber(value: $0) } ?? NSNull(),
            "min_refresh_hz": d.minRefreshHz.map { NSNumber(value: $0) } ?? NSNull(),
            "max_refresh_hz": d.maxRefreshHz.map { NSNumber(value: $0) } ?? NSNull(),
            "color_bit_depth": d.colorBitDepth.map { NSNumber(value: $0) } ?? NSNull(),
            "color_accuracy_index": d.colorAccuracyIndex.map { NSNumber(value: $0) } ?? NSNull(),
            "supports_hdr": d.supportsHDR,
            "timing_mode_count": d.timingModeCount,
            "node": nodeToJSON(d.node)
        ]
    }

    private static func pciNodeToJSON(_ n: PCINode) -> [String: Any] {
        return [
            "id": String(format: "0x%llX", n.backingID.raw),
            "kind": n.kind.rawValue,
            "title": n.title,
            "subtitle": n.subtitle ?? NSNull(),
            "vendor_id": n.vendorID.map { NSNumber(value: $0) } ?? NSNull(),
            "device_id": n.deviceID.map { NSNumber(value: $0) } ?? NSNull(),
            "vendor_name": n.vendorID.flatMap(pciVendorName) ?? NSNull(),
            "class_code": n.classCode.map { NSNumber(value: $0) } ?? NSNull(),
            "subclass_code": n.subclassCode.map { NSNumber(value: $0) } ?? NSNull(),
            "prog_if": n.progIF.map { NSNumber(value: $0) } ?? NSNull(),
            "class_label": n.classCode.map { pciClassLabel($0, n.subclassCode, n.progIF) } ?? NSNull(),
            "link_speed": n.linkSpeed.map { NSNumber(value: $0) } ?? NSNull(),
            "link_width": n.linkWidth.map { NSNumber(value: $0) } ?? NSNull(),
            "max_link_speed": n.maxLinkSpeed.map { NSNumber(value: $0) } ?? NSNull(),
            "max_link_width": n.maxLinkWidth.map { NSNumber(value: $0) } ?? NSNull(),
            "bdf": n.bdf ?? NSNull(),
            "slot_name": n.slotName ?? NSNull(),
            "is_built_in": n.isBuiltIn,
            "children": n.children.map(pciNodeToJSON(_:))
        ]
    }

    private static func physicalPortToJSON(_ p: PhysicalPort) -> [String: Any] {
        let descriptor = MacPortCatalog.current.descriptor(for: p.connector, portNumber: p.number)
        var out: [String: Any] = [
            "number": p.number,
            "id": String(format: "0x%llX", p.id.raw),
            "connector": "\(p.connector)",
            "connector_label": p.connector.label,
            "title": p.cliTitle,
            "location": descriptor?.location as Any? ?? NSNull(),
            "capability": descriptor?.capability as Any? ?? NSNull(),
            "location_label": p.locationLabel as Any? ?? NSNull(),
            "status_label": p.statusLabel,
            "mode": modeToJSON(p.mode),
            "lane_adapter_id": String(format: "0x%llX", p.laneAdapter.id.raw),
            "controller_id": String(format: "0x%llX", p.controller.id.raw),
            "attached_usb_device_count": p.attachedUSBDevices.count,
            "usb_device_roots": p.usbDeviceRoots.map(nodeToJSON(_:)),
            "tunnels": p.tunnels.map { t -> [String: Any] in
                [
                    "kind": "\(t.kind)",
                    "label": t.label,
                    "reserved_bandwidth_100mbps": t.reservedBandwidth,
                    "max_bandwidth_100mbps": t.maxBandwidth,
                    "adapter_count": t.adapterCount
                ]
            }
        ]
        if let device = p.connectedDevice {
            out["connected_device"] = connectedDeviceToJSON(device)
        } else {
            out["connected_device"] = NSNull()
        }
        if let acc = p.accessory { out["accessory"] = accessoryToJSON(acc) }
        // power_input mirrors power_output for symmetry: a flat summary of
        // the negotiated USB-PD contract when the Mac is sinking power on
        // this port. Detailed PDO offers stay under accessory.usb_pd.
        if let win = p.accessory?.usbPD?.winning {
            out["power_input"] = [
                "voltage_mv": win.voltageMV,
                "current_ma": win.maxCurrentMA,
                "power_mw": win.maxPowerMW,
                "power_w": Double(win.maxPowerMW) / 1000.0
            ]
        } else {
            out["power_input"] = NSNull()
        }
        if let sp = p.sourcePower, sp.isInteresting {
            out["power_output"] = sourcePowerToJSON(sp)
        } else {
            out["power_output"] = NSNull()
        }
        return out
    }

    private static func sourcePowerToJSON(_ sp: PortSourcePower) -> [String: Any] {
        var out: [String: Any] = [
            "wake_current_limit_ma": sp.wakeLimitMA.map { NSNumber(value: $0) } ?? NSNull(),
            "sleep_current_limit_ma": sp.sleepLimitMA.map { NSNumber(value: $0) } ?? NSNull(),
            "total_allocated_ma": sp.totalAllocatedMA,
            "estimated_power_w_at_5v": Double(sp.totalAllocatedMA) / 1000.0 * 5.0,
            "sinks": sp.sinks.map { s -> [String: Any] in
                [
                    "id": String(format: "0x%llX", s.id.raw),
                    "name": s.name,
                    "allocated_ma": s.allocatedMA,
                    "capability_ma": s.capabilityMA.map { NSNumber(value: $0) } ?? NSNull(),
                    "config_current_ma": s.configCurrentMA.map { NSNumber(value: $0) } ?? NSNull(),
                    "estimated_power_w_at_5v": Double(s.allocatedMA) / 1000.0 * 5.0
                ]
            }
        ]
        if let pdOut = sp.outputProfile {
            let winning: Any = pdOut.winning.map(usbPDOptionToJSON(_:)) ?? NSNull()
            out["output_profile"] = [
                "winning": winning,
                "offered": pdOut.offered.map(usbPDOptionToJSON(_:))
            ]
        }
        return out
    }

    private static func connectedDeviceToJSON(_ d: ConnectedDevice) -> [String: Any] {
        return [
            "id": String(format: "0x%llX", d.id.raw),
            "title": d.title,
            "subtitle": d.subtitle ?? NSNull(),
            "router_node": nodeToJSON(d.routerNode),
            "daisy_chained": d.daisyChained.map(connectedDeviceToJSON(_:))
        ]
    }

    private static func modeToJSON(_ mode: PhysicalPortMode) -> [String: Any] {
        switch mode {
        case .empty: return ["kind": "empty"]
        case .thunderbolt(let s): return ["kind": "thunderbolt", "link_speed": s]
        case .usbOnly(let s): return ["kind": "usb_only", "speed": s as Any? ?? NSNull()]
        case .displayOnly: return ["kind": "display_only"]
        case .charging(let w): return ["kind": "charging", "watts": w as Any? ?? NSNull()]
        case .unknown: return ["kind": "unknown"]
        }
    }

    private static func nodeToJSON(_ node: TBNode) -> [String: Any] {
        return [
            "id": String(format: "0x%llX", node.id.raw),
            "kind": "\(node.kind)",
            "title": node.title,
            "subtitle": node.subtitle ?? NSNull(),
            "class": node.className,
            "registry_path": node.registryPath ?? NSNull(),
            "properties": propertiesToJSON(node.properties),
            "children": node.children.map(nodeToJSON(_:))
        ]
    }

    /// Walk a property dict and convert each `IORegValue` to a JSON-safe
    /// value. We keep raw types (number stays a number, bool stays a bool,
    /// `Data` becomes a hex string with a `0x` prefix), so downstream
    /// tooling can diff numerics directly instead of fighting display
    /// strings.
    private static func propertiesToJSON(_ props: [String: IORegValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in props {
            out[k] = ioregValueToJSON(v)
        }
        return out
    }

    private static func ioregValueToJSON(_ value: IORegValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return NSNumber(value: n)
        case .unsigned(let u): return NSNumber(value: u)
        case .bool(let b): return b
        case .data(let d):
            return "0x" + d.map { String(format: "%02x", $0) }.joined()
        case .array(let arr):
            return arr.map(ioregValueToJSON(_:))
        case .dictionary(let kv):
            var out: [String: Any] = [:]
            for (k, v) in kv { out[k] = ioregValueToJSON(v) }
            return out
        }
    }

    private static func accessoryToJSON(_ a: PortAccessoryInfo) -> [String: Any] {
        var out: [String: Any] = [
            "id": String(format: "0x%llX", a.id.raw),
            "port_number": a.portNumber,
            "connector": "\(a.connector)",
            "connector_label": a.connector.label,
            "connection": "\(a.connection)",
            "connection_label": a.connection.label,
            "connection_active": a.connectionActive,
            "detected": a.detected,
            "plug_orientation": "\(a.plugOrientation)",
            "supported_transports": a.supportedTransports.map { "\($0)" }.sorted(),
            "provisioned_transports": a.provisionedTransports.map { "\($0)" }.sorted(),
            "active_transports": a.activeTransports.map { "\($0)" }.sorted(),
            "hpd_asserted": a.hpdAsserted,
            "displayport_pin_assignment": a.displayPortPinAssignment,
            "active_cable": a.activeCable,
            "optical_cable": a.opticalCable,
            "connection_count": a.connectionCount,
            "plug_event_count": a.plugEventCount,
            "overcurrent_count": a.overcurrentCount,
            "cable_vendor_id": a.cableVendorID.map { NSNumber(value: $0) } ?? NSNull(),
            "cable_product_id": a.cableProductID.map { NSNumber(value: $0) } ?? NSNull(),
            "cable_manufacturer": a.cableManufacturer ?? NSNull(),
            "raw_properties": propertiesToJSON(a.registryProperties)
        ]
        if let pd = a.usbPD {
            let winning: Any = pd.winning.map(usbPDOptionToJSON(_:)) ?? NSNull()
            let brickID: Any = pd.brickID.map(usbPDOptionToJSON(_:)) ?? NSNull()
            out["usb_pd"] = [
                "winning": winning,
                "brick_id": brickID,
                "offered": pd.offered.map(usbPDOptionToJSON(_:))
            ]
        } else {
            out["usb_pd"] = NSNull()
        }
        return out
    }

    private static func usbPDOptionToJSON(_ o: USBPDOption) -> [String: Any] {
        return [
            "voltage_mv": o.voltageMV,
            "max_current_ma": o.maxCurrentMA,
            "max_power_mw": o.maxPowerMW
        ]
    }

    private static func hostInfoJSON() -> [String: Any] {
        var info = utsname()
        uname(&info)
        let release = withUnsafePointer(to: &info.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let lookup = MacPortCatalog.current
        return [
            "kernel_release": release,
            "kernel_machine": machine,
            "hw_model": lookup.modelID,
            "marketing_name": lookup.entry?.marketingName as Any? ?? NSNull(),
            "chassis": lookup.entry?.chassis as Any? ?? NSNull()
        ]
    }

    // MARK: - Pretty CLI (ANSI + emoji)

    /// Render a `SystemSnapshot` as a colourful tree. When stdout is a TTY
    /// the output uses ANSI colour escapes; otherwise the escapes are
    /// stripped so piping into a file produces clean text. Section gating
    /// matches the GUI sidebar: bare invocation emits only the Physical
    /// Ports section, `showBuses` adds Thunderbolt / USB / PCIe trees, and
    /// `showAll` adds Bluetooth / Displays / Internal Hardware.
    static func pretty(_ snapshot: SystemSnapshot, useColor: Bool, showBuses: Bool, showAll: Bool) -> String {
        let p = PrettyPrinter(useColor: useColor)
        p.header(snapshot)
        p.physicalPorts(TopologyMapper.physicalPorts(from: snapshot))
        if showBuses {
            p.thunderbolt(snapshot.tb)
            p.usb(snapshot.usb)
            p.pcie(snapshot.pcie)
        }
        if showAll {
            p.displays(snapshot.displays)
            p.bluetooth(snapshot.bluetooth)
            p.internalHardware(snapshot.internalHardware)
        }
        return p.flush()
    }

    // MARK: - Simple (shell-script friendly)

    /// Tab-separated port summary, one record per chassis receptacle. Columns
    /// are stable, fields never contain tabs, and `-` denotes absent. Lines
    /// prefixed with `#` are comments (header + schema version) that scripts
    /// can skip with `grep -v '^#'`. Modifiers (`--buses`, `--all`) are
    /// ignored on purpose — `--simple` is a one-thing-only summary.
    static func simple(_ snapshot: SystemSnapshot) -> String {
        let ports = TopologyMapper.physicalPorts(from: snapshot)
        var out = "# PortScope --simple v1\n"
        out += "# connector\tport\tmode\tdetail\tdevice\tpower_in_w\tpower_out_w\n"
        for p in ports {
            let cols: [String] = [
                simpleConnector(p.connector),
                String(p.number),
                simpleMode(p.mode),
                simpleDetail(p),
                simpleDevice(p),
                simplePowerIn(p),
                simplePowerOut(p)
            ]
            out += cols.map(simpleSanitise).joined(separator: "\t") + "\n"
        }
        return out
    }

    private static func simpleConnector(_ c: PortConnectorType) -> String {
        switch c {
        case .usbC: return "usb-c"
        case .usbA: return "usb-a"
        case .magsafe: return "magsafe"
        case .hdmi: return "hdmi"
        case .sdCard: return "sd-card"
        case .acPower: return "power"
        case .ethernet: return "ethernet"
        case .other(let s): return s.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }

    private static func simpleMode(_ m: PhysicalPortMode) -> String {
        switch m {
        case .empty: return "empty"
        case .thunderbolt: return "thunderbolt"
        case .usbOnly: return "usb"
        case .displayOnly: return "display"
        case .charging: return "charging"
        case .unknown: return "unknown"
        }
    }

    private static func simpleDetail(_ p: PhysicalPort) -> String {
        switch p.mode {
        case .empty: return "-"
        case .thunderbolt(let speed):
            return speed > 0 ? tbGenerationShortLabel(speed) : "thunderbolt"
        case .usbOnly(let speed):
            if let s = speed, s > 0 { return usbSpeedShortLabel(s) }
            return "usb"
        case .displayOnly: return "display"
        case .charging(let w):
            if let w, w > 0 { return "\(w)W" }
            return "charging"
        case .unknown: return "-"
        }
    }

    private static func simpleDevice(_ p: PhysicalPort) -> String {
        if let d = p.connectedDevice { return d.title }
        if let root = p.usbDeviceRoots.first { return root.title }
        return "-"
    }

    private static func simplePowerIn(_ p: PhysicalPort) -> String {
        // Mac as the sink — a charger is supplying us. Read the winning PD
        // contract published under IOPortFeaturePowerIn.
        guard let win = p.accessory?.usbPD?.winning, win.maxPowerMW > 0 else { return "-" }
        return String(format: "%.1f", Double(win.maxPowerMW) / 1000.0)
    }

    private static func simplePowerOut(_ p: PhysicalPort) -> String {
        // Mac as the source — what we're delivering across all attached USB
        // sinks on this port, computed at 5 V from allocated current. Matches
        // the "PD out" line in --pretty.
        guard let sp = p.sourcePower, sp.totalAllocatedMA > 0 else { return "-" }
        let watts = Double(sp.totalAllocatedMA) / 1000.0 * 5.0
        return String(format: "%.1f", watts)
    }

    /// Strip any tab / newline so columns can't be broken by user-controlled
    /// strings (USB device names live in this output).
    private static func simpleSanitise(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - Pretty printer

private final class PrettyPrinter {
    private var buffer = ""
    private let useColor: Bool

    init(useColor: Bool) { self.useColor = useColor }

    func flush() -> String { buffer }

    // ANSI helpers
    private func code(_ c: String) -> String { useColor ? "\u{001B}[\(c)m" : "" }
    private var reset: String { code("0") }
    private func wrap(_ s: String, _ c: String) -> String { code(c) + s + reset }
    private func bold(_ s: String) -> String { wrap(s, "1") }
    private func dim(_ s: String) -> String { wrap(s, "2") }
    private func red(_ s: String) -> String { wrap(s, "31") }
    private func green(_ s: String) -> String { wrap(s, "32") }
    private func yellow(_ s: String) -> String { wrap(s, "33") }
    private func blue(_ s: String) -> String { wrap(s, "34") }
    private func magenta(_ s: String) -> String { wrap(s, "35") }
    private func cyan(_ s: String) -> String { wrap(s, "36") }

    private func line(_ s: String = "") { buffer += s + "\n" }

    // MARK: Header

    func header(_ snap: SystemSnapshot) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let ts = df.string(from: snap.capturedAt)
        line(bold("🖥  PortScope · System Snapshot") + dim(" · \(ts)"))
        line(dim("   \(hostLabel())"))
        line()
    }

    private func hostLabel() -> String {
        var info = utsname()
        uname(&info)
        let release = withUnsafePointer(to: &info.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return "Darwin \(release) (\(machine))"
    }

    // MARK: Physical Ports

    func physicalPorts(_ ports: [PhysicalPort]) {
        section("⚡️ Physical Ports", ports.isEmpty ? "—" : pluralize(ports.count, "receptacle"))
        if ports.isEmpty {
            line(dim("   none"))
            line()
            return
        }
        for port in ports {
            let badge = portBadge(port.mode)
            let title = port.cliTitle
            line("   \(badge) \(bold(title))  \(dim(port.statusLabel))")
            if let loc = port.catalogLocation {
                line("      \(dim("Location:")) \(loc)")
            }
            if let cap = port.catalogCapability {
                line("      \(dim("Spec:")) \(cap)")
            }
            if let acc = port.accessory {
                let active = Array(acc.activeTransports).map { "\($0.label)" }.sorted().joined(separator: ", ")
                if !active.isEmpty {
                    line("      \(dim("Transports:")) \(active)")
                }
                if acc.plugOrientation != .unattached {
                    line("      \(dim("Orientation:")) \(acc.plugOrientation.label)")
                }
                // AC Power's own status line already carries the wattage,
                // so don't double up here. USB-C / MagSafe still get this
                // line as the canonical Power Input readout.
                if port.connector != .acPower, let pd = acc.usbPD, let win = pd.winning {
                    line("      \(dim("Power Input:")) \(bold(win.powerLabel)) (\(win.voltageLabel) · \(win.currentLabel))")
                }
                if let cable = acc.cableLabel {
                    line("      \(dim("Cable:")) \(cable)")
                }
                if acc.hpdAsserted {
                    line("      \(dim("DP HPD:")) asserted (pin \(displayPortPinAssignmentLabel(acc.displayPortPinAssignment)))")
                }
            }
            if let sp = port.sourcePower, sp.isInteresting {
                if sp.totalAllocatedMA > 0 {
                    let totalW = Double(sp.totalAllocatedMA) / 1000.0 * 5.0
                    let watt = String(format: "%.1f W", totalW)
                    let amps = String(format: "%.2f A", Double(sp.totalAllocatedMA) / 1000.0)
                    line("      \(dim("Power Output:")) \(bold(watt)) (5 V · \(amps))")
                }
                if let w = sp.wakeLimitMA {
                    let a = String(format: "%.1f A", Double(w) / 1000.0)
                    line("      \(dim("Output Limit:")) \(a) awake\(sp.sleepLimitMA.map { " · " + String(format: "%.1f A", Double($0) / 1000.0) + " asleep" } ?? "")")
                }
            }
            if let device = port.connectedDevice {
                line("      \(green("⚡")) \(device.title)\(device.subtitle.map { dim(" · \($0)") } ?? "")")
                for chained in device.daisyChained {
                    line("         ↳ \(chained.title)\(chained.subtitle.map { dim(" · \($0)") } ?? "")")
                }
            }
            for root in port.usbDeviceRoots {
                line("      \(cyan("🔌")) \(root.title)\(root.subtitle.map { dim(" · \($0)") } ?? "")")
                indentedNode(root, prefix: "         ", showUSBOnly: true)
            }
        }
        line()
    }

    private func portBadge(_ mode: PhysicalPortMode) -> String {
        switch mode {
        case .empty: return dim("○")
        case .thunderbolt: return blue("⚡")
        case .usbOnly: return cyan("🔌")
        case .displayOnly: return magenta("🖥")
        case .charging: return green("🔋")
        case .unknown: return yellow("?")
        }
    }

    // MARK: Thunderbolt

    func thunderbolt(_ snap: TBSnapshot) {
        section("🌩  Thunderbolt", pluralize(snap.controllers.count, "controller"))
        if snap.controllers.isEmpty {
            line(dim("   none"))
            line()
            return
        }
        for (idx, ctrl) in snap.controllers.enumerated() {
            let last = idx == snap.controllers.count - 1
            line("   \(last ? "└" : "├") \(bold(ctrl.title))\(ctrl.subtitle.map { dim(" · \($0)") } ?? "")")
            let nested = promotedChildren(of: ctrl)
            for (cIdx, child) in nested.enumerated() {
                let isLastChild = cIdx == nested.count - 1
                let prefix = "   \(last ? "  " : "│ ") "
                renderNode(child, prefix: prefix, isLast: isLastChild)
            }
        }
        line()
    }

    // MARK: USB

    func usb(_ snap: USBSnapshot) {
        section("🔌 USB", pluralize(snap.controllers.count, "host controller"))
        if snap.controllers.isEmpty {
            line(dim("   none"))
            line()
            return
        }
        for (idx, ctrl) in snap.controllers.enumerated() {
            let last = idx == snap.controllers.count - 1
            line("   \(last ? "└" : "├") \(bold(ctrl.title))\(ctrl.subtitle.map { dim(" · \($0)") } ?? "")")
            let nested = promotedUSBChildren(of: ctrl)
            for (cIdx, child) in nested.enumerated() {
                let isLastChild = cIdx == nested.count - 1
                let prefix = "   \(last ? "  " : "│ ") "
                renderNode(child, prefix: prefix, isLast: isLastChild, showUSBOnly: true)
            }
        }
        line()
    }

    // MARK: Internal Hardware

    func internalHardware(_ hw: InternalHardwareSnapshot) {
        let any = hw.batteryManager != nil
            || hw.magsafe != nil
            || !hw.i2cBuses.isEmpty
            || !hw.spiBuses.isEmpty
            || !hw.socCoprocessors.isEmpty
        section("🧠 Internal Hardware", any ? nil : "none")
        if !any { line(); return }

        if let bm = hw.batteryManager,
           let battery = bm.children.first(where: { $0.kind == .battery }) ?? Optional(bm) {
            renderBattery(battery)
        }
        if let mag = hw.magsafe {
            let label = mag.connectionActive
                ? "Connected" + (mag.usbPD?.winning.map { " · charging \($0.powerLabel)" } ?? "")
                : "Idle"
            line("   🧲 \(bold("MagSafe 3"))  \(dim(label))")
        }
        if !hw.i2cBuses.isEmpty {
            line("   \(yellow("⚙"))  I²C Buses")
            for (i, bus) in hw.i2cBuses.enumerated() {
                let isLast = i == hw.i2cBuses.count - 1
                let prefix = "      "
                line(prefix + (isLast ? "└─ " : "├─ ") + bold(bus.title) + dim(bus.subtitle.map { " · \($0)" } ?? ""))
                let kids = bus.children
                for (j, slave) in kids.enumerated() {
                    let last = j == kids.count - 1
                    let p = prefix + (isLast ? "    " : "│   ")
                    line(p + (last ? "└ " : "├ ") + slave.title + dim(slave.subtitle.map { " · \($0)" } ?? ""))
                }
            }
        }
        if !hw.spiBuses.isEmpty {
            line("   \(magenta("⚙"))  SPI Buses")
            for (i, bus) in hw.spiBuses.enumerated() {
                let isLast = i == hw.spiBuses.count - 1
                let prefix = "      "
                line(prefix + (isLast ? "└─ " : "├─ ") + bold(bus.title) + dim(bus.subtitle.map { " · \($0)" } ?? ""))
            }
        }
        if !hw.coprocessorGroups.isEmpty {
            line("   \(blue("◈"))  SoC Coprocessors")
            for (g, group) in hw.coprocessorGroups.enumerated() {
                let isLastGroup = g == hw.coprocessorGroups.count - 1
                let groupPrefix = "      "
                line(groupPrefix + (isLastGroup ? "└ " : "├ ") + bold(group.category.title))
                for (i, cop) in group.coprocessors.enumerated() {
                    let isLast = i == group.coprocessors.count - 1
                    let childPrefix = groupPrefix + (isLastGroup ? "    " : "│   ")
                    let emoji = coprocessorEmoji(for: cop)
                    line(childPrefix + (isLast ? "└─ " : "├─ ") + "\(emoji) " + cop.title + dim(cop.subtitle.map { " · \($0)" } ?? ""))
                }
            }
        }
        line()
    }

    // MARK: Bluetooth

    func bluetooth(_ snap: BluetoothSnapshot) {
        let total = snap.totalDeviceCount
        let sub = snap.controller == nil ? "no controller" : pluralize(total, "device")
        section("📶 Bluetooth", sub)
        if let c = snap.controller {
            let state = c.isOn ? green("On") : dim("Off")
            line("   \(bold(c.displayChipset)) · \(state) · \(c.transport ?? "—") · \(c.address ?? "—")")
            if let fw = c.firmwareVersion {
                line("   " + dim("Firmware: \(fw)"))
            }
        }
        if !snap.connected.isEmpty {
            line("   " + dim("Connected:"))
            for d in snap.connected {
                line("      " + green("◉ ") + d.name + dim(deviceSubtitle(d)))
            }
        }
        if !snap.paired.isEmpty {
            line("   " + dim("Paired:"))
            for d in snap.paired {
                line("      " + dim("○ ") + d.name + dim(deviceSubtitle(d)))
            }
        }
        line()
    }

    private func deviceSubtitle(_ d: BluetoothDevice) -> String {
        var parts: [String] = []
        if let m = d.minorType, !m.isEmpty { parts.append(m) }
        if let addr = d.address { parts.append(addr) }
        if let rssi = d.rssi { parts.append("\(rssi) dBm") }
        return parts.isEmpty ? "" : " · \(parts.joined(separator: " · "))"
    }

    // MARK: Displays

    func displays(_ snap: DisplaySnapshot) {
        section("🖥  Displays", "\(snap.totalCount) total, \(snap.connectedCount) active")
        if snap.displays.isEmpty {
            line(dim("   none"))
            line()
            return
        }
        for d in snap.displays {
            let icon = d.isBuiltIn ? "💻" : (d.isConnected ? "🖥 " : "⊟ ")
            line("   \(icon) \(bold(d.title))\(d.subtitle.map { dim(" · \($0)") } ?? "")")
            if d.isConnected {
                var bits: [String] = []
                if let depth = d.colorBitDepth { bits.append("\(depth)-bit") }
                if d.supportsHDR { bits.append("HDR") }
                if d.timingModeCount > 0 { bits.append("\(d.timingModeCount) modes") }
                if !bits.isEmpty {
                    line("      " + dim(bits.joined(separator: " · ")))
                }
            }
        }
        line()
    }

    // MARK: PCIe

    func pcie(_ snap: PCISnapshot) {
        section("🚌 PCIe", "\(pluralize(snap.roots.count, "root bridge")), \(pluralize(snap.endpointCount, "endpoint"))")
        if snap.roots.isEmpty {
            line(dim("   none"))
            line()
            return
        }
        for (idx, root) in snap.roots.enumerated() {
            let last = idx == snap.roots.count - 1
            renderPCI(root, prefix: "   ", isLast: last)
        }
        line()
    }

    private func renderPCI(_ n: PCINode, prefix: String, isLast: Bool) {
        let connector = isLast ? "└─ " : "├─ "
        let speedBadge: String
        if let s = n.linkSpeed, let w = n.linkWidth {
            speedBadge = dim(" · ") + cyan("\(pciLinkSpeedShortLabel(s)) ×\(w)")
        } else {
            speedBadge = ""
        }
        let body = bold(n.title) + (n.subtitle.map { dim(" · \($0)") } ?? "") + speedBadge
        line(prefix + connector + body)
        let nextPrefix = prefix + (isLast ? "   " : "│  ")
        for (i, c) in n.children.enumerated() {
            renderPCI(c, prefix: nextPrefix, isLast: i == n.children.count - 1)
        }
    }

    private func renderBattery(_ node: TBNode) {
        let pct = node.properties["CurrentCapacity"]?.asUInt ?? 0
        let charging = node.properties["IsCharging"]?.asBool ?? false
        let external = node.properties["ExternalConnected"]?.asBool ?? false
        let state = charging ? "Charging" : (external ? "On AC" : "On battery")
        let icon = charging ? "🔌🔋" : "🔋"
        line("   \(icon) \(bold("Battery"))  \(dim("\(pct)% · \(state)"))")
    }

    private func coprocessorEmoji(for node: TBNode) -> String {
        let name = node.properties["name"].flatMap { v -> String? in
            if case let .string(s) = v { return s }
            if case let .data(d) = v {
                return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            }
            return nil
        } ?? ""
        if name.hasPrefix("sep") { return "🛡 " }
        if name.hasPrefix("aop") { return "☁️ " }
        if name.hasPrefix("ane") { return "🧠" }
        if name.hasPrefix("isp") { return "📷" }
        if name.hasPrefix("dcp") || name.hasPrefix("disp") { return "🖥 " }
        if name.hasPrefix("ans") { return "💾" }
        if name.hasPrefix("smc") { return "🌡 " }
        if name.hasPrefix("pmp") || name.hasPrefix("pmgr") { return "⚡️" }
        if name.hasPrefix("wlan") { return "📡" }
        if name.hasPrefix("bluetooth") { return "📶" }
        if name.hasPrefix("avd") || name.hasPrefix("ave") { return "🎞 " }
        if name.hasPrefix("jpeg") { return "🖼 " }
        return "◈ "
    }

    // MARK: Generic node rendering

    private func renderNode(_ node: TBNode, prefix: String, isLast: Bool, showUSBOnly: Bool = false) {
        let connector = isLast ? "└─ " : "├─ "
        line(prefix + connector + nodeLine(node))
        let kids = showUSBOnly ? promotedUSBChildren(of: node) : promotedChildren(of: node)
        let nextPrefix = prefix + (isLast ? "   " : "│  ")
        for (i, k) in kids.enumerated() {
            renderNode(k, prefix: nextPrefix, isLast: i == kids.count - 1, showUSBOnly: showUSBOnly)
        }
    }

    private func indentedNode(_ node: TBNode, prefix: String, showUSBOnly: Bool) {
        let kids = showUSBOnly ? promotedUSBChildren(of: node) : promotedChildren(of: node)
        for (i, k) in kids.enumerated() {
            renderNode(k, prefix: prefix, isLast: i == kids.count - 1, showUSBOnly: showUSBOnly)
        }
    }

    private func nodeLine(_ node: TBNode) -> String {
        let icon = kindEmoji(node.kind)
        let title = bold(node.title)
        let sub = node.subtitle.map { dim(" · \($0)") } ?? ""
        return "\(icon) \(title)\(sub)"
    }

    private func kindEmoji(_ kind: TBNodeKind) -> String {
        switch kind {
        case .controller:     return "🎛 "
        case .switch:         return "🔀"
        case .port:           return "🔲"
        case .usbBus:         return "🔌"
        case .usbController:  return "🎛 "
        case .usbHub:         return "🌀"
        case .usbDevice:      return "🔌"
        case .usbInterface:   return "🧩"
        case .pcieBridge:     return "🌉"
        case .pcieDevice:     return "📦"
        case .networkIf:      return "🌐"
        case .appleFabric:    return "🧶"
        case .i2cBus:         return "🪢"
        case .spiBus:         return "🪢"
        case .busDevice:      return "·"
        case .batteryManager: return "🔋"
        case .battery:        return "🔋"
        case .socCoprocessor: return "◈ "
        case .localNode:      return "🏠"
        case .domain:         return "🌐"
        case .other:          return "·"
        }
    }

    // MARK: Sectioning

    private func section(_ title: String, _ subtitle: String?) {
        let head = bold(title)
        if let sub = subtitle { line(head + dim("  ·  \(sub)")) } else { line(head) }
        line(dim(String(repeating: "─", count: 60)))
    }

    /// "1 widget" / "3 widgets" — replaces the lazy "widget(s)" idiom.
    /// Pass `plural:` for words where `+s` isn't right (e.g. "indices").
    private func pluralize(_ n: Int, _ singular: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// Mirror of the sidebar's `promotedChildren`: drops `.other` wrapper
    /// kexts (DPConnectionManager / IPService / port wrappers) and
    /// promotes their meaningful descendants up so the CLI tree matches
    /// what a user sees in the GUI.
    private func promotedChildren(of node: TBNode) -> [TBNode] {
        var out: [TBNode] = []
        for c in node.children {
            if c.kind == .other {
                out.append(contentsOf: promotedChildren(of: c))
            } else {
                out.append(c)
            }
        }
        return out
    }

    private func promotedUSBChildren(of node: TBNode) -> [TBNode] {
        var out: [TBNode] = []
        for c in node.children {
            if c.kind == .other {
                out.append(contentsOf: promotedUSBChildren(of: c))
            } else if c.kind != .usbInterface {
                out.append(c)
            }
        }
        return out
    }
}
