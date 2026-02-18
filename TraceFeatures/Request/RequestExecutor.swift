//
//  RequestExecutor.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import AsyncHTTPClient
import Combine
import Foundation
import NIOCore
import NIOHTTP1
import TraceCore

public struct RequestExecutorTransportRequest: Sendable {
    public let url: URL
    public let methodRaw: String
    public let headers: [String: String]
    public let body: Data?
    public let followRedirects: Bool
    public let timeout: TimeInterval

    public init(
        url: URL,
        methodRaw: String,
        headers: [String: String],
        body: Data?,
        followRedirects: Bool,
        timeout: TimeInterval
    ) {
        self.url = url
        self.methodRaw = methodRaw
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
        self.timeout = timeout
    }
}

public struct RequestExecutorTransportResponse: @unchecked Sendable {
    public let finalURL: URL
    public let statusCode: Int
    public let statusMessage: String?
    public let protocolVersion: HTTPProtocolVersion?
    public let responseHeaders: [TraceHTTPHeader]
    public let body: Data
    public let redirects: [RedirectInfo]
    public let responseCookies: [TraceCore.HTTPCookie]

    public init(
        finalURL: URL,
        statusCode: Int,
        statusMessage: String?,
        protocolVersion: HTTPProtocolVersion?,
        responseHeaders: [TraceHTTPHeader],
        body: Data,
        redirects: [RedirectInfo],
        responseCookies: [TraceCore.HTTPCookie]
    ) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.protocolVersion = protocolVersion
        self.responseHeaders = responseHeaders
        self.body = body
        self.redirects = redirects
        self.responseCookies = responseCookies
    }
}

public protocol RequestExecutorTransport: AnyObject, Sendable {
    func execute(_ request: RequestExecutorTransportRequest) async throws -> RequestExecutorTransportResponse
}

public enum RequestExecutorTransportError: LocalizedError {
    case redirectLimitReached(Int)
    case redirectCycleDetected(String)

    public var errorDescription: String? {
        switch self {
        case let .redirectLimitReached(limit):
            "Redirect limit reached (\(limit))"
        case let .redirectCycleDetected(url):
            "Redirect cycle detected for URL: \(url)"
        }
    }
}

public final class AsyncHTTPClientRequestTransport: @unchecked Sendable, RequestExecutorTransport {
    public static let shared = AsyncHTTPClientRequestTransport()

    private let client: HTTPClient
    private let maxRedirectCount: Int

    public init(maxRedirectCount: Int = 20) {
        self.client = NIORuntime.shared.acquire(for: .app).httpClient
        self.maxRedirectCount = maxRedirectCount
    }

    public init(httpClient: HTTPClient, maxRedirectCount: Int = 20) {
        client = httpClient
        self.maxRedirectCount = maxRedirectCount
    }

    static func shouldFollowRedirectStatus(_ status: HTTPResponseStatus) -> Bool {
        switch status {
        case .movedPermanently, .found, .seeOther, .temporaryRedirect, .permanentRedirect:
            true
        default:
            false
        }
    }

    public func execute(_ request: RequestExecutorTransportRequest) async throws -> RequestExecutorTransportResponse {
        var currentURL = request.url
        var currentMethod = request.methodRaw
        var currentHeaders = request.headers
        var currentBody = request.body

        var redirects: [RedirectInfo] = []
        var visitedURLs: Set<String> = [currentURL.absoluteString]
        var collectedCookies: [Foundation.HTTPCookie] = []

        while true {
            try Task.checkCancellation()
            let response = try await executeSingle(
                url: currentURL,
                methodRaw: currentMethod,
                headers: currentHeaders,
                body: currentBody,
                timeout: request.timeout
            )

            let responseCookies = parseSetCookies(from: response.headers, url: currentURL)
            collectedCookies = mergeCookies(existing: collectedCookies, newCookies: responseCookies)

            let redirectLocation = response.headers.first(name: "Location")
            let redirectTarget = extractRedirectTarget(
                status: response.status,
                location: redirectLocation,
                originalURL: currentURL
            )

            if let redirectTarget {
                redirects.append(
                    RedirectInfo(
                        fromURL: currentURL.absoluteString,
                        toURL: redirectTarget.absoluteString,
                        statusCode: Int(response.status.code),
                        location: redirectLocation
                    )
                )
            }

            guard request.followRedirects, let redirectTarget else {
                let body = try await collectBody(from: response.body)
                return RequestExecutorTransportResponse(
                    finalURL: currentURL,
                    statusCode: Int(response.status.code),
                    statusMessage: response.status.reasonPhrase,
                    protocolVersion: mapProtocolVersion(response.version),
                    responseHeaders: flatten(response.headers),
                    body: body,
                    redirects: redirects,
                    responseCookies: collectedCookies.map(mapCookie)
                )
            }

            guard redirects.count <= maxRedirectCount else {
                throw RequestExecutorTransportError.redirectLimitReached(maxRedirectCount)
            }

            guard visitedURLs.insert(redirectTarget.absoluteString).inserted else {
                throw RequestExecutorTransportError.redirectCycleDetected(redirectTarget.absoluteString)
            }

            try await drainBody(response.body)

            let transformed = transformForRedirect(
                originalURL: currentURL,
                redirectURL: redirectTarget,
                responseStatus: response.status,
                method: currentMethod,
                headers: currentHeaders,
                body: currentBody
            )

            currentURL = redirectTarget
            currentMethod = transformed.method
            currentHeaders = transformed.headers
            currentBody = transformed.body
        }
    }
}

