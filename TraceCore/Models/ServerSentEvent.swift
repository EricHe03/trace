//
//  ServerSentEvent.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Represents a parsed Server-Sent Event (SSE)
public struct ServerSentEvent: Identifiable, Codable, Equatable {
    public let id: UUID
    public var eventId: String?
    public var eventType: String?
    public var data: String
    public var retry: Int?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        eventId: String? = nil,
        eventType: String? = nil,
        data: String,
        retry: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.eventId = eventId
        self.eventType = eventType
        self.data = data
        self.retry = retry
        self.timestamp = timestamp
    }

    /// Human-readable size
    public var sizeString: String {
        let bytes = data.utf8.count
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Preview of the data for display
    public var preview: String {
        let maxLength = 100
        if data.count > maxLength {
            return String(data.prefix(maxLength)) + "..."
        }
        return data
    }

    public static func == (lhs: ServerSentEvent, rhs: ServerSentEvent) -> Bool {
        lhs.id == rhs.id
    }
}

/// Parser for Server-Sent Events (SSE) streams
public class SSEParser {
    private var lineBuffer = ""
    private var bufferedRemainder = ""
    private var atStartOfStream = true
    private var pendingCRLF = false
    private var lastEventID = ""
    private var currentEventType: String?
    private var currentDataLines: [String] = []
    private var currentRetry: Int?

    public init() {}

    /// Returns the buffered (not-yet-finalized) raw text following the last complete event delimiter.
    ///
    /// This is useful for streaming interception pipelines that need to preserve any tail bytes that were
    /// parsed into in-flight state but did not yield a complete event in the current chunk.
    public var bufferedRawRemainder: String {
        bufferedRemainder
    }

    /// Parse incoming SSE data and return complete events
    /// - Parameter data: Raw SSE stream data
    /// - Returns: Array of parsed events
    public func parse(_ data: String) -> [ServerSentEvent] {
        var combined = lineBuffer + data
        lineBuffer = ""

        // If the previous chunk ended with '\r' and this chunk starts with '\n', treat it as CRLF.
        if pendingCRLF {
            if combined.first == "\n" {
                combined.removeFirst()
            }
            pendingCRLF = false
        }

        if atStartOfStream, combined.first == "\u{FEFF}" {
            combined.removeFirst()
        }
        if !combined.isEmpty {
            atStartOfStream = false
        }

        var events: [ServerSentEvent] = []
        var remainderStartIndex = combined.startIndex

        func finalizeEventIfNeeded() {
            guard !currentDataLines.isEmpty else {
                currentEventType = nil
                currentRetry = nil
                return
            }

            let event = ServerSentEvent(
                eventId: lastEventID.isEmpty ? nil : lastEventID,
                eventType: currentEventType?.isEmpty == true ? nil : currentEventType,
                data: currentDataLines.joined(separator: "\n"),
                retry: currentRetry
            )
            events.append(event)
            currentEventType = nil
            currentDataLines.removeAll(keepingCapacity: true)
            currentRetry = nil
        }

        func processLine(_ line: Substring) {
            // Empty line signals end of event
            if line.isEmpty {
                finalizeEventIfNeeded()
                return
            }

            // Ignore comments
            if line.first == ":" {
                return
            }

            // Parse field
            if let colonIndex = line.firstIndex(of: ":") {
                let field = String(line[..<colonIndex])
                var value = line[line.index(after: colonIndex)...]

                // Remove leading space if present
                if value.first == " " {
                    value = value.dropFirst()
                }

                processField(field: field, value: String(value))
            } else {
                // Field with no colon (field name only)
                processField(field: String(line), value: "")
            }
        }

        func processField(field: String, value: String) {
            switch field {
            case "data":
                currentDataLines.append(value)
            case "event":
                currentEventType = value
            case "id":
                if !value.contains("\u{0000}") {
                    lastEventID = value
                }
            case "retry":
                if value.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
                   let parsed = Int(value) {
                    currentRetry = parsed
                }
            default:
                break
            }
        }

        // SSE spec (WHATWG): end-of-line = ( CRLF / CR / LF )
        // We must treat CRLF as a single line break (even if split across chunks).
        var lineStart = combined.startIndex
        var index = combined.startIndex
        while index < combined.endIndex {
            let ch = combined[index]
            if ch == "\r" || ch == "\n" {
                let line = combined[lineStart ..< index]
                processLine(line)

                if ch == "\r" {
                    let next = combined.index(after: index)
                    if next < combined.endIndex {
                        if combined[next] == "\n" {
                            index = next // Consume LF as part of CRLF
                        }
                    } else {
                        // Chunk ended with '\r' - might be CRLF split across chunks.
                        pendingCRLF = true
                    }
                }

                index = combined.index(after: index)
                lineStart = index
                if line.isEmpty {
                    remainderStartIndex = lineStart
                }
                continue
            }
            index = combined.index(after: index)
        }

        // If there's a trailing unterminated line, keep it for the next chunk.
        if lineStart < combined.endIndex {
            lineBuffer = String(combined[lineStart ..< combined.endIndex])
        }

        bufferedRemainder = String(combined[remainderStartIndex ..< combined.endIndex])
        return events
    }

    /// Reset the parser state
    public func reset() {
        lineBuffer = ""
        bufferedRemainder = ""
        atStartOfStream = true
        pendingCRLF = false
        lastEventID = ""
        currentEventType = nil
        currentDataLines.removeAll(keepingCapacity: false)
        currentRetry = nil
    }

    /// Check if the content type indicates SSE
    public static func isSSEContentType(_ contentType: String) -> Bool {
        contentType.lowercased().contains("text/event-stream")
    }
}

/// Extension to NetworkRequest to support SSE metadata
public extension NetworkRequest {
    /// Check if this request is an SSE stream
    var isSSE: Bool {
        // Check Content-Type header in response
        for header in responseHeaders {
            if header.key.lowercased() == "content-type" {
                return SSEParser.isSSEContentType(header.value)
            }
        }
        return false
    }

    /// Parse SSE events from response body
    var sseEvents: [ServerSentEvent] {
        guard isSSE, let bodyString = responseBody.getString() else {
            return []
        }

        let parser = SSEParser()
        return parser.parse(bodyString)
    }
}
