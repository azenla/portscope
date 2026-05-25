//
//  HostSubsystemViews.swift
//  PortScope
//
//  Curated detail views for host-side subsystems that don't live cleanly
//  under USB / TB / PCIe trees: Wi-Fi adapter, the built-in + Continuity
//  cameras, and audio devices (built-in speakers / mic + any HDMI / USB
//  / Bluetooth / AirPlay sink).
//
//  Each of these is its own sidebar entry under the "Show All Devices"
//  area so the user can navigate to it directly — they're not really
//  part of "System Overview", they're peer devices a hardware-viewer
//  ought to surface alongside Bluetooth and Displays.
//

import SwiftUI

// MARK: - Wi-Fi

struct WiFiDetailView: View {
    let info: WiFiInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: identityStats)
                SectionCard(title: "Current Network", symbol: "wifi") {
                    StatGrid(stats: networkStats)
                }
                if let revision = info.firmwareRevision {
                    SectionCard(title: "Driver / Firmware", symbol: "memorychip") {
                        Text(revision)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    private var hero: some View {
        let color: Color = (info.currentSSID != nil) ? .blue : .secondary
        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 84, height: 84)
                Image(systemName: "wifi")
                    .font(.system(size: 32))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(info.chipset ?? "Wi-Fi Adapter").font(.title2).bold()
                if let sub = subline {
                    Text(sub).foregroundStyle(.secondary).font(.callout)
                }
            }
            Spacer()
            if let tier = wifiTier {
                Text(tier)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var subline: String? {
        var parts: [String] = []
        if let iface = info.interface { parts.append(iface) }
        if let status = info.status { parts.append(status) }
        if let ssid = info.currentSSID { parts.append("on \(ssid)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Highest marketing tier the adapter advertises: "Wi-Fi 7" when `be`
    /// is in the supported PHY list, then 6E, 6, 5, etc.
    private var wifiTier: String? {
        guard let phys = info.supportedPHYs?.lowercased() else { return nil }
        if phys.contains("be") {
            return info.supports6GHz ? "Wi-Fi 7" : "Wi-Fi 7"
        }
        if phys.contains("ax") { return info.supports6GHz ? "Wi-Fi 6E" : "Wi-Fi 6" }
        if phys.contains("ac") { return "Wi-Fi 5" }
        if phys.contains("n")  { return "Wi-Fi 4" }
        return nil
    }

    private var identityStats: [Stat] {
        var out: [Stat] = []
        if let chipset = info.chipset {
            out.append(Stat(label: "Chipset", value: chipset,
                            symbol: "antenna.radiowaves.left.and.right"))
        }
        if let iface = info.interface {
            out.append(Stat(label: "Interface", value: iface, symbol: "terminal"))
        }
        if let phys = info.supportedPHYs {
            out.append(Stat(label: "Supported PHYs", value: phys,
                            symbol: "waveform.path"))
        }
        out.append(Stat(label: "6 GHz Band",
                        value: info.supports6GHz ? "Supported" : "Not Supported",
                        symbol: "wave.3.right"))
        if let region = info.regulatoryRegion {
            out.append(Stat(label: "Regulatory", value: region, symbol: "globe"))
        }
        if let mac = info.macAddress {
            out.append(Stat(label: "MAC Address", value: mac.uppercased(),
                            symbol: "barcode", isSecret: true))
        }
        return out
    }

    private var networkStats: [Stat] {
        var out: [Stat] = []
        out.append(Stat(label: "Status",
                        value: info.status ?? "—",
                        symbol: info.currentSSID != nil
                            ? "checkmark.circle.fill" : "circle.dashed"))
        if let ssid = info.currentSSID {
            out.append(Stat(label: "Network", value: ssid,
                            symbol: "wifi", isSecret: true))
        }
        if let phy = info.currentPHY {
            out.append(Stat(label: "Active PHY", value: phy, symbol: "waveform"))
        }
        if let chan = info.currentChannel {
            out.append(Stat(label: "Channel", value: chan, symbol: "dial.medium"))
        }
        return out
    }
}

// MARK: - Camera

struct CameraDetailView: View {
    let camera: CameraInfo

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
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: "camera").font(.system(size: 32))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.name).font(.title2).bold()
                if let m = camera.modelID, m != camera.name {
                    Text(m).foregroundStyle(.secondary).font(.callout)
                }
            }
            Spacer()
        }
    }

    private var stats: [Stat] {
        var out: [Stat] = []
        out.append(Stat(label: "Name", value: camera.name, symbol: "camera"))
        if let m = camera.modelID {
            out.append(Stat(label: "Model ID", value: m, symbol: "tag"))
        }
        if let u = camera.uniqueID {
            out.append(Stat(label: "Unique ID", value: u,
                            symbol: "number", isSecret: true))
        }
        return out
    }
}

// MARK: - Audio

