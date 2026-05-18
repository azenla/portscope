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
            let bluetooth = BluetoothScanner.scan()
            let displays = DisplayScanner.scan()
            let pcie = PCIScanner.scan()
            let snap = SystemSnapshot(
                tb: tb, usb: usb, accessories: accessories,
                internalHardware: internalHardware,
                bluetooth: bluetooth, displays: displays, pcie: pcie,
                capturedAt: Date()
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
    /// battery node resolve from the sidebar). PCIe nodes and displays are
    /// added so their developer-detail rows resolve too.
    private var selectionRoots: [TBNode] {
        var roots = snapshot.tb.controllers
            + snapshot.usb.controllers
            + snapshot.tb.pcieDevicesOverTB
            + snapshot.tb.usbDevicesOverTB
            + snapshot.internalHardware.i2cBuses
            + snapshot.internalHardware.spiBuses
            + snapshot.internalHardware.socCoprocessors
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

    private func exists(id: TBNodeID) -> Bool {
        if PhysicalPortSelector.isPortID(id) { return true }
        if MagSafeSelector.isMagSafeID(id) { return snapshot.internalHardware.magsafe != nil }
        if BluetoothSelector.isControllerID(id) { return snapshot.bluetooth.controller != nil }
        if BluetoothSelector.isDeviceID(id) {
            let all = snapshot.bluetooth.connected + snapshot.bluetooth.paired
            return all.contains { BluetoothSelector.id(for: $0).raw == id.raw }
        }
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

/// Synthetic IDs used for sidebar rows that don't have a unique IORegistry
/// entry to point at (Bluetooth controller, paired Bluetooth devices, etc.).
/// The high 32 bits act as a namespace tag so the IDs never collide with
/// real registry entry IDs.
enum BluetoothSelector {
    private static let controllerMask: UInt64 = 0xB7E0_0000_0000_0000
    private static let deviceMask: UInt64     = 0xB7E1_0000_0000_0000

    static let controllerID = TBNodeID(raw: controllerMask)

    static func isControllerID(_ id: TBNodeID) -> Bool {
        id.raw == controllerMask
    }

    /// Synthesise an ID from the device's stable identifier (BD_ADDR). A
    /// simple hash is fine — collisions across the user's paired-device
    /// set are astronomically unlikely, and even on a collision we'd just
    /// route to the wrong device's detail card.
    static func id(for device: BluetoothDevice) -> TBNodeID {
        let key = (device.address ?? device.name).lowercased()
        let h = UInt64(bitPattern: Int64(stableHash(key)))
        return TBNodeID(raw: deviceMask | (h & 0x0000_FFFF_FFFF_FFFF))
    }

    static func isDeviceID(_ id: TBNodeID) -> Bool {
        (id.raw & 0xFFFF_0000_0000_0000) == deviceMask
    }

    private static func stableHash(_ s: String) -> Int {
        // Deterministic 64-bit FNV-1a so the row identity survives rescans
        // (Swift's `String.hashValue` is randomised per launch).
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return Int(bitPattern: UInt(h))
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
