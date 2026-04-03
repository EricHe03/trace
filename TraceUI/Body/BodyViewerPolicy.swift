//
//  BodyViewerPolicy.swift
//  TraceUI
//
//  Created by Codex on 2026/03/27.
//

import Foundation

/// Centralized viewer budgets so large payloads can degrade gracefully without changing core UX.
public enum BodyViewerPolicy {
    public static let initialStructuredTextLoadBytes = 128 * 1024
    public static let initialPlainTextLoadBytes = 256 * 1024
    public static let initialBinaryLoadBytes = 256 * 1024

    public static let expandedStructuredTextLoadBytes = 384 * 1024
    public static let expandedPlainTextLoadBytes = 768 * 1024
    public static let expandedBinaryLoadBytes = 512 * 1024

    public static let automaticStructuredRenderBytes = 256 * 1024
    public static let jsonStructuredParsingBytes = 256 * 1024
    public static let networkBodySearchBytes = 32 * 1024
    public static let imageThumbnailMaxPixelSize = 2400

    public static func loadLimit(
        contentType: String?,
        requestedFullLoad: Bool,
        isBinary: Bool
    ) -> Int {
        if isBinary {
            return requestedFullLoad ? expandedBinaryLoadBytes : initialBinaryLoadBytes
        }

        if isStructuredTextContentType(contentType) {
            return requestedFullLoad ? expandedStructuredTextLoadBytes : initialStructuredTextLoadBytes
        }

        return requestedFullLoad ? expandedPlainTextLoadBytes : initialPlainTextLoadBytes
    }

    public static func shouldPreferLightweightRenderer(
        contentType: String?,
        byteCount: Int
    ) -> Bool {
        guard byteCount > automaticStructuredRenderBytes else { return false }
        return isStructuredTextContentType(contentType) || isMultipartContentType(contentType)
    }

    public static func shouldBypassJSONStructuredParsing(byteCount: Int) -> Bool {
        byteCount > jsonStructuredParsingBytes
    }

    public static func isStructuredTextContentType(_ contentType: String?) -> Bool {
        guard let contentType = contentType?.lowercased() else { return false }
        return contentType.contains("json") ||
            contentType.contains("xml") ||
            contentType.contains("html") ||
            contentType.contains("javascript") ||
            contentType.contains("css")
    }

    public static func isMultipartContentType(_ contentType: String?) -> Bool {
        contentType?.lowercased().contains("multipart") == true
    }
}
