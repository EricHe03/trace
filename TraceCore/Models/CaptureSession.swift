//
//  CaptureSession.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

public struct CaptureSession: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String?
    public let startTime: Date
    public var endTime: Date?
    public var requestCount: Int
    public var totalDataTransferred: Int64

    public var isActive: Bool {
        endTime == nil
    }

    public var duration: TimeInterval {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }

    private static func makeDisplayDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

    private static func makeRelativeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }

    public var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        let formattedDate = Self.makeDisplayDateFormatter().string(from: startTime)
        return isActive ? "Active Session - \(formattedDate)" : "Session - \(formattedDate)"
    }

    public var relativeTimeString: String {
        Self.makeRelativeFormatter().localizedString(for: startTime, relativeTo: Date())
    }

    public var durationString: String {
        let duration = self.duration
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    public init(id: UUID = UUID(), name: String? = nil, startTime: Date = Date(), endTime: Date? = nil, requestCount: Int = 0, totalDataTransferred: Int64 = 0) {
        self.id = id
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.requestCount = requestCount
        self.totalDataTransferred = totalDataTransferred
    }
}
