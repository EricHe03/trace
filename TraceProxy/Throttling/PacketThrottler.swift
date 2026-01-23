//
//  PacketThrottler.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

/// Applies bandwidth, latency, and packet loss simulation for packets in the tunnel.
/// - Note: Processing is serialized on a private queue and may drop packets to simulate loss.
public final class PacketThrottler {
    /// Packet direction used to apply upload/download-specific rates.
    public enum Direction {
        case upload
        case download
    }

    public init() {
        // Concurrency: Enable re-entrancy checks so we can avoid sync hops on the throttler queue.
        queue.setSpecific(key: queueKey, value: queueToken)
    }

    private let queue = DispatchQueue(label: "com.trace.packet.throttler", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueToken: UInt8 = 1
    private var state: NetworkThrottlingState = .disabled
    private var uploadNextTime: TimeInterval = 0
    private var downloadNextTime: TimeInterval = 0

    /// Updates throttling configuration and resets pacing to "now".
    public func updateState(_ newState: NetworkThrottlingState) {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            state = newState
            let now = CFAbsoluteTimeGetCurrent()
            uploadNextTime = now
            downloadNextTime = now
            return
        }
        queue.sync {
            self.state = newState
            let now = CFAbsoluteTimeGetCurrent()
            self.uploadNextTime = now
            self.downloadNextTime = now
        }
    }

    /// Enqueues a packet for throttled delivery.
    /// - Important: The handler runs on the throttler queue and may never be called if the packet is dropped.
    public func process(packet: Data, direction: Direction, handler: @escaping () -> Void) {
        // Fast path: when throttling is disabled, avoid queueing blocks that retain packet data.
        // Still honor the contract that handlers run on the throttler queue.
        let snapshot: NetworkThrottlingState =
            if DispatchQueue.getSpecific(key: queueKey) == queueToken {
                state
            } else {
                queue.sync { state }
            }
        guard snapshot.activeCondition != nil else {
            if DispatchQueue.getSpecific(key: queueKey) == queueToken {
                handler()
            } else {
                queue.sync {
                    handler()
                }
            }
            return
        }

        queue.async {
            guard let condition = self.state.activeCondition else {
                handler()
                return
            }

            let loss = max(0.0, min(1.0, condition.packetLoss))
            if loss >= 1.0 {
                return
            }
            if loss > 0.0, Double.random(in: 0 ..< 1) < loss {
                return
            }

            let rateKBps = direction == .download ? condition.downloadSpeed : condition.uploadSpeed
            guard rateKBps > 0 else {
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            let rateBytesPerSecond = Double(rateKBps) * 1024.0
            let serializationDelay = Double(packet.count) / rateBytesPerSecond
            let latencySeconds = Double(condition.latency) / 1000.0

            let nextTime = direction == .download ? self.downloadNextTime : self.uploadNextTime
            let baseTime = max(now, nextTime)
            let scheduledTime = baseTime + latencySeconds
            let updatedNextTime = baseTime + serializationDelay

            if direction == .download {
                self.downloadNextTime = updatedNextTime
            } else {
                self.uploadNextTime = updatedNextTime
            }

            let delay = max(0, scheduledTime - now)
            if delay == 0 {
                handler()
            } else {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    handler()
                }
            }
        }
    }
}
