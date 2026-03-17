//
//  BreakpointPresetManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import Combine
@testable import TraceCore
@testable import TraceFeatures
import XCTest

@MainActor
final class BreakpointPresetManagerTests: XCTestCase {
    // MARK: - Initialization Tests

    func testSharedInstance() {
        // Arrange & Act
        let manager1 = BreakpointPresetManager.shared
        let manager2 = BreakpointPresetManager.shared

        // Assert
        XCTAssertTrue(manager1 === manager2, "Shared instance should return the same object")
    }

    func testInitialState() {
        // Arrange
        let manager = BreakpointPresetManager.shared

        // Act
        let presets = manager.presets

        // Assert
        XCTAssertNotNil(presets, "Presets should not be nil")
        XCTAssertTrue(presets is [BreakpointPreset], "Presets should be of correct type")
    }

    // MARK: - Save Preset Tests

    func testSavePreset() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*.example.com"
        )
        let preset = BreakpointPreset(
            id: UUID(),
            name: "Test Preset",
            configuration: configuration
        )
        let initialCount = manager.presets.count

        // Act
        manager.savePreset(preset)

        // Assert
        XCTAssertEqual(manager.presets.count, initialCount + 1, "Preset count should increase by 1")
        XCTAssertTrue(manager.presets.contains(where: { $0.id == preset.id }), "Saved preset should be in presets array")
    }

    func testSaveMultiplePresets() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let preset1 = BreakpointPreset(
            id: UUID(),
            name: "Preset 1",
            configuration: BreakpointConfiguration(enabled: true, breakpointType: .request)
        )
        let preset2 = BreakpointPreset(
            id: UUID(),
            name: "Preset 2",
            configuration: BreakpointConfiguration(enabled: true, breakpointType: .response)
        )
        let preset3 = BreakpointPreset(
            id: UUID(),
            name: "Preset 3",
            configuration: BreakpointConfiguration(enabled: true, breakpointType: .both)
        )

        // Act
        manager.savePreset(preset1)
        manager.savePreset(preset2)
        manager.savePreset(preset3)

        // Assert
        XCTAssertTrue(manager.presets.contains(where: { $0.id == preset1.id }), "Preset 1 should be saved")
        XCTAssertTrue(manager.presets.contains(where: { $0.id == preset2.id }), "Preset 2 should be saved")
        XCTAssertTrue(manager.presets.contains(where: { $0.id == preset3.id }), "Preset 3 should be saved")
    }

    func testSavePresetWithDifferentConfigurations() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let config1 = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .exact,
            matchPattern: "https://api.example.com"
        )
        let config2 = BreakpointConfiguration(
            enabled: false,
            breakpointType: .response,
            matchType: .regex,
            matchPattern: ".*\\.json"
        )
        let preset1 = BreakpointPreset(name: "Exact Match", configuration: config1)
        let preset2 = BreakpointPreset(name: "Regex Match", configuration: config2)

        // Act
        manager.savePreset(preset1)
        manager.savePreset(preset2)

        // Assert
        let saved1 = manager.loadPreset(preset1.id)
        let saved2 = manager.loadPreset(preset2.id)
        XCTAssertEqual(saved1?.configuration.breakpointType, .request)
        XCTAssertEqual(saved2?.configuration.breakpointType, .response)
    }

    func testSavePresetWithComplexConfiguration() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(
            enabled: true,
            breakpointType: .both,
            matchType: .wildcard,
            matchPattern: "*.example.com",
            methods: [.get, .post, .put],
            statusCodes: [200, 201, 400, 404],
            executionMode: .pause,
            maxHits: 10,
            conditions: [
                BreakpointCondition(type: .headerExists, parameter: "Authorization", value: ""),
                BreakpointCondition(type: .bodyContains, parameter: "", value: "test")
            ]
        )
        let preset = BreakpointPreset(name: "Complex Preset", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let saved = manager.loadPreset(preset.id)
        XCTAssertNotNil(saved, "Preset should be saved")
        XCTAssertEqual(saved?.configuration.methods.count, 3)
        XCTAssertEqual(saved?.configuration.statusCodes.count, 4)
        XCTAssertEqual(saved?.configuration.conditions.count, 2)
        XCTAssertEqual(saved?.configuration.maxHits, 10)
    }

    // MARK: - Load Preset Tests

    func testLoadPresetThatExists() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchPattern: "*.example.com"
        )
        let preset = BreakpointPreset(name: "Existing Preset", configuration: configuration)
        manager.savePreset(preset)

        // Act
        let loaded = manager.loadPreset(preset.id)

        // Assert
        XCTAssertNotNil(loaded, "Preset should be loaded")
        XCTAssertEqual(loaded?.id, preset.id, "Loaded preset should have same ID")
        XCTAssertEqual(loaded?.name, "Existing Preset", "Loaded preset should have same name")
    }

    func testLoadPresetThatDoesNotExist() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let nonExistentId = UUID()

        // Act
        let loaded = manager.loadPreset(nonExistentId)

        // Assert
        XCTAssertNil(loaded, "Non-existent preset should return nil")
    }

    func testLoadPresetAfterSavingMultiple() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let preset1 = BreakpointPreset(name: "Preset 1", configuration: BreakpointConfiguration())
        let preset2 = BreakpointPreset(name: "Preset 2", configuration: BreakpointConfiguration())
        let preset3 = BreakpointPreset(name: "Preset 3", configuration: BreakpointConfiguration())
        manager.savePreset(preset1)
        manager.savePreset(preset2)
        manager.savePreset(preset3)

        // Act
        let loaded = manager.loadPreset(preset2.id)

        // Assert
        XCTAssertNotNil(loaded, "Middle preset should be loaded")
        XCTAssertEqual(loaded?.id, preset2.id, "Should load correct preset")
        XCTAssertEqual(loaded?.name, "Preset 2", "Should load correct preset name")
    }

    // MARK: - Apply Preset Tests

    func testApplyPresetThatExists() async {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchPattern: "*.example.com"
        )
        let preset = BreakpointPreset(name: "Apply Test", configuration: configuration)
        manager.savePreset(preset)

        // Act
        manager.applyPreset(preset.id)

        // Allow async task to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert
        let currentConfig = await BreakpointManager.shared.getConfiguration()
        XCTAssertEqual(currentConfig.enabled, true, "Configuration should be applied")
        XCTAssertEqual(currentConfig.breakpointType, .request, "Breakpoint type should match")
    }

    func testApplyPresetThatDoesNotExist() async {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let nonExistentId = UUID()
        let originalConfig = await BreakpointManager.shared.getConfiguration()

        // Act
        manager.applyPreset(nonExistentId)

        // Allow async task to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert
        let currentConfig = await BreakpointManager.shared.getConfiguration()
        XCTAssertEqual(currentConfig.enabled, originalConfig.enabled, "Configuration should not change")
    }

    func testApplyMultiplePresetsSequentially() async {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let preset1 = BreakpointPreset(
            name: "Preset 1",
            configuration: BreakpointConfiguration(enabled: true, breakpointType: .request)
        )
        let preset2 = BreakpointPreset(
            name: "Preset 2",
            configuration: BreakpointConfiguration(enabled: false, breakpointType: .response)
        )
        manager.savePreset(preset1)
        manager.savePreset(preset2)

        // Act
        manager.applyPreset(preset1.id)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let config1 = await BreakpointManager.shared.getConfiguration()

        manager.applyPreset(preset2.id)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let config2 = await BreakpointManager.shared.getConfiguration()

        // Assert
        XCTAssertEqual(config1.enabled, true, "First preset should be applied")
        XCTAssertEqual(config1.breakpointType, .request)
        XCTAssertEqual(config2.enabled, false, "Second preset should be applied")
        XCTAssertEqual(config2.breakpointType, .response)
    }

    // MARK: - Presets Property Tests

    func testPresetsProperty() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let preset1 = BreakpointPreset(name: "Test 1", configuration: BreakpointConfiguration())
        let preset2 = BreakpointPreset(name: "Test 2", configuration: BreakpointConfiguration())
        manager.savePreset(preset1)
        manager.savePreset(preset2)

        // Act
        let presets = manager.presets

        // Assert
        XCTAssertGreaterThanOrEqual(presets.count, 2, "Should have at least saved presets")
        XCTAssertTrue(presets.contains(where: { $0.id == preset1.id }), "Should contain preset1")
        XCTAssertTrue(presets.contains(where: { $0.id == preset2.id }), "Should contain preset2")
    }

    func testPresetsIsNotMutable() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let originalCount = manager.presets.count

        // Act
        var presets = manager.presets
        presets.append(BreakpointPreset(name: "New", configuration: BreakpointConfiguration()))

        // Assert
        XCTAssertEqual(manager.presets.count, originalCount, "Original presets should not change")
    }

    // MARK: - ObservableObject Tests

    func testObjectWillChangePublisher() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let expectation = XCTestExpectation(description: "ObjectWillChange should be called")
        let cancellable = manager.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        // Act
        let preset = BreakpointPreset(name: "Test", configuration: BreakpointConfiguration())
        manager.savePreset(preset)

        // Assert
        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    // MARK: - Edge Cases

    func testSavePresetWithEmptyName() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let preset = BreakpointPreset(name: "", configuration: BreakpointConfiguration())

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with empty name should be saved")
        XCTAssertEqual(loaded?.name, "", "Name should be empty")
    }

    func testSavePresetWithVeryLongName() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let longName = String(repeating: "A", count: 1000)
        let preset = BreakpointPreset(name: longName, configuration: BreakpointConfiguration())

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with long name should be saved")
        XCTAssertEqual(loaded?.name.count, 1000, "Long name should be preserved")
    }

    func testSavePresetWithSpecialCharactersInName() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let specialName = "Test 🔥 @#$% & (preset) [123]"
        let preset = BreakpointPreset(name: specialName, configuration: BreakpointConfiguration())

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with special characters should be saved")
        XCTAssertEqual(loaded?.name, specialName, "Special characters should be preserved")
    }

    func testSavePresetWithUnicodeInName() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let unicodeName = "測試預設"
        let preset = BreakpointPreset(name: unicodeName, configuration: BreakpointConfiguration())

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with Unicode should be saved")
        XCTAssertEqual(loaded?.name, unicodeName, "Unicode should be preserved")
    }

    func testSavePresetWithDisabledConfiguration() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(enabled: false)
        let preset = BreakpointPreset(name: "Disabled Config", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with disabled config should be saved")
        XCTAssertFalse(loaded?.configuration.enabled ?? true, "Config should be disabled")
    }

    func testSavePresetWithAllMatchTypes() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let matchTypes: [MatchType] = [.exact, .wildcard, .regex, .contains]
        var presets: [BreakpointPreset] = []

        // Act
        for matchType in matchTypes {
            let config = BreakpointConfiguration(matchType: matchType, matchPattern: "test")
            let preset = BreakpointPreset(name: "Match \(matchType)", configuration: config)
            manager.savePreset(preset)
            presets.append(preset)
        }

        // Assert
        for (index, preset) in presets.enumerated() {
            let loaded = manager.loadPreset(preset.id)
            XCTAssertNotNil(loaded, "Preset \(index) should be saved")
            XCTAssertEqual(loaded?.configuration.matchType, matchTypes[index])
        }
    }

    func testSavePresetWithAllBreakpointTypes() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let breakpointTypes: [BreakpointType] = [.request, .response, .stream, .both]
        var presets: [BreakpointPreset] = []

        // Act
        for breakpointType in breakpointTypes {
            let config = BreakpointConfiguration(breakpointType: breakpointType)
            let preset = BreakpointPreset(name: "Type \(breakpointType)", configuration: config)
            manager.savePreset(preset)
            presets.append(preset)
        }

        // Assert
        for (index, preset) in presets.enumerated() {
            let loaded = manager.loadPreset(preset.id)
            XCTAssertNotNil(loaded, "Preset \(index) should be saved")
            XCTAssertEqual(loaded?.configuration.breakpointType, breakpointTypes[index])
        }
    }

    func testSavePresetWithAllExecutionModes() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let executionModes: [BreakpointExecutionMode] = [.pause, .editOnce, .alwaysApply, .logOnly]
        var presets: [BreakpointPreset] = []

        // Act
        for executionMode in executionModes {
            let config = BreakpointConfiguration(executionMode: executionMode)
            let preset = BreakpointPreset(name: "Mode \(executionMode)", configuration: config)
            manager.savePreset(preset)
            presets.append(preset)
        }

        // Assert
        for (index, preset) in presets.enumerated() {
            let loaded = manager.loadPreset(preset.id)
            XCTAssertNotNil(loaded, "Preset \(index) should be saved")
            XCTAssertEqual(loaded?.configuration.executionMode, executionModes[index])
        }
    }

    func testSavePresetWithEmptyMethods() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(methods: [])
        let preset = BreakpointPreset(name: "Empty Methods", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with empty methods should be saved")
        XCTAssertTrue(loaded?.configuration.methods.isEmpty ?? false, "Methods should be empty")
    }

    func testSavePresetWithAllHTTPMethods() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let allMethods: Set<HTTPMethod> = [.get, .post, .put, .delete, .patch, .head, .options, .connect]
        let configuration = BreakpointConfiguration(methods: allMethods)
        let preset = BreakpointPreset(name: "All Methods", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with all methods should be saved")
        XCTAssertEqual(loaded?.configuration.methods.count, allMethods.count, "All methods should be preserved")
    }

    func testSavePresetWithManyStatusCodes() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let statusCodes: Set<Int> = Set(100 ... 599)
        let configuration = BreakpointConfiguration(statusCodes: statusCodes)
        let preset = BreakpointPreset(name: "Many Status Codes", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with many status codes should be saved")
        XCTAssertEqual(loaded?.configuration.statusCodes.count, 500, "All status codes should be preserved")
    }

    func testSavePresetWithNilMaxHits() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(maxHits: nil)
        let preset = BreakpointPreset(name: "No Max Hits", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with nil maxHits should be saved")
        XCTAssertNil(loaded?.configuration.maxHits, "MaxHits should be nil")
    }

    func testSavePresetWithZeroMaxHits() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(maxHits: 0)
        let preset = BreakpointPreset(name: "Zero Max Hits", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with zero maxHits should be saved")
        XCTAssertEqual(loaded?.configuration.maxHits, 0, "MaxHits should be zero")
    }

    func testSavePresetWithLargeMaxHits() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(maxHits: Int.max)
        let preset = BreakpointPreset(name: "Large Max Hits", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with large maxHits should be saved")
        XCTAssertEqual(loaded?.configuration.maxHits, Int.max, "MaxHits should be preserved")
    }

    func testSavePresetWithEmptyConditions() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(conditions: [])
        let preset = BreakpointPreset(name: "Empty Conditions", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with empty conditions should be saved")
        XCTAssertTrue(loaded?.configuration.conditions.isEmpty ?? false, "Conditions should be empty")
    }

    func testSavePresetWithManyConditions() {
        // Arrange
        let manager = BreakpointPresetManager.shared
        var conditions: [BreakpointCondition] = []
        for i in 0 ..< 50 {
            conditions.append(BreakpointCondition(type: .headerExists, parameter: "Header\(i)", value: ""))
        }
        let configuration = BreakpointConfiguration(conditions: conditions)
        let preset = BreakpointPreset(name: "Many Conditions", configuration: configuration)

        // Act
        manager.savePreset(preset)

        // Assert
        let loaded = manager.loadPreset(preset.id)
        XCTAssertNotNil(loaded, "Preset with many conditions should be saved")
        XCTAssertEqual(loaded?.configuration.conditions.count, 50, "All conditions should be preserved")
    }

    // MARK: - Performance Tests

    func testSavePresetPerformance() {
        let manager = BreakpointPresetManager.shared
        let configuration = BreakpointConfiguration(enabled: true, breakpointType: .request)

        measure {
            let preset = BreakpointPreset(name: "Performance Test", configuration: configuration)
            manager.savePreset(preset)
        }
    }

    func testLoadPresetPerformance() {
        let manager = BreakpointPresetManager.shared
        let preset = BreakpointPreset(name: "Performance Test", configuration: BreakpointConfiguration())
        manager.savePreset(preset)

        measure {
            _ = manager.loadPreset(preset.id)
        }
    }
}
