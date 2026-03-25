//
//  CaptureBodyPolicy.swift
//  TraceCore
//
//  Created by Justin on 2026/03/21.
//

import Foundation

public enum CaptureBodyPolicy {
    public static let constrainedInlineThreshold = 128 * 1024
    public static let constrainedBinaryCaptureLimit = 64 * 1024
    public static let constrainedCompressedCaptureLimit = 128 * 1024
    public static let constrainedTextCaptureLimit = 256 * 1024

    public static func effectiveInlineThreshold(
        configuredThreshold: Int,
        memoryConstrained: Bool = RuntimeEnvironment.isPacketTunnelExtension
    ) -> Int {
        let safeThreshold = max(1, configuredThreshold)
        guard memoryConstrained else { return safeThreshold }
        return min(safeThreshold, constrainedInlineThreshold)
    }

    public static func effectiveCaptureLimit(
        configuredLimit: Int,
        contentType: String?,
        contentEncoding: String?,
        memoryConstrained: Bool = RuntimeEnvironment.isPacketTunnelExtension
    ) -> Int {
        let safeLimit = max(0, configuredLimit)
        guard safeLimit > 0 else { return 0 }
        guard memoryConstrained else { return safeLimit }

        if hasCompressedContentEncoding(contentEncoding) {
            return min(safeLimit, constrainedCompressedCaptureLimit)
        }

        let constrainedLimit = isLikelyTextualContentType(contentType)
            ? constrainedTextCaptureLimit
            : constrainedBinaryCaptureLimit
        return min(safeLimit, constrainedLimit)
    }

    public static func isLikelyTextualContentType(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mimeType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let mimeType, !mimeType.isEmpty else { return false }
        if mimeType.hasPrefix("text/") { return true }
        if mimeType == "application/json" || mimeType.hasSuffix("+json") { return true }
        if mimeType == "application/xml" || mimeType.hasSuffix("+xml") { return true }
        if mimeType == "application/x-www-form-urlencoded" { return true }
        if mimeType == "application/graphql-response+json" { return true }
        if mimeType == "application/javascript" || mimeType == "text/javascript" { return true }
        if mimeType == "application/x-javascript" { return true }
        if mimeType == "application/ecmascript" || mimeType == "text/ecmascript" { return true }
        if mimeType == "application/problem+json" || mimeType == "application/problem+xml" { return true }
        return false
    }

    public static func hasCompressedContentEncoding(_ contentEncoding: String?) -> Bool {
        guard let contentEncoding else { return false }
        let encodings = contentEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        return !encodings.isEmpty
    }
}
