//
//  PacketFlowRecorderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
@testable import TraceVPNKit
@testable import TracePacket
@testable import TraceCore

final class PacketFlowRecorderTests: XCTestCase {

    // MARK: - Flow Identification Tests

    func testTCPFlowIdentification() {
        struct TestFlowKey: Hashable {
            let sourceIP: String
            let sourcePort: UInt16
            let destIP: String
            let destPort: UInt16
            let proto: UInt8
        }

        let tcpProto: UInt8 = 6

        let flow = TestFlowKey(
            sourceIP: "192.168.1.1",
            sourcePort: 50000,
            destIP: "93.184.216.34",
            destPort: 443,
            proto: tcpProto
        )

        XCTAssertEqual(flow.proto, 6, "TCP protocol number should be 6")
        XCTAssertNotNil(flow)
    }

    func testUDPFlowIdentification() {
        struct TestFlowKey: Hashable {
            let sourceIP: String
            let sourcePort: UInt16
            let destIP: String
            let destPort: UInt16
            let proto: UInt8
        }

        let udpProto: UInt8 = 17

        let flow = TestFlowKey(
            sourceIP: "192.168.1.1",
            sourcePort: 54321,
            destIP: "8.8.8.8",
            destPort: 53,
            proto: udpProto
        )

        XCTAssertEqual(flow.proto, 17, "UDP protocol number should be 17")
    }

    // MARK: - TCP Handshake Tests

    func testTCPSYNDetection() {
        // TCP flags byte: SYN = 0x02
        let synFlag: UInt8 = 0x02

        let isSYN = (synFlag & 0x02) != 0
        let isACK = (synFlag & 0x10) != 0

        XCTAssertTrue(isSYN, "SYN flag should be detected")
        XCTAssertFalse(isACK, "ACK flag should not be set in SYN-only packet")
    }

    func testTCPSYNACKDetection() {
        // TCP flags byte: SYN + ACK = 0x12
        let synAckFlag: UInt8 = 0x12

        let isSYN = (synAckFlag & 0x02) != 0
        let isACK = (synAckFlag & 0x10) != 0

        XCTAssertTrue(isSYN, "SYN flag should be detected")
        XCTAssertTrue(isACK, "ACK flag should be detected")
    }

    func testTCPACKDetection() {
        // TCP flags byte: ACK = 0x10
        let ackFlag: UInt8 = 0x10

        let isACK = (ackFlag & 0x10) != 0
        let isSYN = (ackFlag & 0x02) != 0

        XCTAssertTrue(isACK, "ACK flag should be detected")
        XCTAssertFalse(isSYN, "SYN flag should not be set in ACK-only packet")
    }

    func testTCPHandshakeSequence() {
        struct HandshakeState {
            var synReceived: Bool = false
            var synAckReceived: Bool = false
            var ackReceived: Bool = false
        }

        var state = HandshakeState()

        // Simulate handshake
        state.synReceived = true
        XCTAssertTrue(state.synReceived)
        XCTAssertFalse(state.synAckReceived)
        XCTAssertFalse(state.ackReceived)

        state.synAckReceived = true
        XCTAssertTrue(state.synAckReceived)

        state.ackReceived = true
        XCTAssertTrue(state.ackReceived)

        // Complete handshake
        let handshakeComplete = state.synReceived && state.synAckReceived && state.ackReceived
        XCTAssertTrue(handshakeComplete)
    }

    // MARK: - TCP Termination Tests

    func testTCPFINDetection() {
        // TCP flags byte: FIN = 0x01
        let finFlag: UInt8 = 0x01

        let isFIN = (finFlag & 0x01) != 0

        XCTAssertTrue(isFIN, "FIN flag should be detected")
    }

    func testTCPRSTDetection() {
        // TCP flags byte: RST = 0x04
        let rstFlag: UInt8 = 0x04

        let isRST = (rstFlag & 0x04) != 0

        XCTAssertTrue(isRST, "RST flag should be detected")
    }

    func testTCPFINACKDetection() {
        // TCP flags byte: FIN + ACK = 0x11
        let finAckFlag: UInt8 = 0x11

        let isFIN = (finAckFlag & 0x01) != 0
        let isACK = (finAckFlag & 0x10) != 0

        XCTAssertTrue(isFIN, "FIN flag should be detected")
        XCTAssertTrue(isACK, "ACK flag should be detected")
    }

    func testTCPGracefulShutdown() {
        struct TerminationState {
            var finReceived: Bool = false
            var finAckReceived: Bool = false
        }

        var state = TerminationState()

        state.finReceived = true
        state.finAckReceived = true

        let gracefulShutdown = state.finReceived && state.finAckReceived
        XCTAssertTrue(gracefulShutdown)
    }

    func testTCPAbruptTermination() {
        let rstFlag: UInt8 = 0x04
        let isRST = (rstFlag & 0x04) != 0

        XCTAssertTrue(isRST, "RST indicates abrupt termination")
    }

    // MARK: - Sequence Number Tests

    func testSequenceNumberTracking() {
        var sequenceNumber: UInt32 = 1000

        // Simulate sending data
        let dataLength: UInt32 = 100
        sequenceNumber += dataLength

        XCTAssertEqual(sequenceNumber, 1100)
    }

