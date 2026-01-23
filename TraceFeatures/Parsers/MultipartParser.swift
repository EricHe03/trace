//
//  MultipartParser.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Parses multipart/form-data HTTP requests/responses
public enum MultipartParser {
    /// Represents a single part in a multipart message
    public struct Part {
        public let headers: [String: String]
        public let data: Data

        /// The field name from Content-Disposition header
        public var name: String? {
            guard let disposition = headers["Content-Disposition"] else {
                return nil
            }
            return extractParameter(from: disposition, parameter: "name")
        }

        /// The filename from Content-Disposition header (if present)
        public var filename: String? {
            guard let disposition = headers["Content-Disposition"] else {
                return nil
            }
            return extractParameter(from: disposition, parameter: "filename")
        }

        /// The Content-Type of this part
        public var contentType: String? {
            headers["Content-Type"]
        }

        /// Get the content as a string (if it's text)
        public var stringValue: String? {
            String(data: data, encoding: .utf8)
        }

        /// Whether this part contains a file
        public var isFile: Bool {
            filename != nil
        }

        private func extractParameter(from header: String, parameter: String) -> String? {
            let pattern = "\(parameter)=\"([^\"]+)\""
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }

            let range = NSRange(header.startIndex..., in: header)
            guard let match = regex.firstMatch(in: header, range: range) else {
                return nil
            }

            if let valueRange = Range(match.range(at: 1), in: header) {
                return String(header[valueRange])
            }

            return nil
        }
    }

    /// Parse multipart data from the body
    /// - Parameters:
    ///   - data: The multipart data
    ///   - boundary: The boundary string (from Content-Type header)
    /// - Returns: Array of parsed parts
    public static func parse(data: Data, boundary: String) -> [Part] {
        var parts: [Part] = []

        // Create boundary markers
        let boundaryData = "--\(boundary)".data(using: .utf8)!
        let finalBoundaryData = "--\(boundary)--".data(using: .utf8)!
        let crlf = "\r\n".data(using: .utf8)!
        let headerSeparator = "\r\n\r\n".data(using: .utf8)!

        var offset = 0

        // Skip preamble (data before first boundary)
        if let firstBoundaryRange = data.range(of: boundaryData, in: offset ..< data.count) {
            offset = firstBoundaryRange.upperBound

            // Skip CRLF after boundary
            if data.count > offset + 2 {
                offset += 2
            }
        } else {
            return parts
        }

        // Parse each part
        while offset < data.count {
            // Find the end of headers (empty line)
            guard let headerEndRange = data.range(of: headerSeparator, in: offset ..< data.count) else {
                break
            }

            // Extract headers
            let headersData = data.subdata(in: offset ..< headerEndRange.lowerBound)
            let headers = parseHeaders(headersData)

            // Move past headers and separator
            offset = headerEndRange.upperBound

            // Find next boundary
            guard let nextBoundaryRange = data.range(of: boundaryData, in: offset ..< data.count) else {
                // No more boundaries, use remaining data as last part
                let partData = data.subdata(in: offset ..< data.count)
                let part = Part(headers: headers, data: partData)
                parts.append(part)
                break
            }

            // Extract part data (excluding CRLF before boundary)
            var partEndIndex = nextBoundaryRange.lowerBound
            if partEndIndex >= 2,
               data[partEndIndex - 2] == 13,
               data[partEndIndex - 1] == 10 {
                partEndIndex -= 2
            }

            let partData = data.subdata(in: offset ..< partEndIndex)
            let part = Part(headers: headers, data: partData)
            parts.append(part)

            // Move past boundary
            offset = nextBoundaryRange.upperBound

            // Check if this is the final boundary
            if data.count >= offset + 2,
               data[offset] == 45,
               data[offset + 1] == 45 {
                // This was the final boundary
                break
            }

            // Skip CRLF after boundary
            if data.count > offset + 2 {
                offset += 2
            }
        }

        return parts
    }

    /// Extract boundary from Content-Type header
    /// - Parameter contentType: The Content-Type header value
    /// - Returns: The boundary string, or nil if not found
    public static func extractBoundary(from contentType: String) -> String? {
        // Content-Type: multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW
        let pattern = "boundary=([^;\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(contentType.startIndex..., in: contentType)
        guard let match = regex.firstMatch(in: contentType, range: range) else {
            return nil
        }

        if let boundaryRange = Range(match.range(at: 1), in: contentType) {
            var boundary = String(contentType[boundaryRange])

            // Remove quotes if present
            if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                boundary = String(boundary.dropFirst().dropLast())
            }

            return boundary
        }

        return nil
    }

    private static func parseHeaders(_ data: Data) -> [String: String] {
        guard let headersString = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var headers: [String: String] = [:]
        let lines = headersString.components(separatedBy: "\r\n")

        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }

            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        return headers
    }
}

// MARK: - Data Extension

public extension Data {
    /// Find the range of a pattern in the data
    func range(of pattern: Data, in range: Range<Int>) -> Range<Int>? {
        guard range.lowerBound >= 0 && range.upperBound <= count else {
            return nil
        }

        let start = index(startIndex, offsetBy: range.lowerBound)
        let end = index(startIndex, offsetBy: range.upperBound)
        guard let found = self.range(of: pattern, options: [], in: start ..< end) else {
            return nil
        }

        let lower = distance(from: startIndex, to: found.lowerBound)
        let upper = distance(from: startIndex, to: found.upperBound)
        return lower ..< upper
    }
}
