//
//  BreakpointPresetTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class BreakpointPresetTests: XCTestCase {

    // MARK: - Initializer Tests

    func testInitWithDefaultId() {
        let config = createMockConfiguration()
        let preset = BreakpointPreset(name: "Test Preset", configuration: config)

        XCTAssertNotNil(preset.id)
        XCTAssertEqual(preset.name, "Test Preset")
        XCTAssertEqual(preset.configuration, config)
    }

    func testInitWithCustomId() {
        let customId = UUID()
        let config = createMockConfiguration()
        let preset = BreakpointPreset(id: customId, name: "Custom ID Preset", configuration: config)

        XCTAssertEqual(preset.id, customId)
        XCTAssertEqual(preset.name, "Custom ID Preset")
        XCTAssertEqual(preset.configuration, config)
    }

    func testInitWithEmptyName() {
        let config = createMockConfiguration()
        let preset = BreakpointPreset(name: "", configuration: config)

        XCTAssertTrue(preset.name.isEmpty)
        XCTAssertEqual(preset.configuration, config)
    }

    // MARK: - Codable Tests

    func testCodableRoundTrip() throws {
        let config = createMockConfiguration()
        let preset = BreakpointPreset(
            id: UUID(),
            name: "API Breakpoint",
            configuration: config
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(preset)

        let decoder = JSONDecoder()
        let decodedPreset = try decoder.decode(BreakpointPreset.self, from: data)

        XCTAssertEqual(preset.id, decodedPreset.id)
        XCTAssertEqual(preset.name, decodedPreset.name)
        XCTAssertEqual(preset.configuration, decodedPreset.configuration)
    }

    func testCodableWithComplexConfiguration() throws {
        let condition = BreakpointCondition(
            type: .headerEquals,
            parameter: "Content-Type",
            value: "application/json"
        )
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .both,
            matchType: .regex,
            matchPattern: ".*api/v1/.*",
            methods: [.get, .post, .put],
            statusCodes: [200, 201, 400, 404],
            executionMode: .editOnce,
            maxHits: 10,
            conditions: [condition]
        )

        let preset = BreakpointPreset(name: "Complex Preset", configuration: config)

        let encoder = JSONEncoder()
        let data = try encoder.encode(preset)

        let decoder = JSONDecoder()
        let decodedPreset = try decoder.decode(BreakpointPreset.self, from: data)

        XCTAssertEqual(preset.id, decodedPreset.id)
        XCTAssertEqual(preset.name, decodedPreset.name)
        XCTAssertEqual(preset.configuration.enabled, decodedPreset.configuration.enabled)
        XCTAssertEqual(preset.configuration.breakpointType, decodedPreset.configuration.breakpointType)
        XCTAssertEqual(preset.configuration.matchType, decodedPreset.configuration.matchType)
        XCTAssertEqual(preset.configuration.matchPattern, decodedPreset.configuration.matchPattern)
        XCTAssertEqual(preset.configuration.methods, decodedPreset.configuration.methods)
        XCTAssertEqual(preset.configuration.statusCodes, decodedPreset.configuration.statusCodes)
        XCTAssertEqual(preset.configuration.executionMode, decodedPreset.configuration.executionMode)
        XCTAssertEqual(preset.configuration.maxHits, decodedPreset.configuration.maxHits)
        XCTAssertEqual(preset.configuration.conditions.count, decodedPreset.configuration.conditions.count)
    }

    func testCodableWithNilOptionals() throws {
        let config = BreakpointConfiguration(
            enabled: false,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: nil,
            methods: [],
            statusCodes: [],
            executionMode: .pause,
            maxHits: nil,
            conditions: []
        )

        let preset = BreakpointPreset(name: "Minimal Preset", configuration: config)

        let encoder = JSONEncoder()
        let data = try encoder.encode(preset)

        let decoder = JSONDecoder()
        let decodedPreset = try decoder.decode(BreakpointPreset.self, from: data)

        XCTAssertEqual(preset.id, decodedPreset.id)
        XCTAssertEqual(preset.name, decodedPreset.name)
        XCTAssertNil(decodedPreset.configuration.matchPattern)
        XCTAssertNil(decodedPreset.configuration.maxHits)
        XCTAssertTrue(decodedPreset.configuration.methods.isEmpty)
        XCTAssertTrue(decodedPreset.configuration.statusCodes.isEmpty)
        XCTAssertTrue(decodedPreset.configuration.conditions.isEmpty)
    }

    // MARK: - Equatable Tests

    func testEquatableWithEqualPresets() {
        let id = UUID()
        let config = createMockConfiguration()
        let preset1 = BreakpointPreset(id: id, name: "Test", configuration: config)
        let preset2 = BreakpointPreset(id: id, name: "Test", configuration: config)

        XCTAssertEqual(preset1, preset2)
    }

    func testEquatableWithDifferentIds() {
        let config = createMockConfiguration()
        let preset1 = BreakpointPreset(id: UUID(), name: "Test", configuration: config)
        let preset2 = BreakpointPreset(id: UUID(), name: "Test", configuration: config)

        XCTAssertNotEqual(preset1, preset2)
    }

    func testEquatableWithDifferentNames() {
        let id = UUID()
        let config = createMockConfiguration()
        let preset1 = BreakpointPreset(id: id, name: "Test 1", configuration: config)
        let preset2 = BreakpointPreset(id: id, name: "Test 2", configuration: config)

        XCTAssertNotEqual(preset1, preset2)
    }

    func testEquatableWithDifferentConfigurations() {
        let id = UUID()
        let config1 = BreakpointConfiguration(enabled: true, breakpointType: .request)
        let config2 = BreakpointConfiguration(enabled: false, breakpointType: .response)
        let preset1 = BreakpointPreset(id: id, name: "Test", configuration: config1)
        let preset2 = BreakpointPreset(id: id, name: "Test", configuration: config2)

        XCTAssertNotEqual(preset1, preset2)
    }

    // MARK: - Identifiable Tests

    func testIdentifiableProtocol() {
        let config = createMockConfiguration()
        let preset = BreakpointPreset(name: "Test", configuration: config)

        XCTAssertNotNil(preset.id)
        XCTAssertEqual(preset.id, preset.id)
    }

    func testMultiplePresetsHaveUniqueIds() {
        let config = createMockConfiguration()
        let preset1 = BreakpointPreset(name: "Preset 1", configuration: config)
        let preset2 = BreakpointPreset(name: "Preset 2", configuration: config)
        let preset3 = BreakpointPreset(name: "Preset 3", configuration: config)

        XCTAssertNotEqual(preset1.id, preset2.id)
        XCTAssertNotEqual(preset1.id, preset3.id)
        XCTAssertNotEqual(preset2.id, preset3.id)
    }

    // MARK: - Edge Cases

    func testLongName() {
        let config = createMockConfiguration()
        let longName = String(repeating: "A", count: 1000)
        let preset = BreakpointPreset(name: longName, configuration: config)

        XCTAssertEqual(preset.name.count, 1000)
    }

    func testSpecialCharactersInName() {
        let config = createMockConfiguration()
        let specialName = "Test 🔥 @#$%^&* (preset)"
        let preset = BreakpointPreset(name: specialName, configuration: config)

        XCTAssertEqual(preset.name, specialName)
    }

    func testCodableWithUnicodeCharacters() throws {
        let config = createMockConfiguration()
        let preset = BreakpointPreset(name: "测试断点 🎯", configuration: config)

        let encoder = JSONEncoder()
        let data = try encoder.encode(preset)

        let decoder = JSONDecoder()
        let decodedPreset = try decoder.decode(BreakpointPreset.self, from: data)

        XCTAssertEqual(preset.name, decodedPreset.name)
    }

    // MARK: - Configuration Tests

    func testConfigurationWithAllBreakpointTypes() throws {
        let types: [BreakpointType] = [.request, .response, .both]

        for type in types {
            let config = BreakpointConfiguration(
                enabled: true,
                breakpointType: type,
                matchType: .wildcard,
                matchPattern: "*.example.com"
            )
            let preset = BreakpointPreset(name: "Type Test", configuration: config)

            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(BreakpointPreset.self, from: data)

            XCTAssertEqual(decoded.configuration.breakpointType, type)
        }
    }

    func testConfigurationWithAllMatchTypes() throws {
        let matchTypes: [MatchType] = [.wildcard, .regex, .exact, .contains]

        for matchType in matchTypes {
            let config = BreakpointConfiguration(
                enabled: true,
                breakpointType: .both,
                matchType: matchType,
                matchPattern: "test"
            )
            let preset = BreakpointPreset(name: "Match Type Test", configuration: config)

            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(BreakpointPreset.self, from: data)

            XCTAssertEqual(decoded.configuration.matchType, matchType)
        }
    }

    func testConfigurationWithAllExecutionModes() throws {
        let modes: [BreakpointExecutionMode] = [.pause, .editOnce, .alwaysApply, .logOnly]

        for mode in modes {
            let config = BreakpointConfiguration(
                enabled: true,
                breakpointType: .both,
                matchType: .wildcard,
                matchPattern: "test",
                executionMode: mode
            )
            let preset = BreakpointPreset(name: "Execution Mode Test", configuration: config)

            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(BreakpointPreset.self, from: data)

            XCTAssertEqual(decoded.configuration.executionMode, mode)
        }
    }

    func testConfigurationWithAllHTTPMethods() throws {
        let methods: Set<HTTPMethod> = [.get, .post, .put, .delete, .patch, .head, .options, .connect]
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "test",
            methods: methods
        )
        let preset = BreakpointPreset(name: "Methods Test", configuration: config)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BreakpointPreset.self, from: data)

        XCTAssertEqual(decoded.configuration.methods, methods)
    }

    func testConfigurationWithMultipleStatusCodes() throws {
        let statusCodes: Set<Int> = [200, 201, 204, 301, 302, 400, 401, 403, 404, 500, 502, 503]
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .response,
            matchType: .wildcard,
            matchPattern: "test",
            statusCodes: statusCodes
        )
        let preset = BreakpointPreset(name: "Status Codes Test", configuration: config)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BreakpointPreset.self, from: data)

        XCTAssertEqual(decoded.configuration.statusCodes, statusCodes)
    }

    func testConfigurationWithMultipleConditions() throws {
        let conditions = [
            BreakpointCondition(type: .headerExists, parameter: "Authorization", value: ""),
            BreakpointCondition(type: .headerEquals, parameter: "Content-Type", value: "application/json"),
            BreakpointCondition(type: .bodyContains, parameter: "", value: "error"),
            BreakpointCondition(type: .bodyRegex, parameter: "", value: ".*test.*"),
            BreakpointCondition(type: .queryParamExists, parameter: "debug", value: "")
        ]
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .both,
            matchType: .wildcard,
            matchPattern: "test",
            conditions: conditions
        )
        let preset = BreakpointPreset(name: "Conditions Test", configuration: config)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BreakpointPreset.self, from: data)

        XCTAssertEqual(decoded.configuration.conditions.count, conditions.count)
        for (original, decoded) in zip(conditions, decoded.configuration.conditions) {
            XCTAssertEqual(original.type, decoded.type)
            XCTAssertEqual(original.parameter, decoded.parameter)
            XCTAssertEqual(original.value, decoded.value)
        }
    }

    // MARK: - Sendable Tests

    func testSendableConformance() {
        let config = createMockConfiguration()
        let preset = BreakpointPreset(name: "Sendable Test", configuration: config)

        let expectation = expectation(description: "Sendable preset can be passed to async context")

        Task {
            let capturedPreset = preset
            XCTAssertEqual(capturedPreset.name, "Sendable Test")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Helper Methods

    private func createMockConfiguration() -> BreakpointConfiguration {
        BreakpointConfiguration(
            enabled: true,
            breakpointType: .both,
            matchType: .wildcard,
            matchPattern: "*.example.com",
            methods: [.get, .post],
            statusCodes: [200, 404],
            executionMode: .pause,
            maxHits: nil,
            conditions: []
        )
    }
}