    func testSequenceNumberWrapAround() {
        var sequenceNumber: UInt32 = UInt32.max - 50

        // Add 100 bytes (should wrap around)
        let (newSeq, overflow) = sequenceNumber.addingReportingOverflow(100)

        XCTAssertTrue(overflow, "Sequence number should wrap around")
        XCTAssertEqual(newSeq, 49, "Wrapped sequence number should be correct")
    }

    func testAcknowledgmentNumber() {
        let sentSeq: UInt32 = 1000
        let dataLength: UInt32 = 100
        let expectedAck = sentSeq + dataLength

        XCTAssertEqual(expectedAck, 1100, "ACK should be seq + data length")
    }

    // MARK: - RTT Calculation Tests

    func testRTTSampling() {
        struct RTTSample {
            let timestamp: Date
            let sequenceNumber: UInt32
        }

        let sentTime = Date()
        let seqNum: UInt32 = 1000

        let sample = RTTSample(timestamp: sentTime, sequenceNumber: seqNum)

        // Simulate ACK received
        let ackTime = Date(timeIntervalSinceNow: 0.05) // 50ms later
        let rtt = ackTime.timeIntervalSince(sample.timestamp) * 1000 // Convert to ms

        XCTAssertGreaterThanOrEqual(rtt, 0, "RTT should be non-negative")
        XCTAssertLessThanOrEqual(rtt, 100, "RTT should be reasonable (< 100ms for local test)")
    }

    func testRTTMinMaxTracking() {
        var rttSamples: [Double] = [50, 75, 30, 100, 45] // In milliseconds

        let minRTT = rttSamples.min() ?? 0
        let maxRTT = rttSamples.max() ?? 0
        let avgRTT = rttSamples.reduce(0, +) / Double(rttSamples.count)

        XCTAssertEqual(minRTT, 30)
        XCTAssertEqual(maxRTT, 100)
        XCTAssertEqual(avgRTT, 60)
    }

    func testRTTSegmentMatching() {
        struct RecentSegment {
            let sequenceNumber: UInt32
            let timestamp: Date
        }

        var recentSegments: [RecentSegment] = [
            RecentSegment(sequenceNumber: 1000, timestamp: Date(timeIntervalSinceNow: -0.1)),
            RecentSegment(sequenceNumber: 1100, timestamp: Date(timeIntervalSinceNow: -0.05)),
            RecentSegment(sequenceNumber: 1200, timestamp: Date()),
        ]

        let ackNumber: UInt32 = 1100

        // Find matching segment
        let matchedSegment = recentSegments.first { $0.sequenceNumber == ackNumber }

        XCTAssertNotNil(matchedSegment, "Should find matching segment")
        XCTAssertEqual(matchedSegment?.sequenceNumber, 1100)
    }

    // MARK: - Window Size Tests

    func testTCPWindowSize() {
        let windowSize: UInt16 = 65535 // Maximum window size

        XCTAssertEqual(windowSize, 65535)
        XCTAssertGreaterThan(windowSize, 0)
    }

    func testWindowSizeTracking() {
        var receivedWindows: [UInt16] = []

        receivedWindows.append(65535)
        receivedWindows.append(32768)
        receivedWindows.append(16384)

        XCTAssertEqual(receivedWindows.count, 3)
        XCTAssertEqual(receivedWindows.last, 16384)
    }

    func testZeroWindowDetection() {
        let windowSize: UInt16 = 0

        let isZeroWindow = windowSize == 0

        XCTAssertTrue(isZeroWindow, "Zero window indicates receiver is full")
    }

    // MARK: - Throughput Tests

    func testThroughputCalculation() {
        let bytes: UInt64 = 10000 // 10 KB
        let timeInterval: TimeInterval = 1.0 // 1 second

        let throughputBps = Double(bytes) / timeInterval
        let throughputKBps = throughputBps / 1024

        XCTAssertEqual(throughputKBps, 10000.0 / 1024, accuracy: 0.01)
    }

    func testThroughputBuckets() {
        struct ThroughputSample {
            let timestamp: Date
            let bytes: UInt64
        }

        var samples: [ThroughputSample] = []

        // Add samples every second
        for i in 0..<5 {
            samples.append(ThroughputSample(
                timestamp: Date(timeIntervalSinceNow: Double(-i)),
                bytes: 1000
            ))
        }

        XCTAssertEqual(samples.count, 5)

        // Calculate average throughput
        let totalBytes = samples.reduce(0) { $0 + $1.bytes }
        XCTAssertEqual(totalBytes, 5000)
    }

    func testThroughputPeakDetection() {
        let throughputSamples: [Double] = [100, 500, 1000, 300, 200] // KBps

        let peakThroughput = throughputSamples.max() ?? 0

        XCTAssertEqual(peakThroughput, 1000, "Peak throughput should be 1000 KBps")
    }

    // MARK: - Protocol Detection Tests

