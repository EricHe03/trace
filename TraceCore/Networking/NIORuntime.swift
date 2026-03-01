//
//  NIORuntime.swift
//  TraceCore
//
//  Created by Justin on 2026/02/13.
//

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOTransportServices

public enum NIORuntimeContext: String {
    case app
    case networkExtension
    case tests
}

public enum NIORuntimeShutdownReason: String {
    case appLifecycle
    case networkExtensionLifecycle
    case tests
    case explicit
}

public struct NIORuntimeResources {
    public let eventLoopGroup: EventLoopGroup
    public let httpClient: HTTPClient
}

public final class NIORuntime: @unchecked Sendable {
    public static let shared = NIORuntime()

    private struct RuntimeState {
        var resources: NIORuntimeResources?
        var appRetainCount: Int = 0
        var networkExtensionRetainCount: Int = 0
        var testRetainCount: Int = 0
    }

    private let lock = NSLock()
    private var state = RuntimeState()

    private init() {}

    /// Starts or reuses the shared NIOTS + AsyncHTTPClient runtime.
    ///
    /// Semantics:
    /// - App: runtime is long-lived by default; explicit shutdown is expected.
    /// - Network Extension: last release auto-shuts down when no other context holds the runtime.
    /// - Tests: last release auto-shuts down when no other context holds the runtime.
    @discardableResult
    public func acquire(for context: NIORuntimeContext) -> NIORuntimeResources {
        lock.lock()
        defer { lock.unlock() }

        if state.resources == nil {
            let eventLoopGroup = NIOTSEventLoopGroup()
            var configuration = HTTPClient.Configuration()
            configuration.timeout = .init(
                connect: .seconds(30),
                read: .seconds(60)
            )
            configuration.ignoreUncleanSSLShutdown = true
            let httpClient = HTTPClient(
                eventLoopGroupProvider: .shared(eventLoopGroup),
                configuration: configuration
            )
            state.resources = NIORuntimeResources(
                eventLoopGroup: eventLoopGroup,
                httpClient: httpClient
            )
        }

        incrementRetainCount(for: context)
        return state.resources!
    }

    public func currentResources() -> NIORuntimeResources? {
        lock.lock()
        defer { lock.unlock() }
        return state.resources
    }

    public func release(for context: NIORuntimeContext) throws {
        let resourcesToShutdown: NIORuntimeResources? = {
            lock.lock()
            defer { lock.unlock() }

            decrementRetainCount(for: context)
            guard shouldAutoShutdown(afterReleasing: context) else {
                return nil
            }
            return clearRuntimeStateLocked()
        }()

        if let resourcesToShutdown {
            try shutdown(resourcesToShutdown)
        }
    }

    public func shutdown(reason: NIORuntimeShutdownReason = .explicit) throws {
        _ = reason
        let resourcesToShutdown: NIORuntimeResources? = {
            lock.lock()
            defer { lock.unlock() }
            return clearRuntimeStateLocked()
        }()

        if let resourcesToShutdown {
            try shutdown(resourcesToShutdown)
        }
    }
}

private extension NIORuntime {
    func incrementRetainCount(for context: NIORuntimeContext) {
        switch context {
        case .app:
            state.appRetainCount += 1
        case .networkExtension:
            state.networkExtensionRetainCount += 1
        case .tests:
            state.testRetainCount += 1
        }
    }

    func decrementRetainCount(for context: NIORuntimeContext) {
        switch context {
        case .app:
            state.appRetainCount = max(0, state.appRetainCount - 1)
        case .networkExtension:
            state.networkExtensionRetainCount = max(0, state.networkExtensionRetainCount - 1)
        case .tests:
            state.testRetainCount = max(0, state.testRetainCount - 1)
        }
    }

    func shouldAutoShutdown(afterReleasing context: NIORuntimeContext) -> Bool {
        switch context {
        case .app:
            // App runtime is intentionally long-lived to avoid churn.
            false
        case .networkExtension, .tests:
            state.appRetainCount == 0 &&
                state.networkExtensionRetainCount == 0 &&
                state.testRetainCount == 0
        }
    }

    func clearRuntimeStateLocked() -> NIORuntimeResources? {
        let resources = state.resources
        state.resources = nil
        state.appRetainCount = 0
        state.networkExtensionRetainCount = 0
        state.testRetainCount = 0
        return resources
    }

    func shutdown(_ resources: NIORuntimeResources) throws {
        try resources.httpClient.syncShutdown()
        try resources.eventLoopGroup.syncShutdownGracefully()
    }
}
