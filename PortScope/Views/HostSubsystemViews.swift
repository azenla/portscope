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
                // Connected-network first — that's the live state the user
                // came to see. Identity / driver / adapter capabilities
                // follow below.
                if info.currentSSID != nil {
                    SectionCard(title: "Current Network", symbol: "wifi") {
                        StatGrid(stats: networkStats)
                    }
                    if hasLinkQuality {
                        SectionCard(title: "Link Quality", symbol: "wave.3.right") {
                            VStack(alignment: .leading, spacing: 10) {
                                signalNoiseBar
                                StatGrid(stats: linkQualityStats)
                            }
                        }
                    }
                }
                SectionCard(title: "Adapter", symbol: "antenna.radiowaves.left.and.right") {
                    StatGrid(stats: identityStats)
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

    private var hasLinkQuality: Bool {
        info.rssiDBm != nil || info.noiseDBm != nil
            || info.transmitRateMbps != nil || info.mcsIndex != nil
    }

    /// Visual SNR bar — fills proportional to a clamped 0–70 dB SNR scale.
    /// Anything ≥40 dB is "excellent" (green); 25–40 is good (blue); 15–25
    /// is fair (orange); <15 is poor (red).
    @ViewBuilder
    private var signalNoiseBar: some View {
        let snr = (info.rssiDBm.flatMap { rssi in info.noiseDBm.map { rssi - $0 } }) ?? 0
        let clamped = max(0, min(70, snr))
        let frac = Double(clamped) / 70.0
        let color: Color = clamped >= 40 ? .green
            : clamped >= 25 ? .blue
            : clamped >= 15 ? .orange
            : .red
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Signal-to-Noise Ratio")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(snr) dB")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            .frame(width: 140, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 12)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * frac, height: 12)
                }
            }
            .frame(height: 12)
            Text(qualityLabel(snr: snr))
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func qualityLabel(snr: Int) -> String {
        if snr >= 40 { return "Excellent" }
        if snr >= 25 { return "Good" }
        if snr >= 15 { return "Fair" }
        return "Poor"
    }

    private var linkQualityStats: [Stat] {
        var out: [Stat] = []
        if let rssi = info.rssiDBm {
            out.append(Stat(label: "Signal (RSSI)",
                            value: "\(rssi) dBm",
                            symbol: "wave.3.right"))
        }
        if let noise = info.noiseDBm {
            out.append(Stat(label: "Noise Floor",
                            value: "\(noise) dBm",
                            symbol: "waveform.path.ecg"))
        }
        if let rate = info.transmitRateMbps {
            out.append(Stat(label: "Transmit Rate",
                            value: "\(rate) Mbps",
                            symbol: "speedometer"))
        }
        if let mcs = info.mcsIndex {
            out.append(Stat(label: "MCS Index",
                            value: "\(mcs)",
                            symbol: "tag"))
        }
        return out
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
        if let security = info.security {
            out.append(Stat(label: "Security", value: security,
                            symbol: "lock"))
        }
        if let type = info.networkType {
            out.append(Stat(label: "Network Type", value: type,
                            symbol: "network"))
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
    /// Optional ISP front-end info — supplied by the snapshot, used
    /// when this row represents the built-in camera (i.e. not a
    /// Continuity / iPhone webcam).
    var isp: CameraISPInfo? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: stats)
                if isBuiltInCamera, let isp = isp {
                    SectionCard(title: "Image Signal Processor",
                                symbol: "viewfinder.circle") {
                        VStack(alignment: .leading, spacing: 10) {
                            if isp.isExclaveIsolated {
                                ExclaveBadge()
                            }
                            StatGrid(stats: ispStats(isp))
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620)
        .background(.background)
    }

    /// Continuity webcams (paired iPhone, etc.) report an Apple device
    /// model identifier like `"iPhone18,2"`. Built-in cameras either
    /// don't publish a modelID at all or use a "Camera"-suffixed string
    /// like `"FaceTime HD Camera (Built-in)"`. Anything `iPhone…` or
    /// `iPad…` is treated as external; everything else is built-in.
    private var isBuiltInCamera: Bool {
        guard let m = camera.modelID else { return true }
        let lower = m.lowercased()
        return !(lower.hasPrefix("iphone") || lower.hasPrefix("ipad"))
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

    private func ispStats(_ isp: CameraISPInfo) -> [Stat] {
        var out: [Stat] = []
        // ISP kext class doubles as the silicon-generation tell
        // ("AppleH16CamIn" → M5/T6050 class). Useful when correlating
        // with the chip / system-firmware version on this page.
        out.append(Stat(label: "Driver", value: isp.kextClass,
                        symbol: "cpu"))
        if let v = isp.firmwareVersion {
            out.append(Stat(label: "Firmware", value: v,
                            symbol: "memorychip"))
        }
        if let d = isp.firmwareLinkDate {
            out.append(Stat(label: "Firmware Link Date", value: d,
                            symbol: "calendar"))
        }
        out.append(Stat(label: "Firmware Loaded",
                        value: isp.firmwareLoaded ? "Yes" : "No",
                        symbol: "checkmark.circle"))
        if isp.frontCameraExpected {
            out.append(Stat(label: "Camera",
                            value: cameraStateLabel(isp),
                            symbol: "video.fill"))
        }
        if let s = isp.frontCameraModuleSerial, !s.isEmpty {
            out.append(Stat(label: "Module Serial", value: s,
                            symbol: "barcode", isSecret: true))
        }
        if let s = isp.frontIRProjectorSerial, !s.isEmpty, s != "XXXXXXXX" {
            // The MacBook Pro chassis publishes a placeholder
            // ("XXXXXXXX") for the IR projector serial because it
            // doesn't actually have a structured-light projector.
            // Skip the row when the placeholder is in effect — only
            // chassis with Face ID-class IR populate this for real.
            out.append(Stat(label: "IR Projector Serial", value: s,
                            symbol: "dot.radiowaves.left.and.right",
                            isSecret: true))
        }
        return out
    }

    private func cameraStateLabel(_ isp: CameraISPInfo) -> String {
        if isp.frontCameraStreaming { return "Streaming" }
        if isp.frontCameraActive { return "Active (idle)" }
        return "Powered down"
    }
}

/// Small "Exclave-isolated" pill, rendered alongside any node whose
/// kernel object reports `IOExclaveProxy = Yes` on M5 / T6050+ hosts.
/// Reused across detail views so the visual is consistent.
struct ExclaveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
            Text("Isolated by Exclaves")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(Color.purple)
        .background(
            Capsule().fill(Color.purple.opacity(0.12))
        )
        .help("This engine runs in the secure-world Exclaves domain. "
              + "The kernel communicates with it only through a proxy "
              + "service rather than touching its memory directly.")
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

// MARK: - Storage

struct StorageDetailView: View {
    let storage: InternalStorageInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                StatGrid(stats: stats)
                if !storage.volumes.isEmpty {
                    SectionCard(title: "Volumes (\(storage.volumes.count))",
                                symbol: "externaldrive.connected.to.line.below") {
                        VStack(spacing: 0) {
                            ForEach(storage.volumes) { v in
                                VolumeRow(volume: v)
                                if v.id != storage.volumes.last?.id { Divider() }
                            }
                        }
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
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 84, height: 84)
                Image(systemName: "internaldrive").font(.system(size: 32))
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(storage.model ?? "Internal SSD").font(.title2).bold()
                if let cn = storage.controllerName {
                    Text(cn).foregroundStyle(.secondary).font(.callout)
                }
                if let cap = storage.capacityBytes {
                    Text(formatBytes(cap)).foregroundStyle(.secondary).font(.callout)
                }
            }
            Spacer()
            if let smart = storage.smartStatus {
                Text(smart)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(smart == "Verified" ? .green : .orange)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background((smart == "Verified" ? Color.green : Color.orange).opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private var stats: [Stat] {
        var out: [Stat] = []
        if let m = storage.model {
            out.append(Stat(label: "Model", value: m, symbol: "internaldrive"))
        }
        if let c = storage.controllerName {
            out.append(Stat(label: "Controller", value: c, symbol: "cpu"))
        }
        if let cap = storage.capacityBytes {
            out.append(Stat(label: "Capacity", value: formatBytes(cap),
                            symbol: "externaldrive"))
        }
        if let fw = storage.firmware {
            out.append(Stat(label: "Firmware",
                            value: fw.replacingOccurrences(of: ",", with: ""),
                            symbol: "memorychip"))
        }
        if let bsd = storage.bsdName {
            out.append(Stat(label: "BSD Name", value: bsd, symbol: "terminal"))
        }
        if let trim = storage.trimSupported {
            out.append(Stat(label: "TRIM",
                            value: trim ? "Supported" : "Not Supported",
                            symbol: "scissors"))
        }
        if let smart = storage.smartStatus {
            out.append(Stat(label: "S.M.A.R.T.", value: smart,
                            symbol: "heart.text.square"))
        }
        if let map = storage.partitionMapType {
            out.append(Stat(label: "Partition Map", value: map, symbol: "tablecells"))
        }
        if let rm = storage.removable {
            out.append(Stat(label: "Removable",
                            value: rm ? "Yes" : "No",
                            symbol: "eject"))
        }
        if let s = storage.serial {
            out.append(Stat(label: "Serial", value: s,
                            symbol: "barcode", isSecret: true))
        }
        return out
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useTB]
        fmt.countStyle = .decimal
        return fmt.string(fromByteCount: Int64(bytes))
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: volumeSymbol)
                .foregroundStyle(.green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(volume.name).font(.callout.weight(.medium))
                    if let bsd = volume.bsdName {
                        Text(bsd).font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let cap = volume.capacityBytes {
                Text(formatVolumeBytes(cap))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var volumeSymbol: String {
        switch volume.content {
        case "Apple_APFS_ISC": return "shield.lefthalf.filled"
        case "Apple_APFS_Recovery": return "lifepreserver"
        case "Apple_APFS": return "internaldrive"
        default: return "doc"
        }
    }
    private var subtitle: String? { volume.content }

    private func formatVolumeBytes(_ bytes: UInt64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB, .useTB]
        fmt.countStyle = .decimal
        return fmt.string(fromByteCount: Int64(bytes))
    }
}

struct StorageSidebarRow: View {
    let storage: InternalStorageInfo
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive").foregroundStyle(.green).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(storage.model ?? "Internal SSD").lineLimit(1)
                if let cap = storage.capacityBytes {
                    Text(formatCapacity(cap))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatCapacity(_ bytes: UInt64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useTB]
        fmt.countStyle = .decimal
        return fmt.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Memory

struct MemoryDetailView: View {
    let dimms: [MemoryDIMMInfo]
    let totalBytes: UInt64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                ForEach(dimms) { dimm in
                    SectionCard(title: dimm.slot.map { "\(dimm.name) · \($0)" } ?? dimm.name,
                                symbol: "memorychip") {
                        StatGrid(stats: dimmStats(dimm))
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
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.indigo.opacity(0.15)).frame(width: 84, height: 84)
                Image(systemName: "memorychip").font(.system(size: 32))
                    .foregroundStyle(.indigo)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(totalBytes.map { formatMemoryBytes($0) } ?? "Memory")
                    .font(.title2).bold()
                Text("\(dimms.count) module\(dimms.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
        }
    }

    private func dimmStats(_ d: MemoryDIMMInfo) -> [Stat] {
        var out: [Stat] = []
        if let cap = d.capacityBytes {
            out.append(Stat(label: "Capacity", value: formatMemoryBytes(cap),
                            symbol: "memorychip"))
        }
        if let t = d.type {
            out.append(Stat(label: "Type", value: t,
                            symbol: "rectangle.connected.to.line.below"))
        }
        if let m = d.manufacturer {
            out.append(Stat(label: "Manufacturer", value: m, symbol: "building.2"))
        }
        if let s = d.speed {
            out.append(Stat(label: "Speed", value: s, symbol: "speedometer"))
        }
        if let p = d.partNumber {
            out.append(Stat(label: "Part Number", value: p, symbol: "barcode"))
        }
        if let slot = d.slot {
            out.append(Stat(label: "Slot", value: slot, symbol: "tray"))
        }
        return out
    }

    private func formatMemoryBytes(_ bytes: UInt64) -> String {
        let gib = bytes / (1024 * 1024 * 1024)
        if gib >= 1024 {
            let tib = Double(bytes) / Double(1024 * 1024 * 1024 * 1024)
            return String(format: "%.0f TB", tib)
        }
        return "\(gib) GB"
    }
}

struct MemorySidebarRow: View {
    let info: SystemInfoSnapshot
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip").foregroundStyle(.indigo).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(memoryTitle).lineLimit(1)
                if let s = memorySubtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var memoryTitle: String {
        guard let bytes = info.memoryBytes else { return "Memory" }
        let gib = bytes / (1024 * 1024 * 1024)
        return "\(gib) GB"
    }

    private var memorySubtitle: String? {
        var parts: [String] = []
        if let t = info.memoryType { parts.append(t) }
        if let m = info.memoryManufacturer { parts.append(m) }
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

enum StorageSelector {
    private static let mask: UInt64 = 0x5700_DA7A_0000_0001
    static let id = TBNodeID(raw: mask)
    static func isStorageID(_ id: TBNodeID) -> Bool { id.raw == mask }
}

enum MemorySelector {
    private static let mask: UInt64 = 0x5757_DEAD_0000_0001
    static let id = TBNodeID(raw: mask)
    static func isMemoryID(_ id: TBNodeID) -> Bool { id.raw == mask }
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
