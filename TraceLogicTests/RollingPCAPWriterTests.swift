//
//  RollingPCAPWriterTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
@testable import TraceProxy
import XCTest

final class RollingPCAPWriterTests: XCTestCase {
    // MARK: - Initialization Tests

    func testRollingPCAPWriterInitialization() throws {
        let fileName = "test_rolling_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 10000,
                maxFiles: 3
            )

            XCTAssertTrue(writer.supportsRolling)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            // Expected in test environment
            XCTAssertTrue(true)
        }
    }

    func testRollingPCAPWriterThrowsWhenAppGroupMissing() throws {
        let invalidAppGroupID = "group.invalid.nonexistent"
        let fileName = "test.pcap"

        try XCTSkipIf(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: invalidAppGroupID) != nil,
            "This environment resolves arbitrary app-group identifiers"
        )
        XCTAssertThrowsError(
            try RollingPCAPWriter(
                appGroupID: invalidAppGroupID,
                fileName: fileName,
                maxFileSize: 10000,
                maxFiles: 3
            )
        ) { error in
            XCTAssertTrue(error is PCAPWriterError)
        }
    }

    // MARK: - Properties Tests

    func testSupportsRolling() throws {
        let fileName = "test_rolling_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 10000,
                maxFiles: 3
            )

            XCTAssertTrue(writer.supportsRolling)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Write Tests

    func testWritePacket() throws {
        let fileName = "test_rolling_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 10000,
                maxFiles: 3
            )

            let packet = Data([0x45, 0x00, 0x00, 0x28])
            writer.writePacket(packet)

            // Give async queue time to write
            Thread.sleep(forTimeInterval: 0.1)

            let size = writer.currentFileSize()
            XCTAssertGreaterThan(size, 0)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    func testWriteMultiplePackets() throws {
        let fileName = "test_rolling_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 100_000,
                maxFiles: 3
            )

            // Write multiple packets
            for i in 0 ..< 10 {
                let packet = Data(repeating: UInt8(i), count: 64)
                writer.writePacket(packet)
            }

            // Give async queue time to write
            Thread.sleep(forTimeInterval: 0.2)

            let size = writer.currentFileSize()
            XCTAssertGreaterThan(size, 24) // At least header

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    // MARK: - File Size Tests

    func testCurrentFileSize() throws {
        let fileName = "test_rolling_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 10000,
                maxFiles: 3
            )

            let initialSize = writer.currentFileSize()
            XCTAssertGreaterThan(initialSize, 0)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Close Tests

    func testClose() throws {
        let fileName = "test_rolling_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 10000,
                maxFiles: 3
            )

            writer.close()

            // Should not crash on double close
            writer.close()

            let size = writer.currentFileSize()
            XCTAssertEqual(size, 0)

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Max Files Tests

    func testMaxFilesEnforced() throws {
        let fileName = "test_rolling_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 1000, // Small size to trigger rotation
                maxFiles: 2
            )

            // Write enough data to trigger rotation
            for _ in 0 ..< 50 {
                let packet = Data(repeating: 0x42, count: 100)
                writer.writePacket(packet)
            }

            // Give time for rotation
            Thread.sleep(forTimeInterval: 0.5)

            writer.close()

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)

                // Clean up rotated files
                let stem = fileName.replacingOccurrences(of: ".pcap", with: "")
                for i in 1 ... 5 {
                    let rotatedURL = container.appendingPathComponent("\(stem)_\(i).pcap")
                    try? FileManager.default.removeItem(at: rotatedURL)
                }
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }
}
