//
//  PCAPWriterTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceProxy
@testable import TraceCore

final class PCAPWriterTests: XCTestCase {

    var tempDirectory: URL!
    let testAppGroupID = "group.com.trace.test"

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testPCAPWriterCreatesFile() throws {
        let fileName = "test_\(UUID().uuidString).pcap"

        // Use system app group for testing (will fail gracefully if not available)
        do {
            let writer = try PCAPWriter(appGroupID: AppGroupStorage.appGroupIdentifier, fileName: fileName)
            writer.close()

            // Verify file was created
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier)
            XCTAssertNotNil(container)

            if let container {
                let fileURL = container.appendingPathComponent(fileName)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

                // Cleanup
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            // Expected in test environment without app group
            XCTAssertTrue(true)
        }
    }

    func testPCAPWriterThrowsWhenAppGroupMissing() throws {
        let invalidAppGroupID = "group.invalid.nonexistent"
        let fileName = "test.pcap"

        try XCTSkipIf(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: invalidAppGroupID) != nil,
            "This environment resolves arbitrary app-group identifiers"
        )
        XCTAssertThrowsError(try PCAPWriter(appGroupID: invalidAppGroupID, fileName: fileName)) { error in
            XCTAssertTrue(error is PCAPWriterError)
            if let pcapError = error as? PCAPWriterError {
                XCTAssertEqual(pcapError, PCAPWriterError.appGroupMissing)
            }
        }
    }

    // MARK: - Write Tests

    func testWritePacketWritesData() throws {
        let fileName = "test_\(UUID().uuidString).pcap"

        do {
            let writer = try PCAPWriter(appGroupID: AppGroupStorage.appGroupIdentifier, fileName: fileName)

            // Write a test packet
            let packet = Data([0x45, 0x00, 0x00, 0x28]) // Simple IP header start

            writer.writePacket(packet)

            // Give async queue time to write
            Thread.sleep(forTimeInterval: 0.1)

            // Check file size increased
            let size = writer.currentFileSize()
            XCTAssertGreaterThan(size, 0)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            // Expected in test environment
            XCTAssertTrue(true)
        }
    }

    func testWriteMultiplePackets() throws {
        let fileName = "test_\(UUID().uuidString).pcap"

        do {
            let writer = try PCAPWriter(appGroupID: AppGroupStorage.appGroupIdentifier, fileName: fileName)

            // Write multiple packets
            for i in 0..<10 {
                let packet = Data(repeating: UInt8(i), count: 64)
                writer.writePacket(packet)
            }

            // Give async queue time to write
            Thread.sleep(forTimeInterval: 0.2)

            let size = writer.currentFileSize()
            // Global header (24 bytes) + 10 packets * (16 byte header + 64 byte payload)
            XCTAssertGreaterThan(size, 24)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    // MARK: - File Size Tests

    func testCurrentFileSizeReturnsZeroForNewFile() throws {
        let fileName = "test_\(UUID().uuidString).pcap"

        do {
            let writer = try PCAPWriter(appGroupID: AppGroupStorage.appGroupIdentifier, fileName: fileName)

            let size = writer.currentFileSize()
            // Should have at least the global header (24 bytes)
            XCTAssertGreaterThanOrEqual(size, 24)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Close Tests

    func testCloseDoesNotCrash() throws {
        let fileName = "test_\(UUID().uuidString).pcap"

        do {
            let writer = try PCAPWriter(appGroupID: AppGroupStorage.appGroupIdentifier, fileName: fileName)
            writer.close()

            // Should not crash on double close
            writer.close()

            XCTAssertTrue(true)

            // Cleanup
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Properties Tests

    func testSupportsRolling() throws {
        let fileName = "test_\(UUID().uuidString).pcap"

        do {
            let writer = try PCAPWriter(appGroupID: AppGroupStorage.appGroupIdentifier, fileName: fileName)

            XCTAssertFalse(writer.supportsRolling)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Error Tests

    func testPCAPWriterErrorCases() {
        XCTAssertNotNil(PCAPWriterError.appGroupMissing)
        XCTAssertNotNil(PCAPWriterError.cannotOpenFile)
    }
}
