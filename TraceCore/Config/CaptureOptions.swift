//
//  CaptureOptions.swift
//  TraceCore
//
//  Created by Justin on 2026/01/24.
//

import Foundation

public struct CaptureOptions: Codable, Sendable, Equatable {
    public var captureHeaders: Bool
    public var captureBody: Bool
    public var maxBodySize: Int

    public static let `default` = CaptureOptions(
        captureHeaders: true,
        captureBody: true,
        maxBodySize: 10 * 1024 * 1024
    )

    public init(captureHeaders: Bool, captureBody: Bool, maxBodySize: Int) {
        self.captureHeaders = captureHeaders
        self.captureBody = captureBody
        self.maxBodySize = maxBodySize
    }

    public func normalized() -> CaptureOptions {
        let clampedMax = max(0, maxBodySize)
        return CaptureOptions(
            captureHeaders: captureHeaders,
            captureBody: captureBody,
            maxBodySize: clampedMax
        )
    }
}
