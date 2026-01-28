//
//  NetworkRequest+Tags.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

public extension NetworkRequest {
    // MARK: - Protocol Detection

    /// Indicates whether the request uses HTTP/3.
    var isHTTP3: Bool {
        protocolVersion == .http3
    }

    /// Indicates whether the request is a WebSocket upgrade.
    var isWebSocket: Bool {
        statusCode == 101 && responseHeaders.contains { header in
            header.key.lowercased() == "upgrade" && header.value.lowercased().contains("websocket")
        }
    }

    /// Indicates whether the request is gRPC.
    var isGRPC: Bool {
        contentType?.lowercased().contains("application/grpc") ?? false
    }

    /// Indicates whether the request is GraphQL.
    var isGraphQL: Bool {
        // GraphQL path heuristic.
        if url.lowercased().contains("/graphql") {
            return true
        }
        // GraphQL content-type heuristic.
        if contentType?.lowercased().contains("application/graphql") ?? false {
            return true
        }
        return false
    }

    // MARK: - TLS/Security Detection

    /// Indicates whether this is a TLS passthrough (non-decrypted HTTPS) request.
    /// These are CONNECT requests that couldn't be decrypted due to MITM failure or bypass.
    var isTLSPassthrough: Bool {
        // Check for TLS passthrough marker
        method == .connect && (
            statusMessage?.lowercased().contains("tls passthrough") == true ||
                statusMessage?.lowercased().contains("passthrough") == true
        )
    }

    /// Returns the reason for TLS passthrough if available.
    var tlsPassthroughReason: String? {
        guard isTLSPassthrough else { return nil }

        // Check for X-Trace-Note header which contains the reason
        if let noteHeader = requestHeaders.first(where: { $0.key == "X-Trace-Note" }) {
            return noteHeader.value
        }

        return statusMessage
    }

    /// Indicates whether certificate pinning was likely detected.
    /// This is a heuristic based on TLS handshake failure patterns.
    var isPinningLikely: Bool {
        guard isTLSPassthrough else { return false }

        // IMPORTANT:
        // A TLS handshake failure (e.g. "bad certificate") can be caused by:
        // - Root CA not trusted / full trust not enabled on device
        // - App/extension using different Root CAs
        // - Real certificate pinning
        //
        // So we only flag "pinning likely" when the reason explicitly mentions pinning.
        guard let reason = tlsPassthroughReason?.lowercased() else { return false }
        return reason.contains("certificate pinning") ||
            reason.contains("cert pinning") ||
            reason.contains("pinned certificate") ||
            reason.contains("pinning requirements") ||
            reason.contains("possible_pinning_or_strict_trust")
    }

    // MARK: - Reliability Detection

    /// Indicates whether the request likely failed.
    var isFailed: Bool {
        // TLS passthrough is not a failure - it's expected for pinned apps
        if isTLSPassthrough {
            return false
        }

        // Missing status with negligible duration suggests a failure.
        if statusCode == nil && duration < 0.1 {
            return true
        }
        // Server errors count as failures.
        if let code = statusCode, code >= 500 {
            return true
        }
        return false
    }

    /// Indicates whether the request likely timed out.
    var didTimeout: Bool {
        // Long duration with no status code indicates a timeout.
        statusCode == nil && duration > 30.0
    }

    // MARK: - Performance Detection

    /// Returns the stall duration when the request appears stalled.
    var stallDuration: TimeInterval? {
        guard let phases = timingPhases else { return nil }

        // High time to first byte counts as a stall.
        if let ttfb = phases.ttfb, ttfb > 2.0 {
            return ttfb
        }

        return nil
    }

    // MARK: - Caching Detection

    /// Indicates whether the response appears to be cached.
    var isCached: Bool {
        if let cacheControl = cacheControl?.lowercased() {
            if cacheControl.contains("max-age") || cacheControl.contains("public") {
                // Age header indicates cached delivery.
                if responseHeaders.contains(where: { $0.key.lowercased() == "age" }) {
                    return true
                }
            }
        }

        if let xCache = responseHeaders.first(where: { $0.key.lowercased() == "x-cache" })?.value.lowercased() {
            return xCache.contains("hit")
        }

        return false
    }

    /// Returns the cache source if the response was cached.
    var cacheSource: String? {
        if !isCached { return nil }

        if let xCache = responseHeaders.first(where: { $0.key.lowercased() == "x-cache" })?.value {
            if xCache.lowercased().contains("cloudflare") {
                return "Cloudflare "
            } else if xCache.lowercased().contains("hit") {
                return "CDN "
            }
        }

        if responseHeaders.contains(where: { $0.key.lowercased() == "age" }) {
            return "HTTP "
        }

        return nil
    }

