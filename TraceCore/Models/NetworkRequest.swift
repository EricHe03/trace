//
//  NetworkRequest.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

public struct NetworkRequest: Identifiable, Hashable, @unchecked Sendable {
    public let id: UUID
    public var url: String
    public let method: HTTPMethod
    /// Original method token when it cannot be represented by `HTTPMethod`.
    public var requestMethodRaw: String?
    public var statusCode: Int?
    public var statusMessage: String?
    public let timestamp: Date
    public var duration: TimeInterval
    public var requestHeaders: [TraceHTTPHeader]
    public var responseHeaders: [TraceHTTPHeader]
    public var requestBody: BodyStorage
    public var responseBody: BodyStorage
    public var protocolVersion: HTTPProtocolVersion?

    // Advanced Performance Metrics
    public var timingPhases: NetworkTimingPhases?
    public var tlsInfo: TLSConnectionInfo?

    // Network Throttling
    public var wasThrottled: Bool = false
    public var throttlingProfile: String?

    // Duplicate Detection
    public var isDuplicate: Bool = false
    public var duplicateOfRequestId: UUID?

    /// Session Tracking
    public var sessionId: UUID?

    /// Manual Request Tracking
    public var isManual: Bool = false

    // MARK: - Interception Metadata

    /// Indicates the request was blocked by a rewrite rule
    public var wasBlocked: Bool = false

    /// Indicates the request was cancelled (client disconnected or user action)
    public var wasCancelled: Bool = false

    /// Indicates the request URL or headers were rewritten by a rule
    public var wasRewritten: Bool = false

    /// Indicates the request body was modified (rewrite, script, breakpoint)
    public var requestBodyModified: Bool = false

    /// Indicates the response was mocked (not fetched from real server)
    public var isMocked: Bool = false

    /// Indicates the request is a replay of a previous request
    public var isReplayed: Bool = false

    /// Name of the script that modified this request/response (if any)
    public var appliedScriptName: String?

    /// Indicates a breakpoint was hit and user interacted with this request
    public var hitBreakpoint: Bool = false

    /// Number of retry attempts for this request
    public var retryAttempts: Int = 0

    // MARK: - Execution Diagnostics

    public var executionLog: [ExecutionLogEntry] = []
    public var executionErrors: [ExecutionError] = []
    public var appliedRuleIds: [UUID] = []

    // MARK: - Backward Compatibility Aliases

    /// Alias for retryAttempts for backward compatibility
    public var retryCount: Int {
        get { retryAttempts }
        set { retryAttempts = newValue }
    }

    /// Backward-compatible alias for `requestMethodRaw`.
    @available(*, deprecated, renamed: "requestMethodRaw")
    public var rawMethod: String? {
        get { requestMethodRaw }
        set { requestMethodRaw = newValue }
    }

    /// Alias for appliedScriptName for backward compatibility
    public var scriptName: String? {
        get { appliedScriptName }
        set { appliedScriptName = newValue }
    }

    /// Alias for hitBreakpoint for backward compatibility
    public var hasBreakpoint: Bool {
        get { hitBreakpoint }
        set { hitBreakpoint = newValue }
    }

    /// Backward-compatible alias for `curlExecutionMetadata`.
    @available(*, deprecated, message: "Use curlExecutionMetadata")
    public var curlMetadata: CurlRequestMetadata? {
        get { curlExecutionMetadata.map(CurlRequestMetadata.init(executionMetadata:)) }
        set { curlExecutionMetadata = newValue?.asExecutionMetadata }
    }

    /// Computed count of duplicate requests
    public var duplicateCount: Int {
        isDuplicate ? 2 : 1
    }

    // MARK: - HTTP Header Fields

    /// Content-Type header (http.content_type)
    public var contentType: String?

    /// Content-Encoding header (http.content_encoding) - e.g., gzip, br, deflate
    public var contentEncoding: String?

    /// User-Agent header (http.user_agent)
    public var userAgent: String?

    /// Cache-Control header (http.cache_control)
    public var cacheControl: String?

    /// Request cookies from Cookie header (http.cookie)
    public var requestCookies: [HTTPCookie]?

    /// Response cookies from Set-Cookie header (http.set_cookie)
    public var responseCookies: [HTTPCookie]?

    // MARK: - HTTP Metadata

    /// Parsed query parameters from URI (http.request.uri.query.parameter)
    public var queryParameters: [URLQueryItem]?

    /// Authorization header (http.authorization)
    public var authorization: String?

    /// TLS alert messages captured during connection (tls.alert_message)
    public var tlsAlerts: [TLSAlertMessage]?

    /// Redirect history when the client follows redirects.
    public var redirectChain: [RedirectInfo] = []

    /// cURL import/execution metadata when this request was produced from a cURL command.
    public var curlExecutionMetadata: CurlExecutionMetadata?

