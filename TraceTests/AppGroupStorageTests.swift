//
//  AppGroupStorageTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class AppGroupStorageTests: XCTestCase {

    var storage: AppGroupStorage!
    var testRequestID: UUID!

    override func setUp() {
        super.setUp()
        storage = AppGroupStorage.shared
        testRequestID = UUID()

        // Clean up any existing test data
        try? storage.clearAllRequests()
        try? storage.clearAllTransportRequests()
        try? storage.clearAllWebSocketConnections()
        try? storage.clearAllSSEConnections()
        storage.setTransportStoreBudgetBytesForTesting(nil)
        storage.resetStoredSettings()
    }

    override func tearDown() {
        // Clean up test data
        try? storage.clearAllRequests()
        try? storage.clearAllTransportRequests()
        try? storage.clearAllWebSocketConnections()
        try? storage.clearAllSSEConnections()
        storage.setTransportStoreBudgetBytesForTesting(nil)
        storage.resetStoredSettings()
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let storage1 = AppGroupStorage.shared
        let storage2 = AppGroupStorage.shared

        XCTAssertTrue(storage1 === storage2, "AppGroupStorage should be a singleton")
    }

    // MARK: - Container URL Tests

    func testContainerURLExists() {
        XCTAssertNotNil(storage.containerURL, "Container URL should exist")
    }

    func testContainerURLIsDirectory() {
        guard let containerURL = storage.containerURL else {
            XCTFail("Container URL should exist")
            return
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: containerURL.path, isDirectory: &isDirectory)

        XCTAssertTrue(exists, "Container path should exist")
        XCTAssertTrue(isDirectory.boolValue, "Container path should be a directory")
    }

    // MARK: - Request Storage Tests

    func testSaveRequest() throws {
        let request = createMockRequest()

        XCTAssertNoThrow(try storage.saveRequest(request))
    }

    func testLoadAllRequests() throws {
        // Save multiple requests
        let request1 = createMockRequest(url: "https://example.com/1")
        let request2 = createMockRequest(url: "https://example.com/2")

        try storage.saveRequest(request1)
        try storage.saveRequest(request2)

        // Load all requests
        let loaded = try storage.loadAllRequests()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains { $0.url == "https://example.com/1" })
        XCTAssertTrue(loaded.contains { $0.url == "https://example.com/2" })
    }

    func testLoadAllRequestsSorting() throws {
        // Create requests with different timestamps
        let oldRequest = createMockRequest(
            url: "https://example.com/old",
            timestamp: Date(timeIntervalSinceNow: -3600)
        )
        let recentRequest = createMockRequest(
            url: "https://example.com/recent",
            timestamp: Date()
        )

        try storage.saveRequest(oldRequest)
        try storage.saveRequest(recentRequest)

        let loaded = try storage.loadAllRequests()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.url, "https://example.com/recent", "Most recent request should be first")
        XCTAssertEqual(loaded.last?.url, "https://example.com/old", "Oldest request should be last")
    }

    func testLoadRequestsNewerThanWithExclusionsAndLimit() throws {
        let now = Date()
        let oldRequest = createMockRequest(
            url: "https://example.com/old",
            timestamp: now.addingTimeInterval(-120)
        )
        let recentRequest = createMockRequest(
            url: "https://example.com/recent",
            timestamp: now.addingTimeInterval(-10)
        )
        let newestRequest = createMockRequest(
            url: "https://example.com/newest",
            timestamp: now
        )

        try storage.saveRequest(oldRequest)
        try storage.saveRequest(recentRequest)
        try storage.saveRequest(newestRequest)

        let loaded = try storage.loadRequests(
            newerThan: now.addingTimeInterval(-60),
            excludingIDs: Set([newestRequest.id]),
            limit: 10
        )

        XCTAssertEqual(loaded.map(\.id), [recentRequest.id])
        XCTAssertTrue(loaded.allSatisfy { $0.timestamp >= now.addingTimeInterval(-60) })
    }

    func testLoadRequestByID() throws {
        let request = createMockRequest(url: "https://example.com/by-id")
        try storage.saveRequest(request)

        let loaded = try storage.loadRequest(request.id)
        XCTAssertEqual(loaded?.id, request.id)

        let missing = try storage.loadRequest(UUID())
        XCTAssertNil(missing)
    }

    func testDeleteRequest() throws {
        let request = createMockRequest()
        try storage.saveRequest(request)

        // Verify it was saved
        var loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 1)

        // Delete it
        try storage.deleteRequest(request.id)

        // Verify it was deleted
        loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 0)
    }

    func testDeleteRequestConvenience() throws {
        let request = createMockRequest()
        try storage.saveRequest(request)

        // Delete using convenience method
        try storage.deleteRequest(request)

        // Verify it was deleted
        let loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 0)
    }

    func testClearAllRequests() throws {
        // Save multiple requests
        try storage.saveRequest(createMockRequest(url: "https://example.com/1"))
        try storage.saveRequest(createMockRequest(url: "https://example.com/2"))
        try storage.saveRequest(createMockRequest(url: "https://example.com/3"))

        // Verify they were saved
        var loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 3)

        // Clear all
        try storage.clearAllRequests()

        // Verify all were deleted
        loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 0)
    }

    // MARK: - Transport Request Storage Tests

    func testSaveAndLoadTransportRequests() throws {
        let first = createMockTransportRequest(
            timestamp: Date(timeIntervalSinceNow: -30),
            sourcePort: 53001,
            destinationPort: 53
        )
        let second = createMockTransportRequest(
            timestamp: Date(),
            sourcePort: 53002,
            destinationPort: 123
        )

        try storage.saveTransportRequest(first)
        try storage.saveTransportRequest(second)

        let loaded = try storage.loadAllTransportRequests()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.id, second.id)
        XCTAssertEqual(loaded.last?.id, first.id)
    }

    func testBatchSaveTransportRequests() throws {
        let first = createMockTransportRequest(
            timestamp: Date(timeIntervalSinceNow: -20),
            sourcePort: 54001,
            destinationPort: 53
        )
        let second = createMockTransportRequest(
            timestamp: Date(timeIntervalSinceNow: -10),
            sourcePort: 54002,
            destinationPort: 123
        )
        let third = createMockTransportRequest(
            timestamp: Date(),
            sourcePort: 54003,
            destinationPort: 161
        )

        try storage.saveTransportRequests([first, second, third])

        let loaded = try storage.loadAllTransportRequests()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.first?.id, third.id)
        XCTAssertEqual(loaded.last?.id, first.id)
    }

    func testBatchSaveTransportRequestsThrowsOnPartialFailure() throws {
        guard let containerURL = storage.containerURL else {
            throw StorageError.containerNotFound
        }
        let requestsURL = containerURL.appendingPathComponent("TransportRequests")

        let first = createMockTransportRequest(
            timestamp: Date(timeIntervalSinceNow: -20),
            sourcePort: 54101,
            destinationPort: 53
        )
        let second = createMockTransportRequest(
            timestamp: Date(timeIntervalSinceNow: -10),
            sourcePort: 54102,
            destinationPort: 123
        )
        let third = createMockTransportRequest(
            timestamp: Date(),
            sourcePort: 54103,
            destinationPort: 161
        )

        let blockedPath = requestsURL.appendingPathComponent("\(second.id.uuidString).json")
        try FileManager.default.createDirectory(at: blockedPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blockedPath) }

        XCTAssertThrowsError(try storage.saveTransportRequests([first, second, third]))

        let loaded = try storage.loadAllTransportRequests()
        let loadedIDs = Set(loaded.map(\.id))
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loadedIDs, Set([first.id, third.id]))
    }

    func testSaveAndLoadTransportRequestWithPacketMetadata() throws {
        let payloadFileURL = try makeTransportBodyFile(data: Data([0xAA, 0xBB, 0xCC]))
        let packetFileURL = try makeTransportBodyFile(data: Data([0x45, 0x00, 0x00, 0x3C]))
        let request = TransportRequest(
            timestamp: Date(),
            sourceIP: "10.0.0.5",
            destinationIP: "1.1.1.1",
            sourcePort: 52344,
            destinationPort: 443,
            transport: .tcp,
            applicationProtocol: .tls,
            parserOutcome: .fallbackSignatureOnly,
            payload: .file(payloadFileURL),
            payloadBytes: 3,
            packet: .file(packetFileURL),
            packetBytes: 60,
            ipVersion: 4,
            protocolNumber: 6,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 60,
            fragmentOffset: 0,
            moreFragments: false,
            tcpSequenceNumber: 123,
            tcpAcknowledgmentNumber: 456,
            tcpFlags: 0x12,
            tcpWindowSize: 8192,
            tcpDataOffset: 24,
            tcpOptions: TransportTCPPacketOptions(
                maximumSegmentSize: 1460,
                windowScale: 7,
                sackPermitted: true,
                timestamps: TransportTCPPacketTimestamp(value: 100, echoReply: 101)
            ),
            flowKey: "tcp|10.0.0.5:52344|1.1.1.1:443"
        )

        try storage.saveTransportRequest(request)
        let loaded = try storage.loadAllTransportRequests()
        guard let restored = loaded.first else {
            XCTFail("Expected stored transport request")
            return
        }

        XCTAssertEqual(restored.packetBytes, 60)
        XCTAssertEqual(restored.tcpSequenceNumber, 123)
        XCTAssertEqual(restored.tcpAcknowledgmentNumber, 456)
        XCTAssertEqual(restored.tcpFlags, 0x12)
        XCTAssertEqual(restored.tcpWindowSize, 8192)
        XCTAssertEqual(restored.tcpDataOffset, 24)
        XCTAssertEqual(restored.tcpOptions?.maximumSegmentSize, 1460)
        XCTAssertEqual(restored.tcpOptions?.windowScale, 7)
        XCTAssertEqual(restored.tcpOptions?.sackPermitted, true)
        XCTAssertEqual(restored.tcpOptions?.timestamps?.value, 100)
        XCTAssertEqual(restored.tcpOptions?.timestamps?.echoReply, 101)
        XCTAssertEqual(restored.packet?.getData(), Data([0x45, 0x00, 0x00, 0x3C]))
    }

    func testTransportRingBufferPrunesOldestAndDeletesBodyFiles() throws {
        storage.setTransportStoreBudgetBytesForTesting(1024)
        defer { storage.setTransportStoreBudgetBytesForTesting(nil) }

        let oldPayloadURL = try makeTransportBodyFile(data: Data(repeating: 0xAB, count: 2048))
        let oldPacketURL = try makeTransportBodyFile(data: Data(repeating: 0xCD, count: 2048))
        let oldRequest = TransportRequest(
            timestamp: Date(timeIntervalSinceNow: -60),
            sourceIP: "192.168.1.10",
            destinationIP: "8.8.8.8",
            sourcePort: 53000,
            destinationPort: 443,
            transport: .tcp,
            applicationProtocol: .tls,
            parserOutcome: .fallbackSignatureOnly,
            payload: .file(oldPayloadURL),
            payloadBytes: 2048,
            packet: .file(oldPacketURL),
            packetBytes: 4096,
            ipVersion: 4,
            protocolNumber: 6,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 4096,
            fragmentOffset: 0,
            moreFragments: false,
            flowKey: "tcp|192.168.1.10:53000|8.8.8.8:443"
        )

        let recentRequest = TransportRequest(
            timestamp: Date(),
            sourceIP: "192.168.1.10",
            destinationIP: "8.8.8.8",
            sourcePort: 53001,
            destinationPort: 80,
            transport: .tcp,
            applicationProtocol: .http,
            parserOutcome: .parsed,
            payload: .inline(Data([0x47, 0x45, 0x54])),
            payloadBytes: 3,
            packet: .inline(Data([0x45, 0x00, 0x00, 0x28])),
            packetBytes: 40,
            ipVersion: 4,
            protocolNumber: 6,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 40,
            fragmentOffset: 0,
            moreFragments: false,
            flowKey: "tcp|192.168.1.10:53001|8.8.8.8:80"
        )

        try storage.saveTransportRequests([oldRequest, recentRequest])

        let loaded = try storage.loadAllTransportRequests()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, recentRequest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPayloadURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPacketURL.path))
    }

    func testLoadTransportRequestsNewerThanSupportsSameTimestampWithExclusions() throws {
        let sharedTimestamp = Date()
        let first = createMockTransportRequest(
            timestamp: sharedTimestamp,
            sourcePort: 55001,
            destinationPort: 53
        )
        let second = createMockTransportRequest(
            timestamp: sharedTimestamp,
            sourcePort: 55002,
            destinationPort: 123
        )

        try storage.saveTransportRequests([first, second])

        let known = try storage.loadAllTransportRequests()
        let knownIDs = Set(known.map(\.id))

        let third = createMockTransportRequest(
            timestamp: sharedTimestamp,
            sourcePort: 55003,
            destinationPort: 161
        )
        try storage.saveTransportRequest(third)

        let incremental = try storage.loadTransportRequests(
            newerThan: sharedTimestamp,
            excludingIDs: knownIDs
        )

        XCTAssertEqual(incremental.count, 1)
        XCTAssertEqual(incremental.first?.id, third.id)
    }

    func testLoadTransportRequestsNewerThanHonorsLimit() throws {
        let anchor = Date(timeIntervalSinceNow: -120)
        let first = createMockTransportRequest(
            timestamp: Date(timeIntervalSinceNow: -20),
            sourcePort: 55101,
            destinationPort: 53
        )
        let second = createMockTransportRequest(
            timestamp: Date(timeIntervalSinceNow: -10),
            sourcePort: 55102,
            destinationPort: 123
        )
        let third = createMockTransportRequest(
            timestamp: Date(),
            sourcePort: 55103,
            destinationPort: 161
        )

        try storage.saveTransportRequests([first, second, third])

        let incremental = try storage.loadTransportRequests(newerThan: anchor, limit: 2)

        XCTAssertEqual(incremental.count, 2)
        XCTAssertEqual(incremental.first?.id, third.id)
        XCTAssertEqual(incremental.last?.id, second.id)
    }

    func testLoadTransportRequestsNewerThanWithZeroLimitReturnsNothing() throws {
        let anchor = Date(timeIntervalSinceNow: -120)
        let first = createMockTransportRequest(
            timestamp: Date(timeIntervalSinceNow: -20),
            sourcePort: 55201,
            destinationPort: 53
        )
        let second = createMockTransportRequest(
            timestamp: Date(),
            sourcePort: 55202,
            destinationPort: 123
        )

        try storage.saveTransportRequests([first, second])

        let incremental = try storage.loadTransportRequests(newerThan: anchor, limit: 0)

        XCTAssertTrue(incremental.isEmpty)
    }

    func testClearAllTransportRequests() throws {
        try storage.saveTransportRequest(createMockTransportRequest(destinationPort: 53))
        try storage.saveTransportRequest(createMockTransportRequest(destinationPort: 161))

        var loaded = try storage.loadAllTransportRequests()
        XCTAssertEqual(loaded.count, 2)

        try storage.clearAllTransportRequests()
        loaded = try storage.loadAllTransportRequests()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Stream Storage Tests

    func testUpsertAndLoadStreamSessionAndEvents() throws {
        let sessionID = UUID()
        let session = StreamSession(
            id: sessionID,
            protocolType: .websocket,
            url: "wss://example.com/socket",
            status: .open,
            requestHeaders: [TraceHTTPHeader(key: "Upgrade", value: "websocket")],
            responseHeaders: [TraceHTTPHeader(key: "Connection", value: "Upgrade")]
        )
        try storage.upsertStreamSession(session)

        let sent = StreamEvent(
            sessionID: sessionID,
            sequence: 0,
            direction: .sent,
            kind: .message,
            payload: .text("hello", contentType: "text/plain")
        )
        try storage.appendStreamEvent(sent)

        let largeBinary = Data(repeating: 0xAB, count: 300_000)
        let received = StreamEvent(
            sessionID: sessionID,
            sequence: 0,
            direction: .received,
            kind: .message,
            payload: .binary(largeBinary, contentType: "application/octet-stream")
        )
        try storage.appendStreamEvent(received)

        let loadedSession = try storage.loadStreamSession(sessionID)
        XCTAssertNotNil(loadedSession)
        XCTAssertEqual(loadedSession?.protocolType, .websocket)
        XCTAssertEqual(loadedSession?.eventCount, 2)
        XCTAssertEqual(loadedSession?.bytesOut, 5)
        XCTAssertEqual(loadedSession?.bytesIn, largeBinary.count)

        let events = try storage.loadStreamEvents(sessionID: sessionID)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].payload.text, "hello")
        XCTAssertEqual(events[1].payload.binary?.count, largeBinary.count)
    }

    func testUpsertStreamSessionDoesNotClobberCountersOrMetadata() throws {
        let sessionID = UUID()
        try storage.upsertStreamSession(
            StreamSession(
                id: sessionID,
                protocolType: .websocket,
                url: "wss://example.com/socket",
                status: .open,
                requestHeaders: [],
                responseHeaders: [],
                metadata: ["origin": "initial"],
                eventCount: 0,
                bytesIn: 0,
                bytesOut: 0
            )
        )

        try storage.appendStreamEvent(
            StreamEvent(
                sessionID: sessionID,
                sequence: 1,
                direction: .sent,
                kind: .message,
                payload: .text("hi", contentType: "text/plain; charset=utf-8")
            )
        )

        try storage.upsertStreamSession(
            StreamSession(
                id: sessionID,
                protocolType: .websocket,
                url: "wss://example.com/socket",
                status: .open,
                requestHeaders: [],
                responseHeaders: [],
                metadata: ["other": "value"],
                eventCount: 0,
                bytesIn: 0,
                bytesOut: 0
            )
        )

        let loaded = try storage.loadStreamSession(sessionID)
        XCTAssertEqual(loaded?.eventCount, 1)
        XCTAssertEqual(loaded?.bytesOut, 2)
        XCTAssertEqual(loaded?.metadata["origin"], "initial")
        XCTAssertEqual(loaded?.metadata["other"], "value")
    }

    func testUpsertStreamSessionDoesNotRevertTerminalStatus() throws {
        let sessionID = UUID()
        let endedAt = Date(timeIntervalSince1970: 1_700_000_000)

        try storage.upsertStreamSession(
            StreamSession(
                id: sessionID,
                protocolType: .sse,
                url: "https://example.com/events",
                endTime: endedAt,
                status: .closed,
                requestHeaders: [],
                responseHeaders: []
            )
        )

        try storage.upsertStreamSession(
            StreamSession(
                id: sessionID,
                protocolType: .sse,
                url: "https://example.com/events",
                endTime: nil,
                status: .streaming,
                requestHeaders: [],
                responseHeaders: []
            )
        )

        let loaded = try storage.loadStreamSession(sessionID)
        XCTAssertEqual(loaded?.status, .closed)
        XCTAssertEqual(loaded?.endTime, endedAt)
    }

    func testLoadAllWebSocketConnectionsUsesStreamProjection() throws {
        let sessionID = UUID()
        try storage.upsertStreamSession(
            StreamSession(
                id: sessionID,
                protocolType: .websocket,
                url: "wss://echo.example/ws",
                status: .open,
                requestHeaders: [],
                responseHeaders: []
            )
        )
        try storage.appendStreamEvent(
            StreamEvent(
                sessionID: sessionID,
                sequence: 1,
                direction: .received,
                kind: .message,
                payload: .text("from stream", contentType: "text/plain"),
                metadata: ["message_type": "text"]
            )
        )

        let connections = try storage.loadAllWebSocketConnections()
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections[0].id, sessionID)
        XCTAssertEqual(connections[0].messages.count, 1)
        XCTAssertEqual(connections[0].messages[0].textPayload, "from stream")
    }

    func testLoadAllSSEConnectionsUsesStreamProjection() throws {
        let sessionID = UUID()
        try storage.upsertStreamSession(
            StreamSession(
                id: sessionID,
                protocolType: .sse,
                url: "https://example.com/events",
                status: .streaming,
                requestHeaders: [],
                responseHeaders: []
            )
        )
        try storage.appendStreamEvent(
            StreamEvent(
                sessionID: sessionID,
                sequence: 1,
                direction: .received,
                kind: .sseEvent,
                payload: .text("{\"ok\":true}", contentType: "text/event-stream"),
                metadata: ["event_id": "1", "event_type": "message", "retry": "5000"]
            )
        )

        let connections = try storage.loadAllSSEConnections()
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections[0].id, sessionID)
        XCTAssertEqual(connections[0].events.count, 1)
        XCTAssertEqual(connections[0].events[0].eventId, "1")
        XCTAssertEqual(connections[0].events[0].eventType, "message")
        XCTAssertEqual(connections[0].events[0].retry, 5000)
    }

    func testStreamReplayRecordsRoundTrip() throws {
        let sessionID = UUID()
        try storage.upsertStreamSession(
            StreamSession(
                id: sessionID,
                protocolType: .websocket,
                url: "wss://echo.example/ws",
                status: .open,
                requestHeaders: [],
                responseHeaders: []
            )
        )

        let spec = StreamReplaySpec(sessionID: sessionID, eventIDs: [UUID(), UUID()], timingMode: .step)
        let replayID = try storage.startStreamReplay(spec)
        let recordsAfterStart = try storage.loadStreamReplayRecords(sessionID: sessionID)
        XCTAssertEqual(recordsAfterStart.count, 1)
        XCTAssertEqual(recordsAfterStart[0].replayID, replayID)
        XCTAssertEqual(recordsAfterStart[0].status, .running)
        XCTAssertNil(recordsAfterStart[0].result)

        let result = StreamReplayResult(
            replayID: replayID,
            sessionID: sessionID,
            succeeded: true,
            replayedEvents: 2,
            startedAt: spec.startedAt,
            endedAt: Date()
        )
        try storage.completeStreamReplay(result)

        let recordsAfterCompletion = try storage.loadStreamReplayRecords(sessionID: sessionID)
        XCTAssertEqual(recordsAfterCompletion.count, 1)
        XCTAssertEqual(recordsAfterCompletion[0].status, .succeeded)
        XCTAssertEqual(recordsAfterCompletion[0].result?.replayedEvents, 2)
        XCTAssertEqual(recordsAfterCompletion[0].result?.succeeded, true)
    }

    // MARK: - Configuration Tests

    func testSaveAndLoadConfiguration() throws {
        let config = CaptureConfiguration(
            isEnabled: true,
            filterMode: .whitelist,
            domainFilters: ["example.com", "test.com"],
            captureHeaders: true,
            captureBody: false,
            maxBodySize: 2048,
            captureMode: .proxyOnly,
            fullTunnelDNSServers: ["1.1.1.1"],
            fullTunnelSearchDomains: ["example.local"],
            fullTunnelIPv6Enabled: false,
            fullTunnelSocks5Host: "127.0.0.1",
            fullTunnelSocks5Port: 1080,
            fullTunnelUDPForwardingMode: .split,
            dualMITMPolicy: .strictMITM,
            tcpBypassTTLSeconds: 900,
            dualMITMCircuitBreakerEnabled: false
        )

        try storage.saveConfiguration(config)

        let loaded = storage.loadConfiguration()

        XCTAssertEqual(loaded.isEnabled, config.isEnabled)
        XCTAssertEqual(loaded.filterMode, config.filterMode)
        XCTAssertEqual(loaded.domainFilters, config.domainFilters)
        XCTAssertEqual(loaded.captureHeaders, config.captureHeaders)
        XCTAssertEqual(loaded.captureBody, config.captureBody)
        XCTAssertEqual(loaded.maxBodySize, config.maxBodySize)
        XCTAssertEqual(loaded.captureMode, config.captureMode)
        XCTAssertEqual(loaded.fullTunnelDNSServers, config.fullTunnelDNSServers)
        XCTAssertEqual(loaded.fullTunnelSearchDomains, config.fullTunnelSearchDomains)
        XCTAssertEqual(loaded.fullTunnelIPv6Enabled, config.fullTunnelIPv6Enabled)
        XCTAssertEqual(loaded.fullTunnelSocks5Host, config.fullTunnelSocks5Host)
        XCTAssertEqual(loaded.fullTunnelSocks5Port, config.fullTunnelSocks5Port)
        XCTAssertEqual(loaded.fullTunnelUDPForwardingMode, config.fullTunnelUDPForwardingMode)
        XCTAssertEqual(loaded.dualMITMPolicy, config.dualMITMPolicy)
        XCTAssertEqual(loaded.tcpBypassTTLSeconds, config.tcpBypassTTLSeconds)
        XCTAssertEqual(loaded.dualMITMCircuitBreakerEnabled, config.dualMITMCircuitBreakerEnabled)
    }

    func testLoadConfigurationWithNoFile() {
        // This should return default configuration without throwing
        let config = storage.loadConfiguration()

        XCTAssertNotNil(config)
        XCTAssertEqual(config.isEnabled, CaptureConfiguration.default.isEnabled)
    }

    func testSaveAndLoadCaptureOptions() throws {
        let options = CaptureOptions(captureHeaders: false, captureBody: true, maxBodySize: 5_000_000)
        try storage.saveCaptureOptions(options)

        let loaded = storage.loadCaptureOptions()

        XCTAssertEqual(loaded.captureHeaders, options.captureHeaders)
        XCTAssertEqual(loaded.captureBody, options.captureBody)
        XCTAssertEqual(loaded.maxBodySize, options.maxBodySize)
    }

    func testSaveAndLoadBodyStorageConfig() throws {
        let config = BodyStorageConfig(inlineThreshold: 512 * 1024, truncationThreshold: 5 * 1024 * 1024, previewSize: 256 * 1024)
        try storage.saveBodyStorageConfig(config)

        let loaded = storage.loadBodyStorageConfig()

        XCTAssertEqual(loaded.inlineThreshold, config.inlineThreshold)
        XCTAssertEqual(loaded.truncationThreshold, config.truncationThreshold)
        XCTAssertEqual(loaded.previewSize, config.previewSize)
    }

    func testSaveAndLoadSamplingConfig() throws {
        let config = SamplingConfig(enabled: true, sampleRate: 0.5, strategy: .periodic)
        try storage.saveSamplingConfig(config)

        let loaded = storage.loadSamplingConfig()

        XCTAssertEqual(loaded.enabled, config.enabled)
        XCTAssertEqual(loaded.sampleRate, config.sampleRate)
        XCTAssertEqual(loaded.strategy, config.strategy)
    }

    func testSaveAndLoadMITMAllowlist() throws {
        let list = ["example.com", "*.api.example.com"]
        try storage.saveMITMAllowlist(list)

        let loaded = storage.loadMITMAllowlist()

        XCTAssertEqual(loaded, ["example.com", "*.api.example.com"])
    }

    func testReplaceMITMAutoBypassEntriesAllowsSameHostForDirectAndAlias() throws {
        let host = "203.0.113.42"
        let now = Date()
        let entries = [
            MITMAutoBypassStoredEntry(
                host: host,
                reason: "direct-host",
                createdAt: now,
                expiresAt: now.addingTimeInterval(600),
                isAlias: false
            ),
            MITMAutoBypassStoredEntry(
                host: host,
                reason: "alias-host",
                createdAt: now.addingTimeInterval(1),
                expiresAt: now.addingTimeInterval(600),
                isAlias: true
            )
        ]

        try storage.replaceMITMAutoBypassEntries(entries)
        let loaded = storage
            .loadMITMAutoBypassEntries()
            .filter { $0.host == host }

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.isAlias)), Set([false, true]))
        XCTAssertEqual(Set(loaded.map(\.reason)), Set(["direct-host", "alias-host"]))
    }

    func testSaveAndLoadThrottlingState() throws {
        let state = NetworkThrottlingState(
            enabled: true,
            condition: .custom(download: 1500, upload: 600, latency: 120, packetLoss: 0.02)
        )

        try storage.saveThrottlingState(state)

        let loaded = storage.loadThrottlingState()

        XCTAssertEqual(loaded.enabled, state.enabled)
        XCTAssertEqual(loaded.condition, state.condition)
    }

    // MARK: - Generic Storage Tests

    func testSaveAndLoadData() throws {
        let testData = "Hello, World!".data(using: .utf8)!
        let fileName = "test-file.txt"

        try storage.saveData(testData, to: fileName)

        let loaded = try storage.loadData(from: fileName)

        XCTAssertEqual(loaded, testData)
    }

    func testLoadDataFileNotFound() {
        do {
            _ = try storage.loadData(from: "nonexistent.txt")
            XCTFail("Expected error to be thrown")
        } catch let storageError as StorageError {
            XCTAssertEqual(storageError, .fileNotFound)
        } catch {
            XCTFail("Expected StorageError, got \(error)")
        }
    }

    // MARK: - Storage Stats Tests

    func testStorageStatsEmpty() {
        try? storage.clearAllRequests()

        let stats = storage.getStorageStats()

        XCTAssertEqual(stats.totalRequests, 0)
        XCTAssertEqual(stats.totalSize, 0)
    }

    func testStorageStatsWithData() throws {
        try storage.saveRequest(createMockRequest())

        let stats = storage.getStorageStats()

        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertGreaterThan(stats.totalSize, 0)
    }

    func testStorageStatsFormattedSize() {
        let stats = StorageStats(totalRequests: 5, totalSize: 1024)

        XCTAssertFalse(stats.formattedSize.isEmpty)
        XCTAssertTrue(stats.formattedSize.contains("KB") || stats.formattedSize.contains("bytes"))
    }

    // MARK: - CaptureConfiguration Tests

    func testCaptureConfigurationDefault() {
        let config = CaptureConfiguration.default

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.filterMode, .all)
        XCTAssertTrue(config.domainFilters.isEmpty)
        XCTAssertTrue(config.captureHeaders)
        XCTAssertTrue(config.captureBody)
        XCTAssertEqual(config.maxBodySize, 10 * 1024 * 1024)
    }

    func testCaptureConfigurationDefaultDualMITMSettings() {
        let config = CaptureConfiguration.default

        XCTAssertEqual(config.dualMITMPolicy, .adaptiveFailOpen)
        XCTAssertEqual(config.tcpBypassTTLSeconds, 180)
        XCTAssertTrue(config.dualMITMCircuitBreakerEnabled)
    }

    func testCaptureConfigurationNormalizedAddsDefaultDNSForFullTunnel() {
        var config = CaptureConfiguration.default
        config.captureMode = .fullTunnel
        config.fullTunnelDNSServers = []

        let normalized = config.normalized()

        XCTAssertEqual(normalized.fullTunnelDNSServers, CaptureConfiguration.defaultFullTunnelDNSServers)
    }

    func testCaptureConfigurationNormalizedAddsDefaultDNSForFullTunnelDualMITM() {
        var config = CaptureConfiguration.default
        config.captureMode = .fullTunnelDualMITM
        config.fullTunnelDNSServers = []

        let normalized = config.normalized()

        XCTAssertEqual(normalized.fullTunnelDNSServers, CaptureConfiguration.defaultFullTunnelDNSServers)
    }

    func testCaptureConfigurationNormalizedKeepsEmptyDNSForProxyOnly() {
        var config = CaptureConfiguration.default
        config.captureMode = .proxyOnly
        config.fullTunnelDNSServers = []

        let normalized = config.normalized()

        XCTAssertTrue(normalized.fullTunnelDNSServers.isEmpty)
    }

    func testCaptureConfigurationNormalizedTrimsAndDeduplicatesDNS() {
        var config = CaptureConfiguration.default
        config.captureMode = .fullTunnel
        config.fullTunnelDNSServers = [" 1.1.1.1 ", "", "8.8.8.8", "1.1.1.1"]

        let normalized = config.normalized()

        XCTAssertEqual(normalized.fullTunnelDNSServers, ["1.1.1.1", "8.8.8.8"])
    }

    func testCaptureConfigurationNormalizedClampsDualMITMTTLs() {
        var config = CaptureConfiguration.default
        config.tcpBypassTTLSeconds = 5

        let normalized = config.normalized()

        XCTAssertEqual(normalized.tcpBypassTTLSeconds, 30)
    }

    func testCaptureConfigurationDecodesLegacyJSONWithoutQUICFields() throws {
        // Old persisted JSON that contains now-removed quic* fields should
        // decode cleanly — decodeIfPresent silently ignores unknown keys.
        let json = """
        {
          "isEnabled": true,
          "filterMode": "all",
          "domainFilters": [],
          "captureHeaders": true,
          "captureBody": true,
          "maxBodySize": 4096,
          "captureMode": "fullTunnelDualMITM",
          "fullTunnelDNSServers": ["1.1.1.1"],
          "fullTunnelSearchDomains": [],
          "fullTunnelIPv6Enabled": true,
          "fullTunnelSocks5Host": "127.0.0.1",
          "fullTunnelSocks5Port": 1080,
          "fullTunnelUDPForwardingMode": "split",
          "dualMITMPolicy": "adaptiveFailOpen",
          "tcpBypassTTLSeconds": 180,
          "quicHostFailOpenSeconds": 1800,
          "quicNoProgressGraceMs": 6000,
          "quicNoProgressIdleMs": 6000,
          "quicNoProgressAbsoluteMs": 20000,
          "quicNoProgressMinClientDatagrams": 6,
          "quicAuthorityRetryAttempts": 1,
          "quicCertMaterialCacheTTLSeconds": 1800,
          "dualMITMCircuitBreakerEnabled": true
        }
        """

        let config = try JSONDecoder().decode(CaptureConfiguration.self, from: Data(json.utf8))

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.tcpBypassTTLSeconds, 180)
        XCTAssertTrue(config.dualMITMCircuitBreakerEnabled)
    }

    func testFilterModeEnum() {
        XCTAssertEqual(FilterMode.all.rawValue, "all")
        XCTAssertEqual(FilterMode.whitelist.rawValue, "whitelist")
        XCTAssertEqual(FilterMode.blacklist.rawValue, "blacklist")
    }

    func testCaptureModeBehaviorHelpers() {
        XCTAssertFalse(CaptureMode.proxyOnly.usesPacketTunnelRouting)
        XCTAssertTrue(CaptureMode.fullTunnel.usesPacketTunnelRouting)
        XCTAssertTrue(CaptureMode.fullTunnelDualMITM.usesPacketTunnelRouting)

        XCTAssertTrue(CaptureMode.proxyOnly.usesSystemHTTPProxy)
        XCTAssertTrue(CaptureMode.fullTunnel.usesSystemHTTPProxy)
        XCTAssertFalse(CaptureMode.fullTunnelDualMITM.usesSystemHTTPProxy)

        XCTAssertTrue(CaptureMode.fullTunnel.supportsCustomSocksServer)
        XCTAssertFalse(CaptureMode.fullTunnelDualMITM.supportsCustomSocksServer)

        XCTAssertFalse(CaptureMode.proxyOnly.enablesTCPTransparentMITM)
        XCTAssertFalse(CaptureMode.fullTunnel.enablesTCPTransparentMITM)
        XCTAssertTrue(CaptureMode.fullTunnelDualMITM.enablesTCPTransparentMITM)
    }

    // MARK: - StorageError Tests

    func testStorageErrorDescriptions() {
        XCTAssertNotNil(StorageError.containerNotFound.errorDescription)
        XCTAssertNotNil(StorageError.encodingFailed.errorDescription)
        XCTAssertNotNil(StorageError.decodingFailed.errorDescription)
        XCTAssertNotNil(StorageError.fileNotFound.errorDescription)
    }

    // MARK: - Helper Methods

    private func createMockRequest(
        url: String = "https://example.com",
        timestamp: Date = Date()
    ) -> NetworkRequest {
        return NetworkRequest(
            url: url,
            method: .get,
            statusCode: 200,
            timestamp: timestamp,
            duration: 0.5,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            requestBody: .empty,
            responseBody: .empty
        )
    }

    private func createMockTransportRequest(
        timestamp: Date = Date(),
        sourcePort: UInt16 = 54000,
        destinationPort: UInt16 = 53
    ) -> TransportRequest {
        TransportRequest(
            timestamp: timestamp,
            sourceIP: "192.168.1.100",
            destinationIP: "8.8.8.8",
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            transport: .udp,
            applicationProtocol: destinationPort == 53 ? .dns : .unknown,
            parserOutcome: .parsed,
            payload: .inline(Data([0x12, 0x34, 0x56])),
            payloadBytes: 3,
            ipVersion: 4,
            protocolNumber: 17,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 48,
            fragmentOffset: 0,
            moreFragments: false,
            flowKey: "udp|192.168.1.100:\(sourcePort)|8.8.8.8:\(destinationPort)"
        )
    }

    private func makeTransportBodyFile(data: Data) throws -> URL {
        guard let containerURL = storage.containerURL else {
            throw StorageError.containerNotFound
        }
        let bodiesURL = containerURL.appendingPathComponent("Bodies")
        try FileManager.default.createDirectory(at: bodiesURL, withIntermediateDirectories: true)
        let fileURL = bodiesURL.appendingPathComponent("\(UUID().uuidString).bin")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
