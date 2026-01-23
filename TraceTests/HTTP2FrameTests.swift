//
//  HTTP2FrameTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import TraceCore
@testable import TraceNetworking
@testable import TraceVPN

final class HTTP2FrameTests: XCTestCase {
    // MARK: - Frame Type Tests

    func testFrameType_AllTypes_HaveValidRawValues() {
        XCTAssertEqual(HTTP2FrameType.data.rawValue, 0x0)
        XCTAssertEqual(HTTP2FrameType.headers.rawValue, 0x1)
        XCTAssertEqual(HTTP2FrameType.priority.rawValue, 0x2)
        XCTAssertEqual(HTTP2FrameType.rstStream.rawValue, 0x3)
        XCTAssertEqual(HTTP2FrameType.settings.rawValue, 0x4)
        XCTAssertEqual(HTTP2FrameType.pushPromise.rawValue, 0x5)
        XCTAssertEqual(HTTP2FrameType.ping.rawValue, 0x6)
        XCTAssertEqual(HTTP2FrameType.goaway.rawValue, 0x7)
        XCTAssertEqual(HTTP2FrameType.windowUpdate.rawValue, 0x8)
        XCTAssertEqual(HTTP2FrameType.continuation.rawValue, 0x9)
    }

    func testFrameType_Descriptions_AreCorrect() {
        XCTAssertEqual(HTTP2FrameType.data.description, "DATA")
        XCTAssertEqual(HTTP2FrameType.headers.description, "HEADERS")
        XCTAssertEqual(HTTP2FrameType.priority.description, "PRIORITY")
        XCTAssertEqual(HTTP2FrameType.rstStream.description, "RST_STREAM")
        XCTAssertEqual(HTTP2FrameType.settings.description, "SETTINGS")
        XCTAssertEqual(HTTP2FrameType.pushPromise.description, "PUSH_PROMISE")
        XCTAssertEqual(HTTP2FrameType.ping.description, "PING")
        XCTAssertEqual(HTTP2FrameType.goaway.description, "GOAWAY")
        XCTAssertEqual(HTTP2FrameType.windowUpdate.description, "WINDOW_UPDATE")
        XCTAssertEqual(HTTP2FrameType.continuation.description, "CONTINUATION")
    }

    func testFrameType_InitFromRawValue() {
        XCTAssertEqual(HTTP2FrameType(rawValue: 0x0), .data)
        XCTAssertEqual(HTTP2FrameType(rawValue: 0x1), .headers)
        XCTAssertEqual(HTTP2FrameType(rawValue: 0x4), .settings)
        XCTAssertEqual(HTTP2FrameType(rawValue: 0x9), .continuation)
    }

    func testFrameType_InvalidRawValue_ReturnsNil() {
        XCTAssertNil(HTTP2FrameType(rawValue: 0xFF))
        XCTAssertNil(HTTP2FrameType(rawValue: 0x10))
    }

    // MARK: - Frame Flags Tests

    func testFrameFlags_EndStream() {
        let flags = HTTP2FrameFlags.endStream
        XCTAssertEqual(flags.rawValue, 0x1)
    }

    func testFrameFlags_EndHeaders() {
        let flags = HTTP2FrameFlags.endHeaders
        XCTAssertEqual(flags.rawValue, 0x4)
    }

    func testFrameFlags_Padded() {
        let flags = HTTP2FrameFlags.padded
        XCTAssertEqual(flags.rawValue, 0x8)
    }

    func testFrameFlags_Priority() {
        let flags = HTTP2FrameFlags.priority
        XCTAssertEqual(flags.rawValue, 0x20)
    }

    func testFrameFlags_Ack() {
        let flags = HTTP2FrameFlags.ack
        XCTAssertEqual(flags.rawValue, 0x1)
    }

    func testFrameFlags_CombineMultipleFlags() {
        let flags: HTTP2FrameFlags = [.endStream, .endHeaders]
        XCTAssertEqual(flags.rawValue, 0x1 | 0x4)
        XCTAssertTrue(flags.contains(.endStream))
        XCTAssertTrue(flags.contains(.endHeaders))
    }

    func testFrameFlags_CombineAllCommonFlags() {
        let flags: HTTP2FrameFlags = [.endStream, .endHeaders, .padded, .priority]
        XCTAssertTrue(flags.contains(.endStream))
        XCTAssertTrue(flags.contains(.endHeaders))
        XCTAssertTrue(flags.contains(.padded))
        XCTAssertTrue(flags.contains(.priority))
    }

