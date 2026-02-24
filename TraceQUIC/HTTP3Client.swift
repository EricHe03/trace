//
//  HTTP3Client.swift
//  TraceQUIC
//
//  Created by Codex on 2026/02/18.
//

import Foundation
import TraceCore

public struct HTTP3ClientRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [HTTP3HeaderField]
    public let body: Data?
    public let timeout: TimeInterval
    public let requiresHTTP3: Bool
    public let allowHTTPVersionFallback: Bool
    public let followRedirects: Bool

    public init(
        url: URL,
        method: String,
        headers: [HTTP3HeaderField],
        body: Data?,
        timeout: TimeInterval,
        requiresHTTP3: Bool,
        allowHTTPVersionFallback: Bool,
        followRedirects: Bool = true
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.requiresHTTP3 = requiresHTTP3
        self.allowHTTPVersionFallback = allowHTTPVersionFallback
        self.followRedirects = followRedirects
    }
}

public struct HTTP3ClientResponse: Sendable {
    public let finalURL: URL
    public let statusCode: Int
    public let headers: [HTTP3HeaderField]
    public let body: Data
    public let negotiatedProtocolName: String?
    public let redirects: [RedirectInfo]

    public init(
        finalURL: URL,
        statusCode: Int,
        headers: [HTTP3HeaderField],
        body: Data,
        negotiatedProtocolName: String?,
        redirects: [RedirectInfo] = []
    ) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.negotiatedProtocolName = negotiatedProtocolName
        self.redirects = redirects
    }
}

public enum HTTP3ClientError: LocalizedError {
    case invalidResponse
    case http3RequiresHTTPS
    case http3RequiredButNotNegotiated(String?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid HTTP/3 response"
        case .http3RequiresHTTPS:
            "HTTP/3 requires HTTPS"
        case let .http3RequiredButNotNegotiated(protocolName):
            "HTTP/3 was required but not negotiated (\(protocolName ?? "unknown"))"
        }
    }
}

public protocol HTTP3Client: AnyObject, Sendable {
    func execute(_ request: HTTP3ClientRequest) async throws -> HTTP3ClientResponse
}

public final class URLSessionHTTP3Client: @unchecked Sendable, HTTP3Client {
    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate {
        private let lock = NSLock()
        private var protocolNames: [Int: String] = [:]
        private var redirectsByTaskID: [Int: [RedirectInfo]] = [:]
        private var shouldFollowRedirectsByTaskID: [Int: Bool] = [:]

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            _ = session
            let name = metrics.transactionMetrics.last?.networkProtocolName
            guard let name else { return }
            lock.lock()
            protocolNames[task.taskIdentifier] = name
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            _ = session
            let taskID = task.taskIdentifier
            let fromURL = response.url?.absoluteString ??
                task.currentRequest?.url?.absoluteString ??
                task.originalRequest?.url?.absoluteString
            let toURL = request.url?.absoluteString ??
                response.value(forHTTPHeaderField: "Location")
            let location = response.value(forHTTPHeaderField: "Location")

            lock.lock()
            if let fromURL,
               let toURL,
               !fromURL.isEmpty,
               !toURL.isEmpty {
                redirectsByTaskID[taskID, default: []].append(
                    RedirectInfo(
                        fromURL: fromURL,
                        toURL: toURL,
                        statusCode: response.statusCode,
                        location: location
                    )
                )
            }
            let shouldFollowRedirects = shouldFollowRedirectsByTaskID[taskID] ?? true
            lock.unlock()

            completionHandler(shouldFollowRedirects ? request : nil)
        }

