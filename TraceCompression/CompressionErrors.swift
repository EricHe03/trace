//
//  CompressionErrors.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Defines errors for streaming compression and decompression.
public enum CompressionError: LocalizedError {
    case invalidInput(String)
    case invalidFormat(String)
    case initializationFailed(String)
    case decompressionFailed(String)
    case notInitialized(String)
    case bufferTooSmall(String)
    case unknownError(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInput(message):
            message
        case let .invalidFormat(message):
            message
        case let .initializationFailed(message):
            message
        case let .decompressionFailed(message):
            message
        case let .notInitialized(message):
            message
        case let .bufferTooSmall(message):
            message
        case let .unknownError(message):
            message
        }
    }
}
