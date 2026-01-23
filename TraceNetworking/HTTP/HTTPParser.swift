//
//  HTTPParser.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Parses HTTP/1.1 requests and responses from TCP stream data.
public class HTTPParser {
    // MARK: - Data Structures

    /// Represents a parsed HTTP/1.1 request.
    public struct HTTPRequest {
        public let method: String
        public let uri: String
        public let version: String
        public let headers: [String: [String]]
        public let body: Data
        public let rawRequest: Data
        public let trailers: [String: [String]]
    }

    /// Represents a parsed HTTP/1.1 response.
    public struct HTTPResponse {
        public let version: String
        public let statusCode: Int
        public let statusMessage: String
        public let headers: [String: [String]]
        public let body: Data
        public let rawResponse: Data
        public let trailers: [String: [String]]
    }

    // MARK: - Request Parsing

    /// Attempts to parse an HTTP request from stream data.
    ///
    /// Returns `nil` when the request is incomplete.
    /// - Parameter data: The raw request data.
    /// - Returns: A parsed request or `nil` if incomplete.
    public static func parseRequest(from data: Data) -> HTTPRequest? {
        guard let headerRange = findHeaderDelimiter(in: data) else {
            return nil
        }

        let headerData = data.subdata(in: 0 ..< headerRange.lowerBound)
        let headerSection = String(decoding: headerData, as: UTF8.self)
        let normalizedHeaderSection = normalizeHeaderLines(headerSection)
        let lines = normalizedHeaderSection.components(separatedBy: "\n")

        guard let requestLine = lines.first else {
            return nil
        }

        let requestComponents = requestLine.split(whereSeparator: { $0.isWhitespace })
        guard requestComponents.count >= 3 else {
            return nil
        }

        let method = String(requestComponents[0])
        let uri = String(requestComponents[1])
        let version = String(requestComponents[2])

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased(), default: []].append(value)
            }
        }

        let headerEndOffset = headerRange.upperBound

        let isChunked = headers["transfer-encoding"]?.contains(where: { $0.lowercased().contains("chunked") }) == true
        let expectedBodyLength = getExpectedBodyLength(headers: headers)

        let bodyData: Data
        let rawLength: Int
        var trailers: [String: [String]] = [:]

        if isChunked {
            let bodyStart = headerEndOffset
            let bodySlice = data.subdata(in: bodyStart ..< data.count)
            guard let decodedBody = decodeChunkedBody(bodySlice) else {
                return nil
            }
            guard let chunkedInfo = chunkedBodyInfo(bodySlice) else {
                return nil
            }

            if chunkedInfo.trailersStart < chunkedInfo.end {
                trailers = parseTrailers(
                    in: bodySlice,
                    startOffset: chunkedInfo.trailersStart,
                    endOffset: chunkedInfo.end
                )
            }

            bodyData = decodedBody
            rawLength = headerEndOffset + chunkedInfo.end
        } else if let contentLength = expectedBodyLength {
            let bodyStart = headerEndOffset
            let bodyEnd = bodyStart + contentLength

            guard bodyEnd <= data.count else {
                return nil
            }

            bodyData = data.subdata(in: bodyStart ..< bodyEnd)
            rawLength = headerEndOffset + contentLength
        } else {
            bodyData = Data()
            rawLength = headerEndOffset
        }

        let rawEnd = min(rawLength, data.count)
        return HTTPRequest(
            method: method,
            uri: uri,
            version: version,
            headers: headers,
            body: bodyData,
            rawRequest: data.subdata(in: 0 ..< rawEnd),
            trailers: trailers
        )
    }

    // MARK: - Response Parsing

    /// Attempts to parse an HTTP response from stream data.
    /// - Parameters:
    ///   - data: The response data.
    ///   - isConnectionClosed: Whether the connection has been closed (for responses without Content-Length).
    /// - Returns: A parsed response or `nil` if incomplete.
    public static func parseResponse(from data: Data, isConnectionClosed: Bool = false) -> HTTPResponse? {
        guard let headerRange = findHeaderDelimiter(in: data) else {
            return nil
        }

        let headerData = data.subdata(in: 0 ..< headerRange.lowerBound)
        let headerSection = String(decoding: headerData, as: UTF8.self)
        let normalizedHeaderSection = normalizeHeaderLines(headerSection)
        let lines = normalizedHeaderSection.components(separatedBy: "\n")

        guard let statusLine = lines.first else {
            return nil
        }

        let statusComponents = statusLine.split(whereSeparator: { $0.isWhitespace })
        guard statusComponents.count >= 3 else {
            return nil
        }

        let version = String(statusComponents[0])
        guard let statusCode = Int(statusComponents[1]) else {
            return nil
        }
        let statusMessage = statusComponents.dropFirst(2).joined(separator: " ")

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased(), default: []].append(value)
            }
        }

        let headerEndOffset = headerRange.upperBound

        let isChunked = headers["transfer-encoding"]?.contains(where: { $0.lowercased().contains("chunked") }) == true
        let expectedBodyLength = getExpectedBodyLength(headers: headers)

        let bodyData: Data
        let rawLength: Int
        var trailers: [String: [String]] = [:]

        if statusCode == 204 || statusCode == 304 || (100 ..< 200).contains(statusCode) {
            // Rule: 1xx/204/304 responses never include a body.
            bodyData = Data()
            rawLength = headerEndOffset
        } else if isChunked {
            let bodyStart = headerEndOffset
            let bodySlice = data.subdata(in: bodyStart ..< data.count)
            guard let decodedBody = decodeChunkedBody(bodySlice) else {
                return nil
            }
            guard let chunkedInfo = chunkedBodyInfo(bodySlice) else {
                return nil
            }

            if chunkedInfo.trailersStart < chunkedInfo.end {
                trailers = parseTrailers(
                    in: bodySlice,
                    startOffset: chunkedInfo.trailersStart,
                    endOffset: chunkedInfo.end
                )
            }

            bodyData = decodedBody
            rawLength = headerEndOffset + chunkedInfo.end
        } else if let contentLength = expectedBodyLength {
            let bodyStart = headerEndOffset
            let bodyEnd = bodyStart + contentLength

            if bodyEnd > data.count {
                return nil
            }

            bodyData = data.subdata(in: bodyStart ..< bodyEnd)
            rawLength = headerEndOffset + contentLength
        } else if data.count == headerEndOffset {
            bodyData = Data()
            rawLength = headerEndOffset
        } else if isConnectionClosed {
            // Contract: Callers must mark the connection closed to finalize unknown-length bodies.
            let bodyStart = headerEndOffset
            bodyData = data.subdata(in: bodyStart ..< data.count)
            rawLength = data.count
        } else {
            return nil
        }

        let rawEnd = min(rawLength, data.count)
        return HTTPResponse(
            version: version,
            statusCode: statusCode,
            statusMessage: statusMessage,
            headers: headers,
            body: bodyData,
            rawResponse: data.subdata(in: 0 ..< rawEnd),
            trailers: trailers
        )
    }

    // MARK: - Helper Methods

    private static func findHeaderDelimiter(in data: Data) -> Range<Data.Index>? {
        let patterns: [Data] = [
            Data([13, 10, 13, 10]), // \r\n\r\n
            Data([13, 10, 13]), // \r\n\r
            Data([10, 10]), // \n\n
            Data([13, 13]) // \r\r
        ]

        var bestRange: Range<Data.Index>?
        for pattern in patterns {
            if let range = data.range(of: pattern) {
                if let currentBest = bestRange {
                    if range.lowerBound < currentBest.lowerBound {
                        bestRange = range
                    }
                } else {
                    bestRange = range
                }
            }
        }

        return bestRange
    }

    private static func normalizeHeaderLines(_ headerSection: String) -> String {
        headerSection
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Returns the expected body length from the Content-Length header.
    private static func getExpectedBodyLength(headers: [String: [String]]) -> Int? {
        guard let contentLengthStr = headers["content-length"]?.last else {
            return nil
        }
        return Int(contentLengthStr)
    }

    /// Decodes a chunked transfer-encoding body.
    ///
    /// Returns `nil` when the chunk data is incomplete.
    public static func decodeChunkedBody(_ data: Data) -> Data? {
        let crlf = Data([13, 10])
        var result = Data()
        var offset = 0

        while offset < data.count {
            guard let lineRange = data.range(of: crlf, options: [], in: offset ..< data.count) else {
                return nil
            }

            let lineData = data.subdata(in: offset ..< lineRange.lowerBound)
            let line = String(decoding: lineData, as: UTF8.self)

            let chunkSizeStr: String = if let semicolonIndex = line.firstIndex(of: ";") {
                String(line[..<semicolonIndex])
            } else {
                line
            }

            guard let chunkSize = Int(chunkSizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }

            let dataStart = lineRange.upperBound
            let dataEnd = dataStart + chunkSize
            guard dataEnd <= data.count else {
                return nil
            }

            if chunkSize > 0 {
                result.append(data.subdata(in: dataStart ..< dataEnd))
            }

            let nextStart: Int
            if chunkSize == 0 {
                if dataStart + 2 <= data.count, data[dataStart ..< dataStart + 2] == crlf {
                    nextStart = dataStart + 2
                } else {
                    nextStart = dataStart
                }
            } else {
                let expectedStart = dataEnd + 2
                guard expectedStart <= data.count else {
                    return nil
                }
                guard data[dataEnd ..< expectedStart] == crlf else {
                    return nil
                }
                nextStart = expectedStart
            }

            if chunkSize == 0 {
                if nextStart == data.count {
                    return result
                }

                if let nextLineRange = data.range(of: crlf, options: [], in: nextStart ..< data.count) {
                    let nextLineData = data.subdata(in: nextStart ..< nextLineRange.lowerBound)
                    let nextLine = String(decoding: nextLineData, as: UTF8.self)
                    let nextToken = nextLine.split(separator: ";", maxSplits: 1).first ?? Substring()
                    if Int(nextToken.trimmingCharacters(in: .whitespaces), radix: 16) != nil {
                        offset = nextStart
                        continue
                    }
                }

                let trailerTerminator = Data([13, 10, 13, 10])
                if let trailerEnd = data.range(of: trailerTerminator, options: [], in: nextStart ..< data.count),
                   trailerEnd.upperBound == data.count {
                    return result
                }

                return nil
            }

            offset = nextStart
        }

        return nil
    }

    private struct ChunkedBodyInfo {
        let end: Int
        let trailersStart: Int
    }

    /// Returns the end offset of a complete chunked body (including trailers) or `nil` if incomplete.
    public static func chunkedBodyEndIndex(_ data: Data) -> Int? {
        chunkedBodyInfo(data)?.end
    }

    /// Returns chunked body bounds (including trailers) or `nil` if incomplete.
    private static func chunkedBodyInfo(_ data: Data) -> ChunkedBodyInfo? {
        var index = 0
        let crlf = Data([0x0D, 0x0A])
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        while index < data.count {
            guard let sizeRange = data.range(of: crlf, options: [], in: index ..< data.count) else {
                return nil
            }

            let sizeLineData = data[index ..< sizeRange.lowerBound]
            let sizeString = String(decoding: sizeLineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sizeToken = sizeString.split(separator: ";", maxSplits: 1).first ?? Substring()
            guard let chunkSize = Int(sizeToken, radix: 16) else {
                return nil
            }

            index = sizeRange.upperBound

            if chunkSize == 0 {
                if let trailerEnd = data.range(of: terminator, options: [], in: index ..< data.count) {
                    return ChunkedBodyInfo(end: trailerEnd.upperBound, trailersStart: index)
                }
                let crlfEnd = index + 2
                if crlfEnd <= data.count, data[index ..< crlfEnd] == crlf {
                    return ChunkedBodyInfo(end: crlfEnd, trailersStart: index)
                }
                return nil
            }

            let chunkEnd = index + chunkSize
            let crlfEnd = chunkEnd + 2
            guard chunkEnd <= data.count, crlfEnd <= data.count else {
                return nil
            }

            if data[chunkEnd ..< crlfEnd] != crlf {
                return nil
            }

            index = crlfEnd
        }

        return nil
    }

    /// Parses HTTP trailers (RFC 7230 §4.1.2).
    ///
    /// Trailers appear after a chunked message body.
    /// - Parameters:
    ///   - data: Chunked body slice (chunked data + trailers).
    ///   - startOffset: Offset where trailers begin (after the final chunk CRLF).
    ///   - endOffset: Offset where trailers end (after CRLF CRLF).
    /// - Returns: A dictionary of trailer fields.
    private static func parseTrailers(in data: Data, startOffset: Int, endOffset: Int) -> [String: [String]] {
        var trailers: [String: [String]] = [:]

        let trailerContentEnd = max(startOffset, endOffset - 4)
        guard trailerContentEnd > startOffset else {
            return trailers
        }

        let trailerData = data.subdata(in: startOffset ..< trailerContentEnd)
        let trailerSection = String(decoding: trailerData, as: UTF8.self)
        let lines = trailerSection.components(separatedBy: "\r\n")

        for line in lines {
            guard !line.isEmpty else { continue }

            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                // Rule: Certain headers are not allowed as trailers (RFC 7230 §4.1.2).
                let disallowedTrailers = [
                    "transfer-encoding",
                    "content-length",
                    "host",
                    "cache-control",
                    "max-forwards",
                    "te",
                    "authorization",
                    "set-cookie",
                    "content-encoding",
                    "content-type",
                    "content-range",
                    "trailer"
                ]

                let lowerKey = key.lowercased()
                if !disallowedTrailers.contains(lowerKey) {
                    trailers[lowerKey, default: []].append(value)
                }
            }
        }

        return trailers
    }

    /// Returns whether data contains a complete HTTP request.
    public static func hasCompleteRequest(_ data: Data) -> Bool {
        parseRequest(from: data) != nil
    }

    /// Returns whether data contains a complete HTTP response.
    public static func hasCompleteResponse(_ data: Data) -> Bool {
        parseResponse(from: data) != nil
    }
}
