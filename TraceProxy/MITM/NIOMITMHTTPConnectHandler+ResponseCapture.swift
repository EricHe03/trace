//
//  NIOMITMHTTPConnectHandler+ResponseCapture.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import NIOCore
import NIOHTTP1
import TraceCore

extension NIOMITMHTTPConnectHandler {
    func clearActiveCapturedRequest() {
        activeCapturedRequest = nil
    }

    func publishCapturedRequest(_ request: NetworkRequest) {
        var finalized = request
        annotateCaptureMetadata(&finalized)
        finalizeCapturedDuration(for: &finalized)
        onRequestCaptured?(finalized)
        clearActiveCapturedRequest()
    }

    func finalizeActiveRequestAsHTTPFailure(
        status: HTTPResponseStatus,
        reason: String
    ) {
        guard var request = activeCapturedRequest else { return }
        request.statusCode = Int(status.code)
        request.statusMessage = status.reasonPhrase
        request.executionErrors.append(ExecutionError(message: reason))
        publishCapturedRequest(request)
    }

    func finalizeActiveRequestAsFailure(reason: String) {
        guard var request = activeCapturedRequest else { return }
        request.executionErrors.append(ExecutionError(message: reason))
        publishCapturedRequest(request)
    }

    func finalizeActiveRequestAsCancellation(reason: String) {
        guard var request = activeCapturedRequest else { return }
        request.wasCancelled = true
        request.executionErrors.append(ExecutionError(message: reason))
        publishCapturedRequest(request)
    }

    func makeOutboundRequestContext(from request: NetworkRequest, fallbackBody: Data) -> OutboundRequestContext? {
        let methodToken = request.requestMethodRaw ?? request.method.rawValue
        let requestHeaders = dictionary(from: request.requestHeaders)
        let requestBodyData = request.requestBody.getData()
            ?? request.requestBody.getString()?.data(using: .utf8)
            ?? fallbackBody
        guard URL(string: request.url) != nil else {
            return nil
        }

        return OutboundRequestContext(
            requestSnapshot: request,
            methodToken: methodToken,
            url: request.url,
            headers: requestHeaders,
            body: requestBodyData
        )
    }

    func makeBaseNetworkRequest(
        flowID: UUID,
        requestURL: String,
        methodToken: String,
        requestVersion: HTTPVersion,
        requestHeaders: [String: String],
        requestBodyData: Data,
        startTime: Date,
        captureConfig: CaptureConfiguration
    ) -> NetworkRequest {
        let uppercasedMethod = methodToken.uppercased()
        let mappedMethod = HTTPMethod(rawValue: uppercasedMethod) ?? .get
        let methodRaw = HTTPMethod(rawValue: uppercasedMethod) == nil ? methodToken : nil
        let traceHeaders = captureConfig.captureHeaders ? traceHeaders(from: requestHeaders) : []
        let requestCharset = BodyStorage.extractCharset(from: requestHeaders)
        let requestContentEncoding = requestHeaders.first(where: { $0.key.lowercased() == "content-encoding" })?.value
        let requestBody = bodyStorage(
            from: requestBodyData,
            charset: requestCharset,
            contentEncoding: requestContentEncoding,
            captureConfig: captureConfig
        )
        var request = NetworkRequest(
            id: flowID,
            url: requestURL,
            method: mappedMethod,
            requestMethodRaw: methodRaw,
            statusCode: nil,
            statusMessage: nil,
            timestamp: startTime,
            duration: 0,
            requestHeaders: traceHeaders,
            responseHeaders: [],
            requestBody: requestBody,
            responseBody: .empty,
            protocolVersion: usesHTTP2StreamSemantics ? .http2 : httpProtocolVersion(from: requestVersion)
        )
        annotateCaptureMetadata(&request)
        return request
    }

