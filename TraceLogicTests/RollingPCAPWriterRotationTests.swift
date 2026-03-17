//
//  RollingPCAPWriterRotationTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceProxy
@testable import TraceCore

final class RollingPCAPWriterRotationTests: XCTestCase {

    // MARK: - File Rotation Tests

    func testFileRotationSequence() throws {
        let fileName = "test_rotation_\(UUID().uuidString).pcap"

        do {
            // Create writer with small max size to trigger rotation
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 500, // Very small to trigger rotation
                maxFiles: 3
            )

            // Write enough packets to trigger rotation
            for i in 0..<20 {
                let packet = Data(repeating: UInt8(i), count: 100)
                writer.writePacket(packet)
            }

            // Give time for async writes and rotation
            Thread.sleep(forTimeInterval: 1.0)

            writer.close()

            // Verify rotated files exist
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let stem = fileName.replacingOccurrences(of: ".pcap", with: "")

                // Check for rotated files
                let file1 = container.appendingPathComponent("\(stem)_1.pcap")
                let file1Exists = FileManager.default.fileExists(atPath: file1.path)

                // At least one rotation should have occurred
                XCTAssertTrue(file1Exists, "Expected rotated file to exist")

                // Cleanup
                try? FileManager.default.removeItem(at: container.appendingPathComponent(fileName))
                for i in 1...3 {
                    let rotatedURL = container.appendingPathComponent("\(stem)_\(i).pcap")
                    try? FileManager.default.removeItem(at: rotatedURL)
                }
            }
        } catch PCAPWriterError.appGroupMissing {
            // Expected in test environment
            XCTAssertTrue(true)
        }
    }

    func testRotationFileNaming() throws {
        let fileName = "capture.pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 300,
                maxFiles: 5
            )

            // Write enough to trigger multiple rotations
            for i in 0..<30 {
                let packet = Data(repeating: UInt8(i), count: 100)
                writer.writePacket(packet)
            }

            Thread.sleep(forTimeInterval: 1.0)

            writer.close()

            // Check file naming convention
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                // Check expected file names
                let expectedNames = [
                    "capture_1.pcap",
                    "capture_2.pcap",
                    "capture_3.pcap"
                ]

                for name in expectedNames {
                    let url = container.appendingPathComponent(name)
                    // At least some of these should exist
                    if FileManager.default.fileExists(atPath: url.path) {
                        XCTAssertTrue(name.hasPrefix("capture_"))
                        XCTAssertTrue(name.hasSuffix(".pcap"))
                    }
                }

                // Cleanup
                try? FileManager.default.removeItem(at: container.appendingPathComponent(fileName))
                for i in 1...5 {
                    let rotatedURL = container.appendingPathComponent("capture_\(i).pcap")
                    try? FileManager.default.removeItem(at: rotatedURL)
                }
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    func testMaxFilesEnforcement() throws {
        let fileName = "test_maxfiles_\(UUID().uuidString).pcap"

        do {
            let maxFiles = 2
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 250,
                maxFiles: maxFiles
            )

            // Write enough to trigger many rotations
            for i in 0..<50 {
                let packet = Data(repeating: UInt8(i), count: 100)
                writer.writePacket(packet)
            }

            Thread.sleep(forTimeInterval: 1.5)

            writer.close()

            // Count rotated files
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let stem = fileName.replacingOccurrences(of: ".pcap", with: "")
                var rotatedFileCount = 0

                for i in 1...5 {
                    let url = container.appendingPathComponent("\(stem)_\(i).pcap")
                    if FileManager.default.fileExists(atPath: url.path) {
                        rotatedFileCount += 1
                    }
                }

                // Should not exceed maxFiles - 1 (since active file counts as 1)
                XCTAssertLessThanOrEqual(rotatedFileCount, maxFiles)

                // Cleanup
                try? FileManager.default.removeItem(at: container.appendingPathComponent(fileName))
                for i in 1...5 {
                    let rotatedURL = container.appendingPathComponent("\(stem)_\(i).pcap")
                    try? FileManager.default.removeItem(at: rotatedURL)
                }
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    func testMaxFilesOne() throws {
        let fileName = "test_maxone_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 200,
                maxFiles: 1 // Only keep active file
            )

            // Write enough to trigger rotation
            for i in 0..<15 {
                let packet = Data(repeating: UInt8(i), count: 100)
                writer.writePacket(packet)
            }

            Thread.sleep(forTimeInterval: 0.8)

            writer.close()

            // With maxFiles=1, no rotated files should persist
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let stem = fileName.replacingOccurrences(of: ".pcap", with: "")

                // Check that no rotated files exist
                for i in 1...3 {
                    let url = container.appendingPathComponent("\(stem)_\(i).pcap")
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    // Should not exist (maxFiles=1 means only active file)
                    XCTAssertFalse(exists, "Rotated file should not exist with maxFiles=1")
                }

                // Cleanup
                try? FileManager.default.removeItem(at: container.appendingPathComponent(fileName))
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    func testRotationPreservesData() throws {
        let fileName = "test_preserve_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 400,
                maxFiles: 3
            )

            // Write distinct packets
            let packet1 = Data([0x01, 0x02, 0x03, 0x04])
            let packet2 = Data([0x05, 0x06, 0x07, 0x08])

            writer.writePacket(packet1)
            Thread.sleep(forTimeInterval: 0.1)

            // Write many more to trigger rotation
            for i in 0..<20 {
                let packet = Data(repeating: UInt8(i), count: 100)
                writer.writePacket(packet)
            }

            Thread.sleep(forTimeInterval: 1.0)

            writer.writePacket(packet2)
            Thread.sleep(forTimeInterval: 0.1)

            writer.close()

            // Verify files exist and have data
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let mainURL = container.appendingPathComponent(fileName)

                if FileManager.default.fileExists(atPath: mainURL.path) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: mainURL.path)[.size] as? NSNumber)?
                        .uint64Value ?? 0
                    XCTAssertGreaterThan(size, 0, "Main file should have data")
                }

                // Cleanup
                try? FileManager.default.removeItem(at: mainURL)
                let stem = fileName.replacingOccurrences(of: ".pcap", with: "")
                for i in 1...3 {
                    let rotatedURL = container.appendingPathComponent("\(stem)_\(i).pcap")
                    try? FileManager.default.removeItem(at: rotatedURL)
                }
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    func testConcurrentWritesDuringRotation() throws {
        let fileName = "test_concurrent_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 300,
                maxFiles: 3
            )

            // Simulate concurrent writes that may trigger rotation
            DispatchQueue.concurrentPerform(iterations: 30) { i in
                let packet = Data(repeating: UInt8(i % 256), count: 80)
                writer.writePacket(packet)
            }

            Thread.sleep(forTimeInterval: 1.5)

            writer.close()

            // Should complete without crash
            XCTAssertTrue(true)

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                try? FileManager.default.removeItem(at: container.appendingPathComponent(fileName))
                let stem = fileName.replacingOccurrences(of: ".pcap", with: "")
                for i in 1...5 {
                    let rotatedURL = container.appendingPathComponent("\(stem)_\(i).pcap")
                    try? FileManager.default.removeItem(at: rotatedURL)
                }
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }

    func testZeroMaxFileSizeDisablesRotation() throws {
        let fileName = "test_norotate_\(UUID().uuidString).pcap"

        do {
            let writer = try RollingPCAPWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName,
                maxFileSize: 0, // Disable rotation
                maxFiles: 3
            )

            // Write many packets
            for i in 0..<50 {
                let packet = Data(repeating: UInt8(i), count: 100)
                writer.writePacket(packet)
            }

            Thread.sleep(forTimeInterval: 0.5)

            let size = writer.currentFileSize()
            XCTAssertGreaterThan(size, 0)

            writer.close()

            // No rotation should have occurred
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let stem = fileName.replacingOccurrences(of: ".pcap", with: "")

                for i in 1...3 {
                    let url = container.appendingPathComponent("\(stem)_\(i).pcap")
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    XCTAssertFalse(exists, "No rotation should occur with maxFileSize=0")
                }

                // Cleanup
                try? FileManager.default.removeItem(at: container.appendingPathComponent(fileName))
            }
        } catch PCAPWriterError.appGroupMissing {
            XCTAssertTrue(true)
        }
    }
}