    /// Indicates whether the cached response is stale.
    var isStale: Bool {
        guard isCached else { return false }

        if let cacheControl = cacheControl?.lowercased() {
            return cacheControl.contains("stale-while-revalidate") ||
                cacheControl.contains("stale-if-error")
        }

        if let warning = responseHeaders.first(where: { $0.key.lowercased() == "warning" })?.value {
            return warning.starts(with: "110")
        }

        return false
    }

    /// Number of redirects recorded for the request.
    ///
    /// - Note: Returns `1` when this response is a redirect; otherwise `0`.
    var redirectCount: Int {
        if let chainCount = redirectChain.isEmpty ? nil : redirectChain.count {
            return chainCount
        }
        if let code = statusCode, (300 ... 399).contains(code) {
            return 1 // At minimum this is one redirect.
        }
        return 0
    }

    // MARK: - Analysis Detection

    /// Indicates whether the response content is binary.
    var isBinary: Bool {
        guard let contentType = contentType?.lowercased() else { return false }

        // SVG is XML text, not binary - exclude it
        if contentType.contains("image/svg") {
            return false
        }

        // Keep aligned with DetailView.isBinaryContentType to ensure tagging and UI agree.
        let binaryTypes = [
            "image/", "video/", "audio/",
            "octet-stream",
            "application/pdf",
            "application/zip",
            "application/x-zip-compressed",
            "application/x-gzip",
            "application/gzip",
            "font/"
        ]

        return binaryTypes.contains { contentType.contains($0) }
    }

    // MARK: - Tag Generation

    /// Returns all tags applicable to the request.
    func getAllTags() -> [TagType] {
        var tags: [TagType] = []
        appendProtocolTags(to: &tags)
        appendRealtimeTags(to: &tags)
        appendSecurityTags(to: &tags)
        appendReliabilityTags(to: &tags)
        appendPerformanceTags(to: &tags)
        appendCachingTags(to: &tags)
        appendSourceTags(to: &tags)
        appendAnalysisTags(to: &tags)

        return tags
    }

    private func appendProtocolTags(to tags: inout [TagType]) {
        // Protocol tags (only one is added).
        if isHTTP3 {
            tags.append(.h3)
        } else if isHTTP2 {
            tags.append(.h2)
        }
    }

    private func appendRealtimeTags(to tags: inout [TagType]) {
        if isWebSocket { tags.append(.ws) }
        if isSSE { tags.append(.sse) }
        if isGRPC { tags.append(.grpc) }
        if isGraphQL { tags.append(.graphql) }
    }

    private func appendSecurityTags(to tags: inout [TagType]) {
        if isTLSPassthrough {
            if isPinningLikely {
                tags.append(.pinned)
            } else {
                tags.append(.tlsPassthrough(reason: tlsPassthroughReason))
            }
        }
    }

    private func appendReliabilityTags(to tags: inout [TagType]) {
        if isFailed { tags.append(.failed) }
        if didTimeout { tags.append(.timeout) }
        if wasBlocked { tags.append(.blocked) }
        if wasCancelled { tags.append(.cancelled) }
        if retryAttempts > 0 { tags.append(.retry(count: retryAttempts)) }
    }

    private func appendPerformanceTags(to tags: inout [TagType]) {
        if duration > 5.0 { tags.append(.slow(duration: duration)) }
        if wasThrottled { tags.append(.throttled(profile: throttlingProfile)) }
        if let stall = stallDuration, stall > 2.0 { tags.append(.stalled(duration: stall)) }
    }

    private func appendCachingTags(to tags: inout [TagType]) {
        if isCached { tags.append(.cached(source: cacheSource)) }
        if isStale { tags.append(.stale) }
        if redirectCount > 0 { tags.append(.redirected(count: redirectCount)) }
        if wasRewritten { tags.append(.rewritten) }
    }

    private func appendSourceTags(to tags: inout [TagType]) {
        if isManual { tags.append(.manual) }
        if isReplayed { tags.append(.replayed) }
        if let scriptName = appliedScriptName { tags.append(.script(name: scriptName)) }
        if isMocked { tags.append(.mock) }
    }

    private func appendAnalysisTags(to tags: inout [TagType]) {
        if let size = responseSize, size > 10_000_000 { tags.append(.large(size: size)) }
        if isBinary { tags.append(.binary) }
        if hitBreakpoint { tags.append(.breakpoint) }
    }

    /// Returns the visible tags and overflow count for display.
    ///
    /// - Parameter maxVisible: Maximum number of tags to surface inline.
    /// - Returns: Visible tags and the number of overflowed tags.
    func getVisibleTags(maxVisible: Int = 3) -> (visible: [TagType], overflow: Int) {
        selectVisibleTags(from: getAllTags(), maxVisible: maxVisible)
    }
}
