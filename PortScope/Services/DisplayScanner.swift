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

enum DisplayScanner {
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
        return DisplaySnapshot(displays: out)
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

        // Refresh range from the TimingElements list. Each element's
        // `VerticalAttributes.PreciseSyncRate` is a 16.16 fixed-point Hz
        // value (e.g. 7864320 ≈ 120 Hz, 3932160 = 60 Hz). We pick the
        // lowest and highest unique rates we see across all modes — the
        // `IOMFBDisplayRefresh` dict has refresh-step / idle-interval
        // numbers but they're internal pacing knobs, not the panel's
        // actual range.
        var minHz: Double? = nil
        var maxHz: Double? = nil
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
            }
        }

        // Pull the preferred timing's ColorMode for the bit depth.
        var bitDepth: UInt64? = nil
        if case let .array(arr) = props["PreferredTimingElements"], case let .dictionary(elementKV) = arr.first {
            let elem = Dictionary(elementKV, uniquingKeysWith: { a, _ in a })
            if case let .array(modes) = elem["ColorModes"], case let .dictionary(modeKV) = modes.first {
                let mode = Dictionary(modeKV, uniquingKeysWith: { a, _ in a })
                bitDepth = mode["Depth"]?.asUInt
            }
        }

        let timingCount: Int
        if case let .array(arr) = props["TimingElements"] {
            timingCount = arr.count
        } else {
            timingCount = 0
        }

        let accuracy = props["color-accuracy-index"]?.asUInt
        let supportsHDR = (props["IOMFBSupportsICC"]?.asBool ?? false)
            || (props["IOMFBSupportsHDR"]?.asBool ?? false)
            || (props["IOMFBSupportsGPLite"]?.asBool ?? false)

        // Title / subtitle.
        let title: String
        let subtitle: String?
        if isBuiltIn {
            title = "Built-in Display"
            if hasResolution {
                subtitle = "\(width!) × \(height!)\(refreshBadge(minHz, maxHz))"
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
                ? "\(width!) × \(height!)\(refreshBadge(minHz, maxHz))"
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
            colorBitDepth: bitDepth,
            colorAccuracyIndex: accuracy,
            supportsHDR: supportsHDR,
            timingModeCount: timingCount
        )
    }

    private static func externalIndex(from name: String) -> Int? {
        // "dispext3" → 3, "dispext10" → 10, "disp0" → nil (it's the built-in).
        let prefix = "dispext"
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }

    private static func refreshBadge(_ minHz: Double?, _ maxHz: Double?) -> String {
        guard let maxHz else { return "" }
        if let minHz, abs(maxHz - minHz) > 1 {
            return " · \(Int(minHz.rounded()))–\(Int(maxHz.rounded())) Hz"
        }
        return " · \(Int(maxHz.rounded())) Hz"
    }
}
