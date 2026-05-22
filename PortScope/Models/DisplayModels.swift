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

    static let empty = DisplaySnapshot(displays: [])

    var connectedCount: Int { displays.filter { $0.isConnected }.count }
    var totalCount: Int { displays.count }
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

    /// Refresh rate range in Hz, when reported. The DCP publishes the
    /// allowed minimum and maximum together — variable-refresh panels (the
    /// MacBook Pro's ProMotion XDR) cover 10..120 Hz, fixed displays
    /// publish min == max.
    let minRefreshHz: Double?
    let maxRefreshHz: Double?

    /// Color-element depth (typically 8 or 10) parsed from the preferred
    /// ColorModes entry when available.
    let colorBitDepth: UInt64?
    /// Apple's "color-accuracy-index" — 98 on the XDR panel.
    let colorAccuracyIndex: UInt64?

    /// Whether the engine reports HDR support (IOMFBSupportsHDR, etc.).
    let supportsHDR: Bool

    /// Number of distinct timing modes the panel advertises (i.e. unique
    /// resolution/refresh entries in `TimingElements`).
    let timingModeCount: Int

    var iconSymbol: String { isBuiltIn ? "laptopcomputer" : "display" }
}
