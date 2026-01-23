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
    private var buffer = ""
    /// If the previous parse ended with a lone `\r`, the next chunk may start with `\n`
    /// as part of a CRLF sequence. We track this so we don't treat `\r\n` as two line breaks.
    private var pendingCRLF = false
    private var currentEvent = SSEEventBuilder()

    public init() {}

    /// Parse incoming SSE data and return complete events
    /// - Parameter data: Raw SSE stream data
    /// - Returns: Array of parsed events
    public func parse(_ data: String) -> [ServerSentEvent] {
        var combined = buffer + data
        buffer = ""

        // If the previous chunk ended with '\r' and this chunk starts with '\n', treat it as CRLF.
        if pendingCRLF {
            if combined.first == "\n" {
                combined.removeFirst()
            }
            pendingCRLF = false
        }

        var events: [ServerSentEvent] = []

        func finalizeEventIfNeeded() {
            if let event = currentEvent.build() {
                events.append(event)
            }
            currentEvent.reset()
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

                currentEvent.addField(field, value: String(value))
            } else {
                // Field with no colon (field name only)
                currentEvent.addField(String(line), value: "")
            }
        }

        // SSE spec (WHATWG): end-of-line = ( CRLF / CR / LF )
        // We must treat CRLF as a single line break (even if split across chunks).
        var lineStart = combined.startIndex
        var index = combined.startIndex
        while index < combined.endIndex {
            let ch = combined[index]
            if ch.isNewline {
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
                continue
            }
            index = combined.index(after: index)
        }

        // If there's a trailing unterminated line, keep it for the next chunk.
        if lineStart < combined.endIndex {
            buffer = String(combined[lineStart ..< combined.endIndex])
        }

        return events
    }

    /// Reset the parser state
    public func reset() {
        buffer = ""
        pendingCRLF = false
        currentEvent.reset()
    }

    /// Check if the content type indicates SSE
    public static func isSSEContentType(_ contentType: String) -> Bool {
        contentType.lowercased().contains("text/event-stream")
    }
}

/// Builder for constructing ServerSentEvent objects
private class SSEEventBuilder {
    private var eventId: String?
    private var eventType: String?
    private var dataLines: [String] = []
    private var retry: Int?

    func addField(_ field: String, value: String) {
        switch field {
        case "id":
            eventId = value
        case "event":
            eventType = value
        case "data":
            dataLines.append(value)
        case "retry":
            retry = Int(value)
        default:
            // Unknown field, ignore
            break
        }
    }

    func build() -> ServerSentEvent? {
        // SSE spec: data field is required
        guard !dataLines.isEmpty else {
            return nil
        }

        let data = dataLines.joined(separator: "\n")

        return ServerSentEvent(
            eventId: eventId,
            eventType: eventType,
            data: data,
            retry: retry
        )
    }

    func reset() {
        eventId = nil
        eventType = nil
        dataLines.removeAll()
        retry = nil
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
