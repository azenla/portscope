//
//  DisplayModels.swift
//  PortScope
//
//  Domain model for displays attached to the host. On Apple Silicon the
//  display pipeline is anchored at `IOMobileFramebufferShim` instances under
//  the SoC's display crossbar — one for the built-in panel and one per
//  external display engine. Idle external slots are kept so the user can see
//  how many displays the silicon can drive vs how many are currently lit.
//

import Foundation
import SwiftUI

nonisolated struct DisplaySnapshot {
    /// One entry per `IOMobileFramebufferShim` (Apple Silicon) or
    /// `IOFramebuffer` (Intel). Sorted with built-in first, then connected
    /// externals, then idle slots.
    let displays: [DisplayInfo]
    /// Per-channel HDCP state pulled from `AppleHDCPInterface` siblings
    /// of the DCP pipelines. Apple publishes one channel per
    /// potentially-protected output; only a subset has `Role =
    /// Transmitter` at any given time (those are the actively-protected
    /// links). Channel-to-display attribution isn't published anywhere
    /// stable, so we surface the channel list aggregate rather than per-
    /// display — keeps the data honest. Empty on Intel hosts.
    let hdcpChannels: [HDCPChannelState]
    /// Internal-panel timing-controller chip identification (Parade
    /// DP855 on M3 16" / M5 16", DP825 on M3 14"). Nil when no TCON
    /// driver is loaded — desktops and external-display-only chassis.
    /// Per `design/IOService-Updates.md` M4.
    let panelTCON: PanelTCONInfo?

    static let empty = DisplaySnapshot(displays: [], hdcpChannels: [], panelTCON: nil)

    var connectedCount: Int { displays.filter { $0.isConnected }.count }
    var totalCount: Int { displays.count }
}

/// Parses to the internal-panel TCON chip identification. The kernel's
/// class name itself encodes the chip (`AppleParadeDP855TCON` /
/// `AppleParadeDP825TCON`), and `IONameMatch` carries a more
/// human-friendly token (`parade,DP855`). Both surface in the
/// Developer Details disclosure on the built-in display row.
nonisolated struct PanelTCONInfo: Hashable {
    /// IOKit class name of the matched driver, e.g. `"AppleParadeDP855TCON"`.
    let kextClass: String
    /// Human-readable chip name extracted from the class, e.g. `"Parade DP855"`.
    let chipName: String
    /// `IONameMatched` token from the registry, e.g. `"parade,DP855"`.
    /// Surfaced for parity with grep-friendly device-tree dumps.
    let nameMatch: String?
    /// Hex model code parsed out of the kext's `model` property.
    /// Optional — only present on chips that publish one.
    let modelCode: String?
}

/// One `AppleHDCPInterface` channel decoded into typed fields. Documented
/// in `design/IOService-Updates.md` H2; field shapes confirmed live on
/// an M5 Max where the channels span 0–13 (14 total).
nonisolated struct HDCPChannelState: Hashable, Identifiable {
    var id: UInt64 { UInt64(channel) }
    /// `HDCPChannel` — kernel-assigned channel ID. Stable across reboot
    /// on a given chassis but not portable across machines.
    let channel: Int
    /// True when `HDCPRole == "Transmitter"`. That's the kernel's
    /// signal that an output is actively negotiating HDCP. Inactive
    /// channels report `"(None - Not Open)"`.
    let isTransmitter: Bool
    /// Raw role string for the developer-details disclosure.
    let roleRaw: String?
    /// `HDCPTransport` — 0 = DisplayPort path (USB-C alt-mode + TB
    /// tunnels), 1 = HDMI / embedded DisplayPort (internal panel link
    /// + HDMI receptacle). Lets the view classify channels even when
    /// none are active.
    let transport: Int
    /// `HDCPCapabilityMask` — bitmask: bit `1` = HDCP 1.x available,
    /// bit `2` = HDCP 2.x available. Most channels expose both;
    /// HDMI-only outputs sometimes mask off 1.x.
    let capabilityMask: Int
    /// Decoded host-side protocol support (TX side of the link).
    /// `(1, 2)` = HDCP 1.x + 2.x, `()` = unsupported (idle channel).
    let txProtocols: [Int]
    /// Decoded downstream protocol support (RX side — the connected
    /// sink). `()` until a sink is attached and authenticated.
    let rxProtocols: [Int]
}

extension HDCPChannelState {
    /// Short transport label — "DP / USB-C" for transport 0, "HDMI /
    /// eDP" for transport 1. Used in the chip + table rows.
    var transportLabel: String {
        switch transport {
        case 0: return "DP / USB-C"
        case 1: return "HDMI / eDP"
        default: return "Transport \(transport)"
        }
    }
    /// Highest HDCP revision the host advertises as TX-capable on this
    /// channel ("HDCP 2.x", "HDCP 1.x"), or nil when the channel
    /// advertises nothing (truly disabled).
    var txMaxLabel: String? {
        if txProtocols.contains(2) { return "HDCP 2.x" }
        if txProtocols.contains(1) { return "HDCP 1.x" }
        return nil
    }
    var rxMaxLabel: String? {
        if rxProtocols.contains(2) { return "HDCP 2.x" }
        if rxProtocols.contains(1) { return "HDCP 1.x" }
        return nil
    }
}