private extension AsyncHTTPClientRequestTransport {
    typealias RedirectTransform = (method: String, headers: [String: String], body: Data?)

    func executeSingle(
        url: URL,
        methodRaw: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = nioMethod(from: methodRaw)

        var nioHeaders = HTTPHeaders()
        for (key, value) in headers {
            nioHeaders.replaceOrAdd(name: key, value: value)
        }
        request.headers = nioHeaders

        if let body, !body.isEmpty {
            request.body = .bytes(body)
        }

        let timeoutSeconds = max(Int64(timeout.rounded(.up)), 1)
        return try await client.execute(request, timeout: .seconds(timeoutSeconds))
    }

    func nioMethod(from raw: String) -> NIOHTTP1.HTTPMethod {
        let normalized = raw.uppercased()
        return NIOHTTP1.HTTPMethod(rawValue: normalized) ?? .RAW(value: normalized)
    }

    func mapProtocolVersion(_ version: HTTPVersion) -> HTTPProtocolVersion? {
        switch (version.major, version.minor) {
        case (1, 0):
            .http10
        case (1, 1):
            .http11
        case (2, _):
            .http2
        case (3, _):
            .http3
        default:
            nil
        }
    }

    func flatten(_ headers: HTTPHeaders) -> [TraceHTTPHeader] {
        headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) }
    }

    func collectBody(from body: HTTPClientResponse.Body) async throws -> Data {
        let buffer = try await body.collect(upTo: Int.max)
        return Data(buffer.readableBytesView)
    }

    func drainBody(_ body: HTTPClientResponse.Body) async throws {
        for try await _ in body {
            continue
        }
    }

    func extractRedirectTarget(
        status: HTTPResponseStatus,
        location: String?,
        originalURL: URL
    ) -> URL? {
        guard Self.shouldFollowRedirectStatus(status) else {
            return nil
        }

        guard let location,
              let resolvedURL = URL(string: location, relativeTo: originalURL)?.absoluteURL,
              supportsRedirect(fromScheme: originalURL.scheme, toScheme: resolvedURL.scheme),
              !resolvedURL.isFileURL else {
            return nil
        }

        return resolvedURL
    }

    func supportsRedirect(fromScheme source: String?, toScheme destination: String?) -> Bool {
        guard let source = source?.lowercased(), let destination = destination?.lowercased() else {
            return false
        }
        let allowed = Set(["http", "https"])
        return allowed.contains(source) && allowed.contains(destination)
    }

    func transformForRedirect(
        originalURL: URL,
        redirectURL: URL,
        responseStatus: HTTPResponseStatus,
        method: String,
        headers: [String: String],
        body: Data?
    ) -> RedirectTransform {
        var transformedMethod = method.uppercased()
        var transformedHeaders = headers
        var transformedBody = body

        let convertToGet: Bool
        if responseStatus == .seeOther, transformedMethod != "HEAD" {
            convertToGet = true
        } else if (responseStatus == .movedPermanently || responseStatus == .found), transformedMethod == "POST" {
            convertToGet = true
        } else {
            convertToGet = false
        }

        if convertToGet {
            transformedMethod = "GET"
            transformedBody = nil
            removeHeader(named: "Content-Length", from: &transformedHeaders)
            removeHeader(named: "Content-Type", from: &transformedHeaders)
        }

        if !hasSameOrigin(lhs: originalURL, rhs: redirectURL) {
            removeHeader(named: "Origin", from: &transformedHeaders)
            removeHeader(named: "Cookie", from: &transformedHeaders)
            removeHeader(named: "Authorization", from: &transformedHeaders)
            removeHeader(named: "Proxy-Authorization", from: &transformedHeaders)
        }

        return (transformedMethod, transformedHeaders, transformedBody)
    }

    func hasSameOrigin(lhs: URL, rhs: URL) -> Bool {
        lhs.host == rhs.host && lhs.scheme == rhs.scheme && lhs.port == rhs.port
    }

    func removeHeader(named headerName: String, from headers: inout [String: String]) {
        if let key = headers.keys.first(where: { $0.caseInsensitiveCompare(headerName) == .orderedSame }) {
            headers.removeValue(forKey: key)
        }
    }

    func parseSetCookies(from headers: HTTPHeaders, url: URL) -> [Foundation.HTTPCookie] {
        var cookies: [Foundation.HTTPCookie] = []
        for header in headers where header.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            cookies.append(
                contentsOf: Foundation.HTTPCookie.cookies(
                    withResponseHeaderFields: ["Set-Cookie": header.value],
                    for: url
                )
            )
        }
        return cookies
    }

    func mergeCookies(existing: [Foundation.HTTPCookie], newCookies: [Foundation.HTTPCookie]) -> [Foundation.HTTPCookie] {
        var merged: [String: Foundation.HTTPCookie] = [:]

        for cookie in existing {
            merged[cookieMergeKey(for: cookie)] = cookie
        }

        for cookie in newCookies {
            merged[cookieMergeKey(for: cookie)] = cookie
        }

        return merged.values.sorted {
            let lhs = cookieMergeKey(for: $0)
            let rhs = cookieMergeKey(for: $1)
            return lhs < rhs
        }
    }

    func cookieMergeKey(for cookie: Foundation.HTTPCookie) -> String {
        "\(cookie.name.lowercased())|\(cookie.domain.lowercased())|\(cookie.path)"
    }
}

