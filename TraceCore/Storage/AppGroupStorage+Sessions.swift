//
//  AppGroupStorage+Sessions.swift
//  TraceCore
//
//  Created by OpenAI Codex on 2026/03/06.
//

import Foundation
import GRDB

public extension AppGroupStorage {
    func saveSessions(_ sessions: [CaptureSession]) async throws {
        guard !sessions.isEmpty else { return }
        let encoder = makeEncoder()
        do {
            try withDatabase { pool in
                try pool.write { db in
                    let now = Date().timeIntervalSince1970
                    for session in sessions {
                        let payload = try encoder.encode(session)
                        try db.execute(
                            sql: """
                            INSERT INTO capture_sessions (id, start_time, payload, updated_at)
                            VALUES (?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                                start_time = excluded.start_time,
                                payload = excluded.payload,
                                updated_at = excluded.updated_at
                            """,
                            arguments: [session.id.uuidString, session.startTime.timeIntervalSince1970, payload, now]
                        )
                    }
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    func loadSessions() async throws -> [CaptureSession] {
        try loadAllSessions()
    }

    func saveSession(_ session: CaptureSession) throws {
        guard let data = try? makeEncoder().encode(session) else {
            throw StorageError.encodingFailed
        }
        let now = Date().timeIntervalSince1970
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: """
                INSERT INTO capture_sessions (id, start_time, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    start_time = excluded.start_time,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [session.id.uuidString, session.startTime.timeIntervalSince1970, data, now]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
        CoreLog.storage.debug("event=storage.session_save outcome=success session_id=\(session.id.uuidString, privacy: .public)")
    }

    func loadAllSessions() throws -> [CaptureSession] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM capture_sessions
                        ORDER BY start_time DESC, id DESC
                        """
                    )
                    let decoder = makeDecoder()
                    var sessions: [CaptureSession] = []
                    sessions.reserveCapacity(rows.count)
                    for row in rows {
                        let payload: Data = row["payload"]
                        if let session = try? decoder.decode(CaptureSession.self, from: payload) {
                            sessions.append(session)
                        }
                    }
                    return sessions
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    func deleteSession(_ sessionID: UUID) throws {
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: "DELETE FROM capture_sessions WHERE id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
        CoreLog.storage.debug("event=storage.session_delete outcome=success session_id=\(sessionID.uuidString, privacy: .public)")
    }

    func updateSession(_ session: CaptureSession) throws {
        try saveSession(session)
    }
}
