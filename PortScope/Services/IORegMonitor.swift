//
//  IORegMonitor.swift
//  PortScope
//
//  Posts a notification when any Thunderbolt-related service appears
//  or disappears so the view model can re-scan.
//

import Foundation
import IOKit

@MainActor
final class IORegMonitor {
    static let didChange = Notification.Name("io.zenla.portscope.IOReg.didChange")

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    func start() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        guard let runLoopSource = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        notifyPort = port

        let classes = [
            "IOThunderboltController",
            "IOThunderboltSwitch",
            "IOThunderboltPort",
            "IOThunderboltLocalNode",
            // TB USB tunnel down adapter. The kernel-class name differs by
            // controller generation: `…Type2DownAdapter` on M3+/Type7 hosts
            // and `…USBDownAdapter` (no Type suffix) on M1/M2 family Type5
            // hosts. Watch both so a tunneled USB device fires a rescan on
            // every architecture.
            "AppleThunderboltUSBType2DownAdapter",
            "AppleThunderboltUSBDownAdapter",
            "IOUSBHostController",
            "IOUSBHostDevice",
            // Per-physical-port USB-C receptacle interface — fires on cable
            // insertion / removal, USB-PD renegotiation, alt-mode entry, etc.
            // Different class hierarchies expose the same property schema
            // depending on the host generation, so we have to watch both.
            "AppleHPMInterfaceType10",  // M3+ / TB5 hosts
            "AppleHPMInterfaceType12",  // M4 / additional generations
            "AppleHPMInterfaceType18",  // MacBook Neo / A-series (per WhatCable)
            "AppleTCControllerType10",  // M1 / M2 family
            // MagSafe 3 receptacle. Fires on MagSafe insertion/removal and on
            // charger renegotiation. Same dual-class story as Type10.
            "AppleHPMInterfaceType11",
            "AppleTCControllerType11",
            // Battery / charging state changes (AC attach, charge transitions).
            "AppleSmartBatteryManager"
        ]

        for cls in classes {
            attach(port: port, type: kIOMatchedNotification, className: cls)
            attach(port: port, type: kIOTerminatedNotification, className: cls)
        }
    }

    func stop() {
        for iter in iterators { IOObjectRelease(iter) }
        iterators.removeAll()
        if let port = notifyPort { IONotificationPortDestroy(port) }
        notifyPort = nil
    }

    private func attach(port: IONotificationPortRef, type: String, className: String) {
        guard let dict = IOServiceMatching(className) else { return }
        var iter: io_iterator_t = 0
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddMatchingNotification(
            port,
            type,
            dict,
            { (ctx, iterator) in
                // Drain so the kernel will re-fire next time.
                var s: io_service_t = IOIteratorNext(iterator)
                while s != 0 {
                    IOObjectRelease(s)
                    s = IOIteratorNext(iterator)
                }
                guard let ctx else { return }
                let monitor = Unmanaged<IORegMonitor>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async {
                    monitor.fire()
                }
            },
            selfPtr,
            &iter
        )
        if kr == KERN_SUCCESS {
            // Drain the initial set; this also "arms" the notification.
            var s: io_service_t = IOIteratorNext(iter)
            while s != 0 {
                IOObjectRelease(s)
                s = IOIteratorNext(iter)
            }
            iterators.append(iter)
        }
    }

    private func fire() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
