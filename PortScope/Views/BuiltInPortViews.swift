//
//  BuiltInPortViews.swift
//  PortScope
//
//  Curated detail pages for built-in non-USB-C/USB-A receptacles on the
//  chassis: the AC PSU on desktop Macs, the Ethernet jack, the HDMI jack,
//  and the SD Card slot. Each focuses on what the receptacle actually
//  represents — wattage / link speed / card-present — instead of pushing
//  the USB-C PD / alt-mode template through it.
//

import SwiftUI

// MARK: - AC Power Input

struct ACPowerDetailView: View {
    let port: PhysicalPort
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        DetailContainer {
            let live = port.accessory?.usbPD?.winning
            let isLive = (live?.maxPowerMW ?? 0) > 0

            Hero(
                symbol: "bolt",
                title: port.cliTitle,
                subtitle: heroSubtitle(isLive: isLive),
                status: isLive ? .powerIn(live?.powerLabel ?? "") : .empty
            )

            VStack(alignment: .leading, spacing: PSSpacing.m) {
                SectionHeader("Live telemetry")
                PropertyList {
                    PropertyRowSpec("Power",
                                    live.map { String(format: "%.1f W", Double($0.maxPowerMW) / 1000.0) },
                                    valueColor: PSColor.powerIn)
                    PropertyRowSpec("Voltage",
                                    live.map { String(format: "%.2f V", Double($0.voltageMV) / 1000.0) })
                    PropertyRowSpec("Current",
                                    live.map { String(format: "%.3f A", Double($0.maxCurrentMA) / 1000.0) })
                    PropertyRowSpec("Power source",
                                    (port.accessory?.registryProperties["ExternalConnected"]?.asBool ?? false)
                                        ? "AC mains" : nil)
                    PropertyRowSpec("PSU spec", port.catalogCapability)
                    PropertyRowSpec("Receptacle", port.catalogLocation ?? "Built-in")
                }
            }

            if let dict = telemetryDict {
                lifetimeEnergySection(dict: dict)
            }

            DisclosureCard("Developer details (raw IORegistry)",
                           icon: "wrench.and.screwdriver") {
                if let node = developerNode {
                    PropertyTableView(node: node)
                } else {
                    EmptyStateNote(text: "No IOKit properties were captured for this port.")
                }
            }
        }
    }

    private func heroSubtitle(isLive: Bool) -> String? {
        if isLive { return "Drawing power from the wall" }
        return "No telemetry reported"
    }

    @ViewBuilder
    private func lifetimeEnergySection(dict: [String: IORegValue]) -> some View {
        VStack(alignment: .leading, spacing: PSSpacing.m) {
            SectionHeader("Lifetime energy (since boot)")
            PropertyList {
                if let v = dict["SystemLoad"]?.asUInt {
                    PropertyRowSpec(forcing: "System load",
                                    String(format: "%.2f W", Double(v) / 1000.0))
                }
                if let v = dict["AdapterEfficiencyLoss"]?.asUInt {
                    PropertyRowSpec(forcing: "Adapter loss",
                                    String(format: "%.2f W", Double(v) / 1000.0))
                }
                if let wallTotal = dict["AccumulatedWallEnergyEstimate"]?.asUInt {
                    PropertyRowSpec(forcing: "Wall energy drawn",
                                    formatEnergy(wallTotal))
                }
                if let sysTotal = dict["AccumulatedSystemEnergyConsumed"]?.asUInt {
                    PropertyRowSpec(forcing: "System energy used",
                                    formatEnergy(sysTotal))
                }
            }
        }
    }

    private var telemetryDict: [String: IORegValue]? {
        guard let raw = port.accessory?.registryProperties["PowerTelemetryData"],
              case let .dictionary(kv) = raw
        else { return nil }
        return Dictionary(kv, uniquingKeysWith: { a, _ in a })
    }

    /// `Accumulated*` totals are milliwatt-seconds (mJ).
    private func formatEnergy(_ raw: UInt64) -> String {
        let wh = Double(raw) / 3_600_000.0
        if wh >= 1000 { return String(format: "%.2f kWh", wh / 1000.0) }
        if wh >= 1    { return String(format: "%.1f Wh", wh) }
        return String(format: "%.3f Wh", wh)
    }

    private var developerNode: TBNode? {
        makeBuiltInDeveloperNode(accessory: port.accessory,
                                 title: "Power Input",
                                 className: "AppleSmartBattery")
    }
}