    public init(
        id: UUID = UUID(),
        url: String,
        method: HTTPMethod,
        requestMethodRaw: String? = nil,
        statusCode: Int? = nil,
        statusMessage: String? = nil,
        timestamp: Date = Date(),
        duration: TimeInterval,
        requestHeaders: [TraceHTTPHeader] = [],
        responseHeaders: [TraceHTTPHeader] = [],
        requestBody: BodyStorage = .empty,
        responseBody: BodyStorage = .empty,
        protocolVersion: HTTPProtocolVersion? = nil,
        timingPhases: NetworkTimingPhases? = nil,
        tlsInfo: TLSConnectionInfo? = nil,
        wasThrottled: Bool = false,
        throttlingProfile: String? = nil,
        executionLog: [ExecutionLogEntry] = [],
        executionErrors: [ExecutionError] = [],
        appliedRuleIds: [UUID] = [],
        redirectChain: [RedirectInfo] = [],
        curlExecutionMetadata: CurlExecutionMetadata? = nil
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.requestMethodRaw = requestMethodRaw
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.timestamp = timestamp
        self.duration = duration
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.protocolVersion = protocolVersion ?? Self.detectProtocolVersion(from: requestHeaders, responseHeaders: responseHeaders)
        self.timingPhases = timingPhases
        self.tlsInfo = tlsInfo
        self.wasThrottled = wasThrottled
        self.throttlingProfile = throttlingProfile
        self.executionLog = executionLog
        self.executionErrors = executionErrors
        self.appliedRuleIds = appliedRuleIds
        self.redirectChain = redirectChain
        self.curlExecutionMetadata = curlExecutionMetadata
    }

    /// Backward-compatible initializer for older call sites using `rawMethod`/`curlMetadata`.
    @available(*, deprecated, message: "Use initializer with requestMethodRaw and curlExecutionMetadata")
    public init(
        id: UUID = UUID(),
        url: String,
        method: HTTPMethod,
        rawMethod: String?,
        statusCode: Int? = nil,
        statusMessage: String? = nil,
        timestamp: Date = Date(),
        duration: TimeInterval,
        requestHeaders: [TraceHTTPHeader] = [],
        responseHeaders: [TraceHTTPHeader] = [],
        requestBody: BodyStorage = .empty,
        responseBody: BodyStorage = .empty,
        protocolVersion: HTTPProtocolVersion? = nil,
        timingPhases: NetworkTimingPhases? = nil,
        tlsInfo: TLSConnectionInfo? = nil,
        wasThrottled: Bool = false,
        throttlingProfile: String? = nil,
        executionLog: [ExecutionLogEntry] = [],
        executionErrors: [ExecutionError] = [],
        appliedRuleIds: [UUID] = [],
        redirectChain: [RedirectInfo] = [],
        curlMetadata: CurlRequestMetadata?
    ) {
        self.init(
            id: id,
            url: url,
            method: method,
            requestMethodRaw: rawMethod,
            statusCode: statusCode,
            statusMessage: statusMessage,
            timestamp: timestamp,
            duration: duration,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody,
            protocolVersion: protocolVersion,
            timingPhases: timingPhases,
            tlsInfo: tlsInfo,
            wasThrottled: wasThrottled,
            throttlingProfile: throttlingProfile,
            executionLog: executionLog,
            executionErrors: executionErrors,
            appliedRuleIds: appliedRuleIds,
            redirectChain: redirectChain,
            curlExecutionMetadata: curlMetadata?.asExecutionMetadata
        )
    }

    /// Detect HTTP protocol version from headers
    private static func detectProtocolVersion(from requestHeaders: [TraceHTTPHeader], responseHeaders: [TraceHTTPHeader]) -> HTTPProtocolVersion {
        // Check for HTTP/2-specific pseudo-headers (starting with :)
        let allHeaders = requestHeaders + responseHeaders
        let hasPseudoHeaders = allHeaders.contains { $0.key.hasPrefix(":") }

        if hasPseudoHeaders {
            return .http2
        }

        // Check for HTTP/2 upgrade header
        for header in requestHeaders {
            if header.key.lowercased() == "upgrade" && header.value.lowercased().contains("h2c") {
                return .http2
            }
        }

        // Check ALPN negotiation result (if present in custom header)
        for header in responseHeaders {
            if header.key.lowercased() == "x-protocol" || header.key.lowercased() == "x-alpn" {
                if header.value.lowercased().contains("h2") {
                    return .http2
                }
            }
        }

        // Default to HTTP/1.1
        return .http11
    }

    public var statusColor: StatusColor {
        guard let statusCode else { return .unknown }
        switch statusCode {
        case 200 ..< 300: return .success
        case 300 ..< 400: return .redirect
        case 400 ..< 500: return .clientError
        case 500 ..< 600: return .serverError
        default: return .unknown
        }
    }

    public var statusCodeText: String {
        statusCode.map(String.init) ?? "--"
    }

    public static func == (lhs: NetworkRequest, rhs: NetworkRequest) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public var host: String {
        if let url = URL(string: url) {
            return url.host ?? url.absoluteString
        }
        return url
    }

    public var path: String {
        if let url = URL(string: url) {
            return url.path.isEmpty ? "/" : url.path
        }
        return url
    }

