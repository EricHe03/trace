//
//  CaptureSessionTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class CaptureSessionTests: XCTestCase {

    // MARK: - Initializer Tests

    func testInitWithDefaultValues() {
        let session = CaptureSession()

        XCTAssertNotNil(session.id)
        XCTAssertNil(session.name)
        XCTAssertNotNil(session.startTime)
        XCTAssertNil(session.endTime)
        XCTAssertEqual(session.requestCount, 0)
        XCTAssertEqual(session.totalDataTransferred, 0)
    }

    func testInitWithCustomValues() {
        let id = UUID()
        let name = "Test Session"
        let startTime = Date(timeIntervalSince1970: 1000000)
        let endTime = Date(timeIntervalSince1970: 2000000)
        let requestCount = 42
        let totalData: Int64 = 1024000

        let session = CaptureSession(
            id: id,
            name: name,
            startTime: startTime,
            endTime: endTime,
            requestCount: requestCount,
            totalDataTransferred: totalData
        )

        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.name, name)
        XCTAssertEqual(session.startTime, startTime)
        XCTAssertEqual(session.endTime, endTime)
        XCTAssertEqual(session.requestCount, requestCount)
        XCTAssertEqual(session.totalDataTransferred, totalData)
    }

    func testInitWithNilOptionals() {
        let session = CaptureSession(
            name: nil,
            endTime: nil
        )

        XCTAssertNil(session.name)
        XCTAssertNil(session.endTime)
    }

    func testInitWithEmptyName() {
        let session = CaptureSession(name: "")

        XCTAssertNotNil(session.name)
        XCTAssertEqual(session.name, "")
    }

    // MARK: - Computed Property Tests

    func testIsActiveWhenNoEndTime() {
        let session = CaptureSession(endTime: nil)

        XCTAssertTrue(session.isActive)
    }

    func testIsActiveWhenEndTimeExists() {
        let session = CaptureSession(endTime: Date())

        XCTAssertFalse(session.isActive)
    }

    func testDurationWhenActive() {
        let startTime = Date(timeIntervalSinceNow: -100)
        let session = CaptureSession(startTime: startTime, endTime: nil)

        let duration = session.duration
        XCTAssertGreaterThan(duration, 99)
        XCTAssertLessThan(duration, 101)
    }

    func testDurationWhenCompleted() {
        let startTime = Date(timeIntervalSince1970: 1000000)
        let endTime = Date(timeIntervalSince1970: 1001000)
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        XCTAssertEqual(session.duration, 1000, accuracy: 0.001)
    }

    func testDurationString() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(3665) // 1h 1m 5s
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        let durationString = session.durationString
        XCTAssertEqual(durationString, "1h 1m 5s")
    }

    func testDurationStringMinutesOnly() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(125) // 2m 5s
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        let durationString = session.durationString
        XCTAssertEqual(durationString, "2m 5s")
    }

    func testDurationStringSecondsOnly() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(45) // 45s
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        let durationString = session.durationString
        XCTAssertEqual(durationString, "45s")
    }

    func testDurationStringZeroSeconds() {
        let startTime = Date()
        let session = CaptureSession(startTime: startTime, endTime: startTime)

        let durationString = session.durationString
        XCTAssertEqual(durationString, "0s")
    }

    func testDurationStringRelativeToReferenceDateWhenActive() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let startTime = referenceDate.addingTimeInterval(-125) // 2m 5s
        let session = CaptureSession(startTime: startTime, endTime: nil)

        let durationString = session.durationString(relativeTo: referenceDate)
        XCTAssertEqual(durationString, "2m 5s")
    }

    func testDurationStringClampsNegativeDurations() {
        let startTime = Date(timeIntervalSince1970: 2_000)
        let endTime = Date(timeIntervalSince1970: 1_000)
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        XCTAssertEqual(session.duration, 0)
        XCTAssertEqual(session.durationString, "0s")
    }

    func testDisplayNameWithCustomName() {
        let session = CaptureSession(name: "My API Test")

        XCTAssertEqual(session.displayName, "My API Test")
    }

    func testDisplayNameWithEmptyName() {
        let startTime = Date(timeIntervalSince1970: 1000000)
        let session = CaptureSession(name: "", startTime: startTime, endTime: nil)

        let displayName = session.displayName
        XCTAssertTrue(displayName.contains("Active Session -"))
    }

    func testDisplayNameWithNilNameWhenActive() {
        let session = CaptureSession(name: nil, endTime: nil)

        let displayName = session.displayName
        XCTAssertTrue(displayName.contains("Active Session -"))
    }

    func testDisplayNameWithNilNameWhenCompleted() {
        let session = CaptureSession(name: nil, endTime: Date())

        let displayName = session.displayName
        XCTAssertTrue(displayName.contains("Session -"))
        XCTAssertFalse(displayName.contains("Active"))
    }

    func testRelativeTimeString() {
        let recentTime = Date(timeIntervalSinceNow: -60) // 1 minute ago
        let session = CaptureSession(startTime: recentTime)

        let relativeString = session.relativeTimeString
        XCTAssertFalse(relativeString.isEmpty)
    }

    // MARK: - Codable Tests

    func testCodableRoundTrip() throws {
        let session = CaptureSession(
            id: UUID(),
            name: "Test Session",
            startTime: Date(),
            endTime: Date().addingTimeInterval(3600),
            requestCount: 100,
            totalDataTransferred: 5000000
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        let decodedSession = try decoder.decode(CaptureSession.self, from: data)

        XCTAssertEqual(session.id, decodedSession.id)
        XCTAssertEqual(session.name, decodedSession.name)
        XCTAssertEqual(session.startTime.timeIntervalSince1970, decodedSession.startTime.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(session.endTime)
        XCTAssertNotNil(decodedSession.endTime)
        XCTAssertEqual(session.endTime!.timeIntervalSince1970, decodedSession.endTime!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(session.requestCount, decodedSession.requestCount)
        XCTAssertEqual(session.totalDataTransferred, decodedSession.totalDataTransferred)
    }

    func testCodableWithNilOptionals() throws {
        let session = CaptureSession(
            name: nil,
            endTime: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        let decodedSession = try decoder.decode(CaptureSession.self, from: data)

        XCTAssertNil(decodedSession.name)
        XCTAssertNil(decodedSession.endTime)
    }

    func testCodableWithEmptyName() throws {
        let session = CaptureSession(name: "")

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)

        XCTAssertEqual(decoded.name, "")
    }

    func testCodableWithLargeDataValues() throws {
        let session = CaptureSession(
            requestCount: Int.max,
            totalDataTransferred: Int64.max
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)

        XCTAssertEqual(decoded.requestCount, Int.max)
        XCTAssertEqual(decoded.totalDataTransferred, Int64.max)
    }

    func testCodableWithZeroValues() throws {
        let session = CaptureSession(
            requestCount: 0,
            totalDataTransferred: 0
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)

        XCTAssertEqual(decoded.requestCount, 0)
        XCTAssertEqual(decoded.totalDataTransferred, 0)
    }

    func testCodablePreservesComputedProperties() throws {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(3600)
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)

        XCTAssertFalse(decoded.isActive)
        XCTAssertEqual(decoded.duration, 3600, accuracy: 0.001)
    }

    // MARK: - Equatable Tests

    func testEquatableWithEqualSessions() {
        let id = UUID()
        let startTime = Date()
        let session1 = CaptureSession(id: id, name: "Test", startTime: startTime, requestCount: 10)
        let session2 = CaptureSession(id: id, name: "Test", startTime: startTime, requestCount: 10)

        XCTAssertEqual(session1, session2)
    }

    func testEquatableWithDifferentIds() {
        let session1 = CaptureSession(id: UUID(), name: "Test")
        let session2 = CaptureSession(id: UUID(), name: "Test")

        XCTAssertNotEqual(session1, session2)
    }

    func testEquatableWithDifferentNames() {
        let id = UUID()
        let session1 = CaptureSession(id: id, name: "Test 1")
        let session2 = CaptureSession(id: id, name: "Test 2")

        XCTAssertNotEqual(session1, session2)
    }

    func testEquatableWithDifferentRequestCounts() {
        let id = UUID()
        let session1 = CaptureSession(id: id, requestCount: 10)
        let session2 = CaptureSession(id: id, requestCount: 20)

        XCTAssertNotEqual(session1, session2)
    }

    func testEquatableWithDifferentDataTransferred() {
        let id = UUID()
        let session1 = CaptureSession(id: id, totalDataTransferred: 1000)
        let session2 = CaptureSession(id: id, totalDataTransferred: 2000)

        XCTAssertNotEqual(session1, session2)
    }

    func testEquatableWithNilVsNonNilName() {
        let id = UUID()
        let session1 = CaptureSession(id: id, name: nil)
        let session2 = CaptureSession(id: id, name: "Test")

        XCTAssertNotEqual(session1, session2)
    }

    func testEquatableWithNilVsNonNilEndTime() {
        let id = UUID()
        let session1 = CaptureSession(id: id, endTime: nil)
        let session2 = CaptureSession(id: id, endTime: Date())

        XCTAssertNotEqual(session1, session2)
    }

    // MARK: - Identifiable Tests

    func testIdentifiableProtocol() {
        let session = CaptureSession()

        XCTAssertNotNil(session.id)
    }

    func testMultipleSessionsHaveUniqueIds() {
        let session1 = CaptureSession()
        let session2 = CaptureSession()
        let session3 = CaptureSession()

        XCTAssertNotEqual(session1.id, session2.id)
        XCTAssertNotEqual(session1.id, session3.id)
        XCTAssertNotEqual(session2.id, session3.id)
    }

    // MARK: - Edge Cases

    func testVeryLongSessionDuration() {
        let startTime = Date(timeIntervalSince1970: 0)
        let endTime = Date(timeIntervalSince1970: 86400 * 365 * 10) // 10 years
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        let duration = session.duration
        XCTAssertGreaterThan(duration, 0)

        let durationString = session.durationString
        XCTAssertFalse(durationString.isEmpty)
    }

    func testNegativeDuration() {
        let startTime = Date(timeIntervalSince1970: 2000000)
        let endTime = Date(timeIntervalSince1970: 1000000)
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        let duration = session.duration
        XCTAssertLessThan(duration, 0)
    }

    func testVeryLargeRequestCount() {
        let session = CaptureSession(requestCount: 1000000)

        XCTAssertEqual(session.requestCount, 1000000)
    }

    func testVeryLargeDataTransferred() {
        let largeData: Int64 = 1_000_000_000_000 // 1 TB
        let session = CaptureSession(totalDataTransferred: largeData)

        XCTAssertEqual(session.totalDataTransferred, largeData)
    }

    func testNameWithSpecialCharacters() {
        let specialName = "Test 🎯 @#$%^&* (session)"
        let session = CaptureSession(name: specialName)

        XCTAssertEqual(session.name, specialName)
        XCTAssertEqual(session.displayName, specialName)
    }

    func testCodableWithUnicodeCharacters() throws {
        let session = CaptureSession(name: "测试会话 🔥")

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)

        XCTAssertEqual(decoded.name, "测试会话 🔥")
    }

    func testDurationStringWithExactHours() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(7200) // Exactly 2 hours
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        let durationString = session.durationString
        XCTAssertEqual(durationString, "2h 0m 0s")
    }

    func testDurationStringWithExactMinutes() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(300) // Exactly 5 minutes
        let session = CaptureSession(startTime: startTime, endTime: endTime)

        let durationString = session.durationString
        XCTAssertEqual(durationString, "5m 0s")
    }

    // MARK: - Sendable Tests

    func testSendableConformance() {
        let session = CaptureSession(name: "Sendable Test")

        let expectation = expectation(description: "Sendable session can be passed to async context")

        Task {
            let capturedSession = session
            XCTAssertEqual(capturedSession.name, "Sendable Test")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Mutation Tests

    func testMutateRequestCount() {
        var session = CaptureSession()
        XCTAssertEqual(session.requestCount, 0)

        session.requestCount = 50
        XCTAssertEqual(session.requestCount, 50)
    }

    func testMutateTotalDataTransferred() {
        var session = CaptureSession()
        XCTAssertEqual(session.totalDataTransferred, 0)

        session.totalDataTransferred = 1024000
        XCTAssertEqual(session.totalDataTransferred, 1024000)
    }

    func testMutateName() {
        var session = CaptureSession(name: "Original")
        XCTAssertEqual(session.name, "Original")

        session.name = "Updated"
        XCTAssertEqual(session.name, "Updated")
    }

    func testMutateEndTime() {
        var session = CaptureSession(endTime: nil)
        XCTAssertTrue(session.isActive)

        session.endTime = Date()
        XCTAssertFalse(session.isActive)
    }
}
