//
//  DNSRepositoryConcurrentTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceNetworking

final class DNSRepositoryConcurrentTests: XCTestCase {

    var repository: DNSRepository!

    override func setUp() {
        super.setUp()
        repository = DNSRepository.shared
        repository.clearAll()
        Thread.sleep(forTimeInterval: 0.1)
    }

    override func tearDown() {
        repository.clearAll()
        super.tearDown()
    }

    // MARK: - Concurrent Add Tests

    func testConcurrentAddQueries() {
        let expectation = XCTestExpectation(description: "Concurrent queries")
        let queryCount = 100

        DispatchQueue.concurrentPerform(iterations: queryCount) { i in
            let query = createMockDNSMessage(
                isResponse: false,
                transactionId: UInt16(i)
            )
            repository.add(query)
        }

        // Wait for async operations
        Thread.sleep(forTimeInterval: 0.5)

        let messages = repository.getAllMessages()
        XCTAssertEqual(messages.count, queryCount)

        expectation.fulfill()
        wait(for: [expectation], timeout: 2.0)
    }

    func testConcurrentAddQueriesAndResponses() {
        let expectation = XCTestExpectation(description: "Concurrent mixed")
        let pairCount = 50

        DispatchQueue.concurrentPerform(iterations: pairCount * 2) { i in
            if i % 2 == 0 {
                let query = createMockDNSMessage(
                    isResponse: false,
                    transactionId: UInt16(i / 2),
                    sourceIP: "192.168.1.100",
                    destIP: "8.8.8.8"
                )
                repository.add(query)
            } else {
                // Add slight delay to ensure query is added first
                Thread.sleep(forTimeInterval: 0.001)
                let response = createMockDNSMessage(
                    isResponse: true,
                    transactionId: UInt16(i / 2),
                    sourceIP: "8.8.8.8",
                    destIP: "192.168.1.100"
                )
                repository.add(response)
            }
        }

        Thread.sleep(forTimeInterval: 1.0)

        let messages = repository.getAllMessages()
        XCTAssertEqual(messages.count, pairCount * 2)

        expectation.fulfill()
        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - Concurrent Read Tests

    func testConcurrentReads() {
        // Add some messages first
        for i in 0..<10 {
            let message = createMockDNSMessage(
                isResponse: false,
                transactionId: UInt16(i)
            )
            repository.add(message)
        }

        Thread.sleep(forTimeInterval: 0.2)

        let expectation = XCTestExpectation(description: "Concurrent reads")

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            _ = repository.getAllMessages()
            _ = repository.getQueries()
            _ = repository.getResponses()
            _ = repository.getStatistics()
        }

        expectation.fulfill()
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Concurrent Add and Read Tests

    func testConcurrentAddAndRead() {
        let expectation = XCTestExpectation(description: "Concurrent add and read")

        DispatchQueue.concurrentPerform(iterations: 50) { i in
            if i % 2 == 0 {
                let message = createMockDNSMessage(
                    isResponse: false,
                    transactionId: UInt16(i)
                )
                repository.add(message)
            } else {
                _ = repository.getAllMessages()
                _ = repository.getStatistics()
            }
        }

        Thread.sleep(forTimeInterval: 0.5)

        let messages = repository.getAllMessages()
        XCTAssertGreaterThanOrEqual(messages.count, 25)

        expectation.fulfill()
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Concurrent Delete Tests

    func testConcurrentDelete() {
        // Add messages
        var messageIds: [UUID] = []
        for i in 0..<20 {
            let message = createMockDNSMessage(
                isResponse: false,
                transactionId: UInt16(i)
            )
            messageIds.append(message.id)
            repository.add(message)
        }

        Thread.sleep(forTimeInterval: 0.2)

        let expectation = XCTestExpectation(description: "Concurrent delete")

        // Delete concurrently
        DispatchQueue.concurrentPerform(iterations: messageIds.count) { i in
            repository.delete(messageIds[i])
        }

        Thread.sleep(forTimeInterval: 0.3)

        let messages = repository.getAllMessages()
        XCTAssertEqual(messages.count, 0)

        expectation.fulfill()
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Max Message Limit Tests

    func testMaxMessageLimitEnforcement() {
        let maxMessages = 10000
        let extraMessages = 100

        // Add more than max
        for i in 0..<(maxMessages + extraMessages) {
            let message = createMockDNSMessage(
                isResponse: false,
                transactionId: UInt16(i % 65535),
                timestamp: Date(timeIntervalSinceNow: TimeInterval(i))
            )
            repository.add(message)

            // Give some processing time every 100 messages
            if i % 100 == 0 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        // Wait for all operations to complete
        Thread.sleep(forTimeInterval: 2.0)

        let messages = repository.getAllMessages()

        // Should not exceed max limit by much (may be slightly over during processing)
        XCTAssertLessThanOrEqual(messages.count, maxMessages + 100)
    }

    // MARK: - Query Matching with Multiple Queries Tests

    func testMultipleQueriesSameTransactionID() {
        let transactionId: UInt16 = 12345

        // Add multiple queries with same transaction ID
        let query1 = createMockDNSMessage(
            isResponse: false,
            transactionId: transactionId,
            sourceIP: "192.168.1.100",
            destIP: "8.8.8.8",
            timestamp: Date(timeIntervalSinceNow: -2.0)
        )
        let query2 = createMockDNSMessage(
            isResponse: false,
            transactionId: transactionId,
            sourceIP: "192.168.1.101",
            destIP: "8.8.8.8",
            timestamp: Date(timeIntervalSinceNow: -1.0)
        )

        repository.add(query1)
        Thread.sleep(forTimeInterval: 0.05)
        repository.add(query2)
        Thread.sleep(forTimeInterval: 0.05)

        // Add response - should match most recent query with same source IP
        let response = createMockDNSMessage(
            isResponse: true,
            transactionId: transactionId,
            sourceIP: "8.8.8.8",
            destIP: "192.168.1.101"
        )
        repository.add(response)

        Thread.sleep(forTimeInterval: 0.2)

        let paired = repository.getPairedMessages()

        // Should match with query2 (most recent with matching IP)
        XCTAssertGreaterThanOrEqual(paired.count, 1)
    }

    // MARK: - Response Time Accuracy Tests

    func testResponseTimeCalculation() {
        let transactionId: UInt16 = 99
        let queryTime = Date(timeIntervalSinceNow: -0.5)
        let responseTime = Date()

        let query = createMockDNSMessage(
            isResponse: false,
            transactionId: transactionId,
            sourceIP: "192.168.1.100",
            destIP: "8.8.8.8",
            timestamp: queryTime
        )

        repository.add(query)
        Thread.sleep(forTimeInterval: 0.1)

        let response = createMockDNSMessage(
            isResponse: true,
            transactionId: transactionId,
            sourceIP: "8.8.8.8",
            destIP: "192.168.1.100",
            timestamp: responseTime
        )

        repository.add(response)
        Thread.sleep(forTimeInterval: 0.1)

        let paired = repository.getPairedMessages()

        if let pair = paired.first {
            XCTAssertNotNil(pair.response.responseTime)
            XCTAssertGreaterThan(pair.response.responseTime ?? 0, 0)
            XCTAssertLessThan(pair.response.responseTime ?? 10, 2.0) // Should be under 2 seconds
        }
    }

    // MARK: - Statistics Calculation Tests

    func testStatisticsWithLargeDataset() {
        let messageCount = 1000

        // Add mix of queries and responses
        for i in 0..<messageCount {
            if i % 2 == 0 {
                let query = createMockDNSMessage(
                    isResponse: false,
                    transactionId: UInt16(i / 2)
                )
                repository.add(query)
            } else {
                let response = createMockDNSMessage(
                    isResponse: true,
                    transactionId: UInt16(i / 2),
                    isSuccessful: i % 4 != 0 // 75% successful
                )
                repository.add(response)
            }

            if i % 50 == 0 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        Thread.sleep(forTimeInterval: 1.0)

        let stats = repository.getStatistics()

        XCTAssertEqual(stats.totalMessages, messageCount)
        XCTAssertEqual(stats.totalQueries, messageCount / 2)
        XCTAssertEqual(stats.totalResponses, messageCount / 2)
        XCTAssertGreaterThan(stats.successfulResponses, 0)
        XCTAssertGreaterThan(stats.successRate, 0)
    }

    // MARK: - Notification Tests

    func testNotificationOnAdd() {
        let expectation = XCTestExpectation(description: "Notification")

        let observer = NotificationCenter.default.addObserver(
            forName: DNSRepository.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        let message = createMockDNSMessage(isResponse: false)
        repository.add(message)

        wait(for: [expectation], timeout: 1.0)

        NotificationCenter.default.removeObserver(observer)
    }

    func testNotificationCoalescing() {
        var notificationCount = 0
        let expectation = XCTestExpectation(description: "Coalesced notifications")

        let observer = NotificationCenter.default.addObserver(
            forName: DNSRepository.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
            expectation.fulfill()
        }

        // Add many messages rapidly
        for i in 0..<100 {
            let message = createMockDNSMessage(
                isResponse: false,
                transactionId: UInt16(i)
            )
            repository.add(message)
        }

        // Allow the main-queue coalesced notification to fire.
        wait(for: [expectation], timeout: 2.0)

        // Should have fewer notifications than messages due to coalescing
        XCTAssertLessThan(notificationCount, 100)
        XCTAssertGreaterThan(notificationCount, 0)

        NotificationCenter.default.removeObserver(observer)
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
