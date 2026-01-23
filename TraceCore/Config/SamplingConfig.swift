//
//  SamplingConfig.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public struct SamplingConfig: Codable, Sendable {
    public var enabled: Bool
    public var sampleRate: Double
    public var strategy: SamplingStrategy

    public init(enabled: Bool = false, sampleRate: Double = 1.0, strategy: SamplingStrategy = .random) {
        self.enabled = enabled
        self.sampleRate = sampleRate
        self.strategy = strategy
    }
}

public enum SamplingStrategy: String, Codable, Sendable {
    case random
    case periodic
    case adaptive
}
