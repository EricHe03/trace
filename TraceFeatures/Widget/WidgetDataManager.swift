//
//  WidgetDataManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
#endif
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Manages widget data updates via App Group UserDefaults and Live Activities
@MainActor
public final class WidgetDataManager {
    public static let shared = WidgetDataManager()

    private let defaults: UserDefaults?
    private var currentActivity: Any?
    private var captureStartTime: Date?

    @available(iOS 16.2, *)
    private var liveActivity: Activity<TraceWidgetAttributes>? {
        get { currentActivity as? Activity<TraceWidgetAttributes> }
        set { currentActivity = newValue }
    }

    private init() {
        defaults = UserDefaults(suiteName: AppGroupConfiguration.appGroupIdentifier)
    }

    // MARK: - Widget Updates

    /// Update widget with current capture state
    public func updateWidgetData(
        isCapturing: Bool,
        requestCount: Int,
        dataTransferred: String,
        recentRequests: [WidgetRecentRequest]
    ) {
        defaults?.set(isCapturing, forKey: "widget.isCapturing")
        defaults?.set(requestCount, forKey: "widget.requestCount")
        defaults?.set(dataTransferred, forKey: "widget.dataTransferred")

        // Encode recent requests
        if let encoded = try? JSONEncoder().encode(recentRequests) {
            defaults?.set(encoded, forKey: "widget.recentRequests")
        }

        // Force widget reload
        WidgetCenter.shared.reloadAllTimelines()

        // Update Live Activity if active
        if isCapturing {
            updateLiveActivity(
                requestCount: requestCount,
                dataTransferred: dataTransferred,
                lastRequest: recentRequests.first
            )
        }
    }

    /// Update widget when capture state changes
    public func notifyCaptureStateChanged(isCapturing: Bool) {
        defaults?.set(isCapturing, forKey: "widget.isCapturing")
        WidgetCenter.shared.reloadAllTimelines()

        if isCapturing {
            startLiveActivity()
        } else {
            endLiveActivity()
        }
    }

    /// Update widget with current request count
    public func updateRequestCount(_ count: Int) {
        defaults?.set(count, forKey: "widget.requestCount")
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Live Activity Management

    /// Start a Live Activity for capture session
    public func startLiveActivity() {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        // End any existing activity first
        endLiveActivity()

        captureStartTime = Date()

        let attributes = TraceWidgetAttributes(sessionId: UUID())
        let initialState = TraceWidgetAttributes.ContentState(
            requestCount: 0,
            dataTransferred: "0 B",
            captureStartTime: captureStartTime ?? Date(),
            lastRequestTime: nil,
            lastRequestMethod: nil,
            lastRequestHost: nil,
            lastRequestStatus: nil
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            liveActivity = activity
            FeatureLog.widget.info("event=widget.live_activity_start outcome=success")
        } catch {
            FeatureLog.widget.error("event=widget.live_activity_start outcome=failure error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Update the current Live Activity with new data
    public func updateLiveActivity(
        requestCount: Int,
        dataTransferred: String,
        lastRequest: WidgetRecentRequest?
    ) {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = liveActivity else { return }

        let url = lastRequest.flatMap { URL(string: $0.url) }
        let newState = TraceWidgetAttributes.ContentState(
            requestCount: requestCount,
            dataTransferred: dataTransferred,
            captureStartTime: captureStartTime ?? Date(),
            lastRequestTime: lastRequest?.timestamp,
            lastRequestMethod: lastRequest?.method,
            lastRequestHost: url?.host,
            lastRequestStatus: lastRequest?.statusCode
        )

        Task {
            await activity.update(
                .init(state: newState, staleDate: nil)
            )
        }
    }

    /// End the current Live Activity
    public func endLiveActivity() {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = liveActivity else { return }

        Task {
            await activity.end(
                .init(
                    state: activity.content.state,
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )
            await MainActor.run {
                liveActivity = nil
                captureStartTime = nil
                FeatureLog.widget.info("event=widget.live_activity_end outcome=success")
            }
        }
    }
}