    func testFrameFlags_ToStringArray_SingleFlag() {
        let flags = HTTP2FrameFlags.endStream
        let stringArray = flags.toStringArray()

        XCTAssertEqual(stringArray.count, 1)
        XCTAssertTrue(stringArray.contains("END_STREAM"))
    }

    func testFrameFlags_ToStringArray_MultipleFlags() {
        let flags: HTTP2FrameFlags = [.endStream, .endHeaders, .padded]
        let stringArray = flags.toStringArray()

        XCTAssertEqual(stringArray.count, 3)
        XCTAssertTrue(stringArray.contains("END_STREAM"))
        XCTAssertTrue(stringArray.contains("END_HEADERS"))
        XCTAssertTrue(stringArray.contains("PADDED"))
    }

    func testFrameFlags_ToStringArray_NoFlags() {
        let flags = HTTP2FrameFlags(rawValue: 0)
        let stringArray = flags.toStringArray()

        XCTAssertEqual(stringArray.count, 0)
    }

    func testFrameFlags_ToStringArray_AllFlags() {
        let flags: HTTP2FrameFlags = [.endStream, .endHeaders, .padded, .priority]
        let stringArray = flags.toStringArray()

        XCTAssertEqual(stringArray.count, 4)
    }

    // MARK: - Error Code Tests

    func testErrorCode_AllCodes_HaveCorrectRawValues() {
        XCTAssertEqual(HTTP2ErrorCode.noError.rawValue, 0x0)
        XCTAssertEqual(HTTP2ErrorCode.protocolError.rawValue, 0x1)
        XCTAssertEqual(HTTP2ErrorCode.internalError.rawValue, 0x2)
        XCTAssertEqual(HTTP2ErrorCode.flowControlError.rawValue, 0x3)
        XCTAssertEqual(HTTP2ErrorCode.settingsTimeout.rawValue, 0x4)
        XCTAssertEqual(HTTP2ErrorCode.streamClosed.rawValue, 0x5)
        XCTAssertEqual(HTTP2ErrorCode.frameSizeError.rawValue, 0x6)
        XCTAssertEqual(HTTP2ErrorCode.refusedStream.rawValue, 0x7)
        XCTAssertEqual(HTTP2ErrorCode.cancel.rawValue, 0x8)
        XCTAssertEqual(HTTP2ErrorCode.compressionError.rawValue, 0x9)
        XCTAssertEqual(HTTP2ErrorCode.connectError.rawValue, 0xA)
        XCTAssertEqual(HTTP2ErrorCode.enhanceYourCalm.rawValue, 0xB)
        XCTAssertEqual(HTTP2ErrorCode.inadequateSecurity.rawValue, 0xC)
        XCTAssertEqual(HTTP2ErrorCode.http11Required.rawValue, 0xD)
    }

    func testErrorCode_InitFromRawValue() {
        XCTAssertEqual(HTTP2ErrorCode(rawValue: 0x0), .noError)
        XCTAssertEqual(HTTP2ErrorCode(rawValue: 0x1), .protocolError)
        XCTAssertEqual(HTTP2ErrorCode(rawValue: 0x8), .cancel)
        XCTAssertEqual(HTTP2ErrorCode(rawValue: 0xD), .http11Required)
    }

    // MARK: - Settings Identifier Tests

    func testSettingIdentifier_AllIdentifiers_HaveCorrectRawValues() {
        XCTAssertEqual(HTTP2SettingIdentifier.headerTableSize.rawValue, 0x1)
        XCTAssertEqual(HTTP2SettingIdentifier.enablePush.rawValue, 0x2)
        XCTAssertEqual(HTTP2SettingIdentifier.maxConcurrentStreams.rawValue, 0x3)
        XCTAssertEqual(HTTP2SettingIdentifier.initialWindowSize.rawValue, 0x4)
        XCTAssertEqual(HTTP2SettingIdentifier.maxFrameSize.rawValue, 0x5)
        XCTAssertEqual(HTTP2SettingIdentifier.maxHeaderListSize.rawValue, 0x6)
    }

