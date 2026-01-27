//
//  NetworkSimulator.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public enum FailureType: String, Codable, Sendable {
    case timeout
    case connectionReset
    case corruptData
    case packetLoss
}

public enum NetworkSimulationError: Error, Sendable {
    case timeout
    case connectionReset
    case packetLoss
}

public actor NetworkSimulator {
    public init() {}

    public func applyThrottle(bandwidth: Int, to data: Data) async -> Data {
        guard bandwidth > 0 else { return data }
        let chunkSize = max(1024, bandwidth / 10)
        var output = Data()
        var index = 0
        while index < data.count {
            let end = min(data.count, index + chunkSize)
            output.append(data[index ..< end])
            index = end
            let delayNs = UInt64(Double(chunkSize) / Double(bandwidth) * 1_000_000_000)
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
        return output
    }

    public func applyJitter(baseDelay: Int, variance: Int) async {
        let delay = Self.jitteredDelay(baseDelay: baseDelay, variance: variance)
        if delay > 0 {
            let maxDelayMs = UInt64.max / 1_000_000
            let delayMs = min(UInt64(delay), maxDelayMs)
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
    }

    public nonisolated func simulateFailure(type: FailureType) throws {
        switch type {
        case .timeout:
            throw NetworkSimulationError.timeout
        case .connectionReset:
            throw NetworkSimulationError.connectionReset
        case .packetLoss:
            throw NetworkSimulationError.packetLoss
        case .corruptData:
            return
        }
    }

    static func jitteredDelay(
        baseDelay: Int,
        variance: Int,
        randomInRange: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }
    ) -> Int {
        let normalizedVariance: Int = {
            if variance == Int.min { return Int.max }
            return Swift.abs(variance)
        }()

        let jitterRange = -normalizedVariance ... normalizedVariance
        let jitter = randomInRange(jitterRange)

        let (sum, overflow) = baseDelay.addingReportingOverflow(jitter)
        let safeSum: Int = if overflow {
            (baseDelay >= 0 && jitter >= 0) ? Int.max : Int.min
        } else {
            sum
        }

        return max(0, safeSum)
    }
}
