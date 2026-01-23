//
//  WidgetActionHandler.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

public final class WidgetActionHandler {
    public nonisolated(unsafe) static let shared = WidgetActionHandler()
    private static let maxActionAge: TimeInterval = 5 * 60

    private let defaults: UserDefaults?

    private init() {
        defaults = UserDefaults(suiteName: AppGroupConfiguration.appGroupIdentifier)
    }

    @MainActor
    public func handlePendingAction(
        toggleCapture: @escaping () -> Void,
        clearRequests: @escaping () -> Void
    ) {
        guard let defaults else { return }
        guard let actionRaw = defaults.string(forKey: WidgetActionKey.action),
              let action = WidgetAction(rawValue: actionRaw) else {
            return
        }

        defer {
            defaults.removeObject(forKey: WidgetActionKey.action)
            defaults.removeObject(forKey: WidgetActionKey.actionDate)
            defaults.removeObject(forKey: WidgetActionKey.actionView)
        }

        let actionDate = defaults.object(forKey: WidgetActionKey.actionDate) as? Date
        guard let actionDate else { return }
        guard Date().timeIntervalSince(actionDate) <= Self.maxActionAge else { return }

        switch action {
        case .toggleCapture:
            toggleCapture()
        case .startCapture:
            startCaptureIfNeeded()
        case .stopCapture:
            stopCaptureIfNeeded()
        case .clearRequests:
            clearRequests()
        case .openView:
            let view = defaults.string(forKey: WidgetActionKey.actionView)
            openView(view)
        }
    }

    @MainActor
    private func startCaptureIfNeeded() {
        guard !VPNManager.shared.isConnected else { return }
        Task {
            do {
                try await VPNManager.shared.start()
            } catch {
                FeatureLog.vpn.error("event=vpn.start outcome=failure source=widget_action error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    private func stopCaptureIfNeeded() {
        guard VPNManager.shared.isConnected else { return }
        VPNManager.shared.stop()
    }

    @MainActor
    private func openView(_ rawValue: String?) {
        guard let rawValue else { return }

        switch rawValue {
        case "capture":
            NotificationCenter.default.post(
                name: Notification.Name("com.trace.openTab"),
                object: nil,
                userInfo: ["tab": "network"]
            )
        case "tools":
            NotificationCenter.default.post(
                name: Notification.Name("com.trace.openTab"),
                object: nil,
                userInfo: ["tab": "tools"]
            )
        case "settings":
            NotificationCenter.default.post(
                name: Notification.Name("com.trace.openTab"),
                object: nil,
                userInfo: ["tab": "settings"]
            )
        case "favorites":
            NotificationCenter.default.post(
                name: Notification.Name("com.trace.openTab"),
                object: nil,
                userInfo: ["tab": "network"]
            )
            NotificationCenter.default.post(name: Notification.Name("com.trace.showFavorites"), object: nil)
        default:
            break
        }
    }
}
