//
//  DNSViewModel.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
import SwiftUI
import TraceCore

/// View model for DNS queries and responses.
@MainActor
final class DNSViewModel: ObservableObject {
    // MARK: - Properties

    private let repository = DNSRepository.shared
    private var repositoryObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

    // Filters
    @Published var searchText = "" { didSet { scheduleReload(debounce: true) } }
    @Published var selectedRecordTypes: Set<DNSRecordType> = [] { didSet { scheduleReload() } }
    @Published var selectedResponseCodes: Set<DNSResponseCode> = [] { didSet { scheduleReload() } }
    @Published var showQueriesOnly = false { didSet { scheduleReload() } }
    @Published var showResponsesOnly = false { didSet { scheduleReload() } }
    @Published var showUnansweredOnly = false { didSet { scheduleReload() } }
    @Published var showFailedOnly = false { didSet { scheduleReload() } }

    // Sorting
    @Published var sortOrder: SortOrder = .newestFirst { didSet { scheduleReload() } }

    // Statistics
    @Published var statistics: DNSStatistics?

    @Published private(set) var messages: [DNSMessage] = []

    // MARK: - Initialization

    init() {
        repositoryObserver = NotificationCenter.default.addObserver(
            forName: DNSRepository.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatistics()
            self?.scheduleReload()
        }
        scheduleReload()
        refreshStatistics()
    }

    deinit {
        reloadTask?.cancel()
        if let repositoryObserver {
            NotificationCenter.default.removeObserver(repositoryObserver)
        }
    }

    // MARK: - Data Access

    /// Returns paired query and response messages.
    var pairedMessages: [(query: DNSMessage, response: DNSMessage)] {
        repository.getPairedMessages()
    }

    /// Returns unanswered query messages.
    var unansweredQueries: [DNSMessage] {
        repository.getUnansweredQueries()
    }

    // MARK: - Filtering

    private func applyFilters(to messages: [DNSMessage]) -> [DNSMessage] {
        var filtered = messages

        // Search filter
        if !searchText.isEmpty {
            let lowercased = searchText.lowercased()
            filtered = filtered.filter { message in
                message.queryDomain?.lowercased().contains(lowercased) == true ||
                    message.sourceIP.contains(lowercased) ||
                    message.destIP.contains(lowercased) ||
                    message.resolvedIPs.contains { $0.contains(lowercased) }
            }
        }

        // Record type filter
        if !selectedRecordTypes.isEmpty {
            filtered = filtered.filter { message in
                if let type = message.queryType {
                    return selectedRecordTypes.contains(type)
                }
                return false
            }
        }

        // Response code filter
        if !selectedResponseCodes.isEmpty {
            filtered = filtered.filter { message in
                message.isResponse && selectedResponseCodes.contains(message.responseCode)
            }
        }

        // Query/Response filter
        if showQueriesOnly {
            filtered = filtered.filter { !$0.isResponse }
        } else if showResponsesOnly {
            filtered = filtered.filter(\.isResponse)
        }

        // Unanswered filter
        if showUnansweredOnly {
            filtered = filtered.filter { !$0.isResponse && $0.relatedResponseId == nil }
        }

        // Failed filter
        if showFailedOnly {
            filtered = filtered.filter { $0.isResponse && !$0.isSuccessful }
        }

        return filtered
    }

    private func applySorting(to messages: [DNSMessage]) -> [DNSMessage] {
        switch sortOrder {
        case .newestFirst:
            messages.sorted { $0.timestamp > $1.timestamp }
        case .oldestFirst:
            messages.sorted { $0.timestamp < $1.timestamp }
        case .domainAZ:
            messages.sorted { ($0.queryDomain ?? "") < ($1.queryDomain ?? "") }
        case .domainZA:
            messages.sorted { ($0.queryDomain ?? "") > ($1.queryDomain ?? "") }
        case .fastestResponse:
            messages.sorted { ($0.responseTime ?? .infinity) < ($1.responseTime ?? .infinity) }
        case .slowestResponse:
            messages.sorted { ($0.responseTime ?? 0) > ($1.responseTime ?? 0) }
        }
    }

    // MARK: - Filter Management

    func clearFilters() {
        searchText = ""
        selectedRecordTypes.removeAll()
        selectedResponseCodes.removeAll()
        showQueriesOnly = false
        showResponsesOnly = false
        showUnansweredOnly = false
        showFailedOnly = false
    }

