//
//  MacPortCatalog.swift
//  PortScope
//
//  Static catalogue mapping `hw.model` (e.g. `Mac14,12`) to a per-receptacle
//  location + capability description. Loaded once at process start from the
//  embedded `Resources/MacPortLocations.json` bundle resource. The catalogue
//  is the source of truth for chassis labels in the sidebar: "USB-C Port 4"
//  becomes "Rear (rightmost) USB-C Port", "Thunderbolt 4" — but only when
//  we recognise the host's hw.model. Unrecognised models fall back to the
//  generic numbered label so PortScope never appears to lie.
//
//  See `CLAUDE.md` → "Adding a new Mac model to the port-location catalogue"
//  for the procedure when Apple ships a new chassis.
//

import Foundation
import Darwin

/// One receptacle entry as it appears in the JSON catalogue.
nonisolated struct MacPortDescriptor: Hashable {
    /// Connector kind, parsed from the JSON's `connector` string.
    let connector: PortConnectorType
    /// Kernel `PortNumber` that this entry describes.
    let portNumber: Int
    /// Chassis-relative position, e.g. "Left Rear", "Rear (rightmost)".
    let location: String
    /// Apple-spec capability string, e.g. "Thunderbolt 4", "HDMI 2.1".
    let capability: String?

    /// Full friendly title for the sidebar row, combining location +
    /// connector. Catalogue locations already encode chassis-relative
    /// position ("Left Rear", "Rear (rightmost)") so the formula reduces
    /// to `<location> <kind> Port`; SD Card uses "Slot" since "Port" reads
    /// oddly for a card receptacle.
    var title: String {
        switch connector {
        case .sdCard:  return "\(location) SD Card Slot"
        default:       return "\(location) \(connector.label) Port"
        }
    }
}

/// Per-chassis entry in the catalogue.
nonisolated struct MacChassisEntry: Hashable {
    /// The marketing-friendly name ("MacBook Pro (14-inch, 2024, M4 Pro)").
    let marketingName: String
    /// Free-form chassis blurb ("MacBook Pro 14″ Pro chassis").
    let chassis: String
    /// All known receptacles on this chassis.
    let ports: [MacPortDescriptor]
}

nonisolated enum MacPortCatalog {
    /// Result of looking up the current host in the catalogue.
    struct Lookup {
        let modelID: String
        let entry: MacChassisEntry?

        /// Convenience: descriptor for a given (connector, portNumber) pair,
        /// or nil if either the model or the receptacle is unknown.
        func descriptor(for connector: PortConnectorType, portNumber: Int) -> MacPortDescriptor? {
            entry?.ports.first { $0.connector == connector && $0.portNumber == portNumber }
        }
    }

    /// Lookup for the running host. Computed once; the model identifier
    /// is invariant for the lifetime of the process.
    static let current: Lookup = {
        let modelID = readHWModel() ?? ""
        let entry = loadCatalog()[modelID]
        return Lookup(modelID: modelID, entry: entry)
    }()

    /// Full catalogue, keyed by `hw.model`. Loaded lazily from the bundle.
    static let all: [String: MacChassisEntry] = loadCatalog()

    // MARK: - Load

    private static func loadCatalog() -> [String: MacChassisEntry] {
        guard let url = Bundle.main.url(forResource: "MacPortLocations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = top["models"] as? [String: Any]
        else {
            return [:]
        }
        var out: [String: MacChassisEntry] = [:]
        out.reserveCapacity(models.count)
        for (modelID, value) in models {
            guard let dict = value as? [String: Any],
                  let entry = parseChassis(dict) else { continue }
            out[modelID] = entry
        }
        return out
    }

    private static func parseChassis(_ dict: [String: Any]) -> MacChassisEntry? {
        let name = (dict["marketing_name"] as? String) ?? ""
        let chassis = (dict["chassis"] as? String) ?? ""
        let portsRaw = (dict["ports"] as? [[String: Any]]) ?? []
        var ports: [MacPortDescriptor] = []
        ports.reserveCapacity(portsRaw.count)
        for p in portsRaw {
            guard let connector = parseConnector(p["connector"] as? String),
                  let portNumber = (p["port_number"] as? Int),
                  let location = (p["location"] as? String)
            else { continue }
            let cap = p["capability"] as? String
            ports.append(MacPortDescriptor(
                connector: connector,
                portNumber: portNumber,
                location: location,
                capability: cap
            ))
        }
        return MacChassisEntry(marketingName: name, chassis: chassis, ports: ports)
    }

    /// Translate the catalogue's connector strings into the app's
    /// `PortConnectorType`. Mirrors the kernel-string mapping in the
    /// `PortConnectorType` initializer but uses lower-case kebab strings.
    private static func parseConnector(_ raw: String?) -> PortConnectorType? {
        switch raw {
        case "usb-c":   return .usbC
        case "usb-a":   return .usbA
        case "magsafe": return .magsafe
        case "hdmi":    return .hdmi
        case "sd-card", "sdcard": return .sdCard
        case "ac-power", "power": return .acPower
        case "ethernet": return .ethernet
        default: return nil
        }
    }

    // MARK: - HW model

    /// Read `sysctl hw.model`. Identifies the Mac chassis (e.g. "Mac14,12"),
    /// invariant for the lifetime of the OS install on a given device.
    private static func readHWModel() -> String? {
        var size: size_t = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) != 0 || size == 0 {
            return nil
        }
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.model", &buf, &size, nil, 0) != 0 {
            return nil
        }
        return String(cString: buf)
    }
}
