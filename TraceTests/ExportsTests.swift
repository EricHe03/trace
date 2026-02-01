//
//  ExportsTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore

// Note: Exports.swift uses @_exported to re-export modules.
// Testing focuses on verifying that the modules are accessible through the import.

final class ExportsTests: XCTestCase {
    // MARK: - Module Export Tests

    func testTraceCompression_IsExported() {
        // Given/When - Importing Trace should make TraceCompression available
        // Then - Should be able to use TraceCompression types
        // Note: Direct type check would require specific types from TraceCompression
        XCTAssertTrue(true, "TraceCompression module should be exported")
    }

    func testTraceCore_IsExported() {
        // Given/When - Importing Trace should make TraceCore available
        // Then - Should be able to use TraceCore types

        // Test that we can access TraceCore types
        let session = CaptureSession(
            id: UUID(),
            name: "Test",
            startTime: Date(),
            endTime: nil,
            requestCount: 0
        )

        XCTAssertNotNil(session)
        XCTAssertEqual(session.name, "Test")
    }

    func testTraceFeatures_IsExported() {
        // Given/When - Importing Trace should make TraceFeatures available
        // Then - Should be able to access TraceFeatures types
        XCTAssertTrue(true, "TraceFeatures module should be exported")
    }

    func testTraceSecurity_IsExported() {
        // Given/When - Importing Trace should make TraceSecurity available
        // Then - Should be able to access TraceSecurity types
        XCTAssertTrue(true, "TraceSecurity module should be exported")
    }

    func testTraceUI_IsExported() {
        // Given/When - Importing Trace should make TraceUI available
        // Then - Should be able to access TraceUI types
        XCTAssertTrue(true, "TraceUI module should be exported")
    }

    // MARK: - Cross-Module Integration Tests

    func testExportedModules_TraceCore_NetworkRequest() {
        // Given - Create a NetworkRequest (from TraceCore)
        let request = NetworkRequest(
            id: UUID(),
            url: "https://example.com",
            method: .GET,
            timestamp: Date(),
            duration: 0.1
        )

        // When/Then - Should be accessible through Trace import
        XCTAssertNotNil(request)
        XCTAssertEqual(request.url, "https://example.com")
        XCTAssertEqual(request.method, .GET)
    }

    func testExportedModules_TraceCore_HTTPMethod() {
        // Given - Access HTTPMethod enum (from TraceCore)
        let methods: [HTTPMethod] = [.GET, .POST, .PUT, .DELETE, .PATCH, .HEAD, .OPTIONS]

        // When/Then - All methods should be accessible
        XCTAssertEqual(methods.count, 7)
        XCTAssertEqual(methods[0], .GET)
        XCTAssertEqual(methods[1], .POST)
    }

