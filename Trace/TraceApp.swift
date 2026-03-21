//
//  TraceApp.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceSecurity
import TraceUI
import UIKit

@main
struct TraceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: CaptureViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let vm = CaptureViewModel()
        _viewModel = StateObject(wrappedValue: vm)

        // Note: URLProtocol capture covers in-app traffic; VPN capture relies on system proxy support.
        setupAppearance()

        // Rule: Initialize VPN only after onboarding to control the permission prompt timing.
        // Rule: Configure Quick Actions only after onboarding completes.

        appDelegate.viewModel = vm
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(viewModel: viewModel)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .task {
                    handlePendingWidgetActionIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: .onboardingCompleted)) { _ in
                    VPNManager.shared.initializeIfNeeded()
                    updateQuickActions()
                }
        }
        .onChangeCompat(of: scenePhase) { newPhase in
            if newPhase == .active {
                // Rule: Avoid VPN setup before onboarding completion.
                if OnboardingState.hasCompleted {
                    VPNManager.shared.initializeIfNeeded()
                    updateQuickActions()
                    CertificateManager.shared.checkAndNotifyMismatch()
                }
                handlePendingShortcutIfNeeded()
                handlePendingWidgetActionIfNeeded()
            }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
    }

    private func setupAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    // MARK: - Quick Actions

    private func setupQuickActions() {
        updateQuickActions()
    }

    private func updateQuickActions() {
        let vpnManager = VPNManager.shared

        var shortcutItems: [UIApplicationShortcutItem] = []

        if vpnManager.isConnected {
            shortcutItems.append(
                UIApplicationShortcutItem(
                    type: TraceQuickActionType.stopCapture,
                    localizedTitle: "Stop Capture",
                    localizedSubtitle: "Stop monitoring traffic",
                    icon: UIApplicationShortcutIcon(systemImageName: "stop.circle.fill"),
                    userInfo: nil
                )
            )
        } else {
            shortcutItems.append(
                UIApplicationShortcutItem(
                    type: TraceQuickActionType.startCapture,
                    localizedTitle: "Start Capture",
                    localizedSubtitle: "Begin monitoring traffic",
                    icon: UIApplicationShortcutIcon(systemImageName: "record.circle"),
                    userInfo: nil
                )
            )
        }

        if !viewModel.sessions.isEmpty {
            let requestCount = viewModel.sessions.first?.requestCount ?? 0
            shortcutItems.append(
                UIApplicationShortcutItem(
                    type: TraceQuickActionType.viewLastSession,
                    localizedTitle: "Recent Session",
                    localizedSubtitle: "\(requestCount) request\(requestCount == 1 ? "" : "s")",
                    icon: UIApplicationShortcutIcon(systemImageName: "tray.full.fill"),
                    userInfo: nil
                )
            )
        }

        // Tradeoff: Prefer export over a destructive clear action.
        if !viewModel.sessions.isEmpty {
            shortcutItems.append(
                UIApplicationShortcutItem(
                    type: TraceQuickActionType.exportData,
                    localizedTitle: "Export Data",
                    localizedSubtitle: "Save session as HAR",
                    icon: UIApplicationShortcutIcon(systemImageName: "square.and.arrow.up"),
                    userInfo: nil
                )
            )
        }

        UIApplication.shared.shortcutItems = shortcutItems
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "trace" else { return }

        switch url.host {
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
        case "lastSession":
            if let lastSession = viewModel.sessions.first {
                viewModel.selectedSession = lastSession
            }
        default:
            break
        }
    }

    @MainActor
    private func handlePendingShortcutIfNeeded() {
        guard let shortcutItem = UIApplication.shared.shortcutItem else { return }
        UIApplication.shared.shortcutItem = nil

        Task {
            _ = await QuickActionHandler.shared.handleShortcutItem(shortcutItem, viewModel: viewModel)
        }
    }

    @MainActor
    private func handlePendingWidgetActionIfNeeded() {
        WidgetActionHandler.shared.handlePendingAction(
            toggleCapture: { [viewModel] in viewModel.toggleCapture() },
            clearRequests: { [viewModel] in viewModel.clearRequests() }
        )
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    var viewModel: CaptureViewModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            application.shortcutItem = shortcutItem
        }
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let viewModel else {
            application.shortcutItem = shortcutItem
            completionHandler(false)
            return
        }

        Task {
            let handled = await QuickActionHandler.shared.handleShortcutItem(shortcutItem, viewModel: viewModel)
            completionHandler(handled)
        }
    }
}

// MARK: - UIApplication Extension for Shortcut Item Storage

private nonisolated(unsafe) var _shortcutItemKey: UInt8 = 0

extension UIApplication {
    var shortcutItem: UIApplicationShortcutItem? {
        get { objc_getAssociatedObject(self, &_shortcutItemKey) as? UIApplicationShortcutItem }
        set { objc_setAssociatedObject(self, &_shortcutItemKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
