//
//  TraceDatabase.swift
//  TraceCore
//
//  Created by Justin on 2026/03/01.
//

import Foundation
import GRDB

final class TraceDatabase {
    let pool: DatabasePool

    init(databaseURL: URL) throws {
        let configuration = Self.makeConfiguration()
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(pool)
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.label = "com.trace.storage.database"
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return configuration
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_core_tables") { db in
            try db.create(table: "network_requests", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .double).notNull()
                t.column("session_id", .text)
                t.column("url", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_network_requests_timestamp", on: "network_requests", columns: ["timestamp"], ifNotExists: true)
            try db.create(index: "idx_network_requests_session_timestamp", on: "network_requests", columns: ["session_id", "timestamp"], ifNotExists: true)

            try db.create(table: "transport_requests", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .double).notNull()
                t.column("flow_key", .text).notNull()
                t.column("payload_bytes", .integer).notNull()
                t.column("packet_bytes", .integer)
                t.column("payload", .blob).notNull()
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_transport_requests_timestamp", on: "transport_requests", columns: ["timestamp"], ifNotExists: true)

            try db.create(table: "capture_sessions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("start_time", .double).notNull()
                t.column("payload", .blob).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_capture_sessions_start_time", on: "capture_sessions", columns: ["start_time"], ifNotExists: true)

            try db.create(table: "packet_flows", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("last_seen", .double).notNull()
                t.column("payload", .blob).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_packet_flows_last_seen", on: "packet_flows", columns: ["last_seen"], ifNotExists: true)

            try db.create(table: "udp_flows", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("last_activity", .double).notNull()
                t.column("payload", .blob).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_udp_flows_last_activity", on: "udp_flows", columns: ["last_activity"], ifNotExists: true)

            try db.create(table: "websocket_connections", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("start_time", .double).notNull()
                t.column("payload", .blob).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_websocket_connections_start_time", on: "websocket_connections", columns: ["start_time"], ifNotExists: true)

            try db.create(table: "sse_connections", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("start_time", .double).notNull()
                t.column("payload", .blob).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_sse_connections_start_time", on: "sse_connections", columns: ["start_time"], ifNotExists: true)

            try db.create(table: "config_blobs", ifNotExists: true) { t in
                t.column("name", .text).primaryKey()
                t.column("data", .blob).notNull()
                t.column("updated_at", .double).notNull()
            }

            try db.create(table: "settings_kv", ifNotExists: true) { t in
                t.column("scope", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .blob).notNull()
                t.column("updated_at", .double).notNull()
                t.primaryKey(["scope", "key"])
            }

            try db.create(table: "mitm_auto_bypass_entries", ifNotExists: true) { t in
                t.column("host", .text).primaryKey()
                t.column("reason", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("expires_at", .double).notNull()
                t.column("is_alias", .integer).notNull()
            }
            try db.create(index: "idx_mitm_auto_bypass_expires_at", on: "mitm_auto_bypass_entries", columns: ["expires_at"], ifNotExists: true)

            try db.create(table: "storage_metadata", ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
                t.column("updated_at", .double).notNull()
            }
        }

        migrator.registerMigration("v2_mitm_auto_bypass_composite_primary_key") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS mitm_auto_bypass_entries_v2")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_mitm_auto_bypass_expires_at")
            try db.execute(
                sql: """
                CREATE TABLE mitm_auto_bypass_entries_v2 (
                    host TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    created_at DOUBLE NOT NULL,
                    expires_at DOUBLE NOT NULL,
                    is_alias INTEGER NOT NULL,
                    PRIMARY KEY (host, is_alias)
                )
                """
            )
            try db.execute(
                sql: """
                INSERT INTO mitm_auto_bypass_entries_v2 (host, reason, created_at, expires_at, is_alias)
                SELECT host, reason, created_at, expires_at, is_alias
                FROM mitm_auto_bypass_entries
                """
            )
            try db.execute(sql: "DROP TABLE mitm_auto_bypass_entries")
            try db.execute(sql: "ALTER TABLE mitm_auto_bypass_entries_v2 RENAME TO mitm_auto_bypass_entries")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mitm_auto_bypass_expires_at ON mitm_auto_bypass_entries(expires_at)")
        }

        migrator.registerMigration("v3_stream_event_journal") { db in
            try db.create(table: "stream_sessions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("protocol_type", .text).notNull()
                t.column("url", .text).notNull()
                t.column("start_time", .double).notNull()
                t.column("end_time", .double)
                t.column("status", .text).notNull()
                t.column("request_headers", .blob).notNull()
                t.column("response_headers", .blob).notNull()
                t.column("metadata", .blob).notNull()
                t.column("event_count", .integer).notNull().defaults(to: 0)
                t.column("bytes_in", .integer).notNull().defaults(to: 0)
                t.column("bytes_out", .integer).notNull().defaults(to: 0)
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_stream_sessions_start_time", on: "stream_sessions", columns: ["start_time"], ifNotExists: true)
            try db.create(index: "idx_stream_sessions_protocol_start_time", on: "stream_sessions", columns: ["protocol_type", "start_time"], ifNotExists: true)

            try db.create(table: "stream_events", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().references("stream_sessions", onDelete: .cascade)
                t.column("sequence", .integer).notNull()
                t.column("timestamp", .double).notNull()
                t.column("direction", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("payload_text", .text)
                t.column("payload_inline", .blob)
                t.column("payload_chunked", .integer).notNull().defaults(to: 0)
                t.column("payload_content_type", .text)
                t.column("payload_encoding", .text)
                t.column("payload_size", .integer).notNull().defaults(to: 0)
                t.column("was_modified", .integer).notNull().defaults(to: 0)
                t.column("was_blocked", .integer).notNull().defaults(to: 0)
                t.column("metadata", .blob).notNull()
                t.column("created_at", .double).notNull()
                t.uniqueKey(["session_id", "sequence"])
            }
            try db.create(index: "idx_stream_events_session_sequence", on: "stream_events", columns: ["session_id", "sequence"], ifNotExists: true)
            try db.create(index: "idx_stream_events_session_timestamp", on: "stream_events", columns: ["session_id", "timestamp"], ifNotExists: true)

            try db.create(table: "stream_payload_chunks", ifNotExists: true) { t in
                t.column("event_id", .text).notNull().references("stream_events", onDelete: .cascade)
                t.column("chunk_index", .integer).notNull()
                t.column("chunk", .blob).notNull()
                t.column("created_at", .double).notNull()
                t.primaryKey(["event_id", "chunk_index"])
            }

            try db.create(table: "stream_replays", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().references("stream_sessions", onDelete: .cascade)
                t.column("spec", .blob).notNull()
                t.column("result", .blob)
                t.column("status", .text).notNull()
                t.column("started_at", .double).notNull()
                t.column("ended_at", .double)
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_stream_replays_session_started", on: "stream_replays", columns: ["session_id", "started_at"], ifNotExists: true)

            try Self.backfillLegacyWebSocketSessionsIntoStreamJournal(db)
            try Self.backfillLegacySSESessionsIntoStreamJournal(db)
        }

        migrator.registerMigration("v4_grpc_stream_support") { _ in
            // No DDL: stream_sessions.protocol_type is TEXT without a CHECK constraint,
            // so it already accepts "grpc" rows inserted by the new code path.
            // This migration anchors the feature activation point for future column additions.
        }

        return migrator
    }
}

private extension TraceDatabase {
    static func backfillLegacyWebSocketSessionsIntoStreamJournal(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT payload
            FROM websocket_connections
            ORDER BY start_time ASC, id ASC
            """
        )
        guard !rows.isEmpty else { return }

        let decoder = JSONCoding.makeDecoder()
        let encoder = JSONCoding.makeEncoder()
        let now = Date().timeIntervalSince1970

        for row in rows {
            let payload: Data = row["payload"]
            guard let connection = try? decoder.decode(WebSocketConnection.self, from: payload) else {
                continue
            }

            let requestHeadersData = try encoder.encode(connection.requestHeaders)
            let responseHeadersData = try encoder.encode(connection.responseHeaders)
            let sessionMetadata = try encoder.encode([
                "legacy_source": "websocket_connections",
                "legacy_status": connection.status.rawValue
            ])
            let bytesIn = connection.messages
                .filter { $0.direction == .received }
                .reduce(into: 0) { $0 += $1.payloadLength }
            let bytesOut = connection.messages
                .filter { $0.direction == .sent }
                .reduce(into: 0) { $0 += $1.payloadLength }

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO stream_sessions (
                    id, protocol_type, url, start_time, end_time, status,
                    request_headers, response_headers, metadata,
                    event_count, bytes_in, bytes_out, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    connection.id.uuidString,
                    StreamProtocolType.websocket.rawValue,
                    connection.url,
                    connection.startTime.timeIntervalSince1970,
                    connection.endTime?.timeIntervalSince1970,
                    streamSessionStatus(for: connection.status).rawValue,
                    requestHeadersData,
                    responseHeadersData,
                    sessionMetadata,
                    connection.messages.count,
                    bytesIn,
                    bytesOut,
                    now,
                    now
                ]
            )

            for (offset, message) in connection.messages.enumerated() {
                let sequence = Int64(offset + 1)
                let payloadText = message.messageType == .text ? String(data: message.payload, encoding: .utf8) : nil
                let eventKind = streamEventKind(for: message.messageType)
                let eventDirection = message.direction == .sent ? StreamEventDirection.sent : StreamEventDirection.received
                let eventMetadata = try encoder.encode([
                    "message_type": message.messageType.rawValue,
                    "is_final": message.isFinal ? "true" : "false",
                    "is_masked": message.isMasked ? "true" : "false",
                    "payload_length": String(message.payloadLength)
                ])
                let contentType = message.messageType == .text ? "text/plain; charset=utf-8" : "application/octet-stream"

                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO stream_events (
                        id, session_id, sequence, timestamp, direction, kind,
                        payload_text, payload_inline, payload_chunked,
                        payload_content_type, payload_encoding, payload_size,
                        was_modified, was_blocked, metadata, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        message.id.uuidString,
                        connection.id.uuidString,
                        sequence,
                        message.timestamp.timeIntervalSince1970,
                        eventDirection.rawValue,
                        eventKind.rawValue,
                        payloadText,
                        message.payload,
                        0,
                        contentType,
                        nil,
                        message.payloadLength,
                        0,
                        0,
                        eventMetadata,
                        now
                    ]
                )
            }
        }
    }

    static func backfillLegacySSESessionsIntoStreamJournal(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT payload
            FROM sse_connections
            ORDER BY start_time ASC, id ASC
            """
        )
        guard !rows.isEmpty else { return }

        let decoder = JSONCoding.makeDecoder()
        let encoder = JSONCoding.makeEncoder()
        let now = Date().timeIntervalSince1970

        for row in rows {
            let payload: Data = row["payload"]
            guard let connection = try? decoder.decode(SSEConnection.self, from: payload) else {
                continue
            }

            let requestHeadersData = try encoder.encode(connection.requestHeaders)
            let responseHeadersData = try encoder.encode(connection.responseHeaders)
            let sessionMetadata = try encoder.encode([
                "legacy_source": "sse_connections",
                "legacy_status": connection.status.rawValue,
                "is_truncated": connection.isTruncated ? "true" : "false"
            ])

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO stream_sessions (
                    id, protocol_type, url, start_time, end_time, status,
                    request_headers, response_headers, metadata,
                    event_count, bytes_in, bytes_out, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    connection.id.uuidString,
                    StreamProtocolType.sse.rawValue,
                    connection.url,
                    connection.startTime.timeIntervalSince1970,
                    connection.endTime?.timeIntervalSince1970,
                    streamSessionStatus(for: connection.status).rawValue,
                    requestHeadersData,
                    responseHeadersData,
                    sessionMetadata,
                    connection.events.count,
                    connection.totalBytesReceived,
                    0,
                    now,
                    now
                ]
            )

            for (offset, event) in connection.events.enumerated() {
                let sequence = Int64(offset + 1)
                let metadata = try encoder.encode([
                    "event_id": event.eventId ?? "",
                    "event_type": event.eventType ?? "",
                    "retry": event.retry.map(String.init) ?? ""
                ])

                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO stream_events (
                        id, session_id, sequence, timestamp, direction, kind,
                        payload_text, payload_inline, payload_chunked,
                        payload_content_type, payload_encoding, payload_size,
                        was_modified, was_blocked, metadata, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        event.id.uuidString,
                        connection.id.uuidString,
                        sequence,
                        event.timestamp.timeIntervalSince1970,
                        StreamEventDirection.received.rawValue,
                        StreamEventKind.sseEvent.rawValue,
                        event.data,
                        nil,
                        0,
                        "text/event-stream; charset=utf-8",
                        "utf-8",
                        event.data.utf8.count,
                        0,
                        0,
                        metadata,
                        now
                    ]
                )
            }
        }
    }

    static func streamSessionStatus(for status: WebSocketConnectionStatus) -> StreamSessionStatus {
        switch status {
        case .connecting:
            .connecting
        case .open:
            .open
        case .closing:
            .closing
        case .closed:
            .closed
        case .failed:
            .failed
        }
    }

    static func streamSessionStatus(for status: SSEConnectionStatus) -> StreamSessionStatus {
        switch status {
        case .connecting:
            .connecting
        case .streaming:
            .streaming
        case .closed:
            .closed
        case .failed:
            .failed
        }
    }

    static func streamEventKind(for messageType: WebSocketMessageType) -> StreamEventKind {
        switch messageType {
        case .ping:
            .ping
        case .pong:
            .pong
        case .close:
            .close
        case .text, .binary, .continuation:
            .message
        }
    }
}