    func bodyStorage(
        from data: Data,
        charset: String?,
        contentEncoding: String?,
        captureConfig: CaptureConfiguration,
        decodeCompressedContent: Bool = true
    ) -> BodyStorage {
        guard captureConfig.captureBody, captureConfig.maxBodySize > 0, !data.isEmpty else { return .empty }
        return BodyStorage.from(
            data: data,
            charset: charset,
            maxSize: max(0, captureConfig.maxBodySize),
            contentEncoding: contentEncoding,
            decodeCompressedContent: decodeCompressedContent
        )
    }

    func contentLength(from headers: HTTPHeaders) -> Int? {
        guard let rawValue = headers.first(name: "Content-Length") else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentLength = Int(trimmed), contentLength >= 0 else { return nil }
        return contentLength
    }

    func resolvedResponseBodyBytes(
        declaredContentLength: Int?,
        observedBodyBytes: Int
    ) -> Int {
        if let declaredContentLength, declaredContentLength >= 0 {
            return max(declaredContentLength, observedBodyBytes)
        }
        return observedBodyBytes
    }

    func truncatedBodyStorage(
        fromCapturedData capturedData: Data,
        totalSize: Int,
        charset: String?,
        contentEncoding: String?,
        decodeCompressedContent: Bool,
        maxStoredBodyBytes: Int = Int.max
    ) -> BodyStorage {
        guard !capturedData.isEmpty else { return .empty }
        let effectiveMaxStoredBodyBytes = maxStoredBodyBytes > 0 ? maxStoredBodyBytes : Int.max

        let capturedStorage = BodyStorage.from(
            data: capturedData,
            charset: charset,
            maxSize: effectiveMaxStoredBodyBytes,
            contentEncoding: contentEncoding,
            decodeCompressedContent: decodeCompressedContent
        )

        switch capturedStorage {
        case let .inline(data, capturedCharset, compressionInfo):
            return .truncated(
                data,
                totalSize: max(totalSize, data.count),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .file(url, capturedCharset, compressionInfo):
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? capturedData.count
            return .truncatedFile(
                url,
                totalSize: max(totalSize, fileSize),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .truncated(data, capturedTotalSize, capturedCharset, compressionInfo):
            return .truncated(
                data,
                totalSize: max(totalSize, max(capturedTotalSize, data.count)),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .truncatedFile(url, capturedTotalSize, capturedCharset, compressionInfo):
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? capturedData.count
            return .truncatedFile(
                url,
                totalSize: max(totalSize, max(capturedTotalSize, fileSize)),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case .empty:
            return .empty
        }
    }

    func transitionAfterResponse(
        closeAfterSend: Bool,
        context: ChannelHandlerContext
    ) {
        let shouldEmitPipeliningBadRequest = shouldCloseAfterForwardingResponse && !closeAfterSend
        if shouldEmitPipeliningBadRequest {
            logConnectStage(
                stage: "request_pipelining",
                outcome: "emit_400_after_response",
                detail: "reason=unsupported"
            )
        }
        shouldCloseAfterForwardingResponse = false
        if shouldEmitPipeliningBadRequest {
            state = .closed
            sendResponse(
                status: .badRequest,
                body: "HTTP request pipelining is not supported by the NIO engine yet",
                closeAfterSend: true,
                context: context
            )
            return
        }

        state = closeAfterSend ? .closed : .waitingForRequest
        if closeAfterSend {
            context.close(promise: nil)
        }
    }

    func logResponseCaptureDecision(
        pipeline: String,
        requestID: UUID,
        statusCode: Int?,
        responseHeaders: [TraceHTTPHeader],
        bodyStorage: BodyStorage,
        observedBodyBytes: Int,
        declaredContentLength: Int?,
        captureBodyEnabled: Bool,
        captureBodyLimit: Int,
        decodeCompressedContent: Bool,
        storageContentEncoding: String?
    ) {
        let hostHash = connectTargetHost.map { LogRedaction.hash($0) } ?? "unknown"
        let statusToken = statusCode.map(String.init) ?? "nil"
        let declaredContentLengthToken = declaredContentLength.map(String.init) ?? "nil"
        let contentType = responseHeaderValue(name: "content-type", in: responseHeaders)
        let headerContentEncoding = responseHeaderValue(name: "content-encoding", in: responseHeaders)
        let transferEncoding = responseHeaderValue(name: "transfer-encoding", in: responseHeaders)
        let compressionInfo = bodyStorage.getCompressionInfo()
        let decompressionState = if let compressionInfo {
            compressionInfo.decompressionSuccess ? "success" : "failed"
        } else {
            "none"
        }
        let previewHint = responsePreviewHint(
            contentType: contentType,
            headerContentEncoding: headerContentEncoding,
            decodeCompressedContent: decodeCompressedContent,
            compressionInfo: compressionInfo
        )
        let responseUIRenderHint = responseUIRenderHint(previewHint: previewHint)
        var messageParts = [
            "mode=\(ingressModeLabel)",
            "id=\(connectionID)",
            "host_hash=\(hostHash)",
            "request_id=\(requestID.uuidString)",
            "capture_path=\(capturePathForCurrentContext().rawValue)",
            "pipeline=\(pipeline)",
            "status=\(statusToken)",
            "capture_body=\(captureBodyEnabled)",
            "capture_limit=\(max(0, captureBodyLimit))",
            "observed_bytes=\(max(0, observedBodyBytes))",
            "declared_content_length=\(declaredContentLengthToken)",
            "storage=\(bodyStorageKindToken(bodyStorage))",
            "stored_total_bytes=\(bodyStorage.totalSize)",
            "stored_captured_bytes=\(bodyStorage.capturedSize)",
            "stored_truncated=\(bodyStorage.isTruncated)",
            "stored_file=\(bodyStorage.isFile)",
            "charset=\(normalizedToken(bodyStorage.getCharset()))",
            "header_content_type=\(normalizedContentTypeToken(contentType))",
            "header_content_encoding=\(normalizedHeaderListToken(headerContentEncoding))",
            "storage_content_encoding=\(normalizedHeaderListToken(storageContentEncoding))",
            "transfer_encoding=\(normalizedHeaderListToken(transferEncoding))",
            "decode_compressed=\(decodeCompressedContent)",
            "compression_algorithm=\(normalizedHeaderListToken(compressionInfo?.algorithm))",
            "decompression=\(decompressionState)",
            "preview_hint=\(previewHint)",
            "ui_render_hint=\(responseUIRenderHint)"
        ]
        if let flowID = upstreamHint?.flowID {
            messageParts.append("capture_flow_id=\(flowID)")
        }
        if let metadataVersion = upstreamHint?.version.rawValue {
            messageParts.append("capture_metadata_version=\(metadataVersion)")
        }
        let message = messageParts.joined(separator: " ")

        ProxyLog.mitm.debug("event=proxy.nio_response_capture \(message, privacy: .public)")
        eventLog?.append(type: "proxy_nio_response_capture", msg: message)
    }

    func responseHeaderValue(name: String, in headers: [TraceHTTPHeader]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func bodyStorageKindToken(_ storage: BodyStorage) -> String {
        switch storage {
        case .inline:
            "inline"
        case .file:
            "file"
        case .truncated:
            "truncated"
        case .truncatedFile:
            "truncated_file"
        case .empty:
            "empty"
        }
    }

    func normalizedToken(_ value: String?) -> String {
        guard let value else { return "none" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        return trimmed.lowercased()
            .replacingOccurrences(of: "\t", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    func normalizedHeaderListToken(_ value: String?) -> String {
        guard let value else { return "none" }
        let tokens = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "none" }
        return tokens.joined(separator: "+")
    }

    func normalizedContentTypeToken(_ value: String?) -> String {
        guard let value else { return "none" }
        let mimeType = value
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedToken(mimeType.map { String($0) })
    }

    func responsePreviewHint(
        contentType: String?,
        headerContentEncoding: String?,
        decodeCompressedContent: Bool,
        compressionInfo: CompressionInfo?
    ) -> String {
        let normalizedContentEncoding = normalizedHeaderListToken(headerContentEncoding)
        if !decodeCompressedContent,
           normalizedContentEncoding != "none",
           normalizedContentEncoding != "identity" {
            return "compressed_raw_passthrough"
        }
        if let compressionInfo, !compressionInfo.decompressionSuccess {
            return "decompression_failed"
        }
        let contentTypeToken = normalizedContentTypeToken(contentType)
        if isLikelyTextContentType(contentTypeToken) {
            return "text_candidate"
        }
        if contentTypeToken == "none" {
            return "unknown_mime"
        }
        return "binary_candidate"
    }

    func responseUIRenderHint(previewHint: String) -> String {
        switch previewHint {
        case "text_candidate":
            "text"
        case "decompression_failed":
            "hex_fallback"
        case "compressed_raw_passthrough", "binary_candidate", "unknown_mime":
            "hex"
        default:
            "auto"
        }
    }

    func isLikelyTextContentType(_ contentTypeToken: String) -> Bool {
        if contentTypeToken.hasPrefix("text/") {
            return true
        }
        let textMarkers = [
            "json",
            "xml",
            "javascript",
            "x-www-form-urlencoded",
            "graphql",
            "yaml",
            "toml",
            "csv"
        ]
        return textMarkers.contains { contentTypeToken.contains($0) }
    }

    func annotateCaptureMetadata(_ request: inout NetworkRequest) {
        request.capturePath = capturePathForCurrentContext()
        request.captureFlowID = upstreamHint?.flowID
        request.capturePolicyModeRaw = upstreamHint?.policyModeRaw
        request.captureMetadataVersion = upstreamHint?.version.rawValue
    }

    func capturePathForCurrentContext() -> NetworkCapturePath {
        switch ingressMode {
        case .proxy:
            upstreamHint == nil ? .proxy : .proxyWithUpstreamHint
        case .tunneledHTTPS:
            upstreamHint == nil ? .tunneledHTTPS : .tunneledHTTPSWithUpstreamHint
        }
    }

    func finalizeCapturedDuration(for request: inout NetworkRequest) {
        let elapsed = Date().timeIntervalSince(request.timestamp)
        guard elapsed.isFinite else { return }
        request.duration = max(request.duration, max(0, elapsed))

        // Compute timing phases for proxy path (heuristic estimates without precise timestamps)
        // Proxy path doesn't have granular DNS/TCP/TLS timing, so we estimate based on response size
        request.timingPhases = computeProxyPathTimingPhases(duration: request.duration, responseSize: request.responseBody.totalSize)
    }

    /// Compute heuristic timing phases for proxy path
    /// Since we don't have precise TTFB/content-download boundaries, we estimate based on response size
    private func computeProxyPathTimingPhases(duration: TimeInterval, responseSize: Int) -> NetworkTimingPhases? {
        guard duration > 0.001 else { return nil }

        // Conservative estimate: assume smaller responses are faster
        // Larger responses spend more time in content-download
        let responseSizeMB = Double(responseSize) / (1024 * 1024)
        let contentDownloadRatio = min(0.8, max(0.3, responseSizeMB * 0.5))

        let requestSent = duration * 0.1        // ~10% for request transmission
        let ttfb = duration * (0.4 - contentDownloadRatio * 0.2)  // 20-40% waiting
        let contentDownload = duration - requestSent - ttfb

        return NetworkTimingPhases(
            requestSent: requestSent > 0.001 ? requestSent : nil,
            ttfb: ttfb > 0.001 ? ttfb : nil,
            contentDownload: contentDownload > 0.001 ? contentDownload : nil
        )
    }

    func throttle(
        direction: PacketThrottler.Direction,
        bytes: Int,
        context: ChannelHandlerContext,
        operation: @escaping () -> Void
    ) {
        guard let throttler, bytes > 0 else {
            operation()
            return
        }
        let markerBytes = min(max(bytes, 1), 64 * 1024)
        let marker = Data(repeating: 0, count: markerBytes)
        throttler.process(packet: marker, direction: direction) {
            context.eventLoop.execute {
                operation()
            }
        }
    }
}
