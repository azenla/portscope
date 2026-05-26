//
//  HostMiscViews.swift
//  PortScope
//
//  Detail views for the remaining host subsystems that don't fit in the
//  USB / TB / display flows: NVRAM, GPU (AGX), Touch ID (Mesa), and the
//  built-in input devices (trackpad + keyboard backlight).
//

import SwiftUI
import IOKit

// MARK: - NVRAM

struct NVRAMDetailView: View {
    let snapshot: NVRAMSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if !snapshot.highlighted.isEmpty {
                    SectionCard(title: "Boot Configuration", symbol: "power.circle") {
                        VStack(spacing: 0) {
                            ForEach(snapshot.highlighted) { v in
                                HighlightedRow(variable: v)
                                if v.id != snapshot.highlighted.last?.id { Divider() }
                            }
                        }
                    }
                }
                if !snapshot.allVariables.isEmpty {
                    SectionCard(title: "All Variables (\(snapshot.allVariables.count))",
                                symbol: "list.bullet.rectangle") {
                        VStack(spacing: 0) {
                            ForEach(Array(snapshot.allVariables.enumerated()),
                                    id: \.offset) { _, pair in
                                RawRow(key: pair.key, value: pair.value)
                                if pair.key != snapshot.allVariables.last?.key { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
            // Cap the content width so the variables section doesn't
            // smear edge-to-edge on wide external displays — long hex
            // blobs like `BluetoothUHEDevices` would otherwise stretch
            // an entire 5K wide and end up unreadable. 1100 keeps the
            // page comfortable on a 27" panel and matches the
            // DiagramView interior budget. Center the capped column in
            // the ScrollView so it doesn't slam to the left edge.
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: "memorychip.fill").font(.system(size: 32))
                    .foregroundStyle(.purple)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("NVRAM").font(.title2).bold()
                Text("\(snapshot.allVariables.count) variables persisted in non-volatile RAM")
                    .foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
        }
    }

    private struct HighlightedRow: View {
        let variable: HighlightedVar
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: variable.symbol).foregroundStyle(.purple).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(variable.description).font(.callout.weight(.medium))
                    Text(variable.key).font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(variable.display).font(.callout.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 360, alignment: .trailing)
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
        }
    }

    private struct RawRow: View {
        let key: String
        let value: String
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Text(key).font(.caption.monospaced().weight(.medium))
                    .frame(minWidth: 200, alignment: .leading)
                Text(value).font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4).padding(.horizontal, 4)
        }
    }
}

struct NVRAMSidebarRow: View {
    let snapshot: NVRAMSnapshot
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip.fill").foregroundStyle(.purple).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("NVRAM").lineLimit(1)
                Text("\(snapshot.allVariables.count) variables")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

enum NVRAMSelector {
    private static let mask: UInt64 = 0x5757_DEAD_BEEF_0001
    static let id = TBNodeID(raw: mask)
    static func isNVRAMID(_ id: TBNodeID) -> Bool { id.raw == mask }
}

// MARK: - GPU (AGX)

/// Snapshot of AGX (Apple GPU) properties read at scan time. Apple's
/// `AGXAccelerator` IOService publishes a handful of identifying fields
/// directly as IORegistry properties; live perf counters live behind
/// `IOAccelerator` interfaces that aren't useful to surface in a static
/// view.
struct GPUInfo: Hashable {
    let modelName: String?      // e.g. "Apple M5 Max GPU"
    let coreCount: Int?
    let metalVersion: String?
    let deviceID: UInt64?
    let revisionID: UInt64?
    let busID: String?
    let driverClass: String?

