//
//  NetworkCaptureService.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
import NetworkExtension
import os
import TraceCore
import TraceFeatures

/// Defines network capture operations.
@MainActor
protocol NetworkCaptureServiceProtocol {
    var isCapturing: Bool { get }
    func startCapture() async throws
    func stopCapture() async throws
    func observeCaptureStatus() async -> AsyncStream<Bool>
}

/// Handles network capture through the VPN extension.
@MainActor
class NetworkCaptureService: NetworkCaptureServiceProtocol {
    // MARK: - Dependencies

    private let vpnManager: VPNManaging

    // MARK: - Properties

    var isCapturing: Bool {
        vpnManager.isConnected
    }

    // MARK: - Initialization

    init(vpnManager: VPNManaging = VPNManager.shared) {
        self.vpnManager = vpnManager
    }

    // MARK: - Public Methods

    func startCapture() async throws {
        try await vpnManager.start()
        FeatureLog.vpn.info("event=vpn.capture_start outcome=success source=app")
    }

    func stopCapture() async throws {
        vpnManager.stop()
        FeatureLog.vpn.info("event=vpn.capture_stop outcome=success source=app")
    }

    func observeCaptureStatus() async -> AsyncStream<Bool> {
        AsyncStream { continuation in
            var cancellable: AnyCancellable?
            cancellable = vpnManager.isConnectedPublisher
                .sink { isConnected in
                    continuation.yield(isConnected)
                }

            continuation.onTermination = { _ in
                cancellable?.cancel()
            }
        }
    }
}