    func testSettingIdentifier_InitFromRawValue() {
        XCTAssertEqual(HTTP2SettingIdentifier(rawValue: 0x1), .headerTableSize)
        XCTAssertEqual(HTTP2SettingIdentifier(rawValue: 0x3), .maxConcurrentStreams)
        XCTAssertEqual(HTTP2SettingIdentifier(rawValue: 0x6), .maxHeaderListSize)
    }

    // MARK: - Frame Creation Tests

    func testMakeHTTP2Frame_DataFrameWithEndStream() {
        let payload = "Hello".data(using: .utf8)!
        let flags: HTTP2FrameFlags = [.endStream]
        let frame = makeHTTP2Frame(type: .data, flags: flags, streamId: 1, payload: payload)

        // Frame header is 9 bytes
        XCTAssertEqual(frame.count, 9 + payload.count)

        // Check frame type
        XCTAssertEqual(frame[3], HTTP2FrameType.data.rawValue)

        // Check flags
        XCTAssertEqual(frame[4], flags.rawValue)

        // Check length (first 3 bytes)
        let length = UInt32(frame[0]) << 16 | UInt32(frame[1]) << 8 | UInt32(frame[2])
        XCTAssertEqual(length, UInt32(payload.count))
    }

    func testMakeHTTP2Frame_HeadersFrame() {
        let payload = Data([0x82, 0x86, 0x84, 0x41]) // Example HPACK encoded headers
        let frame = makeHTTP2Frame(type: .headers, flags: .endHeaders, streamId: 1, payload: payload)

        XCTAssertEqual(frame[3], HTTP2FrameType.headers.rawValue)
        XCTAssertEqual(frame[4], HTTP2FrameFlags.endHeaders.rawValue)
    }

    func testMakeHTTP2Frame_SettingsFrame() {
        let payload = Data() // Settings ACK has empty payload
        let frame = makeHTTP2Frame(type: .settings, flags: .ack, streamId: 0, payload: payload)

        XCTAssertEqual(frame[3], HTTP2FrameType.settings.rawValue)
        XCTAssertEqual(frame[4], HTTP2FrameFlags.ack.rawValue)

        // Settings frame should be on stream 0
        let streamId = UInt32(frame[5] & 0x7F) << 24 | UInt32(frame[6]) << 16 | UInt32(frame[7]) << 8 | UInt32(frame[8])
        XCTAssertEqual(streamId, 0)
    }

    func testMakeHTTP2Frame_PingFrame() {
        let payload = Data(count: 8) // Ping payload is always 8 bytes
        let frame = makeHTTP2Frame(type: .ping, flags: [], streamId: 0, payload: payload)

        XCTAssertEqual(frame[3], HTTP2FrameType.ping.rawValue)
        XCTAssertEqual(frame.count, 9 + 8)
    }

    func testMakeHTTP2Frame_StreamIdEncoding() {
        let streamId: UInt32 = 12345
        let frame = makeHTTP2Frame(type: .data, streamId: streamId)

        // Extract stream ID from frame
        let decodedStreamId = UInt32(frame[5] & 0x7F) << 24 | UInt32(frame[6]) << 16 | UInt32(frame[7]) << 8 | UInt32(frame[8])
        XCTAssertEqual(decodedStreamId, streamId)
    }

    func testMakeHTTP2Frame_LargePayload() {
        let largePayload = Data(count: 16384) // 16KB payload
        let frame = makeHTTP2Frame(type: .data, streamId: 1, payload: largePayload)

        XCTAssertEqual(frame.count, 9 + 16384)

        // Check length encoding
        let length = UInt32(frame[0]) << 16 | UInt32(frame[1]) << 8 | UInt32(frame[2])
        XCTAssertEqual(length, 16384)
    }

    func testMakeHTTP2Frame_EmptyPayload() {
        let frame = makeHTTP2Frame(type: .settings, streamId: 0, payload: Data())

        XCTAssertEqual(frame.count, 9) // Just the header

        // Length should be 0
        let length = UInt32(frame[0]) << 16 | UInt32(frame[1]) << 8 | UInt32(frame[2])
        XCTAssertEqual(length, 0)
    }

    // MARK: - Frame Validation Tests

    func testFrameHeader_ValidStructure() {
        let frame = makeHTTP2Frame(type: .data, flags: .endStream, streamId: 1, payload: Data([1, 2, 3]))

        // Verify frame has correct structure
        XCTAssertGreaterThanOrEqual(frame.count, 9)

        // Type should be valid
        XCTAssertNotNil(HTTP2FrameType(rawValue: frame[3]))
    }

