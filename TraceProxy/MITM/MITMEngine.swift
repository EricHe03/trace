//
//  MITMEngine.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/24.
//

import Foundation
import TraceCore

protocol MITMEngine: AnyObject {
    @discardableResult
    func start() throws -> NIOMITMProxyEngine.Endpoint
    func stop()
    func activeConnectionCount() -> Int
}

extension NIOMITMProxyEngine: MITMEngine {}

/// Phase-5 scaffolding wrapper for the modular MITM engine path.
///
/// Current behavior intentionally delegates to the existing NIO engine
/// so rollout can be gated without traffic-path regressions.
final class MITMEngineV2: MITMEngine, @unchecked Sendable {
    private let delegate: NIOMITMProxyEngine

    init(
        port: UInt16,
        eventLog: NDJSONLogWriter?,
        throttler: PacketThrottler?,
        interceptor: (any InterceptionProviding)?,
        captureConfigProvider: @escaping () -> CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?,
        shouldMitmConnect: @escaping (String, UInt16) -> Bool,
        isTransparentTLSEnabled: @escaping () -> Bool,
        shouldFailOpenAfterMITMFailure: @escaping (String, UInt16, String, MITMFailoverContext) -> Bool,
        onMITMFailure: ((String, String) -> Void)?
    ) {
        delegate = NIOMITMProxyEngine(
            port: port,
            eventLog: eventLog,
            throttler: throttler,
            interceptor: interceptor,
            captureConfigProvider: captureConfigProvider,
            onRequestCaptured: onRequestCaptured,
            shouldMitmConnect: shouldMitmConnect,
            isTransparentTLSEnabled: isTransparentTLSEnabled,
            shouldFailOpenAfterMITMFailure: shouldFailOpenAfterMITMFailure,
            onMITMFailure: onMITMFailure
        )
    }

    @discardableResult
    func start() throws -> NIOMITMProxyEngine.Endpoint {
        try delegate.start()
    }

    func stop() {
        delegate.stop()
    }

    func activeConnectionCount() -> Int {
        delegate.activeConnectionCount()
    }
}
