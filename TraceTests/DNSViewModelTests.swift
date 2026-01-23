//
//  DNSViewModelTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/16.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class DNSViewModelTests: XCTestCase {

    var viewModel: DNSViewModel!

    override func setUp() {
        super.setUp()
        viewModel = DNSViewModel()
        // Clear any existing messages
        viewModel.clearAll()
    }

    override func tearDown() {
        viewModel.clearAll()
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testViewModelInitialization() {
        XCTAssertNotNil(viewModel)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertTrue(viewModel.selectedRecordTypes.isEmpty)
        XCTAssertTrue(viewModel.selectedResponseCodes.isEmpty)
        XCTAssertFalse(viewModel.showQueriesOnly)
        XCTAssertFalse(viewModel.showResponsesOnly)
        XCTAssertFalse(viewModel.showUnansweredOnly)
        XCTAssertFalse(viewModel.showFailedOnly)
    }

    func testDefaultSortOrder() {
        XCTAssertEqual(viewModel.sortOrder, .newestFirst)
    }

    // MARK: - Filter Tests

    func testClearFilters() {
        viewModel.searchText = "example.com"
        viewModel.selectedRecordTypes.insert(.a)
        viewModel.showQueriesOnly = true

        viewModel.clearFilters()

        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertTrue(viewModel.selectedRecordTypes.isEmpty)
        XCTAssertFalse(viewModel.showQueriesOnly)
    }

    func testToggleRecordType() {
        XCTAssertFalse(viewModel.selectedRecordTypes.contains(.a))

        viewModel.toggleRecordType(.a)
        XCTAssertTrue(viewModel.selectedRecordTypes.contains(.a))

        viewModel.toggleRecordType(.a)
        XCTAssertFalse(viewModel.selectedRecordTypes.contains(.a))
    }

    func testToggleMultipleRecordTypes() {
        viewModel.toggleRecordType(.a)
        viewModel.toggleRecordType(.aaaa)
        viewModel.toggleRecordType(.cname)

        XCTAssertTrue(viewModel.selectedRecordTypes.contains(.a))
        XCTAssertTrue(viewModel.selectedRecordTypes.contains(.aaaa))
        XCTAssertTrue(viewModel.selectedRecordTypes.contains(.cname))
        XCTAssertEqual(viewModel.selectedRecordTypes.count, 3)
    }

    func testToggleResponseCode() {
        XCTAssertFalse(viewModel.selectedResponseCodes.contains(.noError))

        viewModel.toggleResponseCode(.noError)
        XCTAssertTrue(viewModel.selectedResponseCodes.contains(.noError))

        viewModel.toggleResponseCode(.noError)
        XCTAssertFalse(viewModel.selectedResponseCodes.contains(.noError))
    }

    // MARK: - Sort Order Tests

    func testSortOrderCases() {
        let allCases = DNSViewModel.SortOrder.allCases

        XCTAssertEqual(allCases.count, 6)
        XCTAssertTrue(allCases.contains(.newestFirst))
        XCTAssertTrue(allCases.contains(.oldestFirst))
        XCTAssertTrue(allCases.contains(.domainAZ))
        XCTAssertTrue(allCases.contains(.domainZA))
        XCTAssertTrue(allCases.contains(.fastestResponse))
        XCTAssertTrue(allCases.contains(.slowestResponse))
    }

    func testSortOrderRawValues() {
        XCTAssertEqual(DNSViewModel.SortOrder.newestFirst.rawValue, "Newest First")
        XCTAssertEqual(DNSViewModel.SortOrder.oldestFirst.rawValue, "Oldest First")
        XCTAssertEqual(DNSViewModel.SortOrder.domainAZ.rawValue, "Domain A-Z")
        XCTAssertEqual(DNSViewModel.SortOrder.domainZA.rawValue, "Domain Z-A")
        XCTAssertEqual(DNSViewModel.SortOrder.fastestResponse.rawValue, "Fastest Response")
        XCTAssertEqual(DNSViewModel.SortOrder.slowestResponse.rawValue, "Slowest Response")
    }

    func testChangeSortOrder() {
        viewModel.sortOrder = .oldestFirst
        XCTAssertEqual(viewModel.sortOrder, .oldestFirst)

        viewModel.sortOrder = .domainAZ
        XCTAssertEqual(viewModel.sortOrder, .domainAZ)
    }

    // MARK: - Export Tests

    func testExportToCSVHeader() {
        let csv = viewModel.exportToCSV()

        XCTAssertTrue(csv.hasPrefix("Timestamp,Type,Domain,Record Type,Response Code,Source IP,Dest IP,Response Time (ms),Resolved IPs"))
    }

    func testExportToCSVEmpty() {
        let csv = viewModel.exportToCSV()

        // Should only contain header
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2) // Header + empty line
    }

    func testExportToJSON() {
        let jsonData = viewModel.exportToJSON()

        // With no messages, should return empty array
        XCTAssertNotNil(jsonData)
        if let data = jsonData,
           let string = String(data: data, encoding: .utf8) {
            XCTAssertEqual(string, "[]")
        }
    }

    // MARK: - Statistics Tests

    func testRefreshStatistics() {
        viewModel.refreshStatistics()

        // Should not crash and statistics should exist (even if empty)
        // Statistics might be nil if no messages exist
    }

    // MARK: - Filter Combination Tests

    func testExclusiveQueryResponseFilters() {
        viewModel.showQueriesOnly = true
        XCTAssertTrue(viewModel.showQueriesOnly)
        XCTAssertFalse(viewModel.showResponsesOnly)

        viewModel.showResponsesOnly = true
        XCTAssertTrue(viewModel.showResponsesOnly)
        // Note: Both can be set to true in the view model,
        // but the filter logic handles this
    }

    // MARK: - Helper Function Tests

    func testGetTopDomainsEmpty() {
        let topDomains = viewModel.getTopDomains(limit: 10)
        XCTAssertTrue(topDomains.isEmpty)
    }

    func testGetTopDomainsLimit() {
        let topDomains = viewModel.getTopDomains(limit: 5)
        XCTAssertLessThanOrEqual(topDomains.count, 5)
    }

    func testGetResponseTimeDistribution() {
        let distribution = viewModel.getResponseTimeDistribution()
        XCTAssertTrue(distribution.isEmpty) // No messages
    }

    func testGetRecordTypeDistribution() {
        let distribution = viewModel.getRecordTypeDistribution()
        XCTAssertTrue(distribution.isEmpty) // No messages
    }

    // MARK: - DNSMessage Tests

    func testDNSMessageInitialization() {
        let question = DNSQuestion(name: "example.com", type: .a)
        let message = DNSMessage(
            id: UUID(),
            transactionId: 12345,
            timestamp: Date(),
            isResponse: false,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: false,
            responseCode: .noError,
            questions: [question],
            answers: [],
            authorities: [],
            additionals: [],
            sourceIP: "192.168.1.1",
            sourcePort: 12345,
            destIP: "8.8.8.8",
            destPort: 53,
            messageSize: 0,
            responseTime: nil
        )

        XCTAssertEqual(message.queryDomain, "example.com")
        XCTAssertEqual(message.queryType, .a)
        XCTAssertFalse(message.isResponse)
        XCTAssertEqual(message.destPort, 53)
    }

    func testDNSMessageIsSuccessful() {
        let successQuestion = DNSQuestion(name: "example.com", type: .a)
        let successMessage = DNSMessage(
            id: UUID(),
            transactionId: 1,
            timestamp: Date(),
            isResponse: true,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: true,
            responseCode: .noError,
            questions: [successQuestion],
            answers: [],
            authorities: [],
            additionals: [],
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.1",
            destPort: 12345,
            messageSize: 0,
            responseTime: 0.05
        )

        XCTAssertTrue(successMessage.isSuccessful)

        let failedQuestion = DNSQuestion(name: "nonexistent.example.com", type: .a)
        let failedMessage = DNSMessage(
            id: UUID(),
            transactionId: 2,
            timestamp: Date(),
            isResponse: true,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: true,
            responseCode: .nameError,
            questions: [failedQuestion],
            answers: [],
            authorities: [],
            additionals: [],
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.1",
            destPort: 12345,
            messageSize: 0,
            responseTime: 0.03
        )

        XCTAssertFalse(failedMessage.isSuccessful)
    }

    // MARK: - DNSRecordType Tests

    func testDNSRecordTypeDisplayNames() {
        XCTAssertEqual(DNSRecordType.a.displayName, "A")
        XCTAssertEqual(DNSRecordType.aaaa.displayName, "AAAA")
        XCTAssertEqual(DNSRecordType.cname.displayName, "CNAME")
        XCTAssertEqual(DNSRecordType.mx.displayName, "MX")
        XCTAssertEqual(DNSRecordType.txt.displayName, "TXT")
        XCTAssertEqual(DNSRecordType.ns.displayName, "NS")
        XCTAssertEqual(DNSRecordType.ptr.displayName, "PTR")
        XCTAssertEqual(DNSRecordType.soa.displayName, "SOA")
        XCTAssertEqual(DNSRecordType.srv.displayName, "SRV")
    }

    func testDNSRecordTypeFromCode() {
        XCTAssertEqual(DNSRecordType(rawValue: 1), .a)
        XCTAssertEqual(DNSRecordType(rawValue: 28), .aaaa)
        XCTAssertEqual(DNSRecordType(rawValue: 5), .cname)
        XCTAssertEqual(DNSRecordType(rawValue: 15), .mx)
        XCTAssertEqual(DNSRecordType(rawValue: 16), .txt)
    }

    // MARK: - DNSResponseCode Tests

    func testDNSResponseCodeDisplayNames() {
        XCTAssertEqual(DNSResponseCode.noError.displayName, "NOERROR")
        XCTAssertEqual(DNSResponseCode.formatError.displayName, "FORMERR")
        XCTAssertEqual(DNSResponseCode.serverFailure.displayName, "SERVFAIL")
        XCTAssertEqual(DNSResponseCode.nameError.displayName, "NXDOMAIN")
        XCTAssertEqual(DNSResponseCode.notImplemented.displayName, "NOTIMP")
        XCTAssertEqual(DNSResponseCode.refused.displayName, "REFUSED")
    }

    func testDNSResponseCodeSuccess() {
        XCTAssertTrue(DNSResponseCode.noError.isSuccess)
        XCTAssertFalse(DNSResponseCode.nameError.isSuccess)
        XCTAssertFalse(DNSResponseCode.serverFailure.isSuccess)
        XCTAssertFalse(DNSResponseCode.refused.isSuccess)
    }

    // MARK: - DNSStatistics Tests

    func testDNSStatisticsInitialization() {
        let stats = DNSStatistics(
            totalMessages: 195,
            totalQueries: 100,
            totalResponses: 95,
            successfulResponses: 90,
            failedResponses: 5,
            averageResponseTime: 0.05,
            unansweredQueries: 10
        )

        XCTAssertEqual(stats.totalMessages, 195)
        XCTAssertEqual(stats.totalQueries, 100)
        XCTAssertEqual(stats.totalResponses, 95)
        XCTAssertEqual(stats.successfulResponses, 90)
        XCTAssertEqual(stats.failedResponses, 5)
        XCTAssertEqual(stats.averageResponseTime, 0.05)
        XCTAssertEqual(stats.unansweredQueries, 10)
    }

    func testDNSStatisticsSuccessRate() {
        let stats = DNSStatistics(
            totalMessages: 200,
            totalQueries: 100,
            totalResponses: 100,
            successfulResponses: 80,
            failedResponses: 20,
            averageResponseTime: 0.05,
            unansweredQueries: 0
        )

        XCTAssertEqual(stats.successRate, 0.8, accuracy: 0.01)
    }

    // MARK: - Edge Cases

    func testSearchWithEmptyText() {
        viewModel.searchText = ""
        // Should not filter anything
        XCTAssertEqual(viewModel.searchText, "")
    }

    func testSearchWithSpecialCharacters() {
        viewModel.searchText = "example.com?query=test"
        XCTAssertEqual(viewModel.searchText, "example.com?query=test")
    }

    func testSearchWithUnicode() {
        viewModel.searchText = "münchen.de"
        XCTAssertEqual(viewModel.searchText, "münchen.de")
    }

    func testDeleteOlderThan() {
        // Should not crash even with no messages
        viewModel.deleteOlderThan(days: 7)
    }

    func testPairedMessages() {
        let paired = viewModel.pairedMessages
        XCTAssertTrue(paired.isEmpty) // No messages
    }

    func testUnansweredQueries() {
        let unanswered = viewModel.unansweredQueries
        XCTAssertTrue(unanswered.isEmpty) // No messages
    }
}