/// One DisplayPort / HDMI output rooted at a physical port, with the
/// external displays attributed to it. When the display sits on a dock the
/// dock's TB router exposes one `DP or HDMI Adapter` function adapter per
/// physical jack (the Anker Prime has three; others have two HDMI + one
/// DP, etc.). Adapters with a non-empty `Hop Table` are the ones actively
/// carrying a stream — those become the rows we render. For directly-
/// attached panels (USB-C alt-mode) there's no dock router to grab
/// adapters off, so `adapter` is nil and the display nests straight under
/// the port.
nonisolated struct PortDisplayOutput: Hashable, Identifiable {
    /// The DP/HDMI function adapter on the dock's router. Nil for
    /// direct-attach where the display routes through the host's lane
    /// adapter without an intermediate function adapter we can name.
    let adapter: TBNode?
    /// 1-based row label. Adapter-backed outputs are numbered in
    /// adapter-port-number order so the labels are stable across rescans.
    let ordinal: Int
    /// Displays attributed to this output. Usually 1; can be 0 when a DP
    /// adapter is active but no `DisplayInfo` lines up (rare — see
    /// `displayOutputsAttributed` for the count-mismatch fallback).
    let displays: [DisplayInfo]

    var id: TBNodeID {
        adapter?.id ?? TBNodeID(raw: 0xD15B_0000_0000_0000 | UInt64(ordinal))
    }
}

/// Loose heuristic for attributing external displays to physical ports.
/// The IOService plane doesn't expose a clean port→display link on Apple
/// Silicon, so we lean on runtime signals: DP alt-mode (`carriesDisplay`)
/// for directly-attached panels, or the presence of a DisplayPort TB
/// tunnel for displays carried through a dock. Rules:
///
/// * If exactly one port carries a display, all externals go to it.
/// * If N ports = N externals, pair them 1:1 in (port-number ASC,
///   dispext-name ASC) order.
/// * Otherwise surface every external under every display-carrying port
///   (better to repeat than to vanish — the user can mentally disambiguate).
///
/// Returns the displays that should be shown under `port` in the UI.
/// Shared by the sidebar (per-port display rows) and the port detail view
/// (Displays card) so both see the same attribution.
nonisolated func displaysAttributed(to port: PhysicalPort,
                                    allPorts: [PhysicalPort],
                                    allDisplays: [DisplayInfo]) -> [DisplayInfo] {
    guard portCarriesAnyDisplay(port) else { return [] }
    let dpPorts = allPorts
        .filter(portCarriesAnyDisplay)
        .sorted { $0.number < $1.number }
    let externals = allDisplays
        .filter { !$0.isBuiltIn && $0.isConnected }
        .sorted { $0.deviceTreeName < $1.deviceTreeName }
    guard !externals.isEmpty, !dpPorts.isEmpty else { return [] }
    if dpPorts.count == 1 { return externals }
    if dpPorts.count == externals.count,
       let idx = dpPorts.firstIndex(where: { $0.id == port.id }) {
        return [externals[idx]]
    }
    return externals
}

/// Per-output breakdown for the sidebar / detail view. Splits the displays
/// already attributed to a port (`displaysAttributed`) across the active
/// DP/HDMI function adapters on the dock's router. If the port has no
/// dock (direct-attach), returns a single output with `adapter == nil`
/// carrying all the attributed displays. Empty when the port carries no
/// display at all.
nonisolated func displayOutputsAttributed(to port: PhysicalPort,
                                          allPorts: [PhysicalPort],
                                          allDisplays: [DisplayInfo]) -> [PortDisplayOutput] {
    let attributed = displaysAttributed(to: port,
                                        allPorts: allPorts,
                                        allDisplays: allDisplays)
    guard !attributed.isEmpty else { return [] }
    let adapters = activeDPOutputAdapters(in: port)
    guard !adapters.isEmpty else {
        return [PortDisplayOutput(adapter: nil, ordinal: 1, displays: attributed)]
    }
    if adapters.count == 1 {
        return [PortDisplayOutput(adapter: adapters[0], ordinal: 1, displays: attributed)]
    }
    if adapters.count == attributed.count {
        return adapters.enumerated().map { idx, a in
            PortDisplayOutput(adapter: a, ordinal: idx + 1, displays: [attributed[idx]])
        }
    }
    // Counts mismatch: render every adapter row but only attach a display
    // where we can. Leftover adapters render empty (still useful — the
    // user can see "this output is wired up but I don't know which panel").
    return adapters.enumerated().map { idx, a in
        let mine = idx < attributed.count ? [attributed[idx]] : []
        return PortDisplayOutput(adapter: a, ordinal: idx + 1, displays: mine)
    }
}

