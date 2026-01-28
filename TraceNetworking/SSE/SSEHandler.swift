//
//  SSEHandler.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import Network
import TraceCore

/// Manages Server-Sent Events connections and streaming.
///
/// Discussion: Detects SSE streams, parses events incrementally, and relays data to the client.
public class SSEHandler {
    private let clientConnection: NWConnection
    private var serverConnection: NWConnection?

    private let url: String
    private let connectionID: UUID
    private var connection: SSEConnection
    private var sseParser: SSEParser
    private var onConnectionUpdate: ((SSEConnection) -> Void)?
    private var utf8Remainder = Data()

    private let maxEvents = 1000
    private let maxTotalBytes = 10 * 1024 * 1024 // 10MB

    /// Initializes an SSE handler for a proxied connection.
    public init(
        clientConnection: NWConnection,
        serverConnection: NWConnection?,
        url: String,
        requestHeaders: [TraceHTTPHeader],
        responseHeaders: [TraceHTTPHeader]
    ) {
        self.clientConnection = clientConnection
        self.serverConnection = serverConnection
        self.url = url
        self.connectionID = UUID()
        self.sseParser = SSEParser()

        self.connection = SSEConnection(
            id: connectionID,
            url: url,
            startTime: Date(),
            status: .streaming,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            totalBytesReceived: 0
        )
    }

    // MARK: - Connection Management

    /// Starts the SSE handler and begins proxying server-to-client traffic.
    /// - Parameters:
    ///   - onUpdate: Callback invoked whenever the captured connection is updated.
    ///   - initialBodyData: Response body bytes already forwarded by the caller that must be parsed
    ///     to preserve event boundaries and UTF-8 state.
    public func start(onUpdate: @escaping (SSEConnection) -> Void, initialBodyData: Data = Data()) {
        self.onConnectionUpdate = onUpdate

        saveConnection()

        if !initialBodyData.isEmpty {
            parseSSEData(initialBodyData)
        }

        readFromServer()

        NetworkLog.sse.info("event=sse.connection_open outcome=success url=\(self.url, privacy: .private(mask: .hash))")
    }

    /// Closes the SSE connection and persists the final snapshot.
    public func close() {
        connection.close()
        saveConnection()
        onConnectionUpdate = nil

        clientConnection.cancel()
        serverConnection?.cancel()

        NetworkLog.sse.info("event=sse.connection_close outcome=success url=\(self.url, privacy: .private(mask: .hash))")
    }

    // MARK: - Server -> Client Proxying

    private func readFromServer() {
        serverConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NetworkLog.sse.error("event=sse.server_error outcome=failure error=\(error, privacy: .public)")
                self.failAndClose()
                return
            }

            if let data, !data.isEmpty {
                // Rule: Forward bytes immediately to keep the proxy transparent.
                self.clientConnection.send(content: data, completion: .contentProcessed { sendError in
                    if let sendError {
                        NetworkLog.sse.error("event=sse.client_send outcome=failure error=\(sendError, privacy: .public)")
                        self.failAndClose()
                        return
                    }
                })

                self.parseSSEData(data)
            }

            if !isComplete {
                self.readFromServer()
            } else {
                self.close()
            }
        }
    }

    // MARK: - SSE Event Parsing

    private func parseSSEData(_ data: Data) {
        connection.totalBytesReceived += data.count

        // Rule: Stop parsing when limits are exceeded but keep proxying.
        if connection.events.count >= maxEvents || connection.totalBytesReceived >= maxTotalBytes {
            if !connection.isTruncated {
                connection.isTruncated = true
                NetworkLog.sse.warning("event=sse.connection_truncated outcome=skipped event_count=\(self.connection.events.count, privacy: .public) bytes=\(self.connection.totalBytesReceived, privacy: .public)")
                saveConnection()
            }
            return
        }

        // Rule: Preserve UTF-8 boundary state across chunks.
        let combined = utf8Remainder + data
        let dataString: String
        if let decoded = String(data: combined, encoding: .utf8) {
            dataString = decoded
            utf8Remainder.removeAll()
        } else {
            var decoded: String?
            var splitIndex = combined.count
            let maxTail = min(3, combined.count)
            for drop in 1 ... maxTail {
                let endIndex = combined.count - drop
                guard endIndex > 0 else { break }
                if let candidate = String(data: combined.subdata(in: 0 ..< endIndex), encoding: .utf8) {
                    decoded = candidate
                    splitIndex = endIndex
                    break
                }
            }

            guard let decoded else {
                utf8Remainder = combined
                return
            }

            dataString = decoded
            utf8Remainder = combined.subdata(in: splitIndex ..< combined.count)
        }

        let events = sseParser.parse(dataString)

        for event in events {
            connection.addEvent(event)
        }

        if !events.isEmpty {
            saveConnection()
        }
    }

    // MARK: - Storage

    private func saveConnection() {
        onConnectionUpdate?(connection)

        do {
            try AppGroupStorage.shared.saveSSEConnection(connection)
        } catch {
            NetworkLog.sse.error("event=sse.storage_save outcome=failure error=\(error, privacy: .public)")
        }
    }

    private func failAndClose() {
        connection.status = .failed
        connection.endTime = Date()
        saveConnection()
        onConnectionUpdate = nil

        clientConnection.cancel()
        serverConnection?.cancel()
    }

    #if DEBUG
    /// Test-only hook to feed SSE bytes without starting network reads.
    func testParseSSEData(_ data: Data) {
        parseSSEData(data)
    }

    /// Test-only hook to inspect the current connection snapshot.
    func testConnectionSnapshot() -> SSEConnection {
        connection
    }
    #endif
}
