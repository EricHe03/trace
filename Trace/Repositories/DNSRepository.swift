//
//  DNSRepository.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import os
import TraceCore
import TraceNetworking

/// Repository for storing and managing DNS messages
public final class DNSRepository {
    public static let shared = DNSRepository()
    public static let didChangeNotification = Notification.Name.dnsRepositoryDidChange

    // MARK: - Properties

    private var messages: [UUID: DNSMessage] = [:]
    private var queryIndex: [UInt16: [UUID]] = [:] // Transaction ID -> Query IDs
    private let queue = DispatchQueue(label: "com.trace.dnsrepository", attributes: .concurrent)
    private let storage = AppGroupStorage.shared

    // Configuration
    private let maxMessages = 10000
    private let persistInterval: TimeInterval = 5.0
    private var lastPersist = Date.distantPast
    private var didChangeNotificationPending = false

    // MARK: - Initialization

    private init() {
        loadMessages()
    }

    // MARK: - Message Management

    /// Add a DNS message (query or response)
    public func add(_ message: DNSMessage) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }

            var updatedMessage = message

            // If this is a response, try to match with query
            if message.isResponse {
                updatedMessage = self.matchWithQuery(response: message)
            } else {
                // Store query for future matching
                self.indexQuery(message)
            }

            self.messages[updatedMessage.id] = updatedMessage

            // Enforce max messages limit
            if self.messages.count > self.maxMessages {
                self.removeOldestMessages()
            }

            // Persist periodically
            self.persistIfNeeded()

            NetworkLog.dns.debug(
                "event=dns.message_add outcome=success type=\(message.isResponse ? "response" : "query", privacy: .public) message_id=\(message.id.uuidString, privacy: .public)"
            )

            self.notifyDidChange()
        }
    }

    /// Get all messages
    public func getAllMessages() -> [DNSMessage] {
        queue.sync {
            Array(messages.values).sorted { $0.timestamp > $1.timestamp }
        }
    }

    /// Get message by ID
    public func getMessage(id: UUID) -> DNSMessage? {
        queue.sync {
            messages[id]
        }
    }

    /// Get queries only
    public func getQueries() -> [DNSMessage] {
        queue.sync {
            messages.values.filter { !$0.isResponse }.sorted { $0.timestamp > $1.timestamp }
        }
    }

    /// Get responses only
    public func getResponses() -> [DNSMessage] {
        queue.sync {
            messages.values.filter(\.isResponse).sorted { $0.timestamp > $1.timestamp }
        }
    }

    /// Get paired query-response messages
    public func getPairedMessages() -> [(query: DNSMessage, response: DNSMessage)] {
        queue.sync {
            var pairs: [(query: DNSMessage, response: DNSMessage)] = []

            for message in messages.values where message.isResponse && message.relatedQueryId != nil {
                if let queryId = message.relatedQueryId,
                   let query = messages[queryId] {
                    pairs.append((query, message))
                }
            }

            return pairs.sorted { $0.response.timestamp > $1.response.timestamp }
        }
    }

    /// Get unanswered queries
    public func getUnansweredQueries() -> [DNSMessage] {
        queue.sync {
            messages.values.filter { !$0.isResponse && $0.relatedResponseId == nil }
                .sorted { $0.timestamp > $1.timestamp }
        }
    }

    /// Clear all messages
    public func clearAll() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.messages.removeAll()
            self.queryIndex.removeAll()
            self.persistMessages()
            NetworkLog.dns.info("event=dns.messages_clear outcome=success")
            self.notifyDidChange()
        }
    }

    /// Delete specific message
    public func delete(_ messageId: UUID) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }

            if let message = self.messages[messageId] {
                // Remove from index if it's a query
                if !message.isResponse {
                    self.removeFromQueryIndex(message)
                }

                self.messages.removeValue(forKey: messageId)
                self.persistIfNeeded()
            }

            self.notifyDidChange()
        }
    }

    /// Delete messages older than specified date
    public func deleteOlderThan(_ date: Date) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }

            let oldIds = self.messages.filter { $0.value.timestamp < date }.map(\.key)

            for id in oldIds {
                if let message = self.messages[id], !message.isResponse {
                    self.removeFromQueryIndex(message)
                }
                self.messages.removeValue(forKey: id)
            }

            if !oldIds.isEmpty {
                self.persistMessages()
                NetworkLog.dns.info("event=dns.messages_pruned outcome=success count=\(oldIds.count)")
                self.notifyDidChange()
            }
        }
    }

    private func notifyDidChange() {
        // Coalesce rapid-fire changes (e.g. high DNS volume) into a single UI refresh per main queue tick.
        if didChangeNotificationPending {
            return
        }
        didChangeNotificationPending = true

        DispatchQueue.main.async { [weak self] in
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)

            guard let self else { return }
            self.queue.async(flags: .barrier) { [weak self] in
                self?.didChangeNotificationPending = false
            }
        }
    }

    // MARK: - Query Matching

    private func matchWithQuery(response: DNSMessage) -> DNSMessage {
        var updatedResponse = response

        // Try to find matching query by transaction ID
        if let queryIds = queryIndex[response.transactionId] {
            // Find the most recent unmatched query
            for queryId in queryIds.reversed() {
                if let query = messages[queryId],
                   query.relatedResponseId == nil,
                   query.sourceIP == response.destIP {
                    // Calculate response time
                    let responseTime = response.timestamp.timeIntervalSince(query.timestamp)

                    // Update response
                    updatedResponse.relatedQueryId = queryId
                    updatedResponse.responseTime = responseTime

                    // Update query
                    var updatedQuery = query
                    updatedQuery.relatedResponseId = response.id
                    messages[queryId] = updatedQuery

                    NetworkLog.dns.debug(
                        "event=dns.query_match outcome=success query_id=\(query.id.uuidString, privacy: .public) response_id=\(response.id.uuidString, privacy: .public) duration_ms=\(Int(responseTime * 1000))"
                    )

                    break
                }
            }
        }

        return updatedResponse
    }

    private func indexQuery(_ query: DNSMessage) {
        if queryIndex[query.transactionId] == nil {
            queryIndex[query.transactionId] = []
        }
        queryIndex[query.transactionId]?.append(query.id)
    }

    private func removeFromQueryIndex(_ query: DNSMessage) {
        queryIndex[query.transactionId]?.removeAll { $0 == query.id }
    }

    // MARK: - Statistics

    public func getStatistics() -> DNSStatistics {
        queue.sync {
            let allMessages = Array(messages.values)
            let queries = allMessages.filter { !$0.isResponse }
            let responses = allMessages.filter(\.isResponse)
            let successful = responses.filter(\.isSuccessful)
            let failed = responses.filter { !$0.isSuccessful }
            let paired = responses.filter { $0.relatedQueryId != nil }

            let responseTimes = paired.compactMap(\.responseTime)
            let avgResponseTime = responseTimes.isEmpty ? 0 : responseTimes.reduce(0, +) / Double(responseTimes.count)

            return DNSStatistics(
                totalMessages: allMessages.count,
                totalQueries: queries.count,
                totalResponses: responses.count,
                successfulResponses: successful.count,
                failedResponses: failed.count,
                averageResponseTime: avgResponseTime,
                unansweredQueries: queries.count - paired.count
            )
        }
    }

    // MARK: - Persistence

    private func persistIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastPersist) >= persistInterval {
            persistMessages()
            lastPersist = now
        }
    }

    private func persistMessages() {
        let messagesToSave = Array(messages.values)

        Task {
            do {
                let data = try JSONEncoder().encode(messagesToSave)
                try storage.saveData(data, to: "DNSMessages.json")
                CoreLog.storage.debug(
                    "event=storage.dns_persist outcome=success count=\(messagesToSave.count)"
                )
            } catch {
                CoreLog.storage.error(
                    "event=storage.dns_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func loadMessages() {
        Task {
            do {
                let data = try storage.loadData(from: "DNSMessages.json")
                let loadedMessages = try JSONDecoder().decode([DNSMessage].self, from: data)

                queue.async(flags: .barrier) { [weak self] in
                    guard let self else { return }

                    for message in loadedMessages {
                        self.messages[message.id] = message
                        if !message.isResponse {
                            self.indexQuery(message)
                        }
                    }

                    CoreLog.storage.info(
                        "event=storage.dns_load outcome=success count=\(loadedMessages.count)"
                    )
                }
            } catch {
                if let storageError = error as? StorageError, storageError == .fileNotFound {
                    CoreLog.storage.debug("event=storage.dns_load outcome=skipped reason=file_not_found")
                    return
                }
                CoreLog.storage.error(
                    "event=storage.dns_load outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func removeOldestMessages() {
        let sortedMessages = messages.values.sorted { $0.timestamp < $1.timestamp }
        let toRemove = sortedMessages.prefix(maxMessages / 10) // Remove 10%

        for message in toRemove {
            if !message.isResponse {
                removeFromQueryIndex(message)
            }
            messages.removeValue(forKey: message.id)
        }

        CoreLog.storage.debug(
            "event=storage.dns_prune outcome=success count=\(toRemove.count)"
        )
    }
}

// MARK: - Statistics

public struct DNSStatistics: Codable {
    public let totalMessages: Int
    public let totalQueries: Int
    public let totalResponses: Int
    public let successfulResponses: Int
    public let failedResponses: Int
    public let averageResponseTime: TimeInterval
    public let unansweredQueries: Int

    public var successRate: Double {
        guard totalResponses > 0 else { return 0 }
        return Double(successfulResponses) / Double(totalResponses)
    }

    public var answerRate: Double {
        guard totalQueries > 0 else { return 0 }
        return Double(totalQueries - unansweredQueries) / Double(totalQueries)
    }
}