    static func read() -> GPUInfo? {
        let iter = IORegBridge.services(matchingClass: "AGXAccelerator")
        guard let svc = iter.first else { return nil }
        defer { iter.forEach { IOObjectRelease($0) } }
        let props = IORegBridge.properties(of: svc)
        let device = props["device-id"]?.asUInt
        let rev = props["revision-id"]?.asUInt
        let bus = props["IOPCIClassMatch"]?.asString
        let cls = IORegBridge.className(of: svc)
        // Model + core count come from system_profiler's parse — we
        // re-use whatever SystemInfo already grabbed; the kernel doesn't
        // publish a tidy marketing string for them.
        return GPUInfo(
            modelName: nil,
            coreCount: nil,
            metalVersion: nil,
            deviceID: device,
            revisionID: rev,
            busID: bus,
            driverClass: cls
        )
    }
}

struct GPUDetailView: View {
    let info: SystemInfoSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: stats)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.red.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: "cube.transparent").font(.system(size: 32))
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(info.chipName.map { "\($0) GPU" } ?? "Apple GPU")
                    .font(.title2).bold()
                if let n = info.gpuCoreCount {
                    Text("\(n)-core integrated GPU")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            Spacer()
        }
    }

    private var stats: [Stat] {
        var out: [Stat] = []
        if let cores = info.gpuCoreCount {
            out.append(Stat(label: "Cores", value: "\(cores)", symbol: "cube.transparent"))
        }
        if let metal = info.metalVersion {
            out.append(Stat(label: "Metal Support", value: metal, symbol: "sparkles"))
        }
        if let chip = info.chipName {
            out.append(Stat(label: "Chip", value: chip, symbol: "cpu"))
        }
        if let agx = GPUInfo.read() {
            if let did = agx.deviceID {
                out.append(Stat(label: "Device ID",
                                value: String(format: "0x%04X", did),
                                symbol: "tag"))
            }
            if let rev = agx.revisionID {
                out.append(Stat(label: "Revision",
                                value: String(format: "0x%X", rev),
                                symbol: "number"))
            }
            if let cls = agx.driverClass {
                out.append(Stat(label: "Driver", value: cls,
                                symbol: "puzzlepiece.extension"))
            }
        }
        return out
    }
}

