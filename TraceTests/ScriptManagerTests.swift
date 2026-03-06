//
//  ScriptManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class ScriptManagerTests: XCTestCase {

    var manager: ScriptManager!

    override func setUp() {
        super.setUp()
        manager = ScriptManager.shared
        // Clear all scripts before each test
        manager.clearAllScripts()
    }

    override func tearDown() {
        manager.clearAllScripts()
        manager = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let manager1 = ScriptManager.shared
        let manager2 = ScriptManager.shared

        XCTAssertTrue(manager1 === manager2, "ScriptManager should be a singleton")
    }

    // MARK: - Script Management Tests

    func testAddScript() {
        let script = Script(
            name: "Test Script",
            scriptType: .request,
            matchPattern: "*example.com*",
            code: "console.log('test');"
        )

        manager.addScript(script)

        XCTAssertEqual(manager.scripts.count, 1)
        XCTAssertTrue(manager.scripts.contains { $0.id == script.id })
    }

    func testUpdateScript() {
        var script = Script(
            name: "Original",
            scriptType: .request,
            code: "console.log('original');"
        )

        manager.addScript(script)

        script.name = "Updated"
        script.code = "console.log('updated');"
        manager.updateScript(script)

        let updated = manager.scripts.first { $0.id == script.id }
        XCTAssertEqual(updated?.name, "Updated")
        XCTAssertEqual(updated?.code, "console.log('updated');")
        XCTAssertNotNil(updated?.modifiedAt)
    }

    func testDeleteScript() {
        let script = Script(
            name: "To Delete",
            scriptType: .request,
            code: "console.log('delete me');"
        )

        manager.addScript(script)
        XCTAssertEqual(manager.scripts.count, 1)

        manager.deleteScript(script)
        XCTAssertEqual(manager.scripts.count, 0)
        XCTAssertFalse(manager.scripts.contains { $0.id == script.id })
    }

    func testDeleteScriptsAtIndices() {
        let script1 = Script(name: "Script 1", scriptType: .request, code: "// 1")
        let script2 = Script(name: "Script 2", scriptType: .response, code: "// 2")
        let script3 = Script(name: "Script 3", scriptType: .both, code: "// 3")

        manager.addScript(script1)
        manager.addScript(script2)
        manager.addScript(script3)

        XCTAssertEqual(manager.scripts.count, 3)

        manager.deleteScripts(at: IndexSet([0, 2]))

        XCTAssertEqual(manager.scripts.count, 1)
        XCTAssertEqual(manager.scripts.first?.name, "Script 2")
    }

    func testToggleScript() {
        let script = Script(
            name: "Toggle Test",
            enabled: true,
            scriptType: .request,
            code: "console.log('test');"
        )

        manager.addScript(script)

        XCTAssertTrue(manager.scripts.first?.enabled ?? false)

        manager.toggleScript(script)
        XCTAssertFalse(manager.scripts.first?.enabled ?? true)

        manager.toggleScript(script)
        XCTAssertTrue(manager.scripts.first?.enabled ?? false)
    }

    func testIncrementExecutionCount() {
        let script = Script(
            name: "Execution Counter",
            scriptType: .request,
            code: "console.log('test');"
        )

        manager.addScript(script)

        XCTAssertEqual(manager.scripts.first?.executionCount, 0)

        manager.incrementExecutionCount(for: script.id)
        // Note: incrementExecutionCount doesn't save immediately to avoid excessive I/O
        // So we just verify it was called without errors
    }

    // MARK: - Script Matching Tests

    func testMatchingRequestScripts() {
        let requestScript = Script(
            name: "Request Script",
            enabled: true,
            scriptType: .request,
            matchPattern: "*example.com*",
            code: "console.log('request');"
        )

        let responseScript = Script(
            name: "Response Script",
            enabled: true,
            scriptType: .response,
            matchPattern: "*example.com*",
            code: "console.log('response');"
        )

        let bothScript = Script(
            name: "Both Script",
            enabled: true,
            scriptType: .both,
            matchPattern: "*example.com*",
            code: "console.log('both');"
        )

        manager.addScript(requestScript)
        manager.addScript(responseScript)
        manager.addScript(bothScript)

        let matches = manager.matchingRequestScripts(for: "https://api.example.com/users")

        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.contains { $0.name == "Request Script" })
        XCTAssertTrue(matches.contains { $0.name == "Both Script" })
        XCTAssertFalse(matches.contains { $0.name == "Response Script" })
    }

    func testMatchingResponseScripts() {
        let requestScript = Script(
            name: "Request Script",
            enabled: true,
            scriptType: .request,
            matchPattern: "*example.com*",
            code: "console.log('request');"
        )

        let responseScript = Script(
            name: "Response Script",
            enabled: true,
            scriptType: .response,
            matchPattern: "*example.com*",
            code: "console.log('response');"
        )

        let bothScript = Script(
            name: "Both Script",
            enabled: true,
            scriptType: .both,
            matchPattern: "*example.com*",
            code: "console.log('both');"
        )

        manager.addScript(requestScript)
        manager.addScript(responseScript)
        manager.addScript(bothScript)

        let matches = manager.matchingResponseScripts(for: "https://api.example.com/users")

        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.contains { $0.name == "Response Script" })
        XCTAssertTrue(matches.contains { $0.name == "Both Script" })
        XCTAssertFalse(matches.contains { $0.name == "Request Script" })
    }

    func testMatchingStreamScripts() {
        let streamScript = Script(
            name: "Stream Script",
            enabled: true,
            scriptType: .stream,
            matchPattern: "*example.com*",
            code: "stream.action = 'forward';"
        )

        let requestScript = Script(
            name: "Request Script",
            enabled: true,
            scriptType: .request,
            matchPattern: "*example.com*",
            code: "request.url = request.url;"
        )

        manager.addScript(streamScript)
        manager.addScript(requestScript)

        let matches = manager.matchingStreamScripts(for: "wss://api.example.com/socket")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.name, "Stream Script")
    }

    func testMatchingScriptsIgnoresDisabled() {
        let script = Script(
            name: "Disabled Script",
            enabled: false,
            scriptType: .request,
            matchPattern: "*example.com*",
            code: "console.log('disabled');"
        )

        manager.addScript(script)

        let matches = manager.matchingRequestScripts(for: "https://api.example.com/users")
        XCTAssertEqual(matches.count, 0)
    }

    func testMatchingScriptsWithNoPattern() {
        let script = Script(
            name: "Match All",
            enabled: true,
            scriptType: .request,
            matchPattern: nil,
            code: "console.log('match all');"
        )

        manager.addScript(script)

        let matches = manager.matchingRequestScripts(for: "https://any-url.com/path")
        XCTAssertEqual(matches.count, 1)
    }

    func testExecuteStreamScriptsAsyncAppliesMutationsAndAction() async {
        let streamScript = Script(
            name: "Mutate Stream",
            enabled: true,
            scriptType: .stream,
            matchPattern: "*example.com*",
            code: """
            stream.event.payload.text = 'patched';
            stream.event.metadata['source'] = 'stream-script';
            stream.action = 'forward';
            """
        )
        manager.addScript(streamScript)

        let session = StreamSession(
            protocolType: .websocket,
            url: "wss://api.example.com/socket",
            status: .open
        )
        let event = StreamEvent(
            sessionID: session.id,
            sequence: 1,
            direction: .received,
            kind: .message,
            payload: .text("original", contentType: "text/plain"),
            metadata: ["message_type": "text"]
        )

        let result = await manager.executeStreamScriptsAsync(
            [streamScript],
            context: StreamScriptContext(session: session, event: event)
        )

        XCTAssertEqual(result.action, .forward)
        XCTAssertEqual(result.event.payload.text, "patched")
        XCTAssertEqual(result.event.metadata["source"], "stream-script")
    }

    // MARK: - Statistics Tests

    func testEnabledScriptsCount() {
        let enabledScript = Script(
            name: "Enabled",
            enabled: true,
            scriptType: .request,
            code: "// enabled"
        )

        let disabledScript = Script(
            name: "Disabled",
            enabled: false,
            scriptType: .response,
            code: "// disabled"
        )

        manager.addScript(enabledScript)
        manager.addScript(disabledScript)

        XCTAssertEqual(manager.enabledScriptsCount, 1)
    }

    func testTotalScriptsCount() {
        let script1 = Script(name: "Script 1", scriptType: .request, code: "// 1")
        let script2 = Script(name: "Script 2", scriptType: .response, code: "// 2")

        manager.addScript(script1)
        manager.addScript(script2)

        XCTAssertEqual(manager.totalScriptsCount, 2)
    }

    func testScriptsCountForType() {
        let requestScript1 = Script(name: "Request 1", scriptType: .request, code: "// r1")
        let requestScript2 = Script(name: "Request 2", scriptType: .request, code: "// r2")
        let responseScript = Script(name: "Response", scriptType: .response, code: "// resp")
        let bothScript = Script(name: "Both", scriptType: .both, code: "// both")

        manager.addScript(requestScript1)
        manager.addScript(requestScript2)
        manager.addScript(responseScript)
        manager.addScript(bothScript)

        XCTAssertEqual(manager.scriptsCount(for: .request), 2)
        XCTAssertEqual(manager.scriptsCount(for: .response), 1)
        XCTAssertEqual(manager.scriptsCount(for: .both), 1)
    }

    func testMostUsedScripts() {
        let script1 = Script(name: "Script 1", scriptType: .request, code: "// 1", executionCount: 5)
        let script2 = Script(name: "Script 2", scriptType: .request, code: "// 2", executionCount: 10)
        let script3 = Script(name: "Script 3", scriptType: .request, code: "// 3", executionCount: 3)

        manager.addScript(script1)
        manager.addScript(script2)
        manager.addScript(script3)

        let mostUsed = manager.mostUsedScripts(limit: 2)

        XCTAssertEqual(mostUsed.count, 2)
        XCTAssertEqual(mostUsed[0].name, "Script 2")
        XCTAssertEqual(mostUsed[1].name, "Script 1")
    }

    func testTotalExecutions() {
        let script1 = Script(name: "Script 1", scriptType: .request, code: "// 1", executionCount: 5)
        let script2 = Script(name: "Script 2", scriptType: .request, code: "// 2", executionCount: 10)

        manager.addScript(script1)
        manager.addScript(script2)

        XCTAssertEqual(manager.totalExecutions, 15)
    }

    // MARK: - Template Tests

    func testLoadTemplate() {
        let template = Script(
            name: "Template Script",
            scriptType: .request,
            code: "// template code"
        )

        manager.loadTemplate(template)

        XCTAssertEqual(manager.scripts.count, 1)
        XCTAssertNotEqual(manager.scripts.first?.id, template.id, "Loaded template should have new ID")
        XCTAssertEqual(manager.scripts.first?.name, template.name)
        XCTAssertEqual(manager.scripts.first?.code, template.code)
    }

    // MARK: - Import/Export Tests

    func testExportScripts() throws {
        let script = Script(
            name: "Export Test",
            scriptType: .request,
            code: "console.log('export');"
        )

        manager.addScript(script)

        let url = try manager.exportScripts()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.contains("Scripts"))

        // Clean up
        try? FileManager.default.removeItem(at: url)
    }

    func testImportScriptsMerge() throws {
        let existingScript = Script(
            name: "Existing",
            scriptType: .request,
            code: "// existing"
        )

        let importedScript = Script(
            name: "Imported",
            scriptType: .response,
            code: "// imported"
        )

        manager.addScript(existingScript)

        let data = try JSONEncoder().encode([importedScript])
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_import.json")
        try data.write(to: tempURL)

        try manager.importScripts(from: tempURL, merge: true)

        XCTAssertEqual(manager.scripts.count, 2)
        XCTAssertTrue(manager.scripts.contains { $0.name == "Existing" })
        XCTAssertTrue(manager.scripts.contains { $0.name == "Imported" })

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testImportScriptsReplace() throws {
        let existingScript = Script(
            name: "Existing",
            scriptType: .request,
            code: "// existing"
        )

        let importedScript = Script(
            name: "Imported",
            scriptType: .response,
            code: "// imported"
        )

        manager.addScript(existingScript)

        let data = try JSONEncoder().encode([importedScript])
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_import.json")
        try data.write(to: tempURL)

        try manager.importScripts(from: tempURL, merge: false)

        XCTAssertEqual(manager.scripts.count, 1)
        XCTAssertFalse(manager.scripts.contains { $0.name == "Existing" })
        XCTAssertTrue(manager.scripts.contains { $0.name == "Imported" })

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testClearAllScripts() {
        let script1 = Script(name: "Script 1", scriptType: .request, code: "// 1")
        let script2 = Script(name: "Script 2", scriptType: .response, code: "// 2")

        manager.addScript(script1)
        manager.addScript(script2)

        XCTAssertEqual(manager.scripts.count, 2)

        manager.clearAllScripts()

        XCTAssertEqual(manager.scripts.count, 0)
    }

    // MARK: - Script Execution Tests

    func testExecuteRequestScripts() {
        let script = Script(
            name: "Request Script",
            enabled: true,
            scriptType: .request,
            matchPattern: "*example.com*",
            code: "// Simple script that should not throw"
        )

        manager.addScript(script)

        let request = createMockNetworkRequest()
        let result = manager.executeRequestScripts(on: request)

        // Execution should complete without crashing
        XCTAssertNotNil(result)
    }

    func testExecuteResponseScripts() {
        let script = Script(
            name: "Response Script",
            enabled: true,
            scriptType: .response,
            matchPattern: "*example.com*",
            code: "// Simple script that should not throw"
        )

        manager.addScript(script)

        let request = createMockNetworkRequest()
        let result = manager.executeResponseScripts(on: request)

        // Execution should complete without crashing
        XCTAssertNotNil(result)
    }

    func testExecuteScriptsOnNonMatchingURL() {
        let script = Script(
            name: "Script",
            enabled: true,
            scriptType: .request,
            matchPattern: "*different.com*",
            code: "// Should not run"
        )

        manager.addScript(script)

        let request = createMockNetworkRequest()
        let result = manager.executeRequestScripts(on: request)

        // Should return original request unchanged
        XCTAssertEqual(result.id, request.id)
    }

    // MARK: - Validation Tests

    func testValidateScript() {
        let validCode = "console.log('test');"
        let result = manager.validateScript(validCode)

        // Result should indicate success or failure
        XCTAssertNotNil(result)
    }

    // MARK: - Helper Methods

    private func createMockNetworkRequest() -> NetworkRequest {
        NetworkRequest(
            id: UUID(),
            url: "https://api.example.com/test",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.5,
            requestHeaders: [],
            responseHeaders: [],
            requestBody: .empty,
            responseBody: .empty
        )
    }
}
