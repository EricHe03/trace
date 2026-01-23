//
//  NetworkCaptureStore.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
import TraceCore

/// Manages captured network requests.
@MainActor
class NetworkCaptureStore: ObservableObject {
    // MARK: - Singleton

    static let shared = NetworkCaptureStore()

    // MARK: - Published Properties

    @Published private(set) var requests: [NetworkRequest] = []
    @Published var isCapturing: Bool = false {
        didSet {
            if isCapturing {
                enableCapture()
            } else {
                disableCapture()
            }
        }
    }

    private init() {}

    // MARK: - Public Methods

    /// Adds a captured network request.
    /// - Parameter request: The request to store.
    func addRequest(_ request: NetworkRequest) {
        // Rule: Only record requests while capture is enabled.
        guard isCapturing else { return }

        requests.append(request)
    }

    /// Clears all captured requests.
    func clearRequests() {
        requests.removeAll()
    }

    /// Enables network capture by registering the URLProtocol.
    ///
    /// Discussion: This applies only to URLSessions created after registration and only for
    /// `URLSession.shared` or configurations that include `NetworkInterceptor`.
    /// For custom sessions, use `captureEnabledConfiguration()`.
    func enableCapture() {
        URLProtocol.registerClass(NetworkInterceptor.self)
    }

    /// Creates a URLSessionConfiguration with capture enabled.
    ///
    /// Discussion: Use this for custom URLSessions that should be captured.
    static func captureEnabledConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [NetworkInterceptor.self] + (config.protocolClasses ?? [])
        return config
    }

    /// Disables network capture by unregistering the URLProtocol.
    func disableCapture() {
        URLProtocol.unregisterClass(NetworkInterceptor.self)
    }
}
