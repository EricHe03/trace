//
//  VPNManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
import NetworkExtension
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class VPNManagerTests: XCTestCase {

    var manager: VPNManager!

    override func setUp() {
        super.setUp()
        manager = VPNManager.shared
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let manager1 = VPNManager.shared
        let manager2 = VPNManager.shared

        XCTAssertTrue(manager1 === manager2, "VPNManager should be a singleton")
    }

    // MARK: - Simulator Detection Tests

    func testSimulatorDetection() {
        #if targetEnvironment(simulator)
        XCTAssertTrue(manager.isSimulator, "Should detect simulator environment")
        XCTAssertNotNil(manager.errorMessage, "Should have error message in simulator")
        XCTAssertTrue(manager.errorMessage?.contains("Simulator") ?? false)
        #else
        XCTAssertFalse(manager.isSimulator, "Should not detect simulator on real device")
        #endif
    }

    // MARK: - Status Helpers Tests

    func testStatusTextInvalid() {
        let text = manager.statusText
        // Status can be invalid, disconnected, or other values depending on state
        XCTAssertFalse(text.isEmpty, "Status text should not be empty")
    }

    func testStatusColorMapping() {
        // Test that status color returns valid color strings
        let color = manager.statusColor
        let validColors = ["green", "yellow", "red", "gray"]
        XCTAssertTrue(validColors.contains(color), "Status color should be one of the valid colors")
    }

    // MARK: - Error Tests

    func testVPNErrorNotConfigured() {
        let error = VPNError.notConfigured
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("not configured") ?? false)
    }

    func testVPNErrorPermissionDenied() {
        let error = VPNError.permissionDenied
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("permission denied") ?? false)
    }

    func testVPNErrorSimulatorNotSupported() {
        let error = VPNError.simulatorNotSupported
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Simulator") ?? false)
    }

    func testVPNErrorConnectionFailed() {
        let underlyingError = NSError(domain: "TestDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        let error = VPNError.connectionFailed(underlyingError)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Test error") ?? false)
    }

    // MARK: - NEVPNStatus Extension Tests

    func testNEVPNStatusDescription() {
        XCTAssertEqual(NEVPNStatus.invalid.description, "Invalid")
        XCTAssertEqual(NEVPNStatus.disconnected.description, "Disconnected")
        XCTAssertEqual(NEVPNStatus.connecting.description, "Connecting")
        XCTAssertEqual(NEVPNStatus.connected.description, "Connected")
        XCTAssertEqual(NEVPNStatus.reasserting.description, "Reasserting")
        XCTAssertEqual(NEVPNStatus.disconnecting.description, "Disconnecting")
    }

    // MARK: - Start/Stop Tests (Simulator)

    func testStartThrowsErrorInSimulator() async throws {
        #if targetEnvironment(simulator)
        do {
            try await manager.start()
            XCTFail("Should throw error in simulator")
        } catch let error as VPNError {
            XCTAssertEqual(error, VPNError.simulatorNotSupported)
        } catch {
            XCTFail("Should throw VPNError")
        }
        #else
        // On real device, we can't test without proper VPN setup
        throw XCTSkip("Test only applicable in simulator")
        #endif
    }

    // MARK: - Connection Status Tests

    func testIsConnectedInitialState() {
        // Initially should not be connected (skip check on simulator as VPN is not available)
        if manager.isSimulator {
            // On simulator, VPN is not available
            XCTAssertFalse(manager.isConnected, "Should not be connected on simulator")
        } else {
            XCTAssertFalse(manager.isConnected, "Should not be connected initially")
        }
    }

    func testStatusInitialState() {
        // Status should be one of the valid enum values
        let validStatuses: [NEVPNStatus] = [.invalid, .disconnected, .connecting, .connected, .reasserting, .disconnecting]
        XCTAssertTrue(validStatuses.contains(manager.status), "Status should be a valid NEVPNStatus")
    }
}
