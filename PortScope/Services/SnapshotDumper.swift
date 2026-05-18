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
    static func json(_ snapshot: SystemSnapshot) -> String {
        let root: [String: Any] = snapshotToJSONObject(snapshot)
        let data = (try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func snapshotToJSONObject(_ s: SystemSnapshot) -> [String: Any] {
        return [
            "captured_at": ISO8601DateFormatter().string(from: s.capturedAt),
            "host": hostInfoJSON(),
            "physical_ports": TopologyMapper.physicalPorts(from: s).map(physicalPortToJSON(_:)),
            "thunderbolt": [
                "controllers": s.tb.controllers.map(nodeToJSON(_:)),
                "pcie_devices_over_tb": s.tb.pcieDevicesOverTB.map(nodeToJSON(_:)),
                "usb_devices_over_tb": s.tb.usbDevicesOverTB.map(nodeToJSON(_:))
            ],
            "usb": [
                "controllers": s.usb.controllers.map(nodeToJSON(_:)),
                "tb_context": Dictionary(
                    uniqueKeysWithValues: s.usb.tbContext.map { kv -> (String, String) in
                        (String(format: "0x%llX", kv.key.raw),
                         String(format: "0x%llX", kv.value.raw))
                    }
                )
            ],
            "accessories": s.accessories.map(accessoryToJSON(_:)),
            "internal_hardware": [
                "battery": s.internalHardware.batteryManager.map(nodeToJSON(_:)) ?? NSNull(),
                "magsafe": s.internalHardware.magsafe.map(accessoryToJSON(_:)) ?? NSNull(),
                "i2c_buses": s.internalHardware.i2cBuses.map(nodeToJSON(_:)),
                "spi_buses": s.internalHardware.spiBuses.map(nodeToJSON(_:)),
                "soc_coprocessors": s.internalHardware.socCoprocessors.map(nodeToJSON(_:))
            ]
        ]
    }

    private static func physicalPortToJSON(_ p: PhysicalPort) -> [String: Any] {
        var out: [String: Any] = [
            "number": p.number,
            "id": String(format: "0x%llX", p.id.raw),
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
        return [
            "kernel_release": release,
            "kernel_machine": machine
        ]
    }

    // MARK: - Pretty CLI (ANSI + emoji)

    /// Render a `SystemSnapshot` as a colourful tree. When stdout is a TTY
    /// the output uses ANSI colour escapes; otherwise the escapes are
    /// stripped so piping into a file produces clean text.
    static func pretty(_ snapshot: SystemSnapshot, useColor: Bool) -> String {
        let p = PrettyPrinter(useColor: useColor)
        p.header(snapshot)
        p.physicalPorts(TopologyMapper.physicalPorts(from: snapshot))
        p.thunderbolt(snapshot.tb)
        p.usb(snapshot.usb)
        p.internalHardware(snapshot.internalHardware)
        return p.flush()
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
        section("⚡️ Physical Ports", ports.isEmpty ? "—" : "\(ports.count) receptacle(s)")
        if ports.isEmpty {
            line(dim("   none"))
            line()
            return
        }
        for port in ports {
            let badge = portBadge(port.mode)
            let title = "USB-C Port \(port.number)"
            line("   \(badge) \(bold(title))  \(dim(port.statusLabel))")
            if let acc = port.accessory {
                let active = Array(acc.activeTransports).map { "\($0.label)" }.sorted().joined(separator: ", ")
                if !active.isEmpty {
                    line("      \(dim("transports:")) \(active)")
                }
                if acc.plugOrientation != .unattached {
                    line("      \(dim("orientation:")) \(acc.plugOrientation.label)")
                }
                if let pd = acc.usbPD, let win = pd.winning {
                    line("      \(dim("USB-PD:")) \(win.voltageLabel) @ \(win.currentLabel) = \(bold(win.powerLabel))")
                }
                if let cable = acc.cableLabel {
                    line("      \(dim("cable:")) \(cable)")
                }
                if acc.hpdAsserted {
                    line("      \(dim("DP HPD:")) asserted (pin \(displayPortPinAssignmentLabel(acc.displayPortPinAssignment)))")
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
        case .unknown: return yellow("?")
        }
    }

    // MARK: Thunderbolt

    func thunderbolt(_ snap: TBSnapshot) {
        section("🌩  Thunderbolt", "\(snap.controllers.count) controller(s)")
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
        section("🔌 USB", "\(snap.controllers.count) host controller(s)")
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
        if !hw.socCoprocessors.isEmpty {
            line("   \(blue("◈"))  SoC Coprocessors")
            for (i, cop) in hw.socCoprocessors.enumerated() {
                let isLast = i == hw.socCoprocessors.count - 1
                let prefix = "      "
                let emoji = coprocessorEmoji(for: cop)
                line(prefix + (isLast ? "└─ " : "├─ ") + "\(emoji) " + bold(cop.title) + dim(cop.subtitle.map { " · \($0)" } ?? ""))
            }
        }
        line()
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