    public var responseSize: Int? {
        let bodySize = responseBody.totalSize

        // Try to get content-length from headers
        if let contentLengthHeader = responseHeaders.first(where: { $0.key.lowercased() == "content-length" }),
           let contentLength = Int(contentLengthHeader.value) {
            return contentLength
        }

        // Return body size if available
        return bodySize > 0 ? bodySize : nil
    }

    public var requestSize: Int? {
        let bodySize = requestBody.totalSize

        // Try to get content-length from headers
        if let contentLengthHeader = requestHeaders.first(where: { $0.key.lowercased() == "content-length" }),
           let contentLength = Int(contentLengthHeader.value) {
            return contentLength
        }

        // Return body size if available
        return bodySize > 0 ? bodySize : nil
    }

    /// Check if this request uses HTTP/2 protocol
    public var isHTTP2: Bool {
        protocolVersion == .http2
    }

    /// HTTP/2 stream information (if applicable)
    public var http2Streams: [HTTP2StreamInfo]?

    /// HTTP/2 connection-level information (if applicable)
    public var http2ConnectionInfo: HTTP2ConnectionInfo?

    // MARK: - Field Extraction Methods

    /// Extract HTTP fields from headers and URL
    public mutating func extractHTTPFields() {
        extractContentType()
        extractContentEncoding()
        extractUserAgent()
        extractCacheControl()
        extractCookies()

        extractQueryParameters()
        extractAuthorization()
    }

    private mutating func extractContentType() {
        contentType = responseHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value
    }

    private mutating func extractContentEncoding() {
        contentEncoding = responseHeaders.first(where: { $0.key.lowercased() == "content-encoding" })?.value
    }

    private mutating func extractUserAgent() {
        userAgent = requestHeaders.first(where: { $0.key.lowercased() == "user-agent" })?.value
    }

    private mutating func extractCacheControl() {
        cacheControl = responseHeaders.first(where: { $0.key.lowercased() == "cache-control" })?.value
            ?? requestHeaders.first(where: { $0.key.lowercased() == "cache-control" })?.value
    }

    private mutating func extractCookies() {
        // Parse request cookies from Cookie header
        if let cookieHeader = requestHeaders.first(where: { $0.key.lowercased() == "cookie" })?.value {
            requestCookies = Self.parseCookieHeader(cookieHeader, domain: host)
        }

        // Parse response cookies from Set-Cookie headers
        let setCookieHeaders = responseHeaders.filter { $0.key.lowercased() == "set-cookie" }
        if !setCookieHeaders.isEmpty {
            responseCookies = setCookieHeaders.compactMap { Self.parseSetCookieHeader($0.value, domain: host) }
        }
    }

    private mutating func extractQueryParameters() {
        guard let urlComponents = URLComponents(string: url) else { return }
        queryParameters = urlComponents.queryItems
    }

    private mutating func extractAuthorization() {
        authorization = requestHeaders.first(where: { $0.key.lowercased() == "authorization" })?.value
    }

    // MARK: - Cookie Parsing Helpers

    /// Parse Cookie header: "name1=value1; name2=value2"
    private static func parseCookieHeader(_ cookieHeader: String, domain: String) -> [HTTPCookie] {
        let cookiePairs = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        return cookiePairs.compactMap { pair in
            let components = pair.split(separator: "=", maxSplits: 1)
            guard components.count == 2 else { return nil }
            let name = String(components[0]).trimmingCharacters(in: .whitespaces)
            let value = String(components[1]).trimmingCharacters(in: .whitespaces)
            return HTTPCookie(
                name: name,
                value: value,
                domain: domain,
                path: nil,
                expires: nil,
                secure: false,
                httpOnly: false,
                sameSite: nil
            )
        }
    }

    /// Parse Set-Cookie header: "name=value; Domain=example.com; Path=/; Secure; HttpOnly; SameSite=Lax"
    private static func parseSetCookieHeader(_ setCookieHeader: String, domain: String) -> HTTPCookie? {
        let components = setCookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstComponent = components.first else { return nil }

        // Parse name=value
        let nameValue = firstComponent.split(separator: "=", maxSplits: 1)
        guard nameValue.count == 2 else { return nil }
        let name = String(nameValue[0])
        let value = String(nameValue[1])

        var cookieDomain: String? = domain
        var path: String?
        var expires: Date?
        var secure = false
        var httpOnly = false
        var sameSite: HTTPCookie.SameSitePolicy?

        // Parse attributes
        for component in components.dropFirst() {
            let parts = component.split(separator: "=", maxSplits: 1)
            let key = parts[0].lowercased()

            switch key {
            case "domain":
                if parts.count > 1 {
                    cookieDomain = String(parts[1])
                }
            case "path":
                if parts.count > 1 {
                    path = String(parts[1])
                }
            case "expires":
                if parts.count > 1 {
                    expires = Self.parseCookieDate(String(parts[1]))
                }
            case "max-age":
                if parts.count > 1, let maxAge = TimeInterval(parts[1]) {
                    expires = Date().addingTimeInterval(maxAge)
                }
            case "secure":
                secure = true
            case "httponly":
                httpOnly = true
            case "samesite":
                if parts.count > 1 {
                    let sameSiteValue = String(parts[1]).lowercased()
                    sameSite = HTTPCookie.SameSitePolicy(rawValue: sameSiteValue.capitalized)
                }
            default:
                break
            }
        }

        return HTTPCookie(
            name: name,
            value: value,
            domain: cookieDomain,
            path: path,
            expires: expires,
            secure: secure,
            httpOnly: httpOnly,
            sameSite: sameSite
        )
    }

