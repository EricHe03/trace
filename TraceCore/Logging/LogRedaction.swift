//
//  LogRedaction.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import CryptoKit
import Foundation

/// Provides stable redaction helpers for logs and NDJSON exports.
public enum LogRedaction {
    /// Returns a stable SHA-256 hex prefix for correlation without exposing raw values.
    public static func hash(_ value: String, prefixLength: Int = 12) -> String {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return "invalid" }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let length = max(4, min(prefixLength, hex.count))
        return String(hex.prefix(length))
    }
}
