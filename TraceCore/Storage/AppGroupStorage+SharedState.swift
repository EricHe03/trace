//
//  AppGroupStorage+SharedState.swift
//  TraceCore
//
//  Created by OpenAI Codex on 2026/03/06.
//

import Foundation
import GRDB

public extension AppGroupStorage {
    func saveHardeningSetting(_ value: some Encodable, forKey key: String) throws {
        try saveSettingValue(value, scope: SettingScope.hardening, key: key)
    }

    func loadHardeningSetting<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        loadSettingValue(type, scope: SettingScope.hardening, key: key)
    }

    func saveWidgetState(_ state: WidgetSharedState) throws {
        try saveSettingValue(state, scope: SettingScope.widget, key: "state")
    }

    func loadWidgetState() -> WidgetSharedState {
        loadSettingValue(WidgetSharedState.self, scope: SettingScope.widget, key: "state") ?? WidgetSharedState()
    }

    func saveWidgetPendingAction(_ action: WidgetPendingAction) throws {
        try saveSettingValue(action, scope: SettingScope.widgetAction, key: "pending_action")
    }

    func loadWidgetPendingAction() -> WidgetPendingAction? {
        loadSettingValue(WidgetPendingAction.self, scope: SettingScope.widgetAction, key: "pending_action")
    }

    func clearWidgetPendingAction() throws {
        try removeSetting(scope: SettingScope.widgetAction, key: "pending_action")
    }

    func consumeWidgetPendingAction(maxAge: TimeInterval) -> WidgetPendingAction? {
        guard let action = loadWidgetPendingAction() else { return nil }
        if Date().timeIntervalSince(action.actionDate) > maxAge {
            try? clearWidgetPendingAction()
            return nil
        }
        try? clearWidgetPendingAction()
        return action
    }

    func saveMITMAutoBypassMetadataFlag(_ value: Bool, forKey key: String) throws {
        try saveSettingValue(value, scope: SettingScope.mitmAutoBypassMeta, key: key)
    }

    func loadMITMAutoBypassMetadataFlag(forKey key: String) -> Bool {
        loadSettingValue(Bool.self, scope: SettingScope.mitmAutoBypassMeta, key: key) ?? false
    }

    func replaceMITMAutoBypassEntries(_ entries: [MITMAutoBypassStoredEntry]) throws {
        try withDatabase { pool in
            try pool.write { db in
                try db.execute(sql: "DELETE FROM mitm_auto_bypass_entries")
                for entry in entries {
                    try db.execute(
                        sql: """
                        INSERT INTO mitm_auto_bypass_entries (host, reason, created_at, expires_at, is_alias)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            entry.host,
                            entry.reason,
                            entry.createdAt.timeIntervalSince1970,
                            entry.expiresAt.timeIntervalSince1970,
                            entry.isAlias ? 1 : 0
                        ]
                    )
                }
            }
        }
    }

    func loadMITMAutoBypassEntries() -> [MITMAutoBypassStoredEntry] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT host, reason, created_at, expires_at, is_alias
                        FROM mitm_auto_bypass_entries
                        ORDER BY created_at DESC, host ASC
                        """
                    )
                    return rows.map { row in
                        let isAliasInt: Int = row["is_alias"]
                        return MITMAutoBypassStoredEntry(
                            host: row["host"],
                            reason: row["reason"],
                            createdAt: Date(timeIntervalSince1970: row["created_at"]),
                            expiresAt: Date(timeIntervalSince1970: row["expires_at"]),
                            isAlias: isAliasInt != 0
                        )
                    }
                }
            }
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("mitm_auto_bypass_entries_load")
                    .failure()
                    .error(error)
            )
            return []
        }
    }
}