/// Executes HTTP requests and returns responses.
@MainActor
public final class RequestExecutor: ObservableObject {
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastResponse: NetworkRequest?

    private let transport: any RequestExecutorTransport
    private let cookieStore: CookieStore
    private static let localNetworkRetryDelayNanoseconds: UInt64 = 600_000_000
    private static let manualResponseBodyTruncationLimitBytes = 512 * 1024 * 1024

    // MARK: - Initialization

    /// Creates a request executor using the provided transport or the default AsyncHTTPClient transport.
    /// - Parameters:
    ///   - transport: The transport used to execute HTTP requests.
    ///   - cookieStore: The cookie store used for request cookie lookup and fallback cookie diffs.
    public init(
        transport: any RequestExecutorTransport = AsyncHTTPClientRequestTransport.shared,
        cookieStore: CookieStore = DefaultCookieStore()
    ) {
        self.transport = transport
        self.cookieStore = cookieStore
    }

    // MARK: - Request Execution

    /// Executes a network request and returns the captured response.
    /// - Parameter request: The request to execute.
    /// - Returns: The captured request/response pair.
    /// - Throws: `RequestExecutionError` when the request cannot be executed.
    public func execute(_ request: RequestBuilder) async throws -> NetworkRequest {
        isLoading = true
        defer { isLoading = false }

        let startTime = Date()

        guard let url = URL(string: request.url),
              let scheme = url.scheme else {
            throw RequestExecutionError.invalidURL
        }
        let normalizedScheme = scheme.lowercased()
        guard ["http", "https"].contains(normalizedScheme) else {
            throw RequestExecutionError.unsupportedScheme(normalizedScheme)
        }

        let methodRaw = request.methodRaw ?? request.method.rawValue

        var transportHeaders = request.headers
        if let body = request.body, let bodyData = body.data(using: .utf8) {
            Self.setHeaderValue("\(bodyData.count)", for: "Content-Length", in: &transportHeaders)
        }

        if Self.headerValue(for: "Cookie", in: transportHeaders) == nil {
            let initialCookies = cookieStore.cookies(for: url)
            if !initialCookies.isEmpty {
                let cookieHeader = initialCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                Self.setHeaderValue(cookieHeader, for: "Cookie", in: &transportHeaders)
            }
        }

        let requestBodyData = request.body?.data(using: .utf8)
        let transportRequest = RequestExecutorTransportRequest(
            url: url,
            methodRaw: methodRaw,
            headers: transportHeaders,
            body: requestBodyData,
            followRedirects: request.followRedirects,
            timeout: 30
        )

        let cookiesBefore = cookieStore.cookies(for: url)

        do {
            let transportResponse = try await executeWithPermissionRetry(
                request: transportRequest,
                targetURL: url
            )

            let duration = Date().timeIntervalSince(startTime)

            var networkRequest = NetworkRequest(
                url: url.absoluteString,
                method: request.method,
                requestMethodRaw: request.methodRaw,
                statusCode: transportResponse.statusCode,
                statusMessage: transportResponse.statusMessage,
                timestamp: startTime,
                duration: duration,
                requestHeaders: request.headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) },
                responseHeaders: transportResponse.responseHeaders,
                requestBody: BodyStorage.from(string: request.body ?? ""),
                responseBody: Self.makeManualResponseBodyStorage(from: transportResponse.body),
                protocolVersion: transportResponse.protocolVersion
            )

