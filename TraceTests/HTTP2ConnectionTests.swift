//
//  HTTP2ConnectionTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceNetworking

final class HTTP2ConnectionTests: XCTestCase {

    var connection: HTTP2Connection!

    override func setUp() async throws {
        try await super.setUp()
        connection = HTTP2Connection()
    }

    override func tearDown() async throws {
        connection = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() async {
        let conn = HTTP2Connection()
        let stats = await conn.getStats()

        XCTAssertEqual(stats.localMaxFrameSize, 16384) // Default per RFC 7540
        XCTAssertEqual(stats.remoteMaxFrameSize, 16384)
        XCTAssertFalse(stats.prefaceReceived)
        XCTAssertTrue(stats.isActive)
        XCTAssertEqual(stats.pendingSettingsCount, 0)
    }

    // MARK: - Settings Management Tests

    func testUpdateLocalSettings() async {
        var settings = HTTP2Settings()
        settings.maxFrameSize = 32768

        await connection.updateLocalSettings(settings)

        let maxFrameSize = await connection.getLocalMaxFrameSize()
        XCTAssertEqual(maxFrameSize, 32768)
    }

    func testUpdateRemoteSettings() async {
        var settings = HTTP2Settings()
        settings.maxFrameSize = 32768

        await connection.updateRemoteSettings(settings)

        let maxFrameSize = await connection.getMaxFrameSize()
        XCTAssertEqual(maxFrameSize, 32768)

        let stats = await connection.getStats()
        XCTAssertEqual(stats.pendingSettingsCount, 1)
    }

    func testAcknowledgeSettings() async {
        var settings = HTTP2Settings()
        settings.maxFrameSize = 32768

        await connection.updateRemoteSettings(settings)

        var stats = await connection.getStats()
        XCTAssertEqual(stats.pendingSettingsCount, 1)

        await connection.acknowledgeSettings()

        stats = await connection.getStats()
        XCTAssertEqual(stats.pendingSettingsCount, 0)
    }

    func testMultiplePendingSettings() async {
        for i in 1...3 {
            var settings = HTTP2Settings()
            settings.maxFrameSize = UInt32(16384 * i)
            await connection.updateRemoteSettings(settings)
        }

        var stats = await connection.getStats()
        XCTAssertEqual(stats.pendingSettingsCount, 3)

        await connection.acknowledgeSettings()
        stats = await connection.getStats()
        XCTAssertEqual(stats.pendingSettingsCount, 2)

        await connection.acknowledgeSettings()
        stats = await connection.getStats()
        XCTAssertEqual(stats.pendingSettingsCount, 1)
    }

    // MARK: - Header Table Size Tests

    func testGetHeaderTableSize() async {
        let size = await connection.getHeaderTableSize()
        XCTAssertEqual(size, 4096) // Default per RFC 7540
    }

    func testGetRemoteHeaderTableSize() async {
        let size = await connection.getRemoteHeaderTableSize()
        XCTAssertEqual(size, 4096)
    }

    func testUpdateHeaderTableSize() async {
        var settings = HTTP2Settings()
        settings.headerTableSize = 8192

        await connection.updateLocalSettings(settings)

        let size = await connection.getHeaderTableSize()
        XCTAssertEqual(size, 8192)
    }

    // MARK: - Frame Validation Tests

    func testValidateValidDataFrame() async {
        let header = HTTP2FrameHeader(length: 100, type: HTTP2FrameType.data.rawValue, flags: 0, streamId: 1)
        let frame = HTTP2Frame(header: header, payload: Data(repeating: 0, count: 100))

        let result = await connection.validateFrame(frame)
        XCTAssertTrue(result.isValid)
    }

    func testValidateFrameSizeError() async {
        let header = HTTP2FrameHeader(length: 100000, type: HTTP2FrameType.data.rawValue, flags: 0, streamId: 1)
        let frame = HTTP2Frame(header: header, payload: Data())

        let result = await connection.validateFrame(frame)
        if case .frameSizeError = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected frameSizeError")
        }
    }

    func testValidateSettingsFrameWithZeroStreamId() async {
        let header = HTTP2FrameHeader(length: 0, type: HTTP2FrameType.settings.rawValue, flags: 0, streamId: 0)
        let frame = HTTP2Frame(header: header, payload: Data())

        let result = await connection.validateFrame(frame)
        XCTAssertTrue(result.isValid)
    }

