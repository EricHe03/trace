//
//  HTTP3MitmPipeline.swift
//  TraceQUIC
//
//  Created by Codex on 2026/02/18.
//

import Foundation
import TraceCore

public enum HTTP3MitmPipelineError: LocalizedError, Sendable {
    case blockedByInterceptor
    case interceptorFailure(InterceptionFailure)
    case invalidModifiedRequestURL(String)

    public var errorDescription: String? {
        switch self {
        case .blockedByInterceptor:
            "HTTP/3 request blocked by interceptor"
        case let .interceptorFailure(failure):
            "HTTP/3 request failed in interceptor: \(failure.rawValue)"
        case let .invalidModifiedRequestURL(url):
            "Interceptor returned invalid request URL: \(url)"
        }
    }
}

public struct HTTP3MitmPipelineResponse: Sendable {
    public let streamID: UInt64
    public let statusCode: Int
    public let responseHeaders: [HTTP3HeaderField]
    public let responseBody: Data
    public let capturedRequest: NetworkRequest

    public init(
        streamID: UInt64,
        statusCode: Int,
        responseHeaders: [HTTP3HeaderField],
        responseBody: Data,
        capturedRequest: NetworkRequest
    ) {
        self.streamID = streamID
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.capturedRequest = capturedRequest
    }
}

/// Runs HTTP/3 request/response interception and capture persistence through existing TraceCore contracts.
public actor HTTP3MitmPipeline {
    private let interceptor: (any InterceptionProviding)?
    private let http3Client: any HTTP3Client
    private var samplingSequence: UInt64 = 0

    public init(
        interceptor: (any InterceptionProviding)? = nil,
        http3Client: any HTTP3Client = URLSessionHTTP3Client()
    ) {
        self.interceptor = interceptor
        self.http3Client = http3Client
    }

    public func process(
        flowID: UUID,
        event: HTTP3StreamEvent,
        authorityFallback: String? = nil,
        timeout: TimeInterval = 30,
        requiresHTTP3: Bool = true,
        allowHTTPVersionFallback: Bool = false
    ) async throws -> HTTP3MitmPipelineResponse {
        let startTime = Date()
        let requestHead = try HTTP3Bridge.requestHead(from: event, authorityFallback: authorityFallback)

        let requestBody = event.body.isEmpty ? nil : event.body
        var upstreamURL = requestHead.url
        var upstreamMethod = requestHead.method
        var upstreamHeaders = requestHead.headers
        var upstreamBody = requestBody

        let seedRequest = makeBaseRequest(
            flowID: flowID,
            requestHead: requestHead,
            requestBody: requestBody
        )
        let interceptionBaseRequest = seedRequest

        if let interceptor {
            let interceptionResult = await interceptor.interceptRequest(
                flowId: flowID,
                url: requestHead.url.absoluteString,
                method: requestHead.method,
                headers: HTTP3Bridge.toDictionary(upstreamHeaders),
                body: requestBody
            )

            switch interceptionResult {
            case .blocked:
                throw HTTP3MitmPipelineError.blockedByInterceptor
            case let .failed(failure):
                throw HTTP3MitmPipelineError.interceptorFailure(failure)
            case let .mocked(mockedRequest):
                return try await finalizeResponse(
                    streamID: event.streamID,
                    request: mockedRequest,
                    fallbackStatusCode: mockedRequest.statusCode ?? 200,
                    startTime: startTime
                )
            case let .modified(modifiedRequest):
                guard let modifiedURL = URL(string: modifiedRequest.url) else {
                    throw HTTP3MitmPipelineError.invalidModifiedRequestURL(modifiedRequest.url)
                }

                upstreamURL = modifiedURL
                if let requestMethodRaw = modifiedRequest.requestMethodRaw,
                   !requestMethodRaw.isEmpty {
                    upstreamMethod = requestMethodRaw
                } else {
                    upstreamMethod = modifiedRequest.method.rawValue
                }
                upstreamHeaders = modifiedRequest.requestHeaders
                    .filter { !$0.key.hasPrefix(":") }
                    .map { HTTP3HeaderField(name: $0.key, value: $0.value) }
                upstreamBody = modifiedRequest.requestBody.getData()
            }
        }

        let upstreamResponse = try await http3Client.execute(
            HTTP3ClientRequest(
                url: upstreamURL,
                method: upstreamMethod,
                headers: upstreamHeaders,
                body: upstreamBody,
                timeout: timeout,
                requiresHTTP3: requiresHTTP3,
                allowHTTPVersionFallback: allowHTTPVersionFallback
            )
        )

        let responseHeaders = upstreamResponse.headers
        let responseTraceHeaders = HTTP3Bridge.toTraceHeaders(responseHeaders, includePseudoHeaders: false)

        var responseRequest = interceptionBaseRequest
        responseRequest.url = upstreamResponse.finalURL.absoluteString

        let statusMessage = HTTPURLResponse.localizedString(forStatusCode: upstreamResponse.statusCode)
        let interceptedResponse: NetworkRequest = if let interceptor {
            await interceptor.interceptResponse(
                request: responseRequest,
                statusCode: upstreamResponse.statusCode,
                statusMessage: statusMessage,
                headers: responseTraceHeaders,
                body: upstreamResponse.body
            )
        } else {
            buildResponseWithoutInterceptor(
                request: responseRequest,
                statusCode: upstreamResponse.statusCode,
                statusMessage: statusMessage,
                responseHeaders: responseTraceHeaders,
                responseBody: upstreamResponse.body
            )
        }

        return try await finalizeResponse(
            streamID: event.streamID,
            request: interceptedResponse,
            fallbackStatusCode: upstreamResponse.statusCode,
            startTime: startTime
        )
    }
}