            networkRequest.redirectChain = transportResponse.redirects

            // Ensure derived HTTP fields (cookies, content type, etc.) are populated for manual requests.
            networkRequest.extractHTTPFields()

            // If Set-Cookie headers are missing, use transport-discovered cookies first, then
            // fall back to newly stored cookies from the cookie store.
            if networkRequest.responseCookies?.isEmpty ?? true {
                if !transportResponse.responseCookies.isEmpty {
                    networkRequest.responseCookies = transportResponse.responseCookies
                } else {
                    let cookieURL = URL(string: transportResponse.redirects.last?.toURL ?? url.absoluteString) ?? url
                    let cookiesAfter = cookieStore.cookies(for: cookieURL)
                    let newCookies = Self.diffCookies(before: cookiesBefore, after: cookiesAfter)
                    if !newCookies.isEmpty {
                        networkRequest.responseCookies = newCookies
                    }
                }
            }

            // Rule: Manual requests must be flagged to keep them separate from captured traffic.
            networkRequest.isManual = true

            lastResponse = networkRequest
            return networkRequest

        } catch {
            throw RequestExecutionError.transport(error)
        }
    }

    /// Replays a captured network request.
    /// - Parameter request: The captured request to replay.
    public func replay(_ request: NetworkRequest) async throws -> NetworkRequest {
        let builder = RequestBuilder(from: request)
        var replayed = try await execute(builder)
        replayed.isReplayed = true
        return replayed
    }

    /// Executes a quick GET request.
    /// - Parameters:
    ///   - url: The request URL.
    ///   - headers: Additional request headers.
    public func get(url: String, headers: [String: String] = [:]) async throws -> NetworkRequest {
        let builder = RequestBuilder(
            url: url,
            method: .get,
            headers: headers,
            body: nil
        )
        return try await execute(builder)
    }

    /// Executes a quick POST request.
    /// - Parameters:
    ///   - url: The request URL.
    ///   - body: The request body.
    ///   - headers: Additional request headers.
    public func post(url: String, body: String, headers: [String: String] = [:]) async throws -> NetworkRequest {
        var allHeaders = headers
        if allHeaders["Content-Type"] == nil {
            allHeaders["Content-Type"] = "application/json"
        }

        let builder = RequestBuilder(
            url: url,
            method: .post,
            headers: allHeaders,
            body: body
        )
        return try await execute(builder)
    }
}

private extension RequestExecutor {
    static func makeManualResponseBodyStorage(from data: Data) -> BodyStorage {
        // Manual requests are explicit user actions; keep large payloads shareable by
        // preferring file-backed storage over preview-only truncation in common cases.
        BodyStorage.from(data: data, maxSize: manualResponseBodyTruncationLimitBytes)
    }

    func executeWithPermissionRetry(
        request: RequestExecutorTransportRequest,
        targetURL: URL
    ) async throws -> RequestExecutorTransportResponse {
        do {
            return try await transport.execute(request)
        } catch {
            guard NetworkPermissionHeuristics.isLikelyPermissionIssue(error: error, url: targetURL) else {
                throw error
            }

            // Give the system permission prompt a brief moment to settle before retrying.
            try await Task.sleep(nanoseconds: Self.localNetworkRetryDelayNanoseconds)
            try Task.checkCancellation()
            return try await transport.execute(request)
        }
    }

