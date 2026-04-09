//
//  BreakpointActionDefinitionTests.swift
//  TraceTests
//
//  Created by Justin on 2026-02-01.
//

@testable import TraceCore
@testable import TraceFeatures
import XCTest

final class BreakpointActionDefinitionTests: XCTestCase {
    // MARK: - Initialization Tests

    func testInit_WithDefaultParameters_CreatesInstanceWithEmptyParameters() {
        // Arrange & Act
        let actionType = BreakpointActionType.pause
        let definition = BreakpointActionDefinition(actionType: actionType)

        // Assert
        XCTAssertEqual(definition.actionType, actionType)
        XCTAssertTrue(definition.parameters.isEmpty)
    }

    func testInit_WithCustomParameters_CreatesInstanceWithParameters() {
        // Arrange
        let actionType = BreakpointActionType.log
        let parameters = ["level": "debug", "message": "Test log"]

        // Act
        let definition = BreakpointActionDefinition(actionType: actionType, parameters: parameters)

        // Assert
        XCTAssertEqual(definition.actionType, actionType)
        XCTAssertEqual(definition.parameters.count, 2)
        XCTAssertEqual(definition.parameters["level"], "debug")
        XCTAssertEqual(definition.parameters["message"], "Test log")
    }

    func testInit_WithEmptyParametersDictionary_CreatesInstance() {
        // Arrange & Act
        let definition = BreakpointActionDefinition(
            actionType: .alert,
            parameters: [:]
        )

        // Assert
        XCTAssertEqual(definition.actionType, .alert)
        XCTAssertTrue(definition.parameters.isEmpty)
    }

    // MARK: - Action Type Tests

    func testActionType_Pause_IsSetCorrectly() {
        // Arrange & Act
        let definition = BreakpointActionDefinition(actionType: .pause)

        // Assert
        XCTAssertEqual(definition.actionType, .pause)
    }

    func testActionType_Log_IsSetCorrectly() {
        // Arrange & Act
        let definition = BreakpointActionDefinition(actionType: .log)

        // Assert
        XCTAssertEqual(definition.actionType, .log)
    }

    func testActionType_Alert_IsSetCorrectly() {
        // Arrange & Act
        let definition = BreakpointActionDefinition(actionType: .alert)

        // Assert
        XCTAssertEqual(definition.actionType, .alert)
    }

    func testActionType_AutoModify_IsSetCorrectly() {
        // Arrange & Act
        let definition = BreakpointActionDefinition(actionType: .autoModify)

        // Assert
        XCTAssertEqual(definition.actionType, .autoModify)
    }

    func testActionType_RepeatRequest_IsSetCorrectly() {
        // Arrange & Act
        let definition = BreakpointActionDefinition(actionType: .repeatRequest)

        // Assert
        XCTAssertEqual(definition.actionType, .repeatRequest)
    }

    // MARK: - Parameters Tests

    func testParameters_CanBeModified() {
        // Arrange
        var definition = BreakpointActionDefinition(actionType: .log)

        // Act
        definition.parameters["key1"] = "value1"
        definition.parameters["key2"] = "value2"

        // Assert
        XCTAssertEqual(definition.parameters.count, 2)
        XCTAssertEqual(definition.parameters["key1"], "value1")
        XCTAssertEqual(definition.parameters["key2"], "value2")
    }

    func testParameters_CanBeRemoved() {
        // Arrange
        var definition = BreakpointActionDefinition(
            actionType: .log,
            parameters: ["key1": "value1", "key2": "value2"]
        )

        // Act
        definition.parameters.removeValue(forKey: "key1")

        // Assert
        XCTAssertEqual(definition.parameters.count, 1)
        XCTAssertNil(definition.parameters["key1"])
        XCTAssertEqual(definition.parameters["key2"], "value2")
    }