// MARK: - Ethernet

struct EthernetDetailView: View {
    let port: PhysicalPort
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        DetailContainer {
            let active = linkActive
            Hero(
                symbol: active ? "cable.coaxial" : "cable.coaxial",
                title: port.cliTitle,
                subtitle: subtitle,
                status: active ? .active : .empty
            )

            PropertyList {
                PropertyRowSpec("Negotiated speed",
                                linkSpeedMbps.map(ethernetSpeedLabel))
                PropertyRowSpec("Link state",
                                active ? "Up" : "Down",
                                valueColor: active ? PSColor.active : nil)
                PropertyRowSpec("MAC address",
                                props["IOMACAddress"]?.asString.map(prettifyMAC),
                                mono: true, secret: true)
                PropertyRowSpec("BSD name", props["BSD Name"]?.asString, mono: true)
                PropertyRowSpec("Controller", controllerLabel)
                PropertyRowSpec("Driver", props["Driver_Version"]?.asString, mono: true)
                PropertyRowSpec("Firmware",
                                props["FirmwareVersionString"]?.asString,
                                mono: true)
                PropertyRowSpec("MTU",
                                props["IOMaxTransferUnit"]?.asUInt.map { "\($0) bytes" })
                PropertyRowSpec("Jumbo frames",
                                props["IOMaxPacketSize"]?.asUInt.map {
                                    $0 > 1500 ? "Capable (\($0) bytes)" : "Standard"
                                })
                PropertyRowSpec("PHY spec", port.catalogCapability)
            }

            DisclosureCard("Developer details (raw IORegistry)",
                           icon: "wrench.and.screwdriver") {
                if let node = developerNode {
                    PropertyTableView(node: node)
                } else {
                    EmptyStateNote(text: "No IOKit properties were captured for this port.")
                }
            }
        }
    }

    private var props: [String: IORegValue] { port.accessory?.registryProperties ?? [:] }

    private var linkActive: Bool {
        port.accessory?.connectionActive ?? (props["LinkActive"]?.asBool ?? false)
    }

    private var linkSpeedMbps: UInt64? {
        if let v = props["LinkSpeedMbps"]?.asUInt, v > 0 { return v }
        return nil
    }

    private var subtitle: String? {
        if linkActive {
            if let mbps = linkSpeedMbps { return "Linked · \(ethernetSpeedLabel(mbps))" }
            return "Linked"
        }
        return "Cable unplugged"
    }

    private var controllerLabel: String? {
        let v = props["IOVendor"]?.asString ?? ""
        let m = props["IOModel"]?.asString ?? ""
        let combined = "\(v) \(m)".trimmingCharacters(in: .whitespaces)
        return combined.isEmpty ? nil : combined
    }

    private func prettifyMAC(_ raw: String) -> String {
        var hex = raw
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        guard hex.count == 12 else { return raw }
        let lower = Array(hex.lowercased())
        var parts: [String] = []
        parts.reserveCapacity(6)
        for i in stride(from: 0, to: lower.count, by: 2) {
            parts.append(String(lower[i..<i + 2]))
        }
        return parts.joined(separator: ":")
    }

    private var developerNode: TBNode? {
        makeBuiltInDeveloperNode(accessory: port.accessory,
                                 title: "Ethernet Interface",
                                 className: "IOEthernetInterface")
    }
}

// MARK: - HDMI