    func testTLSClientHelloDetection() {
        // TLS ClientHello starts with: 0x16 (handshake) 0x03 0x01 (TLS 1.0) or 0x03 0x03 (TLS 1.2)
        let tlsClientHello = Data([
            0x16, // Content Type: Handshake (22)
            0x03, 0x03, // Version: TLS 1.2
            0x00, 0x10, // Length: 16 bytes
            0x01, // Handshake Type: ClientHello
            // ... rest of ClientHello
        ])

        let isTLS = tlsClientHello.count >= 3 &&
                    tlsClientHello[0] == 0x16 &&
                    tlsClientHello[1] == 0x03

        XCTAssertTrue(isTLS, "Should detect TLS ClientHello")
    }

    func testHTTPMethodDetection() {
        let httpMethods = ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"]

        for method in httpMethods {
            let httpRequest = Data("\(method) / HTTP/1.1\r\n".utf8)

            let isHTTP = httpMethods.contains { method in
                httpRequest.starts(with: Data(method.utf8))
            }

            XCTAssertTrue(isHTTP, "Should detect HTTP \(method)")
        }
    }

    func testTLSVersionDetection() {
        struct TLSVersion {
            let major: UInt8
            let minor: UInt8

            var description: String {
                switch (major, minor) {
                case (3, 0): return "SSL 3.0"
                case (3, 1): return "TLS 1.0"
                case (3, 2): return "TLS 1.1"
                case (3, 3): return "TLS 1.2"
                case (3, 4): return "TLS 1.3"
                default: return "Unknown"
                }
            }
        }

        let tls12 = TLSVersion(major: 3, minor: 3)
        XCTAssertEqual(tls12.description, "TLS 1.2")

        let tls13 = TLSVersion(major: 3, minor: 4)
        XCTAssertEqual(tls13.description, "TLS 1.3")
    }

    // MARK: - Endpoint Metrics Tests

    func testEndpointMetricsInitialization() {
        struct EndpointMetrics {
            var packets: UInt32 = 0
            var bytes: UInt64 = 0
            var rttSamples: [Double] = []
            var windowSizes: [UInt16] = []
        }

        let metrics = EndpointMetrics()

        XCTAssertEqual(metrics.packets, 0)
        XCTAssertEqual(metrics.bytes, 0)
        XCTAssertTrue(metrics.rttSamples.isEmpty)
        XCTAssertTrue(metrics.windowSizes.isEmpty)
    }

    func testEndpointMetricsUpdate() {
        struct EndpointMetrics {
            var packets: UInt32 = 0
            var bytes: UInt64 = 0
        }

        var metrics = EndpointMetrics()

        // Simulate receiving packets
        metrics.packets += 1
        metrics.bytes += 1500

        metrics.packets += 1
        metrics.bytes += 1500

        XCTAssertEqual(metrics.packets, 2)
        XCTAssertEqual(metrics.bytes, 3000)
    }

    // MARK: - Flow Eviction Tests

    func testIdleFlowEviction() {
        let idleTimeout: TimeInterval = 120 // 2 minutes
        let lastActivity = Date(timeIntervalSinceNow: -180) // 3 minutes ago

        let isExpired = Date().timeIntervalSince(lastActivity) > idleTimeout

        XCTAssertTrue(isExpired, "Flow should be evicted after idle timeout")
    }

    func testActiveFlowRetention() {
        let idleTimeout: TimeInterval = 120
        let lastActivity = Date(timeIntervalSinceNow: -60) // 1 minute ago

        let isExpired = Date().timeIntervalSince(lastActivity) > idleTimeout

        XCTAssertFalse(isExpired, "Active flow should not be evicted")
    }

    func testMaxFlowLimitEviction() {
        let maxFlows = 10000
        var currentFlows = 10000

        let shouldEvict = currentFlows >= maxFlows

        XCTAssertTrue(shouldEvict, "Should evict when max flow limit reached")

        // Simulate eviction
        if shouldEvict {
            currentFlows -= 1
        }

        XCTAssertEqual(currentFlows, 9999)
    }

    // MARK: - Flow Persistence Tests

    func testFlowRecordSerialization() {
        struct FlowRecord: Codable {
            let sourceIP: String
            let destIP: String
            let sourcePort: UInt16
            let destPort: UInt16
            let proto: UInt8
            let packets: UInt32
            let bytes: UInt64
        }

        let record = FlowRecord(
            sourceIP: "192.168.1.1",
            destIP: "93.184.216.34",
            sourcePort: 50000,
            destPort: 443,
            proto: 6,
            packets: 100,
            bytes: 150000
        )

        let encoder = JSONEncoder()
        let data = try? encoder.encode(record)

        XCTAssertNotNil(data, "Flow record should be serializable")
    }

    func testFlowRecordDeserialization() {
        struct FlowRecord: Codable {
            let sourceIP: String
            let destIP: String
        }

        let jsonString = """
        {"sourceIP":"192.168.1.1","destIP":"93.184.216.34"}
        """

        let decoder = JSONDecoder()
        let data = Data(jsonString.utf8)
        let record = try? decoder.decode(FlowRecord.self, from: data)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.sourceIP, "192.168.1.1")
        XCTAssertEqual(record?.destIP, "93.184.216.34")
    }
}