/// DP/HDMI function adapters on the port's connected router that have a
/// non-empty `Hop Table` — the kernel's authoritative "this tunnel is
/// up" signal for function adapters. Sorted by adapter port number so
/// the resulting list is stable across rescans.
nonisolated func activeDPOutputAdapters(in port: PhysicalPort) -> [TBNode] {
    guard let connected = port.connectedDevice else { return [] }
    var out: [TBNode] = []
    for child in connected.routerNode.children where child.kind == .port {
        let desc = child.properties["Description"]?.asString ?? ""
        guard desc == "DP or HDMI Adapter" else { continue }
        if case let .array(arr) = child.properties["Hop Table"], !arr.isEmpty {
            out.append(child)
        }
    }
    return out.sorted {
        ($0.properties["Port Number"]?.asUInt ?? 0)
            < ($1.properties["Port Number"]?.asUInt ?? 0)
    }
}

/// A port "carries a display" if either DP alt-mode is active (direct
/// monitor on USB-C / MagSafe) or a DisplayPort tunnel exists on the TB
/// router (a display routed through a Thunderbolt dock). The kernel only
/// publishes alt-mode flags for the former; the latter shows up purely as
/// a tunnel on the lane.
nonisolated func portCarriesAnyDisplay(_ port: PhysicalPort) -> Bool {
    if port.accessory?.carriesDisplay == true { return true }
    return port.tunnels.contains { $0.kind == .displayPort }
}

nonisolated struct DisplayInfo: Hashable, Identifiable {
    var id: TBNodeID { backingID }

    /// IORegistry entry ID of the IOMobileFramebufferShim node.
    let backingID: TBNodeID
    /// device-tree name that matched (`disp0,t603x`, `dispext1,t603x`, etc.).
    /// "disp0" maps to the built-in panel; "dispextN" are external engines.
    let deviceTreeName: String
    /// Resolved IORegistry node — used by the detail view to expose the raw
    /// property table via the standard Developer-details disclosure.
    let node: TBNode

    /// User-facing title and subtitle.
    let title: String
    let subtitle: String?

    /// True when the engine reports a non-zero panel size — i.e. a display
    /// is actually lit by this pipeline. Idle external slots get `false`.
    let isConnected: Bool
    let isBuiltIn: Bool

    /// Active-mode pixel dimensions, when reported.
    let widthPixels: UInt64?
    let heightPixels: UInt64?

    /// Refresh rate range in Hz across all timing modes the panel advertises.
    /// Fixed-refresh panels publish min == max; ProMotion / FreeSync panels
    /// have a wide span.
    let minRefreshHz: Double?
    let maxRefreshHz: Double?
    /// Refresh rate the engine is currently driving the panel at — pulled
    /// from the `IsPreferred` timing element (the DCP's active mode).
    let currentRefreshHz: Double?

    /// Color-element depth (typically 8 or 10) for the highest-preference
    /// color mode the engine has negotiated, parsed from `ColorElements[0]`.
    let colorBitDepth: UInt64?
    /// Decoded pixel-encoding for the negotiated mode — "RGB",
    /// "YCbCr 4:4:4", "YCbCr 4:2:2", "YCbCr 4:2:0", or nil when unknown.
    let pixelEncoding: String?
    /// Color space for the negotiated mode (sRGB, BT.709, BT.2020, …).
    /// Decoded from the Colorimetry code in `ColorElements[0]`.
    let colorSpace: String?
    /// Apple's "color-accuracy-index" — 98 on the XDR panel.
    let colorAccuracyIndex: UInt64?

    /// Whether the engine reports HDR *support* (any ColorElement has
    /// `DynamicRange = 1`, or `IOMFBSupportsHDR` is true). This is a
    /// static capability — there's no reliable IOMFB property for
    /// "HDR is currently being driven", because the SDR-vs-HDR choice
    /// lives in user-space (System Settings) and only NSScreen's
    /// `maximumExtendedDynamicRangeColorComponentValue` reflects it.
    let supportsHDR: Bool

    /// True when the panel advertises a refresh range wider than 1 Hz —
    /// i.e. it's variable-refresh / ProMotion / FreeSync capable.
    let variableRefreshCapable: Bool
    /// True when QMS / VRR mode is currently enabled on the engine
    /// (`QMSVRREnableConfig != 0`). Distinct from capability — capable
    /// panels may still be driven at a fixed rate when nothing's animating.
    let variableRefreshActive: Bool

    /// Number of distinct timing modes the panel advertises (i.e. unique
    /// resolution/refresh entries in `TimingElements`).
    let timingModeCount: Int

    var iconSymbol: String { isBuiltIn ? "laptopcomputer" : "display" }
}
