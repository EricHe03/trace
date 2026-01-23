//
//  RequestExecutor.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

/// Executes HTTP requests and returns responses.
@MainActor
public final class RequestExecutor: ObservableObject {
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastResponse: NetworkRequest?

    private let session: URLSession
    private let cookieStore: CookieStore

    // Rule: Use a session without NetworkInterceptor to avoid recursive capture and
    // keep user-initiated replays separate from captured traffic.
    private static let customSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }()

    // MARK: - Initialization

    /// Creates a request executor using the provided session or the default one.
    /// - Parameter session: The session to use for requests. When `nil`, a default
    ///   session configured for manual requests is used.
    public init(session: URLSession? = nil, cookieStore: CookieStore = DefaultCookieStore()) {
        self.session = session ?? RequestExecutor.customSession
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

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = 30

        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }

        if let body = request.body, !body.isEmpty {
            let bodyData = body.data(using: .utf8)
            urlRequest.httpBody = bodyData
            if let bodyData {
                urlRequest.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
            }
        }

        let cookiesBefore = cookieStore.cookies(for: url)

        do {
            let redirectDelegate = RedirectTrackingDelegate(followRedirects: request.followRedirects)
            let (data, response) = try await session.data(for: urlRequest, delegate: redirectDelegate)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RequestExecutionError.invalidResponse
            }

            let duration = Date().timeIntervalSince(startTime)

            var networkRequest = NetworkRequest(
                url: url.absoluteString,
                method: request.method,
                statusCode: httpResponse.statusCode,
                timestamp: startTime,
                duration: duration,
                requestHeaders: request.headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) },
                responseHeaders: HTTPHeaderNormalizer.flatten(httpResponse.allHeaderFields),
                requestBody: BodyStorage.from(string: request.body ?? ""),
                responseBody: BodyStorage.from(data: data)
            )

            networkRequest.redirectChain = redirectDelegate.redirects

            // Ensure derived HTTP fields (cookies, content type, etc.) are populated for manual requests.
            networkRequest.extractHTTPFields()

            // If Set-Cookie headers are missing, fall back to newly stored cookies from the cookie store.
            if networkRequest.responseCookies?.isEmpty ?? true {
                let cookieURL = URL(string: redirectDelegate.redirects.last?.toURL ?? url.absoluteString) ?? url
                let cookiesAfter = cookieStore.cookies(for: cookieURL)
                let newCookies = Self.diffCookies(before: cookiesBefore, after: cookiesAfter)
                if !newCookies.isEmpty {
                    networkRequest.responseCookies = newCookies
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
    static func diffCookies(before: [Foundation.HTTPCookie], after: [Foundation.HTTPCookie]) -> [TraceCore.HTTPCookie] {
        let beforeSet = Set(before.map { cookieSignature(for: $0) })
        let newCookies = after.filter { !beforeSet.contains(cookieSignature(for: $0)) }
        return newCookies.map { mapCookie($0) }
    }

    static func cookieSignature(for cookie: Foundation.HTTPCookie) -> String {
        let path = cookie.path
        let domain = cookie.domain
        return "\(cookie.name)|\(cookie.value)|\(domain)|\(path)"
    }

    static func mapCookie(_ cookie: Foundation.HTTPCookie) -> TraceCore.HTTPCookie {
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
}

private final class RedirectTrackingDelegate: NSObject, URLSessionTaskDelegate {
    private(set) var redirects: [RedirectInfo] = []
    private let followRedirects: Bool

    init(followRedirects: Bool) {
        self.followRedirects = followRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let locationHeader = response.allHeaderFields.first { key, _ in
            "\(key)".lowercased() == "location"
        }?.value

        let info = RedirectInfo(
            fromURL: response.url?.absoluteString ?? "",
            toURL: request.url?.absoluteString ?? "",
            statusCode: response.statusCode,
            location: locationHeader.map { "\($0)" }
        )

        redirects.append(info)
        completionHandler(followRedirects ? request : nil)
    }
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
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: String?
    public var protocolVersion: HTTPProtocolVersion?
    public var followRedirects: Bool

    public init(
        url: String,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: String? = nil,
        protocolVersion: HTTPProtocolVersion? = nil,
        followRedirects: Bool = true
    ) {
        self.url = url
        self.method = method
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
        var raw = "\(method.rawValue) \(url) HTTP/1.1\r\n"

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
