//
//  PortScopeViewModel.swift
//  PortScope
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class PortScopeViewModel: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot = .empty
    @Published private(set) var isScanning = false
    @Published var selection: TBNodeID?

    /// Convenience accessor for the TB-only portion of the snapshot.
    var tbSnapshot: TBSnapshot { snapshot.tb }
    var usbSnapshot: USBSnapshot { snapshot.usb }

    private let monitor = IORegMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var debounceTask: Task<Void, Never>?
    private var powerRefreshTask: Task<Void, Never>?

    /// Monotonic generation counter for full rescans. Overlapping rescans
    /// (hot-plug burst, Cmd-R during a scan) would otherwise race: a slow
    /// scanner slice from an older rescan could overwrite a newer rescan's
    /// fresher result, and whichever scan finished first cleared the
    /// spinner. Each slice write and the final stamp apply only while
    /// their epoch is still the latest.
    private var scanEpoch: UInt64 = 0

    /// Cadence for the live power-telemetry poll. The kernel updates
    /// `AppleSmartBattery.PowerTelemetryData` (and per-port HPM USB-PD
    /// readouts) every few seconds, so a faster interval just spins.
    private static let powerRefreshInterval: TimeInterval = 2.0

    init() {
        NotificationCenter.default.publisher(for: IORegMonitor.didChange)
            .sink { [weak self] _ in self?.debouncedRescan() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .portScopeRefresh)
            .sink { [weak self] _ in self?.rescan() }
            .store(in: &cancellables)
        monitor.start()
        // Live power telemetry — re-runs only the accessory + battery
        // scanners so the Power Input wattage / voltage / amperage tick
        // forward without the cost of a full topology rescan. Driven by
        // `Task.sleep` rather than `Timer.publish` because the runloop
        // timer fires during view-update ticks (.common mode), and the
        // sink/continuation chain can resume the snapshot assignment
        // inside a SwiftUI body evaluation — SwiftUI warns and the
        // publish is undefined behaviour. Task.sleep resumes at a clean
        // async point that is never inside a view body.
        powerRefreshTask = Task { [weak self] in
            let nanos = UInt64(Self.powerRefreshInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                await self?.refreshPower()
            }
        }
        rescan()
    }

    deinit {
        debounceTask?.cancel()
        powerRefreshTask?.cancel()
    }

    /// Kick off a full rescan whose results stream into the snapshot one
    /// slice at a time. Each scanner runs in its own task on a global
    /// concurrent queue; when it finishes it hops back to the main actor
    /// and writes only its own field of `snapshot`. The sidebar's bindings
    /// re-render incrementally — Physical Device + Thunderbolt + USB show
    /// up first (those scanners finish in tens of milliseconds), then
    /// PCIe and Displays fill in behind them. Total wall-clock is capped
    /// by the slowest scanner, but first-paint is dramatically faster —
    /// the user starts navigating the device tree while the background
    /// tasks fill in.
    func rescan() {
        scanEpoch &+= 1
        let epoch = scanEpoch
        isScanning = true
        Task {
            await withTaskGroup(of: Void.self) { group in
                // Thunderbolt — fast, IORegistry walk. Drives the sidebar
                // Physical Device topology, so prioritise it.
                group.addTask(priority: .userInitiated) { [self] in
                    let tb = ThunderboltScanner.scan()
                    await MainActor.run {
                        guard self.scanEpoch == epoch else { return }
                        self.snapshot.tb = tb
                    }
                }
                // USB — fast, IORegistry walk. Used for tb-context
                // cross-link and the USB section.
                group.addTask(priority: .userInitiated) { [self] in
                    let usb = USBScanner.scan()
                    await MainActor.run {
                        guard self.scanEpoch == epoch else { return }
                        self.snapshot.usb = usb
                    }
                }
                // Accessories + InternalHardware share a dependency:
                // InternalHardwareScanner takes the accessory list so it
                // can isolate the MagSafe receptacle. Run them as one
                // task to keep that contract intact, then publish both
                // in a single MainActor hop.
                group.addTask(priority: .userInitiated) { [self] in
                    let accessories = AccessoryScanner.scan()
                        + SDCardScanner.scan()
                        + PowerInputScanner.scan()
                        + EthernetScanner.scan()
                    let internalHardware = InternalHardwareScanner.scan(accessories: accessories)
                    await MainActor.run {
                        guard self.scanEpoch == epoch else { return }
                        self.snapshot.accessories = accessories
                        self.snapshot.internalHardware = internalHardware
                    }
                }
                // PCIe — moderate cost (one IORegistry walk for every
                // IOPCIDevice). Independent of the others.
                group.addTask { [self] in
                    let pcie = PCIScanner.scan()
                    await MainActor.run {
                        guard self.scanEpoch == epoch else { return }
                        self.snapshot.pcie = pcie
                    }
                }
                // Displays — IOMobileFramebuffer walk + EDID decode.
                // Moderate cost, no SP spawn.
                group.addTask { [self] in
                    let displays = DisplayScanner.scan()
                    await MainActor.run {
                        guard self.scanEpoch == epoch else { return }
                        self.snapshot.displays = displays
                    }
                }
            }
            // All slices have streamed in; stamp the snapshot and clear
            // the spinner — unless a newer rescan started while this one
            // was in flight (it owns the spinner and the stamp now).
            // Selection picks up here if the user hadn't selected
            // anything yet (or if their previous selection disappeared
            // in the new snapshot).
            guard self.scanEpoch == epoch else { return }
            self.snapshot.capturedAt = Date()
            self.isScanning = false
            if let sel = self.selection, !self.exists(id: sel) {
                self.selection = self.firstSelectable()
            } else if self.selection == nil {
                self.selection = self.firstSelectable()
            }
        }
    }

    private func debouncedRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            self?.rescan()
        }
    }

    /// Lightweight refresh that re-reads only the per-port accessory state
    /// (USB-PD profiles, MagSafe, AC PSU telemetry, SD card, ethernet) and
    /// the battery manager subtree. Bus topology (TB / USB / PCIe) and
    /// displays are carried over from the previous snapshot — none of
    /// those change on the few-second cadence we poll at. Doesn't touch
    /// `isScanning` so the toolbar spinner stays out of the way.
    private func refreshPower() async {
        let scanned = await Task.detached(priority: .utility) {
            let accessories = AccessoryScanner.scan()
                + SDCardScanner.scan()
                + PowerInputScanner.scan()
                + EthernetScanner.scan()
            let battery = InternalHardwareScanner.scanBatteryManager()
            return (accessories, battery)
        }.value
        let (accessories, battery) = scanned
        let prev = self.snapshot
        let magsafe = accessories.first { acc in
            if case .magsafe = acc.connector { return true }
            return false
        }
        let internalHardware = InternalHardwareSnapshot(
            batteryManager: battery ?? prev.internalHardware.batteryManager,
            magsafe: magsafe
        )
        self.snapshot = SystemSnapshot(
            tb: prev.tb,
            usb: prev.usb,
            accessories: accessories,
            internalHardware: internalHardware,
            displays: prev.displays,
            pcie: prev.pcie,
            capturedAt: Date()
        )
    }

    // MARK: - Selection helpers

    /// Roots that the selection lookup walks. Includes TB controllers,
    /// USB controllers, the flattened TB-tunneled device lists, and the
    /// battery manager (so the battery node resolves from the sidebar).
    /// PCIe nodes and displays are added so their developer-detail rows
    /// resolve too.
    private var selectionRoots: [TBNode] {
        var roots = snapshot.tb.controllers
            + snapshot.usb.controllers
            + snapshot.tb.pcieDevicesOverTB
            + snapshot.tb.usbDevicesOverTB
            + snapshot.displays.displays.map(\.node)
            + pciRootNodes()
        if let bm = snapshot.internalHardware.batteryManager {
            roots.append(bm)
        }
        return roots
    }

    /// Flatten PCI tree into the underlying TBNodes so selection lookups
    /// resolve every device. We can't just include the IORegistry tree —
    /// the PCI tree promotes children through bridge boundaries the
    /// IOService plane wouldn't preserve, so we walk the PCINode tree.
    private func pciRootNodes() -> [TBNode] {
        var out: [TBNode] = []
        func walk(_ n: PCINode) {
            out.append(n.node)
            for c in n.children { walk(c) }
        }
        for r in snapshot.pcie.roots { walk(r) }
        return out
    }

    func node(for id: TBNodeID) -> TBNode? {
        for root in selectionRoots {
            if let n = find(id: id, in: root) { return n }
        }
        return nil
    }

    private func find(id: TBNodeID, in node: TBNode) -> TBNode? {
        if node.id == id { return node }
        for c in node.children {
            if let f = find(id: id, in: c) { return f }
        }
        return nil
    }

    /// Parent in any of the roots that this view model owns.
    func parent(of id: TBNodeID) -> TBNode? {
        for root in selectionRoots {
            if let p = findParent(id: id, in: root) { return p }
        }
        return nil
    }

    private func findParent(id: TBNodeID, in node: TBNode) -> TBNode? {
        for c in node.children {
            if c.id == id { return node }
            if let p = findParent(id: id, in: c) { return p }
        }
        return nil
    }

    /// Ancestor chain of `id`, oldest-first, suitable for a breadcrumb.
    /// Filters out `.other` kext-wrapper nodes (USB port wrappers,
    /// `IOServicePort` etc.) so the chain shows only meaningful entities.
    /// `safety` bounds the walk in case a parent loop ever sneaks in.
    func ancestors(of id: TBNodeID) -> [TBNode] {
        var chain: [TBNode] = []
        var current = parent(of: id)
        var safety = 32
        while let p = current, safety > 0 {
            if p.kind != .other {
                chain.append(p)
            }
            current = parent(of: p.id)
            safety -= 1
        }
        return chain.reversed()
    }

    private func exists(id: TBNodeID) -> Bool {
        if PhysicalPortSelector.isPortID(id) { return true }
        if MagSafeSelector.isMagSafeID(id) { return snapshot.internalHardware.magsafe != nil }
        return node(for: id) != nil
    }

    private func firstSelectable() -> TBNodeID? {
        if let first = TopologyMapper.physicalPorts(from: snapshot).first {
            return PhysicalPortSelector.id(for: first)
        }
        return snapshot.tb.controllers.first?.id
    }

    func select(_ id: TBNodeID) {
        selection = id
    }
}

