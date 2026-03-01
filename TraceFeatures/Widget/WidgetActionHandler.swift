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

    private let storage: AppGroupStorage

    private init() {
        storage = AppGroupStorage.shared
    }

    @MainActor
    public func handlePendingAction(
        toggleCapture: @escaping () -> Void,
        clearRequests: @escaping () -> Void
    ) {
        guard let pending = storage.consumeWidgetPendingAction(maxAge: Self.maxActionAge) else {
            return
        }

        switch pending.action {
        case .toggleCapture:
            toggleCapture()
        case .startCapture:
            startCaptureIfNeeded()
        case .stopCapture:
            stopCaptureIfNeeded()
        case .clearRequests:
            clearRequests()
        case .openView:
            openView(pending.actionView)
        }
    }

    @MainActor
    private func startCaptureIfNeeded() {
        // Rule: Avoid triggering VPN permission prompts before onboarding completes.
        guard OnboardingState.hasCompleted else { return }
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
                name: .openTab,
                object: nil,
                userInfo: ["tab": "network"]
            )
        case "tools":
            NotificationCenter.default.post(
                name: .openTab,
                object: nil,
                userInfo: ["tab": "tools"]
            )
        case "settings":
            NotificationCenter.default.post(
                name: .openTab,
                object: nil,
                userInfo: ["tab": "settings"]
            )
        case "favorites":
            NotificationCenter.default.post(
                name: .openTab,
                object: nil,
                userInfo: ["tab": "network"]
            )
            NotificationCenter.default.post(name: .showFavorites, object: nil)
        default:
            break
        }
    }
}