    /// Parse cookie date formats (RFC 1123, RFC 850, ANSI C)
    private static func parseCookieDate(_ dateString: String) -> Date? {
        let formatters = [
            "EEE, dd MMM yyyy HH:mm:ss zzz", // RFC 1123
            "EEEE, dd-MMM-yy HH:mm:ss zzz", // RFC 850
            "EEE MMM d HH:mm:ss yyyy" // ANSI C
        ]

        for format in formatters {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(abbreviation: "GMT")
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        return nil
    }
}

// MARK: - HTTP Cookie

/// Represents an HTTP cookie
public struct HTTPCookie: Codable, Equatable, Identifiable {
    public let id = UUID()
    public let name: String
    public let value: String
    public let domain: String?
    public let path: String?
    public let expires: Date?
    public let secure: Bool
    public let httpOnly: Bool
    public let sameSite: SameSitePolicy?

    public enum SameSitePolicy: String, Codable {
        case strict = "Strict"
        case lax = "Lax"
        case none = "None"
    }

    private enum CodingKeys: String, CodingKey {
        case name, value, domain, path, expires, secure, httpOnly, sameSite
    }

    public init(
        name: String,
        value: String,
        domain: String?,
        path: String?,
        expires: Date?,
        secure: Bool,
        httpOnly: Bool,
        sameSite: SameSitePolicy?
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }
}

// MARK: - TLS Alert Message

/// TLS alert message information (tls.alert_message)
public struct TLSAlertMessage: Codable, Equatable, Identifiable {
    public let id = UUID()
    public let level: AlertLevel
    public let description: AlertDescription
    public let timestamp: Date

    public enum AlertLevel: Int, Codable {
        case warning = 1
        case fatal = 2

        public var displayName: String {
            switch self {
            case .warning: "Warning"
            case .fatal: "Fatal"
            }
        }
    }

    public enum AlertDescription: Int, Codable {
        case closeNotify = 0
        case unexpectedMessage = 10
        case badRecordMAC = 20
        case decryptionFailed = 21
        case recordOverflow = 22
        case decompressionFailure = 30
        case handshakeFailure = 40
        case noCertificate = 41
        case badCertificate = 42
        case unsupportedCertificate = 43
        case certificateRevoked = 44
        case certificateExpired = 45
        case certificateUnknown = 46
        case illegalParameter = 47
        case unknownCA = 48
        case accessDenied = 49
        case decodeError = 50
        case decryptError = 51
        case exportRestriction = 60
        case protocolVersion = 70
        case insufficientSecurity = 71
        case internalError = 80
        case inappropriateFallback = 86
        case userCanceled = 90
        case noRenegotiation = 100
        case missingExtension = 109
        case unsupportedExtension = 110
        case certificateUnobtainable = 111
        case unrecognizedName = 112
        case badCertificateStatusResponse = 113
        case badCertificateHashValue = 114
        case unknownPSKIdentity = 115
        case certificateRequired = 116
        case noApplicationProtocol = 120
        case unknown = 255

        public var displayName: String {
            switch self {
            case .closeNotify: "Close Notify"
            case .unexpectedMessage: "Unexpected Message"
            case .badRecordMAC: "Bad Record MAC"
            case .decryptionFailed: "Decryption Failed"
            case .recordOverflow: "Record Overflow"
            case .decompressionFailure: "Decompression Failure"
            case .handshakeFailure: "Handshake Failure"
            case .noCertificate: "No Certificate"
            case .badCertificate: "Bad Certificate"
            case .unsupportedCertificate: "Unsupported Certificate"
            case .certificateRevoked: "Certificate Revoked"
            case .certificateExpired: "Certificate Expired"
            case .certificateUnknown: "Certificate Unknown"
            case .illegalParameter: "Illegal Parameter"
            case .unknownCA: "Unknown CA"
            case .accessDenied: "Access Denied"
            case .decodeError: "Decode Error"
            case .decryptError: "Decrypt Error"
            case .exportRestriction: "Export Restriction"
            case .protocolVersion: "Protocol Version"
            case .insufficientSecurity: "Insufficient Security"
            case .internalError: "Internal Error"
            case .inappropriateFallback: "Inappropriate Fallback"
            case .userCanceled: "User Canceled"
            case .noRenegotiation: "No Renegotiation"
            case .missingExtension: "Missing Extension"
            case .unsupportedExtension: "Unsupported Extension"
            case .certificateUnobtainable: "Certificate Unobtainable"
            case .unrecognizedName: "Unrecognized Name"
            case .badCertificateStatusResponse: "Bad Certificate Status Response"
            case .badCertificateHashValue: "Bad Certificate Hash Value"
            case .unknownPSKIdentity: "Unknown PSK Identity"
            case .certificateRequired: "Certificate Required"
            case .noApplicationProtocol: "No Application Protocol"
            case .unknown: "Unknown"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case level, description, timestamp
    }
}

/// HTTP Protocol Version
public enum HTTPProtocolVersion: String, Codable, Sendable {
    case http10 = "HTTP/1.0"
    case http11 = "HTTP/1.1"
    case http2 = "HTTP/2"
    case http3 = "HTTP/3"

