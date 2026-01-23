//
//  HARExporter.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

/// Exports and imports network requests in HAR format
public class HARExporter {
    public init() {}

    // MARK: - Export

    /// Exports a list of network requests to HAR format
    public static func export(requests: [NetworkRequest]) -> Data? {
        let har = buildHAR(from: requests)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        return try? encoder.encode(har)
    }

    /// Exports requests as HAR string
    public static func exportAsString(requests: [NetworkRequest]) -> String? {
        guard let data = export(requests: requests) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves requests to HAR file
    public static func exportToFile(requests: [NetworkRequest], filename: String = "trace-export.har") throws -> URL {
        guard let data = export(requests: requests) else {
            throw HARError.exportFailed("Failed to encode HAR data")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(filename)

        try data.write(to: fileURL)

        return fileURL
    }

    // MARK: - Import

    /// Imports network requests from HAR data
    public static func `import`(from data: Data) throws -> [NetworkRequest] {
        let decoder = JSONDecoder()

        // Support multiple date formats that HAR files may use
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try ISO8601 with fractional seconds first (most common)
            let formatters: [ISO8601DateFormatter] = [
                {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return formatter
                }(),
                {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter
                }()
            ]

            for formatter in formatters {
                if let date = formatter.date(from: dateString) {
                    return date
                }
            }

            // Fallback to standard DateFormatter for other formats
            let fallbackFormatter = DateFormatter()
            fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
            fallbackFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            if let date = fallbackFormatter.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string: \(dateString)")
        }

        // Try to decode the HAR file
        let har: HAR
        do {
            har = try decoder.decode(HAR.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            throw HARError.importFailed("Invalid HAR format: \(context.debugDescription)")
        } catch let DecodingError.keyNotFound(key, context) {
            throw HARError.importFailed("Missing required field '\(key.stringValue)' at path: \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.typeMismatch(type, context) {
            throw HARError.importFailed("Type mismatch for \(type) at path: \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.valueNotFound(type, context) {
            throw HARError.importFailed("Missing value for \(type) at path: \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw HARError.importFailed("Failed to parse HAR file: \(error.localizedDescription)")
        }

        return har.log.entries.compactMap { entry in
            convertHAREntryToNetworkRequest(entry)
        }
    }

    /// Imports from HAR file URL
    public static func importFromFile(_ fileURL: URL) throws -> [NetworkRequest] {
        // Validate file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw HARError.importFailed("File not found at path: \(fileURL.path)")
        }

        // Read file data
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HARError.importFailed("Could not read file: \(error.localizedDescription)")
        }

        // Validate file is not empty
        guard !data.isEmpty else {
            throw HARError.importFailed("File is empty")
        }

        return try `import`(from: data)
    }

    /// Imports from HAR string
    public static func importFromString(_ harString: String) throws -> [NetworkRequest] {
        guard let data = harString.data(using: .utf8) else {
            throw HARError.importFailed("Invalid HAR string encoding")
        }
        return try `import`(from: data)
    }

    // MARK: - HAR Building

    private static func buildHAR(from requests: [NetworkRequest]) -> HAR {
        let entries = requests.map { convertNetworkRequestToHAREntry($0) }

        let log = HARLog(
            version: "1.2",
            creator: HARCreator(
                name: "Trace",
                version: "1.0"
            ),
            entries: entries,
            pages: nil,
            browser: nil,
            comment: nil
        )

        return HAR(log: log)
    }

    private static func convertNetworkRequestToHAREntry(_ request: NetworkRequest) -> HAREntry {
        // Calculate timings
        let startedDateTime = request.timestamp
        let time = request.duration * 1000 // Convert to milliseconds

        // Build request
        let httpVersion = request.protocolVersion?.rawValue ?? "HTTP/1.1"
        let harRequest = HARRequest(
            method: request.method.rawValue,
            url: request.url,
            httpVersion: httpVersion,
            headers: request.requestHeaders.map { HARHeader(name: $0.key, value: $0.value, comment: nil) },
            queryString: extractQueryString(from: request.url),
            cookies: extractCookies(from: request.requestHeaders),
            headersSize: -1,
            bodySize: request.requestBody.totalSize,
            postData: request.requestBody.getString().map { buildPostData(body: $0, headers: request.requestHeaders) },
            comment: nil
        )

        let responseMimeType = extractContentType(from: request.responseHeaders)
        let responseBody = makeHARContentBody(from: request.responseBody, mimeType: responseMimeType)

        // Build response
        let harResponse = HARResponse(
            status: request.statusCode ?? 0,
            statusText: HTTPURLResponse.localizedString(forStatusCode: request.statusCode ?? 0),
            httpVersion: httpVersion,
            headers: request.responseHeaders.map { HARHeader(name: $0.key, value: $0.value, comment: nil) },
            cookies: extractCookies(from: request.responseHeaders),
            content: HARContent(
                size: request.responseBody.totalSize,
                compression: nil,
                mimeType: responseMimeType,
                text: responseBody.text,
                encoding: responseBody.encoding,
                comment: nil
            ),
            redirectURL: "",
            headersSize: -1,
            bodySize: request.responseBody.totalSize,
            comment: nil
        )

        // Build timings (simplified)
        let timings = HARTimings(
            send: 0,
            wait: time,
            receive: 0,
            blocked: nil,
            dns: nil,
            connect: nil,
            ssl: nil,
            comment: nil
        )

        return HAREntry(
            startedDateTime: startedDateTime,
            time: time,
            request: harRequest,
            response: harResponse,
            cache: HARCache(),
            timings: timings,
            serverIPAddress: nil,
            connection: nil,
            pageref: nil,
            comment: nil
        )
    }

    private static func convertHAREntryToNetworkRequest(_ entry: HAREntry) -> NetworkRequest {
        let method = HTTPMethod(rawValue: entry.request.method) ?? .get

        // Convert optional strings to BodyStorage using factory method
        let requestBodyStorage: BodyStorage = if let requestBodyText = entry.request.postData?.text {
            BodyStorage.from(string: requestBodyText)
        } else {
            .empty
        }

        let responseBodyStorage: BodyStorage = if let responseBodyText = entry.response.content.text {
            if let encoding = entry.response.content.encoding?.lowercased(), encoding == "base64" {
                if let decoded = Data(base64Encoded: responseBodyText) {
                    BodyStorage.from(data: decoded)
                } else {
                    .empty
                }
            } else {
                BodyStorage.from(string: responseBodyText)
            }
        } else {
            .empty
        }

        return NetworkRequest(
            url: entry.request.url,
            method: method,
            statusCode: entry.response.status,
            timestamp: entry.startedDateTime,
            duration: entry.time / 1000.0, // Convert from milliseconds
            requestHeaders: entry.request.headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) },
            responseHeaders: entry.response.headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) },
            requestBody: requestBodyStorage,
            responseBody: responseBodyStorage
        )
    }

    // MARK: - Helper Methods

    private static func extractQueryString(from url: String) -> [HARQueryParameter] {
        guard let urlComponents = URLComponents(string: url) else { return [] }

        return urlComponents.queryItems?.map { queryItem in
            HARQueryParameter(name: queryItem.name, value: queryItem.value ?? "", comment: nil)
        } ?? []
    }

    private static func extractCookies(from headers: [TraceHTTPHeader]) -> [HARCookie] {
        var cookies: [HARCookie] = []

        for header in headers {
            let lowerKey = header.key.lowercased()
            if lowerKey == "cookie" {
                cookies.append(contentsOf: parseCookieHeader(header.value))
            } else if lowerKey == "set-cookie" {
                if let cookie = parseSetCookie(header.value) {
                    cookies.append(cookie)
                }
            }
        }

        return cookies
    }

    private static func parseCookieHeader(_ value: String) -> [HARCookie] {
        let cookiePairs = value.split(separator: ";")
        return cookiePairs.compactMap { pair in
            let components = pair.split(separator: "=", maxSplits: 1)
            guard components.count == 2 else { return nil }
            return HARCookie(
                name: String(components[0]).trimmingCharacters(in: .whitespaces),
                value: String(components[1]).trimmingCharacters(in: .whitespaces),
                path: nil,
                domain: nil,
                expires: nil,
                httpOnly: nil,
                secure: nil,
                comment: nil
            )
        }
    }

    private static func parseSetCookie(_ value: String) -> HARCookie? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }

        let nameValue = first.split(separator: "=", maxSplits: 1)
        guard nameValue.count == 2 else { return nil }

        var path: String?
        var domain: String?
        var expires: String?
        var httpOnly: Bool?
        var secure: Bool?

        for attribute in parts.dropFirst() {
            let trimmed = attribute.trimmingCharacters(in: .whitespaces)
            let lowercased = trimmed.lowercased()

            if lowercased == "httponly" {
                httpOnly = true
                continue
            }

            if lowercased == "secure" {
                secure = true
                continue
            }

            if lowercased.hasPrefix("path=") {
                path = String(trimmed.dropFirst("path=".count))
                continue
            }

            if lowercased.hasPrefix("domain=") {
                domain = String(trimmed.dropFirst("domain=".count))
                continue
            }

            if lowercased.hasPrefix("expires=") {
                expires = String(trimmed.dropFirst("expires=".count))
                continue
            }
        }

        return HARCookie(
            name: String(nameValue[0]).trimmingCharacters(in: .whitespaces),
            value: String(nameValue[1]).trimmingCharacters(in: .whitespaces),
            path: path,
            domain: domain,
            expires: expires,
            httpOnly: httpOnly,
            secure: secure,
            comment: nil
        )
    }

    private static func extractContentType(from headers: [TraceHTTPHeader]) -> String {
        headers.first { $0.key.lowercased() == "content-type" }?.value ?? "text/plain"
    }

    private static func makeHARContentBody(from body: BodyStorage, mimeType: String) -> (text: String?, encoding: String?) {
        guard !body.isEmpty else { return (nil, nil) }
        guard let data = body.getData(), !data.isEmpty else { return (nil, nil) }

        if isTextualMimeType(mimeType) {
            return (body.getString(), nil)
        }

        return (data.base64EncodedString(), "base64")
    }

    private static func isTextualMimeType(_ mimeType: String) -> Bool {
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if normalized.hasPrefix("text/") {
            return true
        }

        if normalized == "application/json" ||
            normalized == "application/xml" ||
            normalized == "application/javascript" ||
            normalized == "application/x-javascript" ||
            normalized == "application/x-www-form-urlencoded" ||
            normalized == "application/graphql" ||
            normalized == "application/problem+json" ||
            normalized == "application/vnd.api+json" {
            return true
        }

        return normalized.hasSuffix("+json") || normalized.hasSuffix("+xml")
    }

    private static func buildPostData(body: String, headers: [TraceHTTPHeader]) -> HARPostData {
        let mimeType = extractContentType(from: headers)

        return HARPostData(
            mimeType: mimeType,
            text: body,
            params: nil,
            comment: nil
        )
    }
}