struct GPUSidebarRow: View {
    let info: SystemInfoSnapshot
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.transparent").foregroundStyle(.red).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.chipName.map { "\($0) GPU" } ?? "GPU").lineLimit(1)
                if let cores = info.gpuCoreCount {
                    Text("\(cores) cores · \(info.metalVersion ?? "Metal")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum GPUSelector {
    private static let mask: UInt64 = 0x6970_0070_0000_0001
    static let id = TBNodeID(raw: mask)
    static func isGPUID(_ id: TBNodeID) -> Bool { id.raw == mask }
}

// MARK: - Touch ID (Mesa)

/// Touch ID lives behind `AppleMesaShim` on Apple Silicon — a HID
/// service that brokers between the SEP (which holds the enrolled
/// fingerprint templates) and the AOP (which drives the sensor pad).
/// The kernel publishes the sensor's `Product`, `LocationID`, and a
/// handful of vendor/version fields; we surface what's there.
nonisolated struct TouchIDInfo: Hashable {
    let isPresent: Bool
    let product: String?
    let manufacturer: String?
    let vendorID: UInt64?
    let productID: UInt64?
    let firmwareVersion: UInt64?

    static let empty = TouchIDInfo(isPresent: false, product: nil,
                                   manufacturer: nil, vendorID: nil,
                                   productID: nil, firmwareVersion: nil)

    static func read() -> TouchIDInfo {
        let iter = IORegBridge.services(matchingClass: "AppleMesaShim")
        defer { iter.forEach { IOObjectRelease($0) } }
        guard let svc = iter.first else {
            return TouchIDInfo(isPresent: false, product: nil,
                               manufacturer: nil, vendorID: nil,
                               productID: nil, firmwareVersion: nil)
        }
        let props = IORegBridge.properties(of: svc)
        return TouchIDInfo(
            isPresent: true,
            product: props["Product"]?.asString,
            manufacturer: props["Manufacturer"]?.asString,
            vendorID: props["VendorID"]?.asUInt,
            productID: props["ProductID"]?.asUInt,
            firmwareVersion: props["VersionNumber"]?.asUInt
        )
    }
}

struct TouchIDDetailView: View {
    let info: TouchIDInfo
    /// Trusted Apple accessories authenticated via SEP. Rendered as a
    /// section under the Touch ID page because they share the SEP
    /// trust path (Magic Keyboard with Touch ID enrolls fingerprints
    /// here too). Empty list hides the section entirely.
    var trustedAccessories: [TrustedAccessoryInfo] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: stats)
                if !trustedAccessories.isEmpty {
                    SectionCard(
                        title: "Trusted Accessories (\(trustedAccessories.count))",
                        symbol: "checkmark.seal.fill"
                    ) {
                        VStack(spacing: 0) {
                            ForEach(trustedAccessories) { acc in
                                TrustedAccessoryRow(accessory: acc)
                                if acc.id != trustedAccessories.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                SectionCard(title: "How it works", symbol: "info.circle") {
                    Text("Touch ID is brokered by AppleMesaShim — a HID service that mediates between the Secure Enclave (which holds the enrolled fingerprint templates) and the Always-On Processor (which drives the sensor pad). The fingerprint data never leaves the SEP; macOS only ever sees a yes/no match signal.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.pink.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: "touchid").font(.system(size: 32))
                    .foregroundStyle(.pink)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Touch ID").font(.title2).bold()
                Text(info.isPresent ? "AppleMesaShim · Secure Enclave" : "Not present")
                    .foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
        }
    }

    private var stats: [Stat] {
        var out: [Stat] = []
        if let p = info.product {
            out.append(Stat(label: "Sensor", value: p, symbol: "touchid"))
        }
        if let m = info.manufacturer {
            out.append(Stat(label: "Manufacturer", value: m, symbol: "building.2"))
        }
        if let v = info.vendorID, v > 0 {
            out.append(Stat(label: "Vendor ID",
                            value: String(format: "0x%04X", v),
                            symbol: "tag"))
        }
        if let p = info.productID, p > 0 {
            out.append(Stat(label: "Product ID",
                            value: String(format: "0x%04X", p),
                            symbol: "barcode"))
        }
        if let f = info.firmwareVersion, f > 0 {
            out.append(Stat(label: "Firmware Version", value: "\(f)",
                            symbol: "memorychip"))
        }
        return out
    }
}

/// One row in the Trusted Accessories list. Shows the friendly name,
/// VID/PID, and a Touch ID badge when the accessory has a chained
/// `AppleMesaAccessory` child (i.e. it's a fingerprint-capable Magic
/// Keyboard).
private struct TrustedAccessoryRow: View {
    let accessory: TrustedAccessoryInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(.pink)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(accessory.displayName)
                        .font(.callout.weight(.medium))
                    if accessory.hasFingerprintCapability {
                        Image(systemName: "touchid")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                            .help("Includes Touch ID")
                    }
                }
                Text(idLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(accessory.isReady ? "Authenticated" : "Pending")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        accessory.isReady
                            ? Color.green.opacity(0.15)
                            : Color.orange.opacity(0.15)
                    )
                )
                .foregroundStyle(accessory.isReady ? Color.green : Color.orange)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
    }

    private var iconName: String {
        if accessory.hasFingerprintCapability { return "keyboard.badge.eye" }
        if accessory.displayName.lowercased().contains("trackpad") {
            return "rectangle.and.hand.point.up.left"
        }
        if accessory.displayName.lowercased().contains("pencil") {
            return "applepencil"
        }
        return "keyboard"
    }

    private var idLabel: String {
        let vid = accessory.vendorID.map { String(format: "VID 0x%04X", $0) } ?? "VID —"
        let pids = accessory.productIDs.prefix(4)
            .map { String(format: "0x%04X", $0) }
            .joined(separator: ", ")
        if accessory.productIDs.count > 4 {
            return "\(vid) · PIDs \(pids) · +\(accessory.productIDs.count - 4) more"
        }
        return "\(vid) · PIDs \(pids)"
    }
}

/// Walk all `AppleTrustedAccessory` services and build typed records.
/// The match runs against IOHIDInterface children so an accessory only
/// shows up here once it has fully attached over USB / Bluetooth. The
/// `AppleMesaAccessory` chained-child check distinguishes Touch ID
/// keyboards from regular Magic Keyboards.
nonisolated enum TrustedAccessoryScanner {
    static func scan() -> [TrustedAccessoryInfo] {
        var out: [TrustedAccessoryInfo] = []
        for svc in IORegBridge.services(matchingClass: "AppleTrustedAccessory") {
            defer { IOObjectRelease(svc) }
            guard let id = IORegBridge.entryID(of: svc) else { continue }
            let props = IORegBridge.properties(of: svc)
            let vid = props["VendorID"]?.asUInt
            let pids = readUIntArray(props["ProductIDArray"])
            let ready = props["AccessoryReady"]?.asBool ?? false
            let hasMesa = childMatches(svc: svc, className: "AppleMesaAccessory")
            let name = displayName(vendorID: vid, productIDs: pids,
                                   hasFingerprint: hasMesa)
            out.append(TrustedAccessoryInfo(
                id: id, vendorID: vid, productIDs: pids,
                isReady: ready, displayName: name,
                hasFingerprintCapability: hasMesa
            ))
        }
        // Stable order: ready accessories first, then by display name.
        return out.sorted {
            if $0.isReady != $1.isReady { return $0.isReady && !$1.isReady }
            return $0.displayName < $1.displayName
        }
    }

    /// `ProductIDArray` arrives as a CFArray of UInt64s; pull them out
    /// in order.
    private static func readUIntArray(_ value: IORegValue?) -> [UInt64] {
        guard case let .array(arr) = value else { return [] }
        return arr.compactMap { $0.asUInt }
    }

    /// Walk the service's direct children and return true if any of
    /// them match `className`. Used to detect the chained
    /// `AppleMesaAccessory` that signals a Touch ID-capable keyboard.
    private static func childMatches(svc: io_registry_entry_t,
                                     className: String) -> Bool {
        let kids = IORegBridge.children(of: svc)
        defer { kids.forEach { IOObjectRelease($0) } }
        for c in kids {
            if let cls = IORegBridge.className(of: c), cls == className {
                return true
            }
        }
        return false
    }

    /// Heuristic friendly name. Apple's USB Magic Keyboard family
    /// shares VendorID 0x05AC (1452); the product-ID values cluster
    /// around 0x0250…0x0322 for keyboards, 0x0265…0x0269 for
    /// trackpads, 0x0220 for the Apple Pencil. Catalogue maintenance
    /// is light — when a PID isn't recognised the row still renders
    /// with "Trusted Accessory" + the raw IDs so the data isn't lost.
    private static func displayName(vendorID: UInt64?,
                                    productIDs: [UInt64],
                                    hasFingerprint: Bool) -> String {
        guard vendorID == 0x05AC || vendorID == 1452 else {
            return "Trusted Accessory"
        }
        // Specific known PIDs first — these are public via lsusb dumps
        // and the IORegistry traces from Apple's HID kexts.
        let knownPID: [UInt64: String] = [
            0x029A: "Magic Keyboard",
            0x029F: "Magic Keyboard with Touch ID",
            0x0321: "Magic Keyboard (USB-C)",
            0x0322: "Magic Keyboard with Touch ID (USB-C)",
            0x029C: "Magic Keyboard with Numeric Keypad",
            0x029E: "Magic Trackpad",
            0x0265: "Magic Trackpad 2",
            0x0269: "Magic Trackpad (USB-C)",
            0x025C: "Magic Mouse",
            0x0220: "Apple Pencil"
        ]
        for pid in productIDs {
            if let known = knownPID[pid] { return known }
        }
        // Fallback by ranges + fingerprint hint.
        if hasFingerprint { return "Magic Keyboard with Touch ID" }
        if productIDs.contains(where: { (0x029A...0x0322).contains($0) }) {
            return "Apple Magic Keyboard"
        }
        if productIDs.contains(where: { (0x0265...0x0269).contains($0) }) {
            return "Apple Magic Trackpad"
        }
        return "Apple Accessory"
    }
}

struct TouchIDSidebarRow: View {
    let info: TouchIDInfo
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "touchid").foregroundStyle(.pink).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Touch ID").lineLimit(1)
                Text(info.product ?? "AppleMesaShim")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

enum TouchIDSelector {
    private static let mask: UInt64 = 0x717D_0070_0000_0001
    static let id = TBNodeID(raw: mask)
    static func isTouchIDID(_ id: TBNodeID) -> Bool { id.raw == mask }
}

// MARK: - Input Devices (trackpad + keyboard)

/// Trackpad + keyboard identification, pulled from
/// `AppleMultitouchDevice` (Force Touch trackpad with multi-touch
/// elements) and `AppleHIDKeyboardEventDriverV2` (built-in keyboard
/// + backlight controller). We surface what we can read directly
/// from IORegistry.
nonisolated struct InputDevicesInfo: Hashable {
    let trackpad: TrackpadInfo?
    let keyboard: KeyboardInfo?

    static let empty = InputDevicesInfo(trackpad: nil, keyboard: nil)

    static func read() -> InputDevicesInfo {
        return InputDevicesInfo(trackpad: TrackpadInfo.read(),
                                keyboard: KeyboardInfo.read())
    }
}

nonisolated struct TrackpadInfo: Hashable {
    let product: String?
    let vendor: String?
    let firmwareVersion: UInt64?
    let multitouchID: UInt64?

    static func read() -> TrackpadInfo? {
        let iter = IORegBridge.services(matchingClass: "AppleMultitouchDevice")
        defer { iter.forEach { IOObjectRelease($0) } }
        guard let svc = iter.first else { return nil }
        let props = IORegBridge.properties(of: svc)
        return TrackpadInfo(
            product: props["Product"]?.asString,
            vendor: props["Manufacturer"]?.asString,
            firmwareVersion: props["Multitouch ID"]?.asUInt,
            multitouchID: props["BCD Version"]?.asUInt
        )
    }
}

nonisolated struct KeyboardInfo: Hashable {
    let product: String?
    let vendor: String?
    let firmwareVersion: UInt64?

    static func read() -> KeyboardInfo? {
        let iter = IORegBridge.services(matchingClass: "AppleHIDKeyboardEventDriverV2")
        defer { iter.forEach { IOObjectRelease($0) } }
        guard let svc = iter.first else { return nil }
        let props = IORegBridge.properties(of: svc)
        return KeyboardInfo(
            product: props["Product"]?.asString,
            vendor: props["Manufacturer"]?.asString,
            firmwareVersion: props["VersionNumber"]?.asUInt
        )
    }
}

struct InputDevicesDetailView: View {
    let info: InputDevicesInfo
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let trackpad = info.trackpad {
                    SectionCard(title: "Trackpad", symbol: "hand.point.up.left.fill") {
                        StatGrid(stats: trackpadStats(trackpad))
                    }
                }
                if let keyboard = info.keyboard {
                    SectionCard(title: "Built-in Keyboard", symbol: "keyboard") {
                        StatGrid(stats: keyboardStats(keyboard))
                    }
                }
                SectionCard(title: "About these devices", symbol: "info.circle") {
                    Text("Apple silicon laptops route the built-in trackpad through `AppleMultitouchDevice` — a Force Touch capacitive sensor whose pressure / position events are interpreted by the multitouch HID driver. The keyboard is wired through `AppleHIDKeyboardEventDriverV2` and shares its backlight controller with the chassis ambient-light sensor.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: "hand.tap").font(.system(size: 32))
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Input Devices").font(.title2).bold()
                Text("Built-in trackpad + keyboard")
                    .foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
        }
    }

    private func trackpadStats(_ tp: TrackpadInfo) -> [Stat] {
        var out: [Stat] = []
        if let p = tp.product { out.append(Stat(label: "Model", value: p, symbol: "rectangle")) }
        if let v = tp.vendor { out.append(Stat(label: "Vendor", value: v, symbol: "building.2")) }
        if let f = tp.firmwareVersion { out.append(Stat(label: "Multitouch ID",
                                                        value: "\(f)",
                                                        symbol: "memorychip")) }
        out.append(Stat(label: "Force Touch",
                        value: "Supported",
                        symbol: "hand.point.up.left.fill"))
        return out
    }

    private func keyboardStats(_ kb: KeyboardInfo) -> [Stat] {
        var out: [Stat] = []
        if let p = kb.product { out.append(Stat(label: "Model", value: p, symbol: "keyboard")) }
        if let v = kb.vendor { out.append(Stat(label: "Vendor", value: v, symbol: "building.2")) }
        if let f = kb.firmwareVersion { out.append(Stat(label: "Firmware",
                                                        value: "\(f)",
                                                        symbol: "memorychip")) }
        return out
    }
}

struct InputDevicesSidebarRow: View {
    let info: InputDevicesInfo
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap").foregroundStyle(.cyan).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Input Devices").lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    private var subtitle: String {
        var parts: [String] = []
        if info.trackpad != nil { parts.append("Trackpad") }
        if info.keyboard != nil { parts.append("Keyboard") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

enum InputDevicesSelector {
    private static let mask: UInt64 = 0x4900_0010_0000_0001
    static let id = TBNodeID(raw: mask)
    static func isInputID(_ id: TBNodeID) -> Bool { id.raw == mask }
}

// MARK: - HID Devices

struct HIDDevicesDetailView: View {
    let snapshot: HIDDevicesSnapshot
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                ForEach(snapshot.grouped, id: \.category) { group in
                    SectionCard(title: "\(group.category.title) (\(group.devices.count))",
                                symbol: group.category.symbol) {
                        VStack(spacing: 0) {
                            ForEach(group.devices) { dev in
                                HIDDeviceRow(device: dev)
                                if dev.id != group.devices.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 720)
        .background(.background)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: "keyboard.macwindow").font(.system(size: 32))
                    .foregroundStyle(.purple)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("HID Devices").font(.title2).bold()
                Text("\(snapshot.devices.count) Human Interface Device services on this host")
                    .foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
        }
    }
}

private struct HIDDeviceRow: View {
    let device: HIDDeviceInfo
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: device.category.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.product ?? device.kernelClass)
                    .font(.callout.weight(.medium))
                if let s = device.subtitle, !s.isEmpty,
                   s != device.product {
                    Text(s).font(.caption2).foregroundStyle(.secondary)
                }
                Text(metaLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if device.builtIn {
                Text("Built-in")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
    }

    private var metaLine: String {
        var parts: [String] = [device.kernelClass]
        if let up = device.usagePage, let u = device.usage {
            parts.append(String(format: "usage 0x%02llX/%llu", up, u))
        }
        if let v = device.vendorID, v > 0 {
            parts.append(String(format: "VID 0x%04llX", v))
        }
        return parts.joined(separator: " · ")
    }
}

struct HIDDevicesSidebarRow: View {
    let snapshot: HIDDevicesSnapshot
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard.macwindow")
                .foregroundStyle(.purple)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("HID Devices").lineLimit(1)
                Text("\(snapshot.devices.count) services")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

enum HIDDevicesSelector {
    private static let mask: UInt64 = 0x4844_0000_0000_0001
    static let id = TBNodeID(raw: mask)
    static func isHIDID(_ id: TBNodeID) -> Bool { id.raw == mask }
}