    public var displayName: String {
        rawValue
    }

    public var shortName: String {
        switch self {
        case .http10: "1.0"
        case .http11: "1.1"
        case .http2: "2"
        case .http3: "3"
        }
    }

    /// Get color for UI display
    public var color: StatusColor {
        switch self {
        case .http2, .http3:
            .success
        case .http11:
            .info
        case .http10:
            .warning
        }
    }

    /// Get icon for UI display
    public var icon: String {
        switch self {
        case .http2, .http3:
            "bolt.fill"
        case .http11:
            "checkmark.circle.fill"
        case .http10:
            "clock.fill"
        }
    }

    /// Description for tooltip
    var description: String {
        switch self {
        case .http10:
            "HTTP/1.0 - Basic version with headers (1996)"
        case .http11:
            "HTTP/1.1 - Most common version with keep-alive (1997)"
        case .http2:
            "HTTP/2 - Binary protocol with multiplexing (2015)"
        case .http3:
            "HTTP/3 - QUIC-based protocol (2022)"
        }
    }
}

public enum HTTPMethod: String, CaseIterable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case head = "HEAD"
    case options = "OPTIONS"
    /// Used for HTTPS proxy tunneling (e.g., `CONNECT host:443 HTTP/1.1`)
    case connect = "CONNECT"

    public var color: StatusColor {
        switch self {
        case .get: .success
        case .post: .info
        case .put: .warning
        case .delete: .clientError
        case .patch: .warning
        case .head, .options, .connect: .unknown
        }
    }
}

public enum HeaderIndexingPolicy: String, Codable, Sendable {
    case incremental
    case withoutIndexing
    case neverIndexed
}

public struct TraceHTTPHeader: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let key: String
    public let value: String
    public let indexingPolicy: HeaderIndexingPolicy

    public init(key: String, value: String, indexingPolicy: HeaderIndexingPolicy = .incremental) {
        self.key = key
        self.value = value
        self.indexingPolicy = indexingPolicy
    }

    public static func == (lhs: TraceHTTPHeader, rhs: TraceHTTPHeader) -> Bool {
        lhs.key == rhs.key && lhs.value == rhs.value && lhs.indexingPolicy == rhs.indexingPolicy
    }
}

extension TraceHTTPHeader: Codable {
    enum CodingKeys: String, CodingKey {
        case key, value, indexingPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.value = try container.decode(String.self, forKey: .value)
        self.indexingPolicy = try container.decodeIfPresent(HeaderIndexingPolicy.self, forKey: .indexingPolicy) ?? .incremental
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(value, forKey: .value)
        try container.encode(indexingPolicy, forKey: .indexingPolicy)
    }
}

public enum StatusColor {
    case success
    case redirect
    case clientError
    case serverError
    case info
    case warning
    case unknown

    #if canImport(SwiftUI)
    public var swiftUIColor: Color {
        switch self {
        case .success: .green
        case .redirect: .blue
        case .clientError: .orange
        case .serverError: .red
        case .info: .gray
        case .warning: .yellow
        case .unknown: .secondary
        }
    }
    #endif
}

public struct RedirectInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let fromURL: String
    public let toURL: String
    public let statusCode: Int?
    public let location: String?

    public init(
        id: UUID = UUID(),
        fromURL: String,
        toURL: String,
        statusCode: Int?,
        location: String?
    ) {
        self.id = id
        self.fromURL = fromURL
        self.toURL = toURL
        self.statusCode = statusCode
        self.location = location
    }
}

public struct CurlExecutionMetadata: Codable, Equatable, Sendable {
    public let originalCommand: String
    public let transferIndex: Int
    public let transferCount: Int
    public let effectiveOptions: [String: [String]]
    public let diagnostics: [CurlExecutionDiagnostic]

    public init(
        originalCommand: String,
        transferIndex: Int,
        transferCount: Int,
        effectiveOptions: [String: [String]] = [:],
        diagnostics: [CurlExecutionDiagnostic] = []
    ) {
        self.originalCommand = originalCommand
        self.transferIndex = transferIndex
        self.transferCount = transferCount
        self.effectiveOptions = effectiveOptions
        self.diagnostics = diagnostics
    }
}

/// Backward-compatible cURL metadata model kept for serialization and symbol compatibility.
public struct CurlRequestMetadata: Codable, Equatable, Sendable {
    public let originalCommand: String
    public let transferIndex: Int
    public let transferCount: Int
    public let options: [String: [String]]
    public let diagnostics: [CurlExecutionDiagnostic]