private extension HTTP3MitmPipeline {
    func makeBaseRequest(
        flowID: UUID,
        requestHead: HTTP3RequestHead,
        requestBody: Data?
    ) -> NetworkRequest {
        let methodToken = requestHead.method.uppercased()
        let method = HTTPMethod(rawValue: methodToken) ?? .get
        let requestMethodRaw = HTTPMethod(rawValue: methodToken) == nil ? requestHead.method : nil
        let headers = HTTP3Bridge.toTraceHeaders(requestHead.headers, includePseudoHeaders: false)
        let charset = BodyStorage.extractCharset(from: headers)
        let contentEncoding = headerValue(named: "Content-Encoding", in: headers)
        let bodyStorage: BodyStorage = if let requestBody {
            BodyStorage.from(
                data: requestBody,
                charset: charset,
                contentEncoding: contentEncoding
            )
        } else {
            .empty
        }

        return NetworkRequest(
            id: flowID,
            url: requestHead.url.absoluteString,
            method: method,
            requestMethodRaw: requestMethodRaw,
            statusCode: nil,
            statusMessage: nil,
            timestamp: Date(),
            duration: 0,
            requestHeaders: headers,
            responseHeaders: [],
            requestBody: bodyStorage,
            responseBody: .empty,
            protocolVersion: .http3
        )
    }

    func buildResponseWithoutInterceptor(
        request: NetworkRequest,
        statusCode: Int,
        statusMessage: String,
        responseHeaders: [TraceHTTPHeader],
        responseBody: Data
    ) -> NetworkRequest {
        let charset = BodyStorage.extractCharset(from: responseHeaders)
        let contentEncoding = headerValue(named: "Content-Encoding", in: responseHeaders)
        var updated = request
        updated.statusCode = statusCode
        updated.statusMessage = statusMessage
        updated.responseHeaders = responseHeaders
        updated.responseBody = BodyStorage.from(
            data: responseBody,
            charset: charset,
            contentEncoding: contentEncoding
        )
        return updated
    }

