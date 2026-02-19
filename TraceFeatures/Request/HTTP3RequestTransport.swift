//
//  HTTP3RequestTransport.swift
//  TraceFeatures
//
//  Created by Codex on 2026/02/18.
//

import Foundation
import TraceCore
import TraceQUIC

public final class HTTP3RequestTransport: @unchecked Sendable, RequestExecutorTransport {
    public static let shared = HTTP3RequestTransport()

    private let client: HTTP3Client
    private let maxRedirectCount: Int

    public init(client: HTTP3Client = URLSessionHTTP3Client(), maxRedirectCount: Int = 20) {
        self.client = client
        self.maxRedirectCount = maxRedirectCount
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
            let clientRequest = HTTP3ClientRequest(
                url: currentURL,
                method: currentMethod,
                headers: currentHeaders.map { HTTP3HeaderField(name: $0.key, value: $0.value) },
                body: currentBody,
                timeout: request.timeout,
                requiresHTTP3: request.requestedProtocolVersion == .http3,
                allowHTTPVersionFallback: !request.enforceRequestedProtocolVersion,
                followRedirects: false
            )
            let response = try await client.execute(clientRequest)

            let responseCookies = parseSetCookies(from: response.headers, url: currentURL)
            collectedCookies = mergeCookies(existing: collectedCookies, newCookies: responseCookies)

            let redirectLocation = firstHeader(named: "Location", in: response.headers)?.value
            let redirectTarget = extractRedirectTarget(
                statusCode: response.statusCode,
                location: redirectLocation,
                originalURL: currentURL
            )
            if let redirectTarget {
                redirects.append(
                    RedirectInfo(
                        fromURL: currentURL.absoluteString,
                        toURL: redirectTarget.absoluteString,
                        statusCode: response.statusCode,
                        location: redirectLocation
                    )
                )
            }

            guard request.followRedirects, let redirectTarget else {
                return RequestExecutorTransportResponse(
                    finalURL: currentURL,
                    statusCode: response.statusCode,
                    statusMessage: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                    protocolVersion: protocolVersion(
                        negotiatedProtocolName: response.negotiatedProtocolName
                    ),
                    responseHeaders: flatten(response.headers),
                    body: response.body,
                    redirects: redirects,
                    responseCookies: collectedCookies.map(mapHTTP3Cookie)
                )
            }

            guard redirects.count <= maxRedirectCount else {
                throw RequestExecutorTransportError.redirectLimitReached(maxRedirectCount)
            }
            guard visitedURLs.insert(redirectTarget.absoluteString).inserted else {
                throw RequestExecutorTransportError.redirectCycleDetected(redirectTarget.absoluteString)
            }

            let transformed = transformForRedirect(
                originalURL: currentURL,
                redirectURL: redirectTarget,
                statusCode: response.statusCode,
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

private extension HTTP3RequestTransport {
    typealias RedirectTransform = (method: String, headers: [String: String], body: Data?)

    func shouldFollowRedirectStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 301, 302, 303, 307, 308:
            true
        default:
            false
        }
    }

    func extractRedirectTarget(
        statusCode: Int,
        location: String?,
        originalURL: URL
    ) -> URL? {
        guard shouldFollowRedirectStatus(statusCode) else { return nil }
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty else {
            return nil
        }

        let resolvedURL: URL
        if let absolute = URL(string: location), absolute.scheme != nil {
            resolvedURL = absolute
        } else if let relative = URL(string: location, relativeTo: originalURL) {
            resolvedURL = relative.absoluteURL
        } else {
            return nil
        }

        guard supportsRedirect(fromScheme: originalURL.scheme, toScheme: resolvedURL.scheme) else {
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
        statusCode: Int,
        method: String,
        headers: [String: String],
        body: Data?
    ) -> RedirectTransform {
        var transformedMethod = method.uppercased()
        var transformedHeaders = headers
        var transformedBody = body

        let convertToGet = if statusCode == 303, transformedMethod != "HEAD" {
            true
        } else if (statusCode == 301 || statusCode == 302), transformedMethod == "POST" {
            true
        } else {
            false
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

    func firstHeader(named name: String, in headers: [HTTP3HeaderField]) -> HTTP3HeaderField? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func flatten(_ headers: [HTTP3HeaderField]) -> [TraceHTTPHeader] {
        headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) }
    }

    func protocolVersion(negotiatedProtocolName: String?) -> HTTPProtocolVersion? {
        guard let negotiatedProtocolName else {
            return nil
        }
        let normalized = negotiatedProtocolName.lowercased()
        if normalized.contains("h3") || normalized.contains("http/3") {
            return .http3
        }
        if normalized.contains("h2") || normalized.contains("http/2") {
            return .http2
        }
        if normalized.contains("http/1.1") {
            return .http11
        }
        if normalized.contains("http/1.0") {
            return .http10
        }
        return nil
    }

    func parseSetCookies(from headers: [HTTP3HeaderField], url: URL) -> [Foundation.HTTPCookie] {
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

    func mergeCookies(
        existing: [Foundation.HTTPCookie],
        newCookies: [Foundation.HTTPCookie]
    ) -> [Foundation.HTTPCookie] {
        var merged: [String: Foundation.HTTPCookie] = [:]
        for cookie in existing {
            merged[cookieMergeKey(for: cookie)] = cookie
        }
        for cookie in newCookies {
            merged[cookieMergeKey(for: cookie)] = cookie
        }
        return merged.values.sorted {
            cookieMergeKey(for: $0) < cookieMergeKey(for: $1)
        }
    }

    func cookieMergeKey(for cookie: Foundation.HTTPCookie) -> String {
        "\(cookie.name.lowercased())|\(cookie.domain.lowercased())|\(cookie.path)"
    }

    func mapHTTP3Cookie(_ cookie: Foundation.HTTPCookie) -> TraceCore.HTTPCookie {
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
