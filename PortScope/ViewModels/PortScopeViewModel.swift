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

    init() {
        NotificationCenter.default.publisher(for: IORegMonitor.didChange)
            .sink { [weak self] _ in self?.debouncedRescan() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .portScopeRefresh)
            .sink { [weak self] _ in self?.rescan() }
            .store(in: &cancellables)
        monitor.start()
        rescan()
    }

    deinit {
        debounceTask?.cancel()
    }

    func rescan() {
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let tb = ThunderboltScanner.scan()
            let usb = USBScanner.scan()
            let accessories = AccessoryScanner.scan()
            let internalHardware = InternalHardwareScanner.scan(accessories: accessories)
            let snap = SystemSnapshot(
                tb: tb, usb: usb, accessories: accessories,
                internalHardware: internalHardware, capturedAt: Date()
            )
            await MainActor.run {
                self.snapshot = snap
                self.isScanning = false
                if let sel = self.selection, !self.exists(id: sel) {
                    self.selection = self.firstSelectable()
                } else if self.selection == nil {
                    self.selection = self.firstSelectable()
                }
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

    // MARK: - Selection helpers

    /// Roots that the selection lookup walks. Includes TB controllers,
    /// USB controllers, the flattened TB-tunneled device lists, and the
    /// internal-hardware buses + battery (so I²C / SPI children and the
    /// battery node resolve from the sidebar).
    private var selectionRoots: [TBNode] {
        var roots = snapshot.tb.controllers
            + snapshot.usb.controllers
            + snapshot.tb.pcieDevicesOverTB
            + snapshot.tb.usbDevicesOverTB
            + snapshot.internalHardware.i2cBuses
            + snapshot.internalHardware.spiBuses
            + snapshot.internalHardware.socCoprocessors
        if let bm = snapshot.internalHardware.batteryManager {
            roots.append(bm)
        }
        return roots
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
/// colliding with real IORegistry entry IDs.
enum PhysicalPortSelector {
    /// High bit reserved for synthetic IDs.
    private static let portMask: UInt64 = 0xC0DE_C0DE_0000_0000

    static func id(for port: PhysicalPort) -> TBNodeID {
        TBNodeID(raw: portMask | UInt64(port.number))
    }

    static func isPortID(_ id: TBNodeID) -> Bool {
        (id.raw & 0xFFFF_FFFF_0000_0000) == portMask
    }

    static func portNumber(_ id: TBNodeID) -> Int? {
        guard isPortID(id) else { return nil }
        return Int(id.raw & 0xFFFF_FFFF)
    }
}
