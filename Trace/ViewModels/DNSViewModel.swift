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
final class DNSViewModel: ObservableObject {
    // MARK: - Properties

    private let repository = DNSRepository.shared
    private var updateTimer: Timer?

    // Filters
    @Published var searchText = ""
    @Published var selectedRecordTypes: Set<DNSRecordType> = []
    @Published var selectedResponseCodes: Set<DNSResponseCode> = []
    @Published var showQueriesOnly = false
    @Published var showResponsesOnly = false
    @Published var showUnansweredOnly = false
    @Published var showFailedOnly = false

    // Sorting
    @Published var sortOrder: SortOrder = .newestFirst

    // Statistics
    @Published var statistics: DNSStatistics?

    // MARK: - Initialization

    init() {
        startAutoRefresh()
        refreshStatistics()
    }

    deinit {
        stopAutoRefresh()
    }

    // MARK: - Data Access

    /// Returns all filtered and sorted DNS messages.
    var messages: [DNSMessage] {
        var result = repository.getAllMessages()

        // Apply filters
        result = applyFilters(to: result)

        // Apply sorting
        result = applySorting(to: result)

        return result
    }

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
    }

    func clearAll() {
        repository.clearAll()
        refreshStatistics()
    }

    /// Deletes messages older than the provided number of days.
    ///
    /// - Parameter days: Number of days to retain.
    func deleteOlderThan(days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        repository.deleteOlderThan(cutoffDate)
        refreshStatistics()
    }

    // MARK: - Statistics

    /// Refreshes cached DNS statistics.
    func refreshStatistics() {
        statistics = repository.getStatistics()
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

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatistics()
        }
    }

    private func stopAutoRefresh() {
        updateTimer?.invalidate()
        updateTimer = nil
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