    public init(
        originalCommand: String,
        transferIndex: Int,
        transferCount: Int,
        options: [String: [String]] = [:],
        diagnostics: [CurlExecutionDiagnostic] = []
    ) {
        self.originalCommand = originalCommand
        self.transferIndex = transferIndex
        self.transferCount = transferCount
        self.options = options
        self.diagnostics = diagnostics
    }

    public init(executionMetadata: CurlExecutionMetadata) {
        self.init(
            originalCommand: executionMetadata.originalCommand,
            transferIndex: executionMetadata.transferIndex,
            transferCount: executionMetadata.transferCount,
            options: executionMetadata.effectiveOptions,
            diagnostics: executionMetadata.diagnostics
        )
    }

    public var asExecutionMetadata: CurlExecutionMetadata {
        CurlExecutionMetadata(
            originalCommand: originalCommand,
            transferIndex: transferIndex,
            transferCount: transferCount,
            effectiveOptions: options,
            diagnostics: diagnostics
        )
    }
}

public struct CurlExecutionDiagnostic: Codable, Equatable, Sendable {
    public let severity: String
    public let option: String?
    public let message: String

    public init(severity: String, option: String? = nil, message: String) {
        self.severity = severity
        self.option = option
        self.message = message
    }
}

// MARK: - Advanced Performance Metrics

/// Detailed timing breakdown for network requests
public struct NetworkTimingPhases: Codable, Equatable {
    /// DNS lookup time (resolution of domain to IP)
    public let dnsLookup: TimeInterval?

    /// TCP connection establishment time (3-way handshake)
    public let tcpConnection: TimeInterval?

    /// TLS/SSL handshake time (encryption negotiation)
    public let tlsHandshake: TimeInterval?

    /// Time to send the request to the server
    public let requestSent: TimeInterval?

    /// Time to First Byte - waiting for server response to start
    public let ttfb: TimeInterval?

    /// Time to download the response body
    public let contentDownload: TimeInterval?

    /// Time spent processing redirects
    public let redirectTime: TimeInterval?

    public init(
        dnsLookup: TimeInterval? = nil,
        tcpConnection: TimeInterval? = nil,
        tlsHandshake: TimeInterval? = nil,
        requestSent: TimeInterval? = nil,
        ttfb: TimeInterval? = nil,
        contentDownload: TimeInterval? = nil,
        redirectTime: TimeInterval? = nil
    ) {
        self.dnsLookup = dnsLookup
        self.tcpConnection = tcpConnection
        self.tlsHandshake = tlsHandshake
        self.requestSent = requestSent
        self.ttfb = ttfb
        self.contentDownload = contentDownload
        self.redirectTime = redirectTime
    }

    /// Total time (should match NetworkRequest.duration)
    public var total: TimeInterval {
        let dns: TimeInterval = dnsLookup ?? 0
        let tcp: TimeInterval = tcpConnection ?? 0
        let tls: TimeInterval = tlsHandshake ?? 0
        let request: TimeInterval = requestSent ?? 0
        let firstByte: TimeInterval = ttfb ?? 0
        let download: TimeInterval = contentDownload ?? 0
        let redirect: TimeInterval = redirectTime ?? 0

        return dns + tcp + tls + request + firstByte + download + redirect
    }

    /// Check if we have any timing data
    public var hasData: Bool {
        dnsLookup != nil || tcpConnection != nil || tlsHandshake != nil ||
            requestSent != nil || ttfb != nil || contentDownload != nil || redirectTime != nil
    }

    /// Get formatted timing breakdown for display
    public var breakdown: [(String, TimeInterval)] {
        var result: [(String, TimeInterval)] = []

        if let dns = dnsLookup { result.append(("DNS Lookup", dns)) }
        if let tcp = tcpConnection { result.append(("TCP Connection", tcp)) }
        if let tls = tlsHandshake { result.append(("TLS Handshake", tls)) }
        if let request = requestSent { result.append(("Request Sent", request)) }
        if let ttfb { result.append(("Waiting (TTFB)", ttfb)) }
        if let download = contentDownload { result.append(("Content Download", download)) }
        if let redirect = redirectTime { result.append(("Redirect", redirect)) }

        return result
    }
}

// MARK: - TLS/SSL Connection Info

/// TLS/SSL connection information
public struct TLSConnectionInfo: Codable, Equatable {
    /// TLS protocol version (e.g., "TLSv1.2", "TLSv1.3")
    public let protocolVersion: String

    /// Cipher suite used for encryption
    public let cipherSuite: String?

    /// Server certificate chain
    public let certificateChain: [CertificateInfo]?

    /// Whether certificate pinning was validated
    public let certificatePinningEnabled: Bool

    /// Whether the certificate was trusted
    public let certificateTrusted: Bool

    /// ALPN (Application-Layer Protocol Negotiation) information
    public var alpnProtocol: String? // Negotiated protocol (e.g., "h2", "http/1.1")
    public var alpnOffered: [String]? // Protocols offered by client
    public var alpnAvailable: [String]? // Protocols supported by server

