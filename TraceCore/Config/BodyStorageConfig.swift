//
//  BodyStorageConfig.swift
//  TraceCore
//
//  Created by Justin on 2026/01/24.
//

import Foundation

public struct BodyStorageConfig: Codable, Sendable, Equatable {
    public var inlineThreshold: Int
    public var truncationThreshold: Int
    public var previewSize: Int

    public static let `default` = BodyStorageConfig(
        inlineThreshold: 1024 * 1024,
        truncationThreshold: 10 * 1024 * 1024,
        previewSize: 1024 * 1024
    )

    public init(inlineThreshold: Int, truncationThreshold: Int, previewSize: Int) {
        self.inlineThreshold = inlineThreshold
        self.truncationThreshold = truncationThreshold
        self.previewSize = previewSize
    }

    public func normalized() -> BodyStorageConfig {
        let safeInline = max(1, inlineThreshold)
        let safeTruncation = max(safeInline, truncationThreshold)
        let safePreview = min(max(1, previewSize), safeTruncation)
        return BodyStorageConfig(
            inlineThreshold: safeInline,
            truncationThreshold: safeTruncation,
            previewSize: safePreview
        )
    }
}
