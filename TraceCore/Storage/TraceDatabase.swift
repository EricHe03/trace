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

        return migrator
    }
}
