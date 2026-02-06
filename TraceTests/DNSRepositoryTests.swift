//
//  DNSRepositoryTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceNetworking

final class DNSRepositoryTests: XCTestCase {

    var repository: DNSRepository!

    override func setUp() {
        super.setUp()
        repository = DNSRepository.shared
        repository.clearAll()
        // Wait for async clear to complete
        Thread.sleep(forTimeInterval: 0.1)
    }

    override func tearDown() {
        repository.clearAll()
        super.tearDown()
    }

    // MARK: - Add Message Tests

    func testAddDNSQuery() {
        let query = createMockDNSMessage(isResponse: false)

        repository.add(query)

        // Wait for async operation
        Thread.sleep(forTimeInterval: 0.1)

        let messages = repository.getAllMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages.first?.isResponse ?? true)
    }

    func testAddDNSResponse() {
        let response = createMockDNSMessage(isResponse: true)

        repository.add(response)

        // Wait for async operation
        Thread.sleep(forTimeInterval: 0.1)

        let messages = repository.getAllMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.isResponse ?? false)
    }

    func testAddMultipleMessages() {
        let query1 = createMockDNSMessage(isResponse: false, transactionId: 1)
        let query2 = createMockDNSMessage(isResponse: false, transactionId: 2)
        let response = createMockDNSMessage(isResponse: true, transactionId: 1)

        repository.add(query1)
        repository.add(query2)
        repository.add(response)

        // Wait for async operations
        Thread.sleep(forTimeInterval: 0.2)

        let messages = repository.getAllMessages()
        XCTAssertEqual(messages.count, 3)
    }

    // MARK: - Query and Response Tests

    func testGetQueries() {
        let query1 = createMockDNSMessage(isResponse: false, transactionId: 1)
        let query2 = createMockDNSMessage(isResponse: false, transactionId: 2)
        let response = createMockDNSMessage(isResponse: true, transactionId: 1)

        repository.add(query1)
        repository.add(query2)
        repository.add(response)

        // Wait for async operations
        Thread.sleep(forTimeInterval: 0.2)

        let queries = repository.getQueries()
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries.allSatisfy { !$0.isResponse })
    }

    func testGetResponses() {
        let query = createMockDNSMessage(isResponse: false, transactionId: 1)
        let response1 = createMockDNSMessage(isResponse: true, transactionId: 1)
        let response2 = createMockDNSMessage(isResponse: true, transactionId: 2)

        repository.add(query)
        repository.add(response1)
        repository.add(response2)

        // Wait for async operations
        Thread.sleep(forTimeInterval: 0.2)

        let responses = repository.getResponses()
        XCTAssertEqual(responses.count, 2)
        XCTAssertTrue(responses.allSatisfy(\.isResponse))
    }

    // MARK: - Query Matching Tests

    func testQueryResponseMatching() {
        let transactionId: UInt16 = 12345
        let query = createMockDNSMessage(
            isResponse: false,
            transactionId: transactionId,
            sourceIP: "192.168.1.100",
            destIP: "8.8.8.8"
        )

        let response = createMockDNSMessage(
            isResponse: true,
            transactionId: transactionId,
            sourceIP: "8.8.8.8",
            destIP: "192.168.1.100"
        )

        repository.add(query)
        Thread.sleep(forTimeInterval: 0.1)
        repository.add(response)
        Thread.sleep(forTimeInterval: 0.1)

        let paired = repository.getPairedMessages()
        XCTAssertEqual(paired.count, 1)
        XCTAssertEqual(paired.first?.query.transactionId, transactionId)
        XCTAssertEqual(paired.first?.response.transactionId, transactionId)
    }

    func testUnansweredQueries() {
        let query1 = createMockDNSMessage(isResponse: false, transactionId: 1)
        let query2 = createMockDNSMessage(isResponse: false, transactionId: 2)
        let response = createMockDNSMessage(isResponse: true, transactionId: 1)

        repository.add(query1)
        repository.add(query2)
        repository.add(response)

        // Wait for async operations
        Thread.sleep(forTimeInterval: 0.2)

        let unanswered = repository.getUnansweredQueries()
        // query2 should be unanswered
        XCTAssertGreaterThanOrEqual(unanswered.count, 1)
    }

    // MARK: - Statistics Tests

    func testStatistics() {
        let query1 = createMockDNSMessage(isResponse: false, transactionId: 1)
        let query2 = createMockDNSMessage(isResponse: false, transactionId: 2)
        let successResponse = createMockDNSMessage(isResponse: true, transactionId: 1, isSuccessful: true)
        let failedResponse = createMockDNSMessage(isResponse: true, transactionId: 3, isSuccessful: false)

        repository.add(query1)
        repository.add(query2)
        repository.add(successResponse)
        repository.add(failedResponse)

        // Wait for async operations
        Thread.sleep(forTimeInterval: 0.3)

        let stats = repository.getStatistics()

        XCTAssertEqual(stats.totalMessages, 4)
        XCTAssertEqual(stats.totalQueries, 2)
        XCTAssertEqual(stats.totalResponses, 2)
        XCTAssertEqual(stats.successfulResponses, 1)
        XCTAssertEqual(stats.failedResponses, 1)
    }

    func testStatisticsSuccessRate() {
        let stats = DNSStatistics(
            totalMessages: 10,
            totalQueries: 5,
            totalResponses: 5,
            successfulResponses: 4,
            failedResponses: 1,
            averageResponseTime: 0.05,
            unansweredQueries: 1
        )

        XCTAssertEqual(stats.successRate, 0.8, accuracy: 0.001)
    }

    func testStatisticsAnswerRate() {
        let stats = DNSStatistics(
            totalMessages: 10,
            totalQueries: 5,
            totalResponses: 4,
            successfulResponses: 3,
            failedResponses: 1,
            averageResponseTime: 0.05,
            unansweredQueries: 1
        )

        XCTAssertEqual(stats.answerRate, 0.8, accuracy: 0.001)
    }

    // MARK: - Delete Tests

    func testDeleteMessage() {
        let message = createMockDNSMessage(isResponse: false)

        repository.add(message)
        Thread.sleep(forTimeInterval: 0.1)

        let messagesBefore = repository.getAllMessages()
        XCTAssertEqual(messagesBefore.count, 1)

        repository.delete(message.id)
        Thread.sleep(forTimeInterval: 0.1)

        let messagesAfter = repository.getAllMessages()
        XCTAssertEqual(messagesAfter.count, 0)
    }

    func testClearAll() {
        let message1 = createMockDNSMessage(isResponse: false)
        let message2 = createMockDNSMessage(isResponse: true)

        repository.add(message1)
        repository.add(message2)
        Thread.sleep(forTimeInterval: 0.1)

        let messagesBefore = repository.getAllMessages()
        XCTAssertEqual(messagesBefore.count, 2)

        repository.clearAll()
        Thread.sleep(forTimeInterval: 0.1)

        let messagesAfter = repository.getAllMessages()
        XCTAssertEqual(messagesAfter.count, 0)
    }

    func testDeleteOlderThan() {
        let oldMessage = createMockDNSMessage(
            isResponse: false,
            timestamp: Date(timeIntervalSinceNow: -86400 * 2) // 2 days ago
        )
        let newMessage = createMockDNSMessage(
            isResponse: false,
            timestamp: Date()
        )

        repository.add(oldMessage)
        repository.add(newMessage)
        Thread.sleep(forTimeInterval: 0.1)

        let cutoffDate = Date(timeIntervalSinceNow: -86400) // 1 day ago
        repository.deleteOlderThan(cutoffDate)
        Thread.sleep(forTimeInterval: 0.1)

        let messages = repository.getAllMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, newMessage.id)
    }

    // MARK: - Get Message Tests

    func testGetMessageById() {
        let message = createMockDNSMessage(isResponse: false)

        repository.add(message)
        Thread.sleep(forTimeInterval: 0.1)

        let retrieved = repository.getMessage(id: message.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, message.id)
    }

    func testGetMessageByIdNonExistent() {
        let retrieved = repository.getMessage(id: UUID())
        XCTAssertNil(retrieved)
    }

    // MARK: - Helper Methods

    private func createMockDNSMessage(
        isResponse: Bool,
        transactionId: UInt16 = 1,
        sourceIP: String = "192.168.1.100",
        destIP: String = "8.8.8.8",
        timestamp: Date = Date(),
        isSuccessful: Bool = true
    ) -> DNSMessage {
        let question = DNSQuestion(name: "example.com", type: .a)
        let responseCode: DNSResponseCode = isResponse ? (isSuccessful ? .noError : .nameError) : .noError

        let answers: [DNSResourceRecord]
        if isResponse, isSuccessful {
            answers = [
                DNSResourceRecord(
                    name: "example.com",
                    type: .a,
                    ttl: 60,
                    dataLength: 4,
                    data: Data([93, 184, 216, 34])
                )
            ]
        } else {
            answers = []
        }

        return DNSMessage(
            transactionId: transactionId,
            timestamp: timestamp,
            isResponse: isResponse,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: isResponse,
            responseCode: responseCode,
            questions: [question],
            answers: answers,
            authorities: [],
            additionals: [],
            sourceIP: sourceIP,
            sourcePort: isResponse ? 53 : 54321,
            destIP: destIP,
            destPort: isResponse ? 54321 : 53,
            messageSize: 0,
            relatedQueryId: nil,
            relatedResponseId: nil,
            responseTime: nil
        )
    }
}