    func finalizeResponse(
        streamID: UInt64,
        request: NetworkRequest,
        fallbackStatusCode: Int,
        startTime: Date
    ) async throws -> HTTP3MitmPipelineResponse {
        var finalRequest = request
        finalRequest.duration = Date().timeIntervalSince(startTime)
        finalRequest.protocolVersion = .http3
        finalRequest.extractHTTPFields()

        do {
            try await persistIfNeeded(finalRequest)
        } catch {
            CoreLog.storage.error(
                "event=http3.capture_save outcome=failure request_id=\(finalRequest.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        await QUICConnectionManager.shared.recordHTTP3RequestCaptured(
            isSSE: isServerSentEventResponse(finalRequest.responseHeaders)
        )

        let statusCode = finalRequest.statusCode ?? fallbackStatusCode
        let responseHeaders = HTTP3Bridge.toHTTP3ResponseHeaders(
            statusCode: statusCode,
            headers: finalRequest.responseHeaders
        )
        let responseBody = finalRequest.responseBody.getData() ?? Data()

        return HTTP3MitmPipelineResponse(
            streamID: streamID,
            statusCode: statusCode,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            capturedRequest: finalRequest
        )
    }

    func isServerSentEventResponse(_ headers: [TraceHTTPHeader]) -> Bool {
        headers.contains { header in
            guard header.key.caseInsensitiveCompare("Content-Type") == .orderedSame else {
                return false
            }
            return header.value.lowercased().contains("text/event-stream")
        }
    }

    func persistIfNeeded(_ request: NetworkRequest) async throws {
        let captureConfig = AppGroupStorage.shared.loadConfiguration().normalized()
        guard shouldPersist(request, using: captureConfig) else { return }

        let samplingConfig = AppGroupStorage.shared.loadSamplingConfig().normalized()
        guard await shouldSample(using: samplingConfig) else { return }

        let persisted = makePersistedCapture(from: request, captureConfig: captureConfig)
        try AppGroupStorage.shared.saveRequest(persisted)
    }

    func makePersistedCapture(
        from request: NetworkRequest,
        captureConfig: CaptureConfiguration
    ) -> NetworkRequest {
        var persisted = request

        if !captureConfig.captureHeaders {
            persisted.requestHeaders = []
            persisted.responseHeaders = []
        }

        if !captureConfig.captureBody || captureConfig.maxBodySize <= 0 {
            persisted.requestBody = .empty
            persisted.responseBody = .empty
            return persisted
        }

        let boundedMaxSize = max(0, captureConfig.maxBodySize)
        persisted.requestBody = boundedBodyStorage(
            from: request.requestBody,
            headers: request.requestHeaders,
            maxSize: boundedMaxSize
        )
        persisted.responseBody = boundedBodyStorage(
            from: request.responseBody,
            headers: request.responseHeaders,
            maxSize: boundedMaxSize
        )
        return persisted
    }

    func boundedBodyStorage(
        from body: BodyStorage,
        headers: [TraceHTTPHeader],
        maxSize: Int
    ) -> BodyStorage {
        guard maxSize > 0, let raw = body.getData() else {
            return .empty
        }

        let charset = body.getCharset() ?? BodyStorage.extractCharset(from: headers)
        return BodyStorage.from(
            data: raw,
            charset: charset,
            maxSize: maxSize,
            decodeCompressedContent: false
        )
    }

    func shouldPersist(_ request: NetworkRequest, using config: CaptureConfiguration) -> Bool {
        guard config.isEnabled else { return false }

        switch config.filterMode {
        case .all:
            return true
        case .whitelist:
            guard !config.domainFilters.isEmpty else { return false }
        case .blacklist:
            break
        }

        guard let host = URL(string: request.url)?.host?.lowercased(), !host.isEmpty else {
            return config.filterMode != .whitelist
        }

        let matches = config.domainFilters.contains { pattern in
            domainFilterMatches(host: host, pattern: pattern)
        }

        switch config.filterMode {
        case .all:
            return true
        case .whitelist:
            return matches
        case .blacklist:
            return !matches
        }
    }

    func domainFilterMatches(host: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowercasedPattern = trimmed.lowercased()
        if lowercasedPattern == "*" { return true }
        if lowercasedPattern.contains("*") {
            return StringMatcher(
                matchType: .wildcard,
                pattern: lowercasedPattern,
                caseSensitive: false
            ).matches(host)
        }
        return host == lowercasedPattern || host.hasSuffix("." + lowercasedPattern)
    }

    func shouldSample(using config: SamplingConfig) async -> Bool {
        guard config.enabled else { return true }

        let rate = max(0.0, min(1.0, config.sampleRate))
        if rate <= 0 { return false }
        if rate >= 1 { return true }

        switch config.strategy {
        case .random:
            return Double.random(in: 0 ..< 1) < rate
        case .periodic:
            samplingSequence &+= 1
            let interval = max(1, Int((1.0 / rate).rounded()))
            return samplingSequence % UInt64(interval) == 0
        case .adaptive:
            let activeConnections = max(1, await QUICConnectionManager.shared.snapshot().activeConnections)
            let scale = 50.0 / Double(max(50, activeConnections))
            let adjustedRate = min(rate, rate * scale)
            return Double.random(in: 0 ..< 1) < adjustedRate
        }
    }

    func headerValue(named name: String, in headers: [TraceHTTPHeader]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