    public init(
        protocolVersion: String,
        cipherSuite: String? = nil,
        certificateChain: [CertificateInfo]? = nil,
        certificatePinningEnabled: Bool = false,
        certificateTrusted: Bool = false,
        alpnProtocol: String? = nil,
        alpnOffered: [String]? = nil,
        alpnAvailable: [String]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.cipherSuite = cipherSuite
        self.certificateChain = certificateChain
        self.certificatePinningEnabled = certificatePinningEnabled
        self.certificateTrusted = certificateTrusted
        self.alpnProtocol = alpnProtocol
        self.alpnOffered = alpnOffered
        self.alpnAvailable = alpnAvailable
    }
}

/// Certificate information
public struct CertificateInfo: Codable, Equatable, Identifiable {
    public let id = UUID()

    /// Certificate subject (Common Name)
    public let subject: String

    /// Certificate issuer
    public let issuer: String

    /// Valid from date
    public let validFrom: Date

    /// Valid until date
    public let validUntil: Date

    /// SHA-256 fingerprint
    public let fingerprint: String

    /// Public key algorithm (e.g., "RSA 2048", "ECDSA P-256")
    public let publicKeyAlgorithm: String

    /// Serial number
    public let serialNumber: String?

    /// Check if certificate is currently valid
    public var isValid: Bool {
        let now = Date()
        return now >= validFrom && now <= validUntil
    }

    /// Check if certificate is expiring soon (within 30 days)
    public var isExpiringSoon: Bool {
        let thirtyDaysFromNow = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return validUntil <= thirtyDaysFromNow && isValid
    }

    private enum CodingKeys: String, CodingKey {
        case subject, issuer, validFrom, validUntil, fingerprint, publicKeyAlgorithm, serialNumber
    }

    public init(
        subject: String,
        issuer: String,
        validFrom: Date,
        validUntil: Date,
        fingerprint: String,
        publicKeyAlgorithm: String,
        serialNumber: String?
    ) {
        self.subject = subject
        self.issuer = issuer
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.fingerprint = fingerprint
        self.publicKeyAlgorithm = publicKeyAlgorithm
        self.serialNumber = serialNumber
    }
}

// MARK: - HTTP/2 Stream Information

/// Per-stream information for HTTP/2 connections
public struct HTTP2StreamInfo: Identifiable, Codable {
    public let id: UUID
    public let streamId: Int
    public var headers: [TraceHTTPHeader]
    public var dataFrames: [HTTP2DataFrame]
    public var state: StreamState
    public var priority: StreamPriority?
    public var windowSize: Int
    public var totalDataSize: Int
    public var startTime: Date
    public var endTime: Date?

    public enum StreamState: String, Codable {
        case idle
        case reservedLocal
        case reservedRemote
        case open
        case halfClosedLocal
        case halfClosedRemote
        case closed
    }

    public struct StreamPriority: Codable {
        public let exclusive: Bool
        public let dependsOn: Int
        public let weight: Int

        public init(exclusive: Bool, dependsOn: Int, weight: Int) {
            self.exclusive = exclusive
            self.dependsOn = dependsOn
            self.weight = weight
        }
    }

    /// Total duration of the stream
    public var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    public init(
        id: UUID = UUID(),
        streamId: Int,
        headers: [TraceHTTPHeader],
        dataFrames: [HTTP2DataFrame],
        state: StreamState,
        priority: StreamPriority?,
        windowSize: Int,
        totalDataSize: Int,
        startTime: Date,
        endTime: Date?
    ) {
        self.id = id
        self.streamId = streamId
        self.headers = headers
        self.dataFrames = dataFrames
        self.state = state
        self.priority = priority
        self.windowSize = windowSize
        self.totalDataSize = totalDataSize
        self.startTime = startTime
        self.endTime = endTime
    }

    private enum CodingKeys: String, CodingKey {
        case streamId, headers, dataFrames, state, priority, windowSize, totalDataSize, startTime, endTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.streamId = try container.decode(Int.self, forKey: .streamId)
        self.headers = try container.decode([TraceHTTPHeader].self, forKey: .headers)
        self.dataFrames = try container.decode([HTTP2DataFrame].self, forKey: .dataFrames)
        self.state = try container.decode(StreamState.self, forKey: .state)
        self.priority = try container.decodeIfPresent(StreamPriority.self, forKey: .priority)
        self.windowSize = try container.decode(Int.self, forKey: .windowSize)
        self.totalDataSize = try container.decode(Int.self, forKey: .totalDataSize)
        self.startTime = try container.decode(Date.self, forKey: .startTime)
        self.endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
    }
}

/// Individual HTTP/2 frame information
public struct HTTP2DataFrame: Identifiable, Codable {
    public let id: UUID
    public let frameType: String
    public let flags: [String]
    public let payloadSize: Int
    public let timestamp: Date
    public let rawData: Data?

    public init(
        id: UUID = UUID(),
        frameType: String,
        flags: [String],
        payloadSize: Int,
        timestamp: Date,
        rawData: Data?
    ) {
        self.id = id
        self.frameType = frameType
        self.flags = flags
        self.payloadSize = payloadSize
        self.timestamp = timestamp
        self.rawData = rawData
    }