    static func headerValue(for name: String, in headers: [String: String]) -> String? {
        guard let key = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        return headers[key]
    }

    static func setHeaderValue(_ value: String, for name: String, in headers: inout [String: String]) {
        if let existingKey = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            headers[existingKey] = value
        } else {
            headers[name] = value
        }
    }

    static func diffCookies(before: [Foundation.HTTPCookie], after: [Foundation.HTTPCookie]) -> [TraceCore.HTTPCookie] {
        let beforeSet = Set(before.map { cookieSignature(for: $0) })
        let newCookies = after.filter { !beforeSet.contains(cookieSignature(for: $0)) }
        return newCookies.map(mapCookie)
    }

    static func cookieSignature(for cookie: Foundation.HTTPCookie) -> String {
        let path = cookie.path
        let domain = cookie.domain
        return "\(cookie.name)|\(cookie.value)|\(domain)|\(path)"
    }
}

private func mapCookie(_ cookie: Foundation.HTTPCookie) -> TraceCore.HTTPCookie {
    TraceCore.HTTPCookie(
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path,
        expires: cookie.expiresDate,
        secure: cookie.isSecure,
        httpOnly: cookie.isHTTPOnly,
        sameSite: nil
    )
}

// MARK: - Errors

public enum RequestExecutionError: LocalizedError {
    case invalidURL
    case invalidResponse
    case transport(Error)
    case unsupportedScheme(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL"
        case .invalidResponse:
            "Invalid response"
        case let .transport(error):
            error.localizedDescription
        case let .unsupportedScheme(scheme):
            "Unsupported URL scheme: \(scheme)"
        }
    }
}

// MARK: - Request Builder

/// Builds HTTP requests for execution.
public struct RequestBuilder {
    public var url: String
    public var method: TraceCore.HTTPMethod
    public var methodRaw: String?
    public var headers: [String: String]
    public var body: String?
    public var protocolVersion: HTTPProtocolVersion?
    public var followRedirects: Bool

    public init(
        url: String,
        method: TraceCore.HTTPMethod = .get,
        methodRaw: String? = nil,
        headers: [String: String] = [:],
        body: String? = nil,
        protocolVersion: HTTPProtocolVersion? = nil,
        followRedirects: Bool = true
    ) {
        self.url = url
        self.method = method
        self.methodRaw = methodRaw
        self.headers = headers
        self.body = body
        self.protocolVersion = protocolVersion
        self.followRedirects = followRedirects
    }

    /// Creates a request builder from a captured request.
    /// - Parameter request: The captured request to convert.
    public init(from request: NetworkRequest) {
        self.url = request.url
        self.method = request.method
        self.methodRaw = request.requestMethodRaw
        self.protocolVersion = request.protocolVersion
        self.followRedirects = true

        var headersDict: [String: String] = [:]
        for header in request.requestHeaders {
            headersDict[header.key] = header.value
        }
        self.headers = headersDict

        self.body = request.requestBody.getString()
    }

    /// Exports the request as a cURL command.
    /// - Returns: A shell-escaped cURL command.
    public func toCURL() -> String {
        let request = NetworkRequest(
            url: url,
            method: method,
            requestMethodRaw: methodRaw,
            statusCode: nil,
            statusMessage: nil,
            timestamp: Date(),
            duration: 0,
            requestHeaders: headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) },
            responseHeaders: [],
            requestBody: body.flatMap { BodyStorage.from(string: $0) } ?? .empty,
            responseBody: .empty,
            protocolVersion: protocolVersion
        )
        return CurlCommandGenerator.generate(from: request, options: .init(followRedirects: followRedirects))
    }

    /// Exports the request as raw HTTP/1.1 text.
    /// - Returns: The raw HTTP/1.1 request.
    public func toHTTPRaw() -> String {
        let methodToken = methodRaw.flatMap { $0.isEmpty ? nil : $0 } ?? method.rawValue
        var raw = "\(methodToken) \(url) HTTP/1.1\r\n"

        for (key, value) in headers {
            raw += "\(key): \(value)\r\n"
        }

        raw += "\r\n"

        if let body {
            raw += body
        }

        return raw
    }
}