        func protocolName(for taskID: Int) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return protocolNames[taskID]
        }

        func redirectChain(for taskID: Int) -> [RedirectInfo] {
            lock.lock()
            defer { lock.unlock() }
            return redirectsByTaskID[taskID] ?? []
        }

        func setFollowRedirects(_ shouldFollowRedirects: Bool, for taskID: Int) {
            lock.lock()
            shouldFollowRedirectsByTaskID[taskID] = shouldFollowRedirects
            lock.unlock()
        }

        func clearTaskState(taskID: Int) {
            lock.lock()
            protocolNames.removeValue(forKey: taskID)
            redirectsByTaskID.removeValue(forKey: taskID)
            shouldFollowRedirectsByTaskID.removeValue(forKey: taskID)
            lock.unlock()
        }
    }

    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        var resolvedConfiguration: URLSessionConfiguration = if let copied = configuration.copy() as? URLSessionConfiguration {
            copied
        } else {
            .ephemeral
        }
        resolvedConfiguration.httpShouldSetCookies = true
        if resolvedConfiguration.httpCookieStorage == nil {
            resolvedConfiguration.httpCookieStorage = HTTPCookieStorage()
        }
        self.configuration = resolvedConfiguration
    }

    public func execute(_ request: HTTP3ClientRequest) async throws -> HTTP3ClientResponse {
        if request.requiresHTTP3, request.url.scheme?.lowercased() != "https" {
            throw HTTP3ClientError.http3RequiresHTTPS
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        if #available(iOS 14.5, macOS 11.3, *) {
            urlRequest.assumesHTTP3Capable = true
        }
        for header in request.headers {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }

        let delegate = MetricsDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let cookieStorage = session.configuration.httpCookieStorage
        let cookiesBefore = cookieStorage?.cookies(for: request.url) ?? []

        let (data, response, taskID): (Data, URLResponse, Int) = try await withCheckedThrowingContinuation { continuation in
            var taskIdentifier = 0
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    delegate.clearTaskState(taskID: taskIdentifier)
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    delegate.clearTaskState(taskID: taskIdentifier)
                    continuation.resume(throwing: HTTP3ClientError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response, taskIdentifier))
            }
            taskIdentifier = task.taskIdentifier
            delegate.setFollowRedirects(request.followRedirects, for: taskIdentifier)
            task.resume()
        }
        defer { delegate.clearTaskState(taskID: taskID) }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTP3ClientError.invalidResponse
        }

        let negotiatedProtocolName = delegate.protocolName(for: taskID)
        let redirects = delegate.redirectChain(for: taskID)
        if request.requiresHTTP3, !request.allowHTTPVersionFallback {
            let normalized = negotiatedProtocolName?.lowercased() ?? ""
            let negotiatedHTTP3 = normalized.contains("h3") || normalized.contains("http/3")
            if !negotiatedHTTP3 {
                throw HTTP3ClientError.http3RequiredButNotNegotiated(negotiatedProtocolName)
            }
        }

        var responseHeaders = Self.flattenHeaders(httpResponse.allHeaderFields)
        if let cookieStorage {
            let finalURL = httpResponse.url ?? request.url
            let cookiesAfter = cookieStorage.cookies(for: finalURL) ?? []
            let newCookies = Self.diffCookies(before: cookiesBefore, after: cookiesAfter)
            Self.appendSetCookieHeadersIfNeeded(to: &responseHeaders, cookies: newCookies)
        }

        return HTTP3ClientResponse(
            finalURL: httpResponse.url ?? request.url,
            statusCode: httpResponse.statusCode,
            headers: responseHeaders,
            body: data,
            negotiatedProtocolName: negotiatedProtocolName,
            redirects: redirects
        )
    }

    private static func flattenHeaders(_ values: [AnyHashable: Any]) -> [HTTP3HeaderField] {
        var flattened: [HTTP3HeaderField] = []
        for (key, value) in values {
            let name = String(describing: key)
            if let values = value as? [String] {
                flattened.append(contentsOf: values.map { HTTP3HeaderField(name: name, value: $0) })
            } else if let values = value as? [Any] {
                flattened.append(contentsOf: values.map { HTTP3HeaderField(name: name, value: String(describing: $0)) })
            } else {
                flattened.append(HTTP3HeaderField(name: name, value: String(describing: value)))
            }
        }
        return flattened
    }

    private static func appendSetCookieHeadersIfNeeded(
        to headers: inout [HTTP3HeaderField],
        cookies: [Foundation.HTTPCookie]
    ) {
        for cookie in cookies {
            let serializedCookie = serializedSetCookie(for: cookie)
            let alreadyPresent = headers.contains {
                $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame &&
                    $0.value == serializedCookie
            }
            guard !alreadyPresent else { continue }
            headers.append(
                HTTP3HeaderField(
                    name: "Set-Cookie",
                    value: serializedCookie
                )
            )
        }
    }

    private static func diffCookies(
        before: [Foundation.HTTPCookie],
        after: [Foundation.HTTPCookie]
    ) -> [Foundation.HTTPCookie] {
        let beforeSet = Set(before.map(CookieFingerprint.init))
        return after.filter { !beforeSet.contains(CookieFingerprint($0)) }
    }

    private static func serializedSetCookie(for cookie: Foundation.HTTPCookie) -> String {
        var parts = ["\(cookie.name)=\(cookie.value)"]
        parts.append("Domain=\(cookie.domain)")
        parts.append("Path=\(cookie.path)")
        if let expires = cookie.expiresDate {
            parts.append("Expires=\(formatCookieDate(expires))")
        }
        if cookie.isSecure {
            parts.append("Secure")
        }
        if cookie.isHTTPOnly {
            parts.append("HttpOnly")
        }
        return parts.joined(separator: "; ")
    }

    private static func formatCookieDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private struct CookieFingerprint: Hashable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let secure: Bool
        let httpOnly: Bool

        init(_ cookie: Foundation.HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
        }
    }
}