    func testFrameHeader_ReservedBitClear() {
        let streamId: UInt32 = 0x7FFFFFFF // Max stream ID (31 bits)
        let frame = makeHTTP2Frame(type: .data, streamId: streamId)

        // First bit of stream ID should be 0 (reserved)
        XCTAssertEqual(frame[5] & 0x80, 0)
    }

    // MARK: - Multiple Flags Combinations Tests

    func testFrameFlags_DataFrameWithMultipleFlags() {
        let flags: HTTP2FrameFlags = [.endStream, .padded]
        let frame = makeHTTP2Frame(type: .data, flags: flags, streamId: 1)

        XCTAssertEqual(frame[4], flags.rawValue)
        XCTAssertEqual(frame[4], 0x1 | 0x8)
    }

    func testFrameFlags_HeadersFrameWithAllFlags() {
        let flags: HTTP2FrameFlags = [.endStream, .endHeaders, .padded, .priority]
        let frame = makeHTTP2Frame(type: .headers, flags: flags, streamId: 1)

        XCTAssertEqual(frame[4], flags.rawValue)
        XCTAssertTrue(flags.contains(.endStream))
        XCTAssertTrue(flags.contains(.endHeaders))
        XCTAssertTrue(flags.contains(.padded))
        XCTAssertTrue(flags.contains(.priority))
    }

    // MARK: - Edge Cases

    func testFrameType_MaxValidRawValue() {
        let maxType = HTTP2FrameType.continuation
        XCTAssertEqual(maxType.rawValue, 0x9)
    }

    func testStreamId_MaxValue() {
        let maxStreamId: UInt32 = 0x7FFFFFFF // 2^31 - 1
        let frame = makeHTTP2Frame(type: .data, streamId: maxStreamId)

        let decoded = UInt32(frame[5] & 0x7F) << 24 | UInt32(frame[6]) << 16 | UInt32(frame[7]) << 8 | UInt32(frame[8])
        XCTAssertEqual(decoded, maxStreamId)
    }

    func testFrameLength_MaxValue() {
        // Max frame payload size is 2^24 - 1 = 16,777,215 bytes
        // We'll test a smaller but significant value
        let payloadSize = 65535 // 64KB - 1
        let payload = Data(count: payloadSize)
        let frame = makeHTTP2Frame(type: .data, streamId: 1, payload: payload)

        let length = UInt32(frame[0]) << 16 | UInt32(frame[1]) << 8 | UInt32(frame[2])
        XCTAssertEqual(length, UInt32(payloadSize))
    }

    // MARK: - Frame Size Validation Tests

    func testFrameParsing_WithinDefaultMaxSize_Succeeds() {
        // Create frame with 16KB payload (default max)
        let payload = Data(count: 16384)
        let frameData = makeHTTP2Frame(type: .data, streamId: 1, payload: payload)

        let parsedFrame = HTTP2Frame.parse(from: frameData)
        XCTAssertNotNil(parsedFrame)
        XCTAssertEqual(parsedFrame?.header.length, 16384)
    }

    func testFrameParsing_ExceedsMaxSize_ReturnsNil() {
        // Create frame with 20KB payload (exceeds default max of 16384)
        let payload = Data(count: 20000)
        let frameData = makeHTTP2Frame(type: .data, streamId: 1, payload: payload)

        let parsedFrame = HTTP2Frame.parse(from: frameData, maxFrameSize: 16384)
        XCTAssertNil(parsedFrame)
    }

    func testFrameParsing_ExactlyAtMaxSize_Succeeds() {
        // Frame exactly at max size should succeed
        let maxSize: UInt32 = 16384
        let payload = Data(count: Int(maxSize))
        let frameData = makeHTTP2Frame(type: .data, streamId: 1, payload: payload)

        let parsedFrame = HTTP2Frame.parse(from: frameData, maxFrameSize: maxSize)
        XCTAssertNotNil(parsedFrame)
    }

    func testFrameParsing_CustomMaxSize_Respected() {
        // Test with custom max size of 8KB
        let customMax: UInt32 = 8192
        let payload = Data(count: 10000)
        let frameData = makeHTTP2Frame(type: .data, streamId: 1, payload: payload)

        let parsedFrame = HTTP2Frame.parse(from: frameData, maxFrameSize: customMax)
        XCTAssertNil(parsedFrame)
    }

