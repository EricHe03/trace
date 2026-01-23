//
//  HTTP2Connection.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Manages HTTP/2 connection state and enforces RFC 7540 rules.
public actor HTTP2Connection {
    // MARK: - Connection State

    private var localSettings: HTTP2Settings

    private var remoteSettings: HTTP2Settings

    private var pendingSettings: [HTTP2Settings] = []

    private var prefaceReceived: Bool = false

    private var isActive: Bool = true

    // MARK: - Initialization

    public init() {
        self.localSettings = HTTP2Settings()
        self.remoteSettings = HTTP2Settings()
    }

    // MARK: - Settings Management

    /// Updates local settings (typically from a received SETTINGS frame).
    func updateLocalSettings(_ settings: HTTP2Settings) {
        localSettings = settings
    }

    /// Updates remote settings and queues them for ACK.
    func updateRemoteSettings(_ settings: HTTP2Settings) {
        remoteSettings = settings
        pendingSettings.append(settings)
    }

    /// Acknowledges the oldest pending SETTINGS frame.
    func acknowledgeSettings() {
        if !pendingSettings.isEmpty {
            pendingSettings.removeFirst()
        }
    }

    /// Returns the current maximum frame size for outgoing frames.
    func getMaxFrameSize() -> UInt32 {
        remoteSettings.maxFrameSize
    }

    /// Returns the current maximum frame size for incoming frames.
    func getLocalMaxFrameSize() -> UInt32 {
        localSettings.maxFrameSize
    }

    /// Returns the current local header table size.
    func getHeaderTableSize() -> UInt32 {
        localSettings.headerTableSize
    }

    /// Returns the current remote header table size.
    func getRemoteHeaderTableSize() -> UInt32 {
        remoteSettings.headerTableSize
    }

    // MARK: - Frame Validation

    /// Validates an incoming frame against current settings.
    /// - Parameter frame: The frame to validate.
    /// - Returns: A validation result.
    func validateFrame(_ frame: HTTP2Frame) -> FrameValidationResult {
        if frame.header.length > localSettings.maxFrameSize {
            return .frameSizeError
        }

        if let frameType = frame.header.frameType {
            // Rule: Stream ID must be 0 for connection-level frames.
            let requiresZeroStreamId = [
                HTTP2FrameType.settings,
                .ping,
                .goaway
            ]

            if requiresZeroStreamId.contains(frameType) && frame.header.streamId != 0 {
                return .protocolError("Stream ID must be 0 for \(frameType.description) frame")
            }

            // Rule: Stream ID must not be 0 for stream-level frames.
            let requiresNonZeroStreamId = [
                HTTP2FrameType.data,
                .headers,
                .priority,
                .rstStream,
                .pushPromise,
                .continuation
            ]

            if requiresNonZeroStreamId.contains(frameType) && frame.header.streamId == 0 {
                return .protocolError("Stream ID must not be 0 for \(frameType.description) frame")
            }
        }

        return .valid
    }

    /// Represents the validation result for an HTTP/2 frame.
    enum FrameValidationResult {
        case valid
        case frameSizeError
        case protocolError(String)

        var isValid: Bool {
            if case .valid = self {
                return true
            }
            return false
        }
    }

    // MARK: - Connection Management

    /// Marks the connection preface as received.
    public func receivedPreface() {
        prefaceReceived = true
    }

    /// Returns whether the connection preface has been received.
    func hasPrefaceReceived() -> Bool {
        prefaceReceived
    }

    /// Closes the connection.
    func close() {
        isActive = false
    }

    /// Returns whether the connection is active.
    func active() -> Bool {
        isActive
    }

    // MARK: - Settings Helpers

    /// Creates a SETTINGS frame with current local settings.
    func createSettingsFrame() -> HTTP2Frame? {
        guard let payload = localSettings.serialize() else {
            return nil
        }

        let header = HTTP2FrameHeader(
            length: UInt32(payload.count),
            type: HTTP2FrameType.settings.rawValue,
            flags: 0,
            streamId: 0
        )

        return HTTP2Frame(header: header, payload: payload)
    }

    /// Creates a SETTINGS ACK frame.
    func createSettingsAckFrame() -> HTTP2Frame {
        let header = HTTP2FrameHeader(
            length: 0,
            type: HTTP2FrameType.settings.rawValue,
            flags: HTTP2FrameFlags.ack.rawValue,
            streamId: 0
        )

        return HTTP2Frame(header: header, payload: Data())
    }

    /// Returns a snapshot of connection statistics.
    func getStats() -> ConnectionStats {
        ConnectionStats(
            localMaxFrameSize: localSettings.maxFrameSize,
            remoteMaxFrameSize: remoteSettings.maxFrameSize,
            localHeaderTableSize: localSettings.headerTableSize,
            remoteHeaderTableSize: remoteSettings.headerTableSize,
            prefaceReceived: prefaceReceived,
            isActive: isActive,
            pendingSettingsCount: pendingSettings.count
        )
    }

    /// Represents a snapshot of HTTP/2 connection statistics.
    struct ConnectionStats {
        let localMaxFrameSize: UInt32
        let remoteMaxFrameSize: UInt32
        let localHeaderTableSize: UInt32
        let remoteHeaderTableSize: UInt32
        let prefaceReceived: Bool
        let isActive: Bool
        let pendingSettingsCount: Int
    }
}
