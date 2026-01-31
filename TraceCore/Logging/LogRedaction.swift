//
//  LogRedaction.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import CommonCrypto
import Foundation

/// Provides stable redaction helpers for logs and NDJSON exports.
public enum LogRedaction {
    /// Returns a stable SHA-256 hex prefix for correlation without exposing raw values.
    public static func hash(_ value: String, prefixLength: Int = 12) -> String {
        guard let data = value.data(using: .utf8) else { return "invalid" }
        let digest = sha256(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let length = max(4, min(prefixLength, hex.count))
        return String(hex.prefix(length))
    }

    private static func sha256(data: Data) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash
    }
}