    func testParameters_WithSpecialCharacters() {
        // Arrange
        let parameters = [
            "url": "https://example.com/api?key=value&foo=bar",
            "header": "Content-Type: application/json",
            "body": "{\"message\": \"Hello, World!\"}"
        ]

        // Act
        let definition = BreakpointActionDefinition(actionType: .autoModify, parameters: parameters)

        // Assert
        XCTAssertEqual(definition.parameters["url"], parameters["url"])
        XCTAssertEqual(definition.parameters["header"], parameters["header"])
        XCTAssertEqual(definition.parameters["body"], parameters["body"])
    }

    func testParameters_WithEmptyStrings() {
        // Arrange
        let parameters = ["key1": "", "key2": "value2"]

        // Act
        let definition = BreakpointActionDefinition(actionType: .log, parameters: parameters)

        // Assert
        XCTAssertEqual(definition.parameters["key1"], "")
        XCTAssertEqual(definition.parameters["key2"], "value2")
    }

    // MARK: - Codable Tests

    func testCodable_Pause_EncodesAndDecodes() throws {
        // Arrange
        let original = BreakpointActionDefinition(actionType: .pause)

        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: encoded)

        // Assert
        XCTAssertEqual(decoded.actionType, original.actionType)
        XCTAssertEqual(decoded.parameters, original.parameters)
    }

    func testCodable_Log_WithParameters_EncodesAndDecodes() throws {
        // Arrange
        let parameters = ["level": "info", "message": "Test message"]
        let original = BreakpointActionDefinition(actionType: .log, parameters: parameters)

        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: encoded)

        // Assert
        XCTAssertEqual(decoded.actionType, original.actionType)
        XCTAssertEqual(decoded.parameters, original.parameters)
        XCTAssertEqual(decoded.parameters["level"], "info")
        XCTAssertEqual(decoded.parameters["message"], "Test message")
    }

    func testCodable_Alert_EncodesAndDecodes() throws {
        // Arrange
        let parameters = ["title": "Alert", "message": "Breakpoint triggered"]
        let original = BreakpointActionDefinition(actionType: .alert, parameters: parameters)

        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: encoded)

        // Assert
        XCTAssertEqual(decoded.actionType, original.actionType)
        XCTAssertEqual(decoded.parameters, original.parameters)
    }

    func testCodable_AutoModify_EncodesAndDecodes() throws {
        // Arrange
        let parameters = [
            "headerKey": "X-Custom-Header",
            "headerValue": "CustomValue"
        ]
        let original = BreakpointActionDefinition(actionType: .autoModify, parameters: parameters)

        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: encoded)

        // Assert
        XCTAssertEqual(decoded.actionType, original.actionType)
        XCTAssertEqual(decoded.parameters, original.parameters)
    }

    func testCodable_RepeatRequest_EncodesAndDecodes() throws {
        // Arrange
        let parameters = ["count": "3", "delay": "1000"]
        let original = BreakpointActionDefinition(actionType: .repeatRequest, parameters: parameters)

        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: encoded)

        // Assert
        XCTAssertEqual(decoded.actionType, original.actionType)
        XCTAssertEqual(decoded.parameters, original.parameters)
    }

    func testCodable_WithComplexParameters_EncodesAndDecodes() throws {
        // Arrange
        let parameters = [
            "url": "https://api.example.com/endpoint?param=value",
            "method": "POST",
            "headers": "Content-Type: application/json\nAuthorization: Bearer token",
            "body": "{\"key\": \"value\", \"nested\": {\"foo\": \"bar\"}}"
        ]
        let original = BreakpointActionDefinition(actionType: .autoModify, parameters: parameters)

        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: encoded)

        // Assert
        XCTAssertEqual(decoded.actionType, original.actionType)
        XCTAssertEqual(decoded.parameters, original.parameters)
        XCTAssertEqual(decoded.parameters.count, 4)
    }

    func testCodable_WithEmptyParameters_EncodesAndDecodes() throws {
        // Arrange
        let original = BreakpointActionDefinition(actionType: .pause, parameters: [:])

        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: encoded)

        // Assert
        XCTAssertEqual(decoded.actionType, original.actionType)
        XCTAssertTrue(decoded.parameters.isEmpty)
    }

    // MARK: - BreakpointActionType Tests

    func testBreakpointActionType_RawValue_Pause() {
        // Assert
        XCTAssertEqual(BreakpointActionType.pause.rawValue, "pause")
    }

    func testBreakpointActionType_RawValue_Log() {
        // Assert
        XCTAssertEqual(BreakpointActionType.log.rawValue, "log")
    }

    func testBreakpointActionType_RawValue_Alert() {
        // Assert
        XCTAssertEqual(BreakpointActionType.alert.rawValue, "alert")
    }

    func testBreakpointActionType_RawValue_AutoModify() {
        // Assert
        XCTAssertEqual(BreakpointActionType.autoModify.rawValue, "autoModify")
    }

    func testBreakpointActionType_RawValue_RepeatRequest() {
        // Assert
        XCTAssertEqual(BreakpointActionType.repeatRequest.rawValue, "repeatRequest")
    }

    func testBreakpointActionType_Codable_AllCases() throws {
        // Arrange
        let allCases: [BreakpointActionType] = [.pause, .log, .alert, .autoModify, .repeatRequest]

        // Act & Assert
        for actionType in allCases {
            let encoded = try JSONEncoder().encode(actionType)
            let decoded = try JSONDecoder().decode(BreakpointActionType.self, from: encoded)
            XCTAssertEqual(decoded, actionType)
        }
    }

    func testBreakpointActionType_FromRawValue() {
        // Arrange & Act
        let pause = BreakpointActionType(rawValue: "pause")
        let log = BreakpointActionType(rawValue: "log")
        let alert = BreakpointActionType(rawValue: "alert")
        let autoModify = BreakpointActionType(rawValue: "autoModify")
        let repeatRequest = BreakpointActionType(rawValue: "repeatRequest")
        let invalid = BreakpointActionType(rawValue: "invalid")

        // Assert
        XCTAssertEqual(pause, .pause)
        XCTAssertEqual(log, .log)
        XCTAssertEqual(alert, .alert)
        XCTAssertEqual(autoModify, .autoModify)
        XCTAssertEqual(repeatRequest, .repeatRequest)
        XCTAssertNil(invalid)
    }

    // MARK: - Sendable Conformance Tests

    func testSendable_CanBeUsedAcrossConcurrencyBoundaries() async {
        // Arrange
        let definition = BreakpointActionDefinition(
            actionType: .log,
            parameters: ["message": "Test"]
        )

        // Act & Assert - Should compile without warnings
        await withCheckedContinuation { continuation in
            Task {
                _ = definition
                continuation.resume()
            }
        }
    }

    // MARK: - Edge Cases

    func testParameters_WithLargeValues() {
        // Arrange
        let largeValue = String(repeating: "A", count: 10000)
        let parameters = ["largeKey": largeValue]

        // Act
        let definition = BreakpointActionDefinition(actionType: .log, parameters: parameters)

        // Assert
        XCTAssertEqual(definition.parameters["largeKey"], largeValue)
        XCTAssertEqual(definition.parameters["largeKey"]?.count, 10000)
    }

    func testParameters_WithUnicodeCharacters() {
        // Arrange
        let parameters = [
            "emoji": "🔥💯🎉",
            "chinese": "你好世界",
            "arabic": "مرحبا بالعالم",
            "mixed": "Hello 世界 🌍"
        ]

        // Act
        let definition = BreakpointActionDefinition(actionType: .log, parameters: parameters)

        // Assert
        XCTAssertEqual(definition.parameters["emoji"], "🔥💯🎉")
        XCTAssertEqual(definition.parameters["chinese"], "你好世界")
        XCTAssertEqual(definition.parameters["arabic"], "مرحبا بالعالم")
        XCTAssertEqual(definition.parameters["mixed"], "Hello 世界 🌍")
    }

    func testParameters_WithNumericStringValues() {
        // Arrange
        let parameters = [
            "count": "42",
            "delay": "1000",
            "percentage": "75.5"
        ]

        // Act
        let definition = BreakpointActionDefinition(actionType: .repeatRequest, parameters: parameters)

        // Assert
        XCTAssertEqual(definition.parameters["count"], "42")
        XCTAssertEqual(definition.parameters["delay"], "1000")
        XCTAssertEqual(definition.parameters["percentage"], "75.5")
    }

    func testParameters_WithBooleanStringValues() {
        // Arrange
        let parameters = [
            "enabled": "true",
            "disabled": "false"
        ]

        // Act
        let definition = BreakpointActionDefinition(actionType: .autoModify, parameters: parameters)

        // Assert
        XCTAssertEqual(definition.parameters["enabled"], "true")
        XCTAssertEqual(definition.parameters["disabled"], "false")
    }

    // MARK: - JSON Serialization Tests

    func testJSON_ValidFormat() throws {
        // Arrange
        let definition = BreakpointActionDefinition(
            actionType: .log,
            parameters: ["message": "Test"]
        )

        // Act
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(definition)
        let jsonString = String(data: jsonData, encoding: .utf8)

        // Assert
        XCTAssertNotNil(jsonString)
        XCTAssertTrue(jsonString?.contains("actionType") ?? false)
        XCTAssertTrue(jsonString?.contains("parameters") ?? false)
        XCTAssertTrue(jsonString?.contains("log") ?? false)
    }

    func testJSON_RoundTrip() throws {
        // Arrange
        let original = BreakpointActionDefinition(
            actionType: .autoModify,
            parameters: [
                "key1": "value1",
                "key2": "value2"
            ]
        )

        // Act
        let jsonData = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: jsonData)
        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(BreakpointActionDefinition.self, from: reencoded)

        // Assert
        XCTAssertEqual(redecoded.actionType, original.actionType)
        XCTAssertEqual(redecoded.parameters, original.parameters)
    }

    // MARK: - Integration Tests

    func testMultipleDefinitions_WithDifferentActionTypes() {
        // Arrange & Act
        let definitions = [
            BreakpointActionDefinition(actionType: .pause),
            BreakpointActionDefinition(actionType: .log, parameters: ["level": "debug"]),
            BreakpointActionDefinition(actionType: .alert, parameters: ["title": "Alert"]),
            BreakpointActionDefinition(actionType: .autoModify, parameters: ["header": "X-Custom"]),
            BreakpointActionDefinition(actionType: .repeatRequest, parameters: ["count": "5"])
        ]

        // Assert
        XCTAssertEqual(definitions.count, 5)
        XCTAssertEqual(definitions[0].actionType, .pause)
        XCTAssertEqual(definitions[1].actionType, .log)
        XCTAssertEqual(definitions[2].actionType, .alert)
        XCTAssertEqual(definitions[3].actionType, .autoModify)
        XCTAssertEqual(definitions[4].actionType, .repeatRequest)
    }

    func testArray_OfDefinitions_Codable() throws {
        // Arrange
        let definitions = [
            BreakpointActionDefinition(actionType: .pause),
            BreakpointActionDefinition(actionType: .log, parameters: ["message": "Test"]),
            BreakpointActionDefinition(actionType: .alert, parameters: ["title": "Alert"])
        ]

        // Act
        let encoded = try JSONEncoder().encode(definitions)
        let decoded = try JSONDecoder().decode([BreakpointActionDefinition].self, from: encoded)

        // Assert
        XCTAssertEqual(decoded.count, definitions.count)
        XCTAssertEqual(decoded[0].actionType, .pause)
        XCTAssertEqual(decoded[1].actionType, .log)
        XCTAssertEqual(decoded[2].actionType, .alert)
        XCTAssertEqual(decoded[1].parameters["message"], "Test")
    }
}
