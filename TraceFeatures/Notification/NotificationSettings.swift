//
//  NotificationSettings.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation

/// Stores user notification preferences.
public final class NotificationSettings: ObservableObject, Codable, @unchecked Sendable {
    public let objectWillChange = ObservableObjectPublisher()

    /// Controls whether HTTP error notifications are enabled.
    public var enableErrorNotifications: Bool = true {
        willSet { objectWillChange.send() }
        didSet { save() }
    }

    /// Controls whether slow request notifications are enabled.
    public var enableSlowRequestNotifications: Bool = true {
        willSet { objectWillChange.send() }
        didSet { save() }
    }

    /// Controls whether large data notifications are enabled.
    public var enableLargeDataNotifications: Bool = false {
        willSet { objectWillChange.send() }
        didSet { save() }
    }

    /// Defines the slow request threshold in seconds.
    public var slowRequestThreshold: TimeInterval = 3.0 {
        willSet { objectWillChange.send() }
        didSet { save() }
    }

    /// Defines the large data threshold in bytes.
    public var largeDataThreshold: Int64 = 5_000_000 {
        willSet { objectWillChange.send() }
        didSet { save() }
    }

    /// Shared notification settings instance.
    public static let shared = NotificationSettings.load()

    // MARK: - Persistence

    private static let key = "notificationSettings"

    private enum CodingKeys: String, CodingKey {
        case enableErrorNotifications
        case enableSlowRequestNotifications
        case enableLargeDataNotifications
        case slowRequestThreshold
        case largeDataThreshold
    }

    public static func load() -> NotificationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(NotificationSettings.self, from: data)
        else {
            return NotificationSettings()
        }
        return settings
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: NotificationSettings.key)
        }
    }
}