struct HDMIDetailView: View {
    let port: PhysicalPort
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        DetailContainer {
            let attached = hpd || connectionActive || dpAlt
            Hero(
                symbol: "display",
                title: port.cliTitle,
                subtitle: subtitle,
                status: attached ? .active : .empty
            )

            PropertyList {
                PropertyRowSpec(forcing: "Cable", hpd ? "Seated" : "Unplugged")
                PropertyRowSpec(forcing: "Sink negotiated",
                                connectionActive ? "Yes" : "No")
                PropertyRowSpec("Active transports", activeTransports)
                PropertyRowSpec("HDMI spec", port.catalogCapability)
                PropertyRowSpec("Receptacle", port.catalogLocation ?? "Built-in")
                PropertyRowSpec("Lifetime plug events",
                                props["ConnectionCount"]?.asUInt
                                    .map { $0 == 0 ? nil : String($0) } ?? nil)
            }

            DisclosureCard("Developer details (raw IORegistry)",
                           icon: "wrench.and.screwdriver") {
                if let node = developerNode {
                    PropertyTableView(node: node)
                } else {
                    EmptyStateNote(text: "No IOKit properties were captured for this port.")
                }
            }
        }
    }

    private var props: [String: IORegValue] { port.accessory?.registryProperties ?? [:] }

    private var hpd: Bool {
        props["HDMI_HPD"]?.asBool ?? port.accessory?.hpdAsserted ?? false
    }
    private var connectionActive: Bool {
        port.accessory?.connectionActive ?? false
    }
    private var dpAlt: Bool {
        port.accessory?.activeTransports.contains(.displayPort) ?? false
    }

    private var subtitle: String? {
        if connectionActive { return "Display attached and negotiated" }
        if hpd { return "Cable seated · waiting on link" }
        if dpAlt { return "Carrying DisplayPort" }
        return "No cable detected"
    }

    private var activeTransports: String? {
        guard let arr = props["TransportsActive"]?.asArray, !arr.isEmpty else { return nil }
        return arr.joined(separator: ", ")
    }

    private var developerNode: TBNode? {
        makeBuiltInDeveloperNode(accessory: port.accessory,
                                 title: "HDMI Port",
                                 className: "IODPHDMIPort")
    }
}

// MARK: - SD Card

struct SDCardDetailView: View {
    let port: PhysicalPort
    let onNavigate: (TBNodeID) -> Void

    var body: some View {
        DetailContainer {
            let inserted = port.accessory?.connectionActive ?? false
            Hero(
                symbol: inserted ? "sdcard.fill" : "sdcard",
                title: port.cliTitle,
                subtitle: inserted ? "Card inserted and mounted" : "Slot empty",
                status: inserted ? .active : .empty
            )

            PropertyList {
                PropertyRowSpec(forcing: "Card", inserted ? "Inserted" : "Empty")
                PropertyRowSpec("Reader spec", port.catalogCapability)
                PropertyRowSpec("Receptacle", port.catalogLocation ?? "Built-in")
            }

            DisclosureCard("Developer details (raw IORegistry)",
                           icon: "wrench.and.screwdriver") {
                if let node = developerNode {
                    PropertyTableView(node: node)
                } else {
                    EmptyStateNote(text: "No IOKit properties were captured for this port.")
                }
            }
        }
    }

    private var developerNode: TBNode? {
        makeBuiltInDeveloperNode(accessory: port.accessory,
                                 title: "SD Card Reader",
                                 className: "pcie-sdreader")
    }
}

// MARK: - Shared helpers

/// Build a synthetic `TBNode` for the built-in port's accessory so the
/// design-system `DisclosureCard` + `PropertyTableView` pair can render
/// the raw IORegistry properties uniformly across every detail page.
private func makeBuiltInDeveloperNode(accessory: PortAccessoryInfo?,
                                      title: String,
                                      className: String) -> TBNode? {
    guard let accessory else { return nil }
    let props = accessory.registryProperties
    let order = props.keys.sorted()
    return TBNode(
        id: accessory.id,
        kind: .other,
        title: title,
        subtitle: nil,
        className: className,
        properties: props,
        propertyOrder: order,
        children: [],
        registryPath: accessory.registryPath
    )
}

private extension IORegValue {
    var asArray: [String]? {
        guard case .array(let arr) = self else { return nil }
        let strings = arr.compactMap { $0.asString }
        return strings.count == arr.count ? strings : nil
    }
}