struct AudioDeviceDetailView: View {
    let device: AudioDeviceInfo

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
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: iconForTransport(device.transport))
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.title2).bold()
                if let s = subline {
                    Text(s).foregroundStyle(.secondary).font(.callout)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if device.isDefaultOutput {
                    AudioBadge(text: "Default Out", color: .green)
                }
                if device.isDefaultInput {
                    AudioBadge(text: "Default In", color: .indigo)
                }
            }
        }
    }

    private var subline: String? {
        var parts: [String] = []
        if let m = device.manufacturer, !m.isEmpty { parts.append(m) }
        if let t = device.transport, !t.isEmpty { parts.append(t) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var stats: [Stat] {
        var out: [Stat] = []
        if let m = device.manufacturer {
            out.append(Stat(label: "Manufacturer", value: m, symbol: "building.2"))
        }
        if let t = device.transport {
            out.append(Stat(label: "Transport", value: t,
                            symbol: iconForTransport(t)))
        }
        if let oc = device.outputChannels, oc > 0 {
            out.append(Stat(label: "Output Channels", value: "\(oc)",
                            symbol: "speaker.wave.2"))
        }
        if let ic = device.inputChannels, ic > 0 {
            out.append(Stat(label: "Input Channels", value: "\(ic)",
                            symbol: "mic"))
        }
        if let r = device.sampleRateHz, r > 0 {
            let khz = Double(r) / 1000.0
            let display = khz.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f kHz", khz)
                : String(format: "%.1f kHz", khz)
            out.append(Stat(label: "Sample Rate", value: display, symbol: "waveform"))
        }
        out.append(Stat(label: "Default Output",
                        value: device.isDefaultOutput ? "Yes" : "No",
                        symbol: "checkmark.circle"))
        out.append(Stat(label: "Default Input",
                        value: device.isDefaultInput ? "Yes" : "No",
                        symbol: "checkmark.circle"))
        return out
    }
}

private struct AudioBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

/// Map an SP transport string to a hero icon. Used by both AudioRow
/// (inside System Overview, before the move) and `AudioDeviceDetailView`.
nonisolated func iconForTransport(_ t: String?) -> String {
    switch t {
    case "HDMI": return "tv"
    case "USB": return "cable.connector"
    case "Bluetooth": return "dot.radiowaves.left.and.right"
    case "AirPlay": return "airplayaudio"
    case "Built-in": return "macbook"
    default: return "speaker.wave.2"
    }
}

// MARK: - Sidebar rows

struct WiFiSidebarRow: View {
    let info: WiFiInfo
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
                .foregroundStyle((info.currentSSID != nil) ? Color.blue : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.chipset ?? "Wi-Fi").lineLimit(1)
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let ssid = info.currentSSID { parts.append("on \(ssid)") }
        else if let status = info.status { parts.append(status) }
        if let phy = info.currentPHY { parts.append(phy) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct CameraSidebarRow: View {
    let camera: CameraInfo
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera").foregroundStyle(.blue).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(camera.name).lineLimit(1)
                if let m = camera.modelID, m != camera.name {
                    Text(m).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct AudioSidebarRow: View {
    let device: AudioDeviceInfo
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForTransport(device.transport))
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(device.name).lineLimit(1)
                    if device.isDefaultOutput {
                        Text("OUT").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if device.isDefaultInput {
                        Text("IN").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let t = device.transport, !t.isEmpty { parts.append(t) }
        if let mfr = device.manufacturer, !mfr.isEmpty { parts.append(mfr) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Synthetic selectors

/// Sidebar selection for the Wi-Fi adapter row. Single-instance per host.
enum WiFiSelector {
    private static let mask: UInt64 = 0x5757_FB7F_0000_0001
    static let id = TBNodeID(raw: mask)
    static func isWiFiID(_ id: TBNodeID) -> Bool { id.raw == mask }
}

/// Synthetic IDs for camera rows. `SPCameraDataType` gives us a per-device
/// `Unique ID` (a UUID-like string); when present we hash it into the low
/// bits so each camera gets a stable id across rescans. Without a unique
/// ID we fall back to hashing the device name.
enum CameraSelector {
    private static let mask: UInt64 = 0xCA17_E5A0_0000_0000

    static func id(for camera: CameraInfo) -> TBNodeID {
        let h = UInt64(bitPattern: Int64(camera.id.hashValue)) & 0xFFFF_FFFF
        return TBNodeID(raw: mask | h)
    }
    static func isCameraID(_ id: TBNodeID) -> Bool {
        (id.raw & 0xFFFF_FFFF_0000_0000) == mask
    }
}

/// Same trick for audio device rows. The device name (which SP always
/// publishes uniquely per device) is the hash source.
enum AudioSelector {
    private static let mask: UInt64 = 0xA4D1_0000_0000_0000

    static func id(for device: AudioDeviceInfo) -> TBNodeID {
        let h = UInt64(bitPattern: Int64(device.id.hashValue)) & 0xFFFF_FFFF
        return TBNodeID(raw: mask | h)
    }
    static func isAudioID(_ id: TBNodeID) -> Bool {
        (id.raw & 0xFFFF_FFFF_0000_0000) == mask
    }
}