    func toggleRecordType(_ type: DNSRecordType) {
        if selectedRecordTypes.contains(type) {
            selectedRecordTypes.remove(type)
        } else {
            selectedRecordTypes.insert(type)
        }
    }

    func toggleResponseCode(_ code: DNSResponseCode) {
        if selectedResponseCodes.contains(code) {
            selectedResponseCodes.remove(code)
        } else {
            selectedResponseCodes.insert(code)
        }
    }

    // MARK: - Actions

    func deleteMessage(_ message: DNSMessage) {
        repository.delete(message.id)
        refreshStatistics()
        reloadMessages()
    }

    func clearAll() {
        repository.clearAll()
        refreshStatistics()
        reloadMessages()
    }

    /// Deletes messages older than the provided number of days.
    ///
    /// - Parameter days: Number of days to retain.
    func deleteOlderThan(days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        repository.deleteOlderThan(cutoffDate)
        refreshStatistics()
        reloadMessages()
    }

    // MARK: - Statistics

    /// Refreshes cached DNS statistics.
    func refreshStatistics() {
        statistics = repository.getStatistics()
    }

    private func scheduleReload(debounce: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.reloadMessages()
        }
    }

    func reloadMessages() {
        var result = repository.getAllMessages()
        result = applyFilters(to: result)
        result = applySorting(to: result)
        messages = result
    }

    // MARK: - Export

    /// Exports the current messages as a CSV string.
    ///
    /// - Returns: CSV representation of the filtered messages.
    func exportToCSV() -> String {
        let messages = self.messages
        var csv = "Timestamp,Type,Domain,Record Type,Response Code,Source IP,Dest IP,Response Time (ms),Resolved IPs\n"

        for message in messages {
            let timestamp = ISO8601DateFormatter().string(from: message.timestamp)
            let type = message.isResponse ? "Response" : "Query"
            let domain = message.queryDomain ?? ""
            let recordType = message.queryType?.displayName ?? ""
            let responseCode = message.isResponse ? message.responseCode.displayName : ""
            let responseTime = message.responseTime.map { String(format: "%.2f", $0 * 1000) } ?? ""
            let resolvedIPs = message.resolvedIPs.joined(separator: "; ")

            csv += "\"\(timestamp)\",\"\(type)\",\"\(domain)\",\"\(recordType)\",\"\(responseCode)\",\"\(message.sourceIP)\",\"\(message.destIP)\",\"\(responseTime)\",\"\(resolvedIPs)\"\n"
        }

        return csv
    }

    /// Exports the current messages as JSON data.
    ///
    /// - Returns: JSON-encoded messages, or `nil` if encoding fails.
    func exportToJSON() -> Data? {
        let messages = self.messages
        return try? JSONEncoder().encode(messages)
    }

    // MARK: - Sort Order

    enum SortOrder: String, CaseIterable {
        case newestFirst = "Newest First"
        case oldestFirst = "Oldest First"
        case domainAZ = "Domain A-Z"
        case domainZA = "Domain Z-A"
        case fastestResponse = "Fastest Response"
        case slowestResponse = "Slowest Response"
    }
}

// MARK: - Helpers

extension DNSViewModel {
    /// Returns the top queried domains.
    ///
    /// - Parameter limit: Maximum number of domains to return.
    func getTopDomains(limit: Int = 10) -> [(domain: String, count: Int)] {
        let messages = repository.getAllMessages()
        let domains = messages.compactMap(\.queryDomain)

        var domainCounts: [String: Int] = [:]
        for domain in domains {
            domainCounts[domain, default: 0] += 1
        }

        return domainCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }

    /// Returns the collected response times for all messages.
    func getResponseTimeDistribution() -> [TimeInterval] {
        let messages = repository.getAllMessages()
        return messages.compactMap(\.responseTime)
    }

    /// Returns the record type distribution for all messages.
    func getRecordTypeDistribution() -> [(type: DNSRecordType, count: Int)] {
        let messages = repository.getAllMessages()
        var typeCounts: [DNSRecordType: Int] = [:]

        for message in messages {
            if let type = message.queryType {
                typeCounts[type, default: 0] += 1
            }
        }

        return typeCounts
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }
}