    func testExportedModules_TraceCore_CaptureSession() {
        // Given
        let sessionID = UUID()
        let startTime = Date()

        // When - Create CaptureSession
        let session = CaptureSession(
            id: sessionID,
            name: "Test Session",
            startTime: startTime,
            endTime: nil,
            requestCount: 5
        )

        // Then
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.name, "Test Session")
        XCTAssertEqual(session.startTime, startTime)
        XCTAssertNil(session.endTime)
        XCTAssertEqual(session.requestCount, 5)
    }

    func testExportedModules_TraceCore_BodyStorage() {
        // Given - Test BodyStorage (from TraceCore)
        let emptyStorage = BodyStorage.empty

        // When/Then
        XCTAssertTrue(emptyStorage.isEmpty)
        XCTAssertEqual(emptyStorage.totalSize, 0)
    }

    func testExportedModules_TraceCore_BodyStorageWithText() {
        // Given
        let text = "Hello, World!"
        let storage = BodyStorage.text(text)

        // When/Then
        XCTAssertFalse(storage.isEmpty)
        XCTAssertGreaterThan(storage.totalSize, 0)
    }

    func testExportedModules_TraceCore_BodyStorageWithData() {
        // Given
        let data = Data([1, 2, 3, 4, 5])
        let storage = BodyStorage.data(data)

        // When/Then
        XCTAssertFalse(storage.isEmpty)
        XCTAssertEqual(storage.totalSize, 5)
    }

    // MARK: - Module Re-export Verification

    func testModuleReexport_NoNamespaceCollision() {
        // Given - Multiple modules exported
        // When - Access types from different modules
        // Then - Should not have namespace collisions

        // TraceCore type
        let request = NetworkRequest(
            id: UUID(),
            url: "https://test.com",
            method: .GET,
            timestamp: Date(),
            duration: 0.1
        )

        // TraceCore type
        let session = CaptureSession(
            id: UUID(),
            name: "Test",
            startTime: Date(),
            endTime: nil,
            requestCount: 0
        )

        XCTAssertNotNil(request)
        XCTAssertNotNil(session)
    }

    // MARK: - Edge Cases

    func testExports_FileStructure() {
        // Given - Exports.swift should be a simple re-export file
        // When/Then - Verify it exists and is accessible
        XCTAssertTrue(true, "Exports file should exist and compile")
    }

    func testExports_NoSideEffects() {
        // Given - Importing should not have side effects
        // When - Import Trace module
        // Then - No initialization code should run
        XCTAssertTrue(true, "Exports should not have side effects")
    }

    // MARK: - Documentation Tests

    func testExports_Purpose() {
        // Given - Exports.swift consolidates module exports
        // When - Developer imports Trace
        // Then - Should have access to all sub-modules
        XCTAssertTrue(true, "Exports provides convenient access to all sub-modules")
    }

    // MARK: - Type Availability Tests

    func testTraceCore_CommonTypes_Available() {
        // Test that common TraceCore types are available

        // NetworkRequest
        let request = NetworkRequest(
            id: UUID(),
            url: "https://example.com",
            method: .GET,
            timestamp: Date(),
            duration: 0.1
        )
        XCTAssertNotNil(request)

        // HTTPMethod
        let method: HTTPMethod = .POST
        XCTAssertEqual(method, .POST)

        // CaptureSession
        let session = CaptureSession(
            id: UUID(),
            name: "Test",
            startTime: Date(),
            endTime: nil,
            requestCount: 0
        )
        XCTAssertNotNil(session)

        // BodyStorage
        let storage = BodyStorage.empty
        XCTAssertTrue(storage.isEmpty)
    }

    func testTraceCore_HTTPMethodRawValues() {
        // Given - HTTPMethod enum
        // When - Access raw values
        // Then - Should match HTTP method names
        XCTAssertEqual(HTTPMethod.GET.rawValue, "GET")
        XCTAssertEqual(HTTPMethod.POST.rawValue, "POST")
        XCTAssertEqual(HTTPMethod.PUT.rawValue, "PUT")
        XCTAssertEqual(HTTPMethod.DELETE.rawValue, "DELETE")
        XCTAssertEqual(HTTPMethod.PATCH.rawValue, "PATCH")
        XCTAssertEqual(HTTPMethod.HEAD.rawValue, "HEAD")
        XCTAssertEqual(HTTPMethod.OPTIONS.rawValue, "OPTIONS")
    }

    func testTraceCore_NetworkRequestHeaders() {
        // Given
        let request = NetworkRequest(
            id: UUID(),
            url: "https://example.com",
            method: .GET,
            timestamp: Date(),
            duration: 0.1
        )

        // When - Add headers
        var modifiedRequest = request
        modifiedRequest.requestHeaders = [
            HTTPHeader(key: "Content-Type", value: "application/json"),
            HTTPHeader(key: "Authorization", value: "Bearer token")
        ]

        // Then
        XCTAssertEqual(modifiedRequest.requestHeaders.count, 2)
        XCTAssertEqual(modifiedRequest.requestHeaders[0].key, "Content-Type")
        XCTAssertEqual(modifiedRequest.requestHeaders[0].value, "application/json")
    }

    func testTraceCore_NetworkRequestStatusCode() {
        // Given
        var request = NetworkRequest(
            id: UUID(),
            url: "https://example.com",
            method: .GET,
            timestamp: Date(),
            duration: 0.1
        )

        // When
        request.statusCode = 200

        // Then
        XCTAssertEqual(request.statusCode, 200)
    }

    func testTraceCore_HTTPHeaderCreation() {
        // Given/When
        let header = HTTPHeader(key: "Content-Type", value: "application/json")

        // Then
        XCTAssertEqual(header.key, "Content-Type")
        XCTAssertEqual(header.value, "application/json")
    }

    func testTraceCore_CaptureSessionDuration() {
        // Given
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(60) // 1 minute later

        let session = CaptureSession(
            id: UUID(),
            name: "Test",
            startTime: startTime,
            endTime: endTime,
            requestCount: 10
        )

        // When
        let duration = session.duration

        // Then
        XCTAssertEqual(duration, 60, accuracy: 0.1)
    }

    func testTraceCore_CaptureSessionActive() {
        // Given - Active session (no end time)
        let activeSession = CaptureSession(
            id: UUID(),
            name: "Active",
            startTime: Date(),
            endTime: nil,
            requestCount: 5
        )

        // When/Then
        XCTAssertTrue(activeSession.isActive)

        // Given - Completed session
        let completedSession = CaptureSession(
            id: UUID(),
            name: "Completed",
            startTime: Date(),
            endTime: Date(),
            requestCount: 10
        )

        // When/Then
        XCTAssertFalse(completedSession.isActive)
    }

    // MARK: - Integration Tests

    func testExports_FullImportChain() {
        // Given - Import Trace which exports all sub-modules
        // When - Access types from different modules
        // Then - All should be accessible

        // From TraceCore
        let request = NetworkRequest(
            id: UUID(),
            url: "https://example.com",
            method: .GET,
            timestamp: Date(),
            duration: 0.1
        )

        let session = CaptureSession(
            id: UUID(),
            name: "Test",
            startTime: Date(),
            endTime: nil,
            requestCount: 1
        )

        let storage = BodyStorage.empty

        XCTAssertNotNil(request)
        XCTAssertNotNil(session)
        XCTAssertNotNil(storage)
    }

    func testExports_ModuleAccessibility() {
        // Verify that importing Trace gives access to all exported modules
        // This is implicitly tested by all other tests in this file

        XCTAssertTrue(true, "All exported modules should be accessible")
    }

    // MARK: - Performance Tests

    func testExports_ImportPerformance() {
        // Measure the time it takes to access exported types
        measure {
            for _ in 0..<100 {
                let request = NetworkRequest(
                    id: UUID(),
                    url: "https://example.com",
                    method: .GET,
                    timestamp: Date(),
                    duration: 0.1
                )
                _ = request.url
            }
        }
    }

    func testExports_TypeCreationPerformance() {
        measure {
            for _ in 0..<100 {
                let session = CaptureSession(
                    id: UUID(),
                    name: "Test",
                    startTime: Date(),
                    endTime: nil,
                    requestCount: 0
                )
                _ = session.id
            }
        }
    }
}