// MARK: - HAR Data Models

public struct HAR: Codable {
    public let log: HARLog
}

public struct HARLog: Codable {
    public let version: String
    public let creator: HARCreator
    public let entries: [HAREntry]
    public let pages: [HARPage]?
    public let browser: HARCreator?
    public let comment: String?
}

public struct HARCreator: Codable {
    public let name: String
    public let version: String
}

public struct HAREntry: Codable {
    public let startedDateTime: Date
    public let time: Double
    public let request: HARRequest
    public let response: HARResponse
    public let cache: HARCache
    public let timings: HARTimings
    public let serverIPAddress: String?
    public let connection: String?
    public let pageref: String?
    public let comment: String?
}

public struct HARRequest: Codable {
    public let method: String
    public let url: String
    public let httpVersion: String
    public let headers: [HARHeader]
    public let queryString: [HARQueryParameter]
    public let cookies: [HARCookie]
    public let headersSize: Int
    public let bodySize: Int
    public let postData: HARPostData?
    public let comment: String?
}

public struct HARResponse: Codable {
    public let status: Int
    public let statusText: String
    public let httpVersion: String
    public let headers: [HARHeader]
    public let cookies: [HARCookie]
    public let content: HARContent
    public let redirectURL: String
    public let headersSize: Int
    public let bodySize: Int
    public let comment: String?
}