/// Synthetic IDs used to select a "physical port" row in the sidebar without
/// colliding with real IORegistry entry IDs. The lower 32 bits encode the
/// receptacle: bits 24..31 = connector family code (so USB-C port 1 and
/// USB-A port 1 don't share an ID), bits 0..23 = chassis port number.
enum PhysicalPortSelector {
    private static let portMask: UInt64 = 0xC0DE_C0DE_0000_0000

    static func id(for port: PhysicalPort) -> TBNodeID {
        let connector = connectorCode(port.connector) << 24
        let number = UInt64(port.number) & 0xFFFFFF
        return TBNodeID(raw: portMask | connector | number)
    }

    static func isPortID(_ id: TBNodeID) -> Bool {
        (id.raw & 0xFFFF_FFFF_0000_0000) == portMask
    }

    static func portNumber(_ id: TBNodeID) -> Int? {
        guard isPortID(id) else { return nil }
        return Int(id.raw & 0xFFFFFF)
    }

    private static func connectorCode(_ c: PortConnectorType) -> UInt64 {
        switch c {
        case .usbC: return 0
        case .usbA: return 1
        case .magsafe: return 2
        case .hdmi: return 3
        case .sdCard: return 4
        case .acPower: return 5
        case .ethernet: return 6
        case .other: return 7
        }
    }
}