    private enum CodingKeys: String, CodingKey {
        case frameType, flags, payloadSize, timestamp, rawData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.frameType = try container.decode(String.self, forKey: .frameType)
        self.flags = try container.decode([String].self, forKey: .flags)
        self.payloadSize = try container.decode(Int.self, forKey: .payloadSize)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.rawData = try container.decodeIfPresent(Data.self, forKey: .rawData)
    }
}

/// HTTP/2 connection-level information
public struct HTTP2ConnectionInfo: Codable {
    public var settingsReceived: [String: Int]
    public var settingsSent: [String: Int]
    public var goAwayReceived: Bool
    public var lastStreamId: Int?
    public var connectionStartTime: Date
    public var connectionEndTime: Date?

    /// HPACK table snapshot (optional, captured when debugging is enabled)
    public var hpackTableSnapshot: HPACKTableSnapshot?

    /// HPACK table events history (optional, captured when debugging is enabled)
    public var hpackTableEvents: [HPACKTableEvent]?

    /// Check if connection is still active
    public var isActive: Bool {
        connectionEndTime == nil && !goAwayReceived
    }

    /// Total connection duration
    public var duration: TimeInterval? {
        guard let end = connectionEndTime else { return nil }
        return end.timeIntervalSince(connectionStartTime)
    }

    public init(
        settingsReceived: [String: Int],
        settingsSent: [String: Int],
        goAwayReceived: Bool,
        lastStreamId: Int?,
        connectionStartTime: Date,
        connectionEndTime: Date?,
        hpackTableSnapshot: HPACKTableSnapshot?,
        hpackTableEvents: [HPACKTableEvent]?
    ) {
        self.settingsReceived = settingsReceived
        self.settingsSent = settingsSent
        self.goAwayReceived = goAwayReceived
        self.lastStreamId = lastStreamId
        self.connectionStartTime = connectionStartTime
        self.connectionEndTime = connectionEndTime
        self.hpackTableSnapshot = hpackTableSnapshot
        self.hpackTableEvents = hpackTableEvents
    }
}

// NOTE: HPACKTableSnapshot and HPACKTableEvent are mirrored in Trace/Models/HPACKTypes.swift
// for use in the main app target.

// MARK: - Sample Data for Testing

extension HPACKTableSnapshot {
    /// Creates a sample HPACK table snapshot with realistic data for testing
    static func sample() -> HPACKTableSnapshot {
        // RFC 7541 static table (first 10 entries as example)
        let staticEntries: [(index: Int, name: String, value: String)] = [
            (index: 1, name: ":authority", value: ""),
            (index: 2, name: ":method", value: "GET"),
            (index: 3, name: ":method", value: "POST"),
            (index: 4, name: ":path", value: "/"),
            (index: 5, name: ":path", value: "/index.html"),
            (index: 6, name: ":scheme", value: "http"),
            (index: 7, name: ":scheme", value: "https"),
            (index: 8, name: ":status", value: "200"),
            (index: 9, name: ":status", value: "204"),
            (index: 10, name: ":status", value: "206")
        ]

        // Sample dynamic entries
        let dynamicEntries: [(index: Int, name: String, value: String, size: Int)] = [
            (index: 62, name: ":authority", value: "api.example.com", size: 57),
            (index: 63, name: "authorization", value: "Bearer eyJhbGc...", size: 78),
            (index: 64, name: "user-agent", value: "Trace/1.0", size: 43),
            (index: 65, name: "accept", value: "application/json", size: 49)
        ]

        return HPACKTableSnapshot(
            staticEntries: staticEntries,
            dynamicEntries: dynamicEntries,
            currentSize: 227, // Sum of dynamic entry sizes
            maxSize: 4096
        )
    }
}

extension HPACKTableEvent {
    /// Creates sample HPACK table events for testing
    static func sampleEvents() -> [HPACKTableEvent] {
        let now = Date()
        let snapshot = HPACKTableSnapshot.sample()
        return [
            HPACKTableEvent(
                type: .entryAdded(name: ":authority", value: "api.example.com", index: 62),
                timestamp: now.addingTimeInterval(-10),
                tableSnapshot: snapshot
            ),
            HPACKTableEvent(
                type: .entryAdded(name: "authorization", value: "Bearer token...", index: 63),
                timestamp: now.addingTimeInterval(-8),
                tableSnapshot: snapshot
            ),
            HPACKTableEvent(
                type: .tableSizeUpdated(newSize: 8192),
                timestamp: now.addingTimeInterval(-5),
                tableSnapshot: snapshot
            ),
            HPACKTableEvent(
                type: .entryEvicted(name: ":authority", value: "old.example.com", index: 62),
                timestamp: now.addingTimeInterval(-3),
                tableSnapshot: snapshot
            ),
            HPACKTableEvent(
                type: .entryAdded(name: "user-agent", value: "Trace/1.0", index: 64),
                timestamp: now.addingTimeInterval(-1),
                tableSnapshot: snapshot
            )
        ]
    }
}
