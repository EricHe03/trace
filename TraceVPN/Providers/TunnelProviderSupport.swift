//
//  TunnelProviderSupport.swift
//  TraceVPN
//
//  Created by Codex on 2026/03/17.
//

import Foundation
import os

final class CompletionHandlerBox<T>: @unchecked Sendable {
    private let handler: (T) -> Void

    init(_ handler: @escaping (T) -> Void) {
        self.handler = handler
    }

    func call(_ value: T) {
        handler(value)
    }
}

final class UnsafeSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

actor CompletionOnce {
    private let handler: CompletionHandlerBox<Void>
    private let queue: DispatchQueue
    private var didComplete = false

    init(handler: CompletionHandlerBox<Void>, queue: DispatchQueue) {
        self.handler = handler
        self.queue = queue
    }

    func call() {
        guard !didComplete else { return }
        didComplete = true
        queue.async {
            self.handler.call(())
        }
    }
}

actor StartTunnelCompletion {
    private let invocationID: String
    private let startWall: Date
    private let handler: CompletionHandlerBox<Error?>
    private let queue: DispatchQueue
    private var didComplete = false

    init(invocationID: String, startWall: Date, handler: CompletionHandlerBox<Error?>, queue: DispatchQueue) {
        self.invocationID = invocationID
        self.startWall = startWall
        self.handler = handler
        self.queue = queue
    }

    func complete(_ error: Error?) {
        guard !didComplete else { return }
        didComplete = true

        let elapsedMs = Int(Date().timeIntervalSince(startWall) * 1000)
        if let error {
            VPNLog.tunnel.error(
                "event=vpn.tunnel_start outcome=failure id=\(self.invocationID, privacy: .public) duration_ms=\(elapsedMs) error=\(String(describing: error), privacy: .public)"
            )
        } else {
            VPNLog.tunnel.info(
                "event=vpn.tunnel_start outcome=success id=\(self.invocationID, privacy: .public) duration_ms=\(elapsedMs)"
            )
        }
        queue.async {
            self.handler.call(error)
        }
    }
}

struct AppMessageCompletion: @unchecked Sendable {
    private let handler: CompletionHandlerBox<Data?>?
    private let queue: DispatchQueue

    init(handler: ((Data?) -> Void)?, queue: DispatchQueue) {
        self.handler = handler.map { CompletionHandlerBox($0) }
        self.queue = queue
    }

    func call(_ data: Data?) {
        guard let handler else { return }
        queue.async {
            handler.call(data)
        }
    }

    static func call(handler: ((Data?) -> Void)?, queue: DispatchQueue, data: Data?) {
        guard let handler else { return }
        queue.async {
            handler(data)
        }
    }
}
