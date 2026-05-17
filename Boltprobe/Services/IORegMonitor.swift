//
//  IORegMonitor.swift
//  Boltprobe
//
//  Posts a notification when any Thunderbolt-related service appears
//  or disappears so the view model can re-scan.
//

import Foundation
import IOKit

@MainActor
final class IORegMonitor {
    static let didChange = Notification.Name("io.zenla.boltprobe.IOReg.didChange")

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
            "AppleThunderboltUSBType2DownAdapter"
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
