//
//  BoltprobeViewModel.swift
//  Boltprobe
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class BoltprobeViewModel: ObservableObject {
    @Published private(set) var snapshot: TBSnapshot = .empty
    @Published private(set) var isScanning = false
    @Published var selection: TBNodeID?

    private let monitor = IORegMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var debounceTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.publisher(for: IORegMonitor.didChange)
            .sink { [weak self] _ in self?.debouncedRescan() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .boltprobeRefresh)
            .sink { [weak self] _ in self?.rescan() }
            .store(in: &cancellables)
        monitor.start()
        rescan()
    }

    deinit {
        debounceTask?.cancel()
        // Monitor is main-actor; let ARC tear it down with the view model.
    }

    func rescan() {
        isScanning = true
        // Move the IOKit walk off the main actor since it can be slow on deep topologies.
        Task.detached(priority: .userInitiated) {
            let snap = ThunderboltScanner.scan()
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

    func node(for id: TBNodeID) -> TBNode? {
        for c in snapshot.controllers {
            if let n = find(id: id, in: c) { return n }
        }
        for n in snapshot.pcieDevicesOverTB {
            if let f = find(id: id, in: n) { return f }
        }
        for n in snapshot.usbDevicesOverTB {
            if let f = find(id: id, in: n) { return f }
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

    /// Return the node that has `id` as a direct child, anywhere in the snapshot.
    func parent(of id: TBNodeID) -> TBNode? {
        for c in snapshot.controllers {
            if let p = findParent(id: id, in: c) { return p }
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
        node(for: id) != nil
    }

    private func firstSelectable() -> TBNodeID? {
        // Prefer the first physical Thunderbolt port (the active lane adapter).
        TopologyMapper.physicalPorts(from: snapshot).first?.id
            ?? snapshot.controllers.first?.id
    }

    func select(_ id: TBNodeID) {
        selection = id
    }
}