public struct HARHeader: Codable {
    public let name: String
    public let value: String
    public let comment: String?
}

public struct HARQueryParameter: Codable {
    public let name: String
    public let value: String
    public let comment: String?
}

public struct HARCookie: Codable {
    public let name: String
    public let value: String
    public let path: String?
    public let domain: String?
    public let expires: String?
    public let httpOnly: Bool?
    public let secure: Bool?
    public let comment: String?
}

public struct HARPostData: Codable {
    public let mimeType: String
    public let text: String?
    public let params: [HARParam]?
    public let comment: String?
}

public struct HARParam: Codable {
    public let name: String
    public let value: String?
    public let fileName: String?
    public let contentType: String?
    public let comment: String?
}

public struct HARContent: Codable {
    public let size: Int
    public let compression: Int?
    public let mimeType: String
    public let text: String?
    public let encoding: String?
    public let comment: String?
}

public struct HARCache: Codable {
    // Simplified - can be expanded
}

public struct HARTimings: Codable {
    public let send: Double
    public let wait: Double
    public let receive: Double
    public let blocked: Double?
    public let dns: Double?
    public let connect: Double?
    public let ssl: Double?
    public let comment: String?
}

public struct HARPage: Codable {
    public let startedDateTime: Date
    public let id: String
    public let title: String
    public let pageTimings: HARPageTimings
    public let comment: String?
}

public struct HARPageTimings: Codable {
    public let onContentLoad: Double?
    public let onLoad: Double?
    public let comment: String?
}

// MARK: - Errors

public enum HARError: LocalizedError {
    case exportFailed(String)
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .exportFailed(message):
            "HAR export failed: \(message)"
        case let .importFailed(message):
            "HAR import failed: \(message)"
        }
    }
}
