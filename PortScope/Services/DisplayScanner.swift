//
//  DisplayScanner.swift
//  PortScope
//
//  Walk every `IOMobileFramebufferShim` (Apple Silicon) and `IOFramebuffer`
//  (Intel hosts) and surface them as `DisplayInfo`. The IOMFB property dict
//  carries DisplayWidth/Height when a panel is lit, plus a refresh window
//  in `IOMFBDisplayRefresh` and a `TimingElements` array describing every
//  mode the panel advertises.
//

import Foundation
import IOKit

nonisolated enum DisplayScanner {
    static func scan() -> DisplaySnapshot {
        var out: [DisplayInfo] = []
        out.append(contentsOf: scanClass("IOMobileFramebufferShim"))
        // Intel hosts publish framebuffers under `IOFramebuffer`. On Apple
        // Silicon this class is empty, so it's safe to scan unconditionally.
        out.append(contentsOf: scanClass("IOFramebuffer"))

        // Sort: built-in first, then connected externals (by name), then
        // idle slots (also by name) so the user sees the lit displays at
        // the top of the section.
        out.sort {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn && !$1.isBuiltIn }
            if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
            return $0.deviceTreeName < $1.deviceTreeName
        }
        return DisplaySnapshot(
            displays: out,
            hdcpChannels: scanHDCPChannels()
        )
    }

    /// Walk every `AppleHDCPInterface` and decode it into a typed
    /// `HDCPChannelState`. The kernel publishes one interface per
    /// potentially-protected output (14 on M5 Max — one per DCP plus
    /// the HDMI / eDP paths); only a subset reports `Role == Transmitter`
    /// at any given time. Channel ordering is stable, so sorting by
    /// channel ID gives the user a predictable table.
    private static func scanHDCPChannels() -> [HDCPChannelState] {
        var out: [HDCPChannelState] = []
        for svc in IORegBridge.services(matchingClass: "AppleHDCPInterface") {
            defer { IOObjectRelease(svc) }
            let props = IORegBridge.properties(of: svc)
            guard let chan = props["HDCPChannel"]?.asUInt else { continue }
            let role = props["HDCPRole"]?.asString
            let transport = Int(props["HDCPTransport"]?.asUInt ?? 0)
            let mask = Int(props["HDCPCapabilityMask"]?.asUInt ?? 0)
            out.append(HDCPChannelState(
                channel: Int(chan),
                isTransmitter: role?.lowercased() == "transmitter",
                roleRaw: role,
                transport: transport,
                capabilityMask: mask,
                txProtocols: readProtocolsArray(props["HDCPTXCapabilities"]),
                rxProtocols: readProtocolsArray(props["HDCPRXCapabilities"])
            ))
        }
        return out.sorted { $0.channel < $1.channel }
    }

    /// `HDCPTXCapabilities` / `HDCPRXCapabilities` are dicts shaped
    /// `{ Protocols = (1, 2) }` — extract the numeric array.
    private static func readProtocolsArray(_ value: IORegValue?) -> [Int] {
        guard case let .dictionary(kv) = value else { return [] }
        for (k, v) in kv where k == "Protocols" {
            if case let .array(arr) = v {
                return arr.compactMap { $0.asUInt.map(Int.init) }
            }
        }
        return []
    }

    private static func scanClass(_ className: String) -> [DisplayInfo] {
        var out: [DisplayInfo] = []
        for svc in IORegBridge.services(matchingClass: className) {
            defer { IOObjectRelease(svc) }
            guard let node = NodeBuilder.build(from: svc) else { continue }
            out.append(buildDisplay(from: node))
        }
        return out
    }

    private static func buildDisplay(from node: TBNode) -> DisplayInfo {
        let props = node.properties

        // `IONameMatched` is the one entry from `IONameMatch` the kext
        // actually bound to — e.g. "disp0,t603x" for the built-in.
        let matched = props["IONameMatched"]?.asString ?? ""
        let deviceTreeName = matched.split(separator: ",").first.map(String.init) ?? "display"

        let width = props["DisplayWidth"]?.asUInt
        let height = props["DisplayHeight"]?.asUInt
        let hasResolution = (width ?? 0) > 0 && (height ?? 0) > 0

        let isBuiltIn = deviceTreeName == "disp0" || deviceTreeName.hasPrefix("disp0")
        let isConnected = hasResolution

        // Refresh range + currently-active rate from TimingElements.
        // Each element's `VerticalAttributes.PreciseSyncRate` is a 16.16
        // fixed-point Hz value (7864320 ≈ 120 Hz, 3932160 = 60 Hz). The
        // kernel publishes the *active* timing's `ID` separately in
        // `DPTimingModeId` — that's what System Settings / system_profiler
        // read to display the current refresh. Don't use `IsPreferred`
        // for this: PreferredTimingElements is the EDID-declared default
        // list (often 60 Hz), not the currently-driven mode.
        //
        // `IOMFBDisplayRefresh` has its own min/max numbers, but those
        // are internal DCP pacing knobs and don't match what the user
        // sees in Settings.
        let activeTimingID = props["DPTimingModeId"]?.asUInt
        var minHz: Double? = nil
        var maxHz: Double? = nil
        var currentHz: Double? = nil
        if case let .array(arr) = props["TimingElements"] {
            for elem in arr {
                guard case let .dictionary(elemKV) = elem else { continue }
                let elemDict = Dictionary(elemKV, uniquingKeysWith: { a, _ in a })
                guard case let .dictionary(vKV) = elemDict["VerticalAttributes"] else { continue }
                let vDict = Dictionary(vKV, uniquingKeysWith: { a, _ in a })
                guard let raw = vDict["PreciseSyncRate"]?.asUInt, raw > 0 else { continue }
                let hz = Double(raw) / 65536.0
                if hz <= 0 { continue }
                minHz = min(minHz ?? hz, hz)
                maxHz = max(maxHz ?? hz, hz)
                if let activeID = activeTimingID,
                   elemDict["ID"]?.asUInt == activeID {
                    currentHz = hz
                }
            }
        }

        // Negotiated color mode — `ColorElements[0]` is the first entry
        // in the engine's preference-ordered list. *Not* a reliable
        // indicator of what's currently lighting the panel: the kernel
        // sorts by an internal Score that often puts HDR-capable modes
        // first regardless of whether HDR is enabled in System
        // Settings. So we surface depth / encoding / color space (which
        // are typically the same across all modes in the list and
        // accurate either way) and skip the dynamic-range field
        // entirely. Falls back to PreferredTimingElements[0].ColorModes
        // when ColorElements is absent.
        let activeMode = activeColorMode(props)
        let bitDepth = activeMode?.depth
        let pixelEncoding = activeMode.flatMap { decodePixelEncoding($0.pixelEncoding) }
        let colorSpace = activeMode.flatMap { decodeColorSpace($0.colorimetry) }

        let timingCount: Int
        if case let .array(arr) = props["TimingElements"] {
            timingCount = arr.count
        } else {
            timingCount = 0
        }

        let accuracy = props["color-accuracy-index"]?.asUInt
        // HDR support: any ColorElement in the negotiated list with
        // DynamicRange = 1, or the kernel's HDR-support flags. This is
        // capability-only — see the model comment for why we don't
        // claim "HDR active" from the kernel side.
        let hasHDRElement: Bool = {
            guard case let .array(arr) = props["ColorElements"] else { return false }
            for elem in arr {
                guard case let .dictionary(kv) = elem else { continue }
                let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
                if d["DynamicRange"]?.asUInt == 1 { return true }
            }
            return false
        }()
        let supportsHDR = hasHDRElement
            || (props["IOMFBSupportsICC"]?.asBool ?? false)
            || (props["IOMFBSupportsHDR"]?.asBool ?? false)
            || (props["IOMFBSupportsGPLite"]?.asBool ?? false)

        // VRR: capability comes from a wider-than-1Hz refresh range
        // (fixed panels publish min == max). Currently-enabled state
        // comes from `QMSVRREnableConfig`, which the DCP flips when
        // adaptive sync is live on the panel.
        let vrrCapable: Bool
        if let lo = minHz, let hi = maxHz {
            vrrCapable = (hi - lo) > 1
        } else {
            vrrCapable = false
        }
        let vrrActive = (props["QMSVRREnableConfig"]?.asUInt ?? 0) != 0

        // Title / subtitle. Subtitle shows the *current* refresh rate
        // (not the range — that goes in the detail view), keeping the
        // sidebar row to one tight line.
        let title: String
        let subtitle: String?
        if isBuiltIn {
            title = "Built-in Display"
            if hasResolution {
                subtitle = "\(width!) × \(height!)\(refreshBadge(currentHz, minHz, maxHz))"
            } else {
                subtitle = nil
            }
        } else if isConnected {
            // Apple's framebuffer doesn't carry a vendor/model name; the
            // best we can do without IODisplayConnect/EDID is "External
            // Display N". Pull the trailing index off the device-tree name.
            let idx = externalIndex(from: deviceTreeName)
            title = idx.map { "External Display \($0)" } ?? "External Display"
            subtitle = hasResolution
                ? "\(width!) × \(height!)\(refreshBadge(currentHz, minHz, maxHz))"
                : nil
        } else {
            let idx = externalIndex(from: deviceTreeName)
            title = idx.map { "External Engine \($0)" } ?? "External Engine"
            subtitle = "Idle — no display attached"
        }

        return DisplayInfo(
            backingID: node.id,
            deviceTreeName: deviceTreeName,
            node: node,
            title: title,
            subtitle: subtitle,
            isConnected: isConnected,
            isBuiltIn: isBuiltIn,
            widthPixels: width,
            heightPixels: height,
            minRefreshHz: minHz,
            maxRefreshHz: maxHz,
            currentRefreshHz: currentHz,
            colorBitDepth: bitDepth,
            pixelEncoding: pixelEncoding,
            colorSpace: colorSpace,
            colorAccuracyIndex: accuracy,
            supportsHDR: supportsHDR,
            variableRefreshCapable: vrrCapable,
            variableRefreshActive: vrrActive,
            timingModeCount: timingCount
        )
    }

    /// One ColorElements entry — the kernel's highest-preference mode.
    /// Fields are 1:1 from the kernel dict.
    private struct ActiveColorMode {
        let depth: UInt64
        let pixelEncoding: UInt64
        let colorimetry: UInt64
    }

    /// Pull the kernel's preferred color mode. `ColorElements` is sorted
    /// by an internal Score; entry 0 is the engine's preference, *not*
    /// necessarily what macOS is driving the panel with (the SDR-vs-HDR
    /// choice lives in user-space). We use this for depth / encoding /
    /// color-space metadata — values that are stable across the
    /// negotiated list — and ignore the DynamicRange flag at the
    /// element level. Falls back to PreferredTimingElements →
    /// ColorModes when ColorElements is missing.
    private static func activeColorMode(_ props: [String: IORegValue]) -> ActiveColorMode? {
        let arr: [IORegValue]
        if case let .array(a) = props["ColorElements"] {
            arr = a
        } else if case let .array(timings) = props["PreferredTimingElements"],
                  case let .dictionary(timingKV) = timings.first,
                  case let .array(modes) = Dictionary(timingKV, uniquingKeysWith: { a, _ in a })["ColorModes"] {
            arr = modes
        } else {
            return nil
        }
        guard case let .dictionary(kv) = arr.first else { return nil }
        let d = Dictionary(kv, uniquingKeysWith: { a, _ in a })
        guard let depth = d["Depth"]?.asUInt else { return nil }
        return ActiveColorMode(
            depth: depth,
            pixelEncoding: d["PixelEncoding"]?.asUInt ?? 0,
            colorimetry: d["Colorimetry"]?.asUInt ?? 0
        )
    }

    /// IOMobileFramebuffer's `PixelEncoding` enum — observed values across
    /// Apple Silicon framebuffers. 0 = RGB is the desktop default; the
    /// YCbCr variants are picked up when an HDMI sink can't sustain RGB
    /// at the negotiated bandwidth (e.g. 4K60 over HDMI 2.0).
    private static func decodePixelEncoding(_ raw: UInt64) -> String? {
        switch raw {
        case 0: return "RGB"
        case 1: return "YCbCr 4:4:4"
        case 2: return "YCbCr 4:2:2"
        case 3: return "YCbCr 4:2:0"
        default: return "Encoding \(raw)"
        }
    }

    /// Apple's `Colorimetry` code — the color-space identifier embedded in
    /// each ColorElements entry. Values observed on Apple Silicon: 0/1
    /// are the CEA-861 SDTV/HDTV codes; 9 is BT.2020 (HDR signalling); 10
    /// is sRGB on external displays; 16 is Apple's Display P3 code used
    /// by the built-in Liquid Retina XDR panel. Unknown codes fall
    /// through with the raw value so future panels surface something
    /// rather than going silent.
    private static func decodeColorSpace(_ raw: UInt64) -> String? {
        switch raw {
        case 0: return "BT.601"
        case 1: return "BT.709"
        case 9: return "BT.2020"
        case 10: return "sRGB"
        case 16: return "Display P3"
        default: return "Colorimetry \(raw)"
        }
    }

    private static func externalIndex(from name: String) -> Int? {
        // "dispext3" → 3, "dispext10" → 10, "disp0" → nil (it's the built-in).
        let prefix = "dispext"
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }

    /// Subtitle refresh badge. Prefer the currently-driven rate; fall
    /// back to the min–max range (for capability rows where the kernel
    /// hasn't marked a `IsPreferred` timing) and finally to the max.
    private static func refreshBadge(_ currentHz: Double?,
                                     _ minHz: Double?,
                                     _ maxHz: Double?) -> String {
        if let curr = currentHz {
            return " · \(Int(curr.rounded())) Hz"
        }
        guard let maxHz else { return "" }
        if let minHz, abs(maxHz - minHz) > 1 {
            return " · \(Int(minHz.rounded()))–\(Int(maxHz.rounded())) Hz"
        }
        return " · \(Int(maxHz.rounded())) Hz"
    }
}