    func testValidateSettingsFrameWithNonZeroStreamId() async {
        let header = HTTP2FrameHeader(length: 0, type: HTTP2FrameType.settings.rawValue, flags: 0, streamId: 1)
        let frame = HTTP2Frame(header: header, payload: Data())

        let result = await connection.validateFrame(frame)
        if case .protocolError = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected protocolError")
        }
    }

    func testValidatePingFrameWithZeroStreamId() async {
        let header = HTTP2FrameHeader(length: 8, type: HTTP2FrameType.ping.rawValue, flags: 0, streamId: 0)
        let frame = HTTP2Frame(header: header, payload: Data(repeating: 0, count: 8))

        let result = await connection.validateFrame(frame)
        XCTAssertTrue(result.isValid)
    }

    func testValidatePingFrameWithNonZeroStreamId() async {
        let header = HTTP2FrameHeader(length: 8, type: HTTP2FrameType.ping.rawValue, flags: 0, streamId: 1)
        let frame = HTTP2Frame(header: header, payload: Data(repeating: 0, count: 8))

        let result = await connection.validateFrame(frame)
        if case .protocolError = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected protocolError")
        }
    }

    func testValidateDataFrameWithNonZeroStreamId() async {
        let header = HTTP2FrameHeader(length: 100, type: HTTP2FrameType.data.rawValue, flags: 0, streamId: 1)
        let frame = HTTP2Frame(header: header, payload: Data(repeating: 0, count: 100))

        let result = await connection.validateFrame(frame)
        XCTAssertTrue(result.isValid)
    }

    func testValidateDataFrameWithZeroStreamId() async {
        let header = HTTP2FrameHeader(length: 100, type: HTTP2FrameType.data.rawValue, flags: 0, streamId: 0)
        let frame = HTTP2Frame(header: header, payload: Data(repeating: 0, count: 100))

        let result = await connection.validateFrame(frame)
        if case .protocolError = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected protocolError")
        }
    }

    func testValidateHeadersFrameWithNonZeroStreamId() async {
        let header = HTTP2FrameHeader(length: 50, type: HTTP2FrameType.headers.rawValue, flags: 0, streamId: 1)
        let frame = HTTP2Frame(header: header, payload: Data(repeating: 0, count: 50))

        let result = await connection.validateFrame(frame)
        XCTAssertTrue(result.isValid)
    }

    func testValidateGoAwayFrameWithZeroStreamId() async {
        let header = HTTP2FrameHeader(length: 8, type: HTTP2FrameType.goaway.rawValue, flags: 0, streamId: 0)
        let frame = HTTP2Frame(header: header, payload: Data(repeating: 0, count: 8))

        let result = await connection.validateFrame(frame)
        XCTAssertTrue(result.isValid)
    }

    // MARK: - Connection Preface Tests

    func testPrefaceNotReceivedInitially() async {
        let received = await connection.hasPrefaceReceived()
        XCTAssertFalse(received)
    }

    func testMarkPrefaceReceived() async {
        await connection.receivedPreface()

        let received = await connection.hasPrefaceReceived()
        XCTAssertTrue(received)
    }

    // MARK: - Connection Management Tests

    func testConnectionActiveInitially() async {
        let active = await connection.active()
        XCTAssertTrue(active)
    }

    func testCloseConnection() async {
        await connection.close()

        let active = await connection.active()
        XCTAssertFalse(active)
    }

    // MARK: - Settings Frame Creation Tests

    func testCreateSettingsFrame() async {
        let frame = await connection.createSettingsFrame()

        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.header.type, HTTP2FrameType.settings.rawValue)
        XCTAssertEqual(frame?.header.streamId, 0)
        XCTAssertEqual(frame?.header.flags, 0)
    }

    func testCreateSettingsAckFrame() async {
        let frame = await connection.createSettingsAckFrame()

        XCTAssertEqual(frame.header.type, HTTP2FrameType.settings.rawValue)
        XCTAssertEqual(frame.header.streamId, 0)
        XCTAssertEqual(frame.header.flags, HTTP2FrameFlags.ack.rawValue)
        XCTAssertEqual(frame.header.length, 0)
        XCTAssertEqual(frame.payload.count, 0)
    }

    // MARK: - Connection Stats Tests

    func testGetStats() async {
        let stats = await connection.getStats()

        XCTAssertEqual(stats.localMaxFrameSize, 16384)
        XCTAssertEqual(stats.remoteMaxFrameSize, 16384)
        XCTAssertEqual(stats.localHeaderTableSize, 4096)
        XCTAssertEqual(stats.remoteHeaderTableSize, 4096)
        XCTAssertFalse(stats.prefaceReceived)
        XCTAssertTrue(stats.isActive)
        XCTAssertEqual(stats.pendingSettingsCount, 0)
    }

    func testGetStatsAfterChanges() async {
        var settings = HTTP2Settings()
        settings.maxFrameSize = 32768
        settings.headerTableSize = 8192

        await connection.updateLocalSettings(settings)
        await connection.updateRemoteSettings(settings)
        await connection.receivedPreface()

        let stats = await connection.getStats()

        XCTAssertEqual(stats.localMaxFrameSize, 32768)
        XCTAssertEqual(stats.remoteMaxFrameSize, 32768)
        XCTAssertEqual(stats.localHeaderTableSize, 8192)
        XCTAssertEqual(stats.remoteHeaderTableSize, 8192)
        XCTAssertTrue(stats.prefaceReceived)
        XCTAssertTrue(stats.isActive)
        XCTAssertEqual(stats.pendingSettingsCount, 1)
    }

    // MARK: - Edge Cases

    func testMultipleSettingsUpdates() async {
        for i in 1...10 {
            var settings = HTTP2Settings()
            settings.maxFrameSize = UInt32(16384 + i * 1024)
            await connection.updateRemoteSettings(settings)
        }

        let maxFrameSize = await connection.getMaxFrameSize()
        XCTAssertEqual(maxFrameSize, UInt32(16384 + 10 * 1024))
    }

    func testAcknowledgeMoreSettingsThanPending() async {
        await connection.acknowledgeSettings()
        await connection.acknowledgeSettings()

        let stats = await connection.getStats()
        XCTAssertEqual(stats.pendingSettingsCount, 0)
    }

    func testValidateUnknownFrameType() async {
        let header = HTTP2FrameHeader(length: 0, type: 0xFF, flags: 0, streamId: 1)
        let frame = HTTP2Frame(header: header, payload: Data())

        let result = await connection.validateFrame(frame)
        XCTAssertTrue(result.isValid) // Unknown frame types should be ignored
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentSettingsUpdates() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    var settings = HTTP2Settings()
                    settings.maxFrameSize = UInt32(16384 + i * 1024)
                    await self.connection.updateRemoteSettings(settings)
                }
            }
        }

        let stats = await connection.getStats()
        XCTAssertGreaterThan(stats.pendingSettingsCount, 0)
    }

    func testConcurrentFrameValidation() async {
        await withTaskGroup(of: Bool.self) { group in
            for i in 1...10 {
                group.addTask {
                    let header = HTTP2FrameHeader(length: 100, type: HTTP2FrameType.data.rawValue, flags: 0, streamId: UInt32(i))
                    let frame = HTTP2Frame(header: header, payload: Data(repeating: 0, count: 100))
                    let result = await self.connection.validateFrame(frame)
                    return result.isValid
                }
            }

            var allValid = true
            for await isValid in group {
                allValid = allValid && isValid
            }
            XCTAssertTrue(allValid)
        }
    }

    // MARK: - Frame Validation Result Tests

    func testFrameValidationResultIsValid() {
        let result = HTTP2Connection.FrameValidationResult.valid
        XCTAssertTrue(result.isValid)
    }

    func testFrameValidationResultFrameSizeError() {
        let result = HTTP2Connection.FrameValidationResult.frameSizeError
        XCTAssertFalse(result.isValid)
    }

    func testFrameValidationResultProtocolError() {
        let result = HTTP2Connection.FrameValidationResult.protocolError("Test error")
        XCTAssertFalse(result.isValid)
    }

    // MARK: - Integration Tests

    func testCompleteSettingsExchange() async {
        // Create and send initial settings
        let initialFrame = await connection.createSettingsFrame()
        XCTAssertNotNil(initialFrame)

        // Receive remote settings
        var remoteSettings = HTTP2Settings()
        remoteSettings.maxFrameSize = 32768
        await connection.updateRemoteSettings(remoteSettings)

        // Send ACK
        let ackFrame = await connection.createSettingsAckFrame()
        XCTAssertEqual(ackFrame.header.flags, HTTP2FrameFlags.ack.rawValue)

        // Acknowledge pending settings
        await connection.acknowledgeSettings()

        let stats = await connection.getStats()
        XCTAssertEqual(stats.remoteMaxFrameSize, 32768)
        XCTAssertEqual(stats.pendingSettingsCount, 0)
    }

    func testConnectionLifecycle() async {
        // Connection starts active
        var isActive = await connection.active()
        XCTAssertTrue(isActive)

        // Receive preface
        await connection.receivedPreface()
        var prefaceReceived = await connection.hasPrefaceReceived()
        XCTAssertTrue(prefaceReceived)

        // Exchange settings
        var settings = HTTP2Settings()
        settings.maxFrameSize = 32768
        await connection.updateRemoteSettings(settings)
        await connection.acknowledgeSettings()

        // Validate some frames
        let dataHeader = HTTP2FrameHeader(length: 100, type: HTTP2FrameType.data.rawValue, flags: 0, streamId: 1)
        let dataFrame = HTTP2Frame(header: dataHeader, payload: Data(repeating: 0, count: 100))
        let dataResult = await connection.validateFrame(dataFrame)
        XCTAssertTrue(dataResult.isValid)

        // Close connection
        await connection.close()
        isActive = await connection.active()
        XCTAssertFalse(isActive)
    }
}