    func testFrameParsing_SmallFrameCustomMax_Succeeds() {
        // Small frame should succeed even with small max
        let customMax: UInt32 = 8192
        let payload = Data(count: 100)
        let frameData = makeHTTP2Frame(type: .data, streamId: 1, payload: payload)

        let parsedFrame = HTTP2Frame.parse(from: frameData, maxFrameSize: customMax)
        XCTAssertNotNil(parsedFrame)
    }

    func testFrameParsing_ValidationDisabled_AcceptsLargeFrames() {
        // With validation disabled, should accept large frames
        let largePayload = Data(count: 100000)
        let frameData = makeHTTP2Frame(type: .data, streamId: 1, payload: largePayload)

        let parsedFrame = HTTP2Frame.parse(from: frameData, maxFrameSize: 16384, validateSize: false)
        XCTAssertNotNil(parsedFrame)
        XCTAssertEqual(parsedFrame?.header.length, 100000)
    }

    func testFrameParsing_ZeroSizeFrame_Succeeds() {
        // Zero-size frames should always succeed
        let frameData = makeHTTP2Frame(type: .settings, streamId: 0, payload: Data())

        let parsedFrame = HTTP2Frame.parse(from: frameData, maxFrameSize: 16384)
        XCTAssertNotNil(parsedFrame)
        XCTAssertEqual(parsedFrame?.header.length, 0)
    }

    // MARK: - Settings Validation Tests

    func testSettings_ValidFrameSize_Succeeds() {
        var settings = HTTP2Settings()
        settings.maxFrameSize = 32768 // Valid: 32KB

        let payload = settings.serialize()
        XCTAssertNotNil(payload)
    }

    func testSettings_FrameSizeTooSmall_ReturnsNil() {
        var settings = HTTP2Settings()
        settings.maxFrameSize = 8192 // Invalid: below minimum of 16384

        let payload = settings.serialize()
        XCTAssertNil(payload)
    }

    func testSettings_FrameSizeTooLarge_ReturnsNil() {
        var settings = HTTP2Settings()
        settings.maxFrameSize = 20000000 // Invalid: above maximum of 16777215

        let payload = settings.serialize()
        XCTAssertNil(payload)
    }

    func testSettings_FrameSizeAtMinimum_Succeeds() {
        var settings = HTTP2Settings()
        settings.maxFrameSize = HTTP2Settings.minFrameSize // 16384

        let payload = settings.serialize()
        XCTAssertNotNil(payload)
    }

    func testSettings_FrameSizeAtMaximum_Succeeds() {
        var settings = HTTP2Settings()
        settings.maxFrameSize = HTTP2Settings.maxFrameSizeLimit // 16777215

        let payload = settings.serialize()
        XCTAssertNotNil(payload)
    }

    func testSettings_WindowSizeInvalid_ReturnsNil() {
        var settings = HTTP2Settings()
        settings.initialWindowSize = 0x80000000 // Invalid: above 2^31-1

        let payload = settings.serialize()
        XCTAssertNil(payload)
    }

    func testSettings_WindowSizeValid_Succeeds() {
        var settings = HTTP2Settings()
        settings.initialWindowSize = 0x7FFFFFFF // Valid: exactly 2^31-1

        let payload = settings.serialize()
        XCTAssertNotNil(payload)
    }

    func testSettings_Parse_InvalidFrameSize_ReturnsNil() {
        // Create settings payload with invalid frame size
        var data = Data()

        // Add invalid max frame size setting (below minimum)
        data.append(contentsOf: [0x00, 0x05]) // Setting ID: 5 (MAX_FRAME_SIZE)
        data.append(contentsOf: [0x00, 0x00, 0x10, 0x00]) // Value: 4096 (invalid)

        let settings = HTTP2Settings.parse(from: data)
        XCTAssertNil(settings)
    }

    func testSettings_Parse_ValidFrameSize_Succeeds() {
        // Create settings payload with valid frame size
        var data = Data()

        // Add valid max frame size setting
        data.append(contentsOf: [0x00, 0x05]) // Setting ID: 5 (MAX_FRAME_SIZE)
        data.append(contentsOf: [0x00, 0x00, 0x80, 0x00]) // Value: 32768 (valid)

        let settings = HTTP2Settings.parse(from: data)
        XCTAssertNotNil(settings)
        XCTAssertEqual(settings?.maxFrameSize, 32768)
    }
}
