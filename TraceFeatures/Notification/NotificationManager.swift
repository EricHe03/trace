//
//  NotificationManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import UIKit
import UserNotifications
#if canImport(TraceCore)
import TraceCore
#endif

/// Manages local notifications for network capture events.
public class NotificationManager: NSObject {
    public nonisolated(unsafe) static let shared = NotificationManager()

    private let notificationCenter = UNUserNotificationCenter.current()

    override private init() {
        super.init()
        setupNotificationCategories()
    }

    // MARK: - Setup

    /// Requests notification permissions and registers the delegate.
    /// - Throws: An error if authorization fails.
    public func requestAuthorization() async throws {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        try await notificationCenter.requestAuthorization(options: options)
        notificationCenter.delegate = self
    }

    /// Returns the current notification authorization status.
    public func checkAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await notificationCenter.notificationSettings()
        return settings.authorizationStatus
    }

    /// Returns whether notifications are authorized for this app.
    public func areNotificationsEnabled() async -> Bool {
        let status = await checkAuthorizationStatus()
        return status == .authorized || status == .provisional
    }

    /// Opens system settings so the user can enable notifications.
    /// - Note: This method is only available in the main app target, not in app extensions.
    public func openNotificationSettings() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        #if !os(watchOS)
        if let settingsUrl = URL(string: "app-settings:") {
            DispatchQueue.main.async {
                // Rule: Use dynamic UIApplication access so app extensions can compile.
                if let sharedApplication = NSClassFromString("UIApplication") as? NSObject.Type {
                    let selector = NSSelectorFromString("sharedApplication")
                    if sharedApplication.responds(to: selector),
                       let application = sharedApplication.perform(selector)?.takeUnretainedValue() as? NSObject {
                        let openSelector = NSSelectorFromString("openURL:")
                        if application.responds(to: openSelector) {
                            _ = application.perform(openSelector, with: settingsUrl)
                        }
                    }
                }
            }
        }
        #endif
        #endif
    }

    /// Registers notification action categories.
    private func setupNotificationCategories() {
        let viewAction = UNNotificationAction(
            identifier: "VIEW_REQUEST",
            title: "View Request",
            options: [.foreground]
        )

        let stopCaptureAction = UNNotificationAction(
            identifier: "STOP_CAPTURE",
            title: "Stop Capture",
            options: [.destructive]
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )

        let errorCategory = UNNotificationCategory(
            identifier: "HTTP_ERROR",
            actions: [viewAction, stopCaptureAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        let slowRequestCategory = UNNotificationCategory(
            identifier: "SLOW_REQUEST",
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        let largeDataCategory = UNNotificationCategory(
            identifier: "LARGE_DATA",
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter.setNotificationCategories([errorCategory, slowRequestCategory, largeDataCategory])
    }

    // MARK: - Send Notifications

    /// Sends a generic local notification.
    /// - Parameters:
    ///   - title: The notification title.
    ///   - body: The notification body.
    ///   - identifier: The notification identifier.
    /// - Throws: An error if the notification cannot be scheduled.
    public func sendNotification(title: String, body: String, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let notificationRequest = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            notificationCenter.add(notificationRequest) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// Sends a notification for an HTTP error response.
    /// - Parameter request: The request that produced the error response.
    public func notifyHTTPError(request: NetworkRequest) {
        guard let statusCode = request.statusCode else {
            FeatureLog.notification.warning("event=notification.http_error outcome=skipped reason=no_status_code")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "HTTP \(statusCode) Error"
        content.body = "\(request.method.rawValue) \(request.url)"
        content.sound = .default
        content.categoryIdentifier = "HTTP_ERROR"

        // Rule: Include the request ID for deep linking.
        content.userInfo = ["requestId": request.id.uuidString]

        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        notificationCenter.add(notificationRequest) { error in
            if let error {
                FeatureLog.notification.error("event=notification.http_error outcome=failure status_code=\(statusCode) error=\(error.localizedDescription, privacy: .public)")
            } else {
                FeatureLog.notification.debug("event=notification.http_error outcome=success status_code=\(statusCode)")
            }
        }
    }

    /// Sends a notification for a slow request.
    /// - Parameters:
    ///   - request: The request that was slow.
    ///   - duration: The request duration in seconds.
    public func notifySlowRequest(request: NetworkRequest, duration: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Slow Request Detected"
        content.body = "\(request.method.rawValue) \(request.url) took \(String(format: "%.2f", duration))s"
        content.sound = .default
        content.categoryIdentifier = "SLOW_REQUEST"

        // Rule: Include the request ID for deep linking.
        content.userInfo = ["requestId": request.id.uuidString]

        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        notificationCenter.add(notificationRequest) { error in
            if let error {
                FeatureLog.notification.error("event=notification.slow_request outcome=failure duration_s=\(String(format: "%.2f", duration), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            } else {
                FeatureLog.notification.debug("event=notification.slow_request outcome=success duration_s=\(String(format: "%.2f", duration), privacy: .public)")
            }
        }
    }

    /// Sends a notification for large request or response payloads.
    /// - Parameters:
    ///   - request: The request that triggered the notification.
    ///   - size: The payload size in bytes.
    public func notifyLargeData(request: NetworkRequest, size: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "Large Request Detected"
        let sizeString = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        content.body = "\(request.method.rawValue) \(request.url) - \(sizeString)"
        content.sound = .default
        content.categoryIdentifier = "LARGE_DATA"

        // Rule: Include the request ID for deep linking.
        content.userInfo = ["requestId": request.id.uuidString]

        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        notificationCenter.add(notificationRequest) { error in
            if let error {
                FeatureLog.notification.error("event=notification.large_data outcome=failure size_bytes=\(size) error=\(error.localizedDescription, privacy: .public)")
            } else {
                FeatureLog.notification.debug("event=notification.large_data outcome=success size_bytes=\(size)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Handles notifications while the app is in the foreground.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        FeatureLog.notification.debug("event=notification.present outcome=success context=foreground")
        // Rule: Present banners in the foreground to mirror background alerts.
        completionHandler([.banner, .sound])
    }

    /// Handles notification actions.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let requestId = userInfo["requestId"] as? String

        switch response.actionIdentifier {
        case "VIEW_REQUEST":
            if let requestId {
                FeatureLog.notification.info("event=notification.action action=view_request request_id=\(requestId, privacy: .public)")
                NotificationCenter.default.post(
                    name: .viewRequest,
                    object: nil,
                    userInfo: ["requestId": requestId]
                )
            } else {
                FeatureLog.notification.warning("event=notification.action action=view_request outcome=failure reason=no_request_id")
            }

        case "STOP_CAPTURE":
            FeatureLog.notification.info("event=notification.action action=stop_capture")
            Task { @MainActor in
                VPNManager.shared.stop()
            }

        case "DISMISS", UNNotificationDefaultActionIdentifier:
            FeatureLog.notification.debug("event=notification.action action=dismiss")

        default:
            FeatureLog.notification.warning("event=notification.action action=unknown identifier=\(response.actionIdentifier, privacy: .public)")
        }

        completionHandler()
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let viewRequest = Notification.Name("viewRequest")
    static let openTab = Notification.Name("com.trace.openTab")
    static let showFavorites = Notification.Name("com.trace.showFavorites")
    static let onboardingCompleted = Notification.Name("onboardingCompleted")
}
