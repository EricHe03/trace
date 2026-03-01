//
//  AppGroupNotificationObserver.swift
//  TraceCore
//

import Foundation

public class NotificationObserver {
    private let lock = NSLock()
    private var observer: UnsafeMutableRawPointer?
    private var handler: (@Sendable () -> Void)?
    private var notificationName: CFString?

    public func stop() {
        lock.lock()
        let observer = observer
        let notificationName = notificationName
        self.observer = nil
        self.notificationName = nil
        handler = nil
        lock.unlock()

        guard let observer, let notificationName else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            CFNotificationName(notificationName),
            nil
        )
        Unmanaged<NotificationObserver>.fromOpaque(observer).release()
    }

    public func observe(notificationName: String, handler: @escaping @Sendable () -> Void) {
        stop()

        lock.lock()
        self.handler = handler
        self.notificationName = notificationName as CFString
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        lock.unlock()

        // Use a weak reference pattern
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<NotificationObserver>.fromOpaque(observer).takeUnretainedValue()
            let handler = instance.handler
            DispatchQueue.main.async {
                handler?()
            }
        }

        lock.lock()
        self.observer = Unmanaged.passRetained(self).toOpaque()
        let observer = self.observer
        let name = self.notificationName
        lock.unlock()
        CFNotificationCenterAddObserver(
            center,
            observer,
            callback,
            name,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        stop()
    }
}

public final class AppGroupStorageObserverToken: @unchecked Sendable {
    private var cancelHandler: (() -> Void)?
    private let cancelLock = NSLock()

    public init(_ cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    public func cancel() {
        cancelLock.lock()
        let handler = cancelHandler
        cancelHandler = nil
        cancelLock.unlock()
        handler?()
    }

    deinit {
        cancel()
    }
}
