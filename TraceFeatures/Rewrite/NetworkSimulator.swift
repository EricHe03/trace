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
        let jitter = Int.random(in: -variance ... variance)
        let delay = max(0, baseDelay + jitter)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
    }

    public func simulateFailure(type: FailureType) throws {
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
}
