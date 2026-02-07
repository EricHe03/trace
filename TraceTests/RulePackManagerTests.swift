//
//  RulePackManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class RulePackManagerTests: XCTestCase {

    var manager: RulePackManager!
    var testFileURL: URL?

    override func setUp() async throws {
        try await super.setUp()
        manager = RulePackManager.shared
    }

    override func tearDown() async throws {
        // Clean up test files
        if let url = testFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        testFileURL = nil
        try await super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSharedInstance() {
        // Arrange & Act
        let instance1 = RulePackManager.shared
        let instance2 = RulePackManager.shared

        // Assert
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Export Rule Pack Tests

    func testExportRulePackWithEmptyRules() throws {
        // Arrange
        let rules: [RewriteRule] = []
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Empty Pack")

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        XCTAssertTrue(exportURL.path.contains("RulePack_"))
        XCTAssertTrue(exportURL.pathExtension == "json")

        // Verify file content
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        XCTAssertEqual(decoded.metadata.name, "Empty Pack")
        XCTAssertEqual(decoded.rules.count, 0)
        XCTAssertEqual(decoded.groups.count, 0)
    }

    func testExportRulePackWithSingleRule() throws {
        // Arrange
        let rule = makeRewriteRule(
            name: "Test Rule",
            matchURL: "*.example.com"
        )
        let rules = [rule]
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Single Rule Pack")

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        // Verify rule was exported correctly
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertEqual(decoded.rules.first?.name, "Test Rule")
        XCTAssertEqual(decoded.rules.first?.matchPattern, "*.example.com")
    }

    func testExportRulePackWithMultipleRules() throws {
        // Arrange
        let rule1 = makeRewriteRule(name: "Rule 1", matchURL: "*.example1.com")
        let rule2 = makeRewriteRule(name: "Rule 2", matchURL: "*.example2.com")
        let rule3 = makeRewriteRule(name: "Rule 3", matchURL: "*.example3.com")
        let rules = [rule1, rule2, rule3]
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Multi Rule Pack")

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        XCTAssertEqual(decoded.rules.count, 3)
        XCTAssertEqual(decoded.rules[0].name, "Rule 1")
        XCTAssertEqual(decoded.rules[1].name, "Rule 2")
        XCTAssertEqual(decoded.rules[2].name, "Rule 3")
    }

    func testExportRulePackWithGroups() throws {
        // Arrange
        let rule1 = makeRewriteRule(name: "Rule 1")
        let rule2 = makeRewriteRule(name: "Rule 2")
        let rules = [rule1, rule2]

        let group = makeRuleGroup(
            name: "Test Group",
            enabled: true,
            ruleIds: [rule1.id, rule2.id]
        )
        let groups = [group]
        let metadata = makeRulePackMetadata(name: "Pack with Groups")

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        XCTAssertEqual(decoded.groups.count, 1)
        XCTAssertEqual(decoded.groups.first?.name, "Test Group")
        XCTAssertEqual(decoded.groups.first?.rules.count, 2)
    }

    func testExportRulePackWithMetadata() throws {
        // Arrange
        let rules: [RewriteRule] = []
        let groups: [RuleGroup] = []
        let createdDate = Date(timeIntervalSince1970: 1609459200) // 2021-01-01
        let metadata = RulePackMetadata(
            name: "Test Pack",
            version: "1.0.0",
            author: "Test Author",
            description: "Test Description",
            createdAt: createdDate
        )

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        XCTAssertEqual(decoded.metadata.name, "Test Pack")
        XCTAssertEqual(decoded.metadata.version, "1.0.0")
        XCTAssertEqual(decoded.metadata.author, "Test Author")
        XCTAssertEqual(decoded.metadata.description, "Test Description")
        XCTAssertEqual(decoded.metadata.createdAt.timeIntervalSince1970,
                      createdDate.timeIntervalSince1970,
                      accuracy: 1.0)
    }

    func testExportRulePackJSONFormatting() throws {
        // Arrange
        let rule = makeRewriteRule(name: "Test Rule")
        let rules = [rule]
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Format Test")

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert - Verify pretty printing and sorted keys
        let jsonString = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(jsonString.contains("\n")) // Pretty printed
        XCTAssertTrue(jsonString.contains("  ")) // Contains indentation

        // Verify the JSON is valid
        let data = try Data(contentsOf: exportURL)
        XCTAssertNoThrow(try JSONDecoder().decode(RulePack.self, from: data))
    }

    func testExportRulePackFilename() throws {
        // Arrange
        let rules: [RewriteRule] = []
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Test")

        let beforeTimestamp = Int(Date().timeIntervalSince1970)

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        let afterTimestamp = Int(Date().timeIntervalSince1970)

        // Assert - Filename should contain timestamp
        let filename = exportURL.lastPathComponent
        XCTAssertTrue(filename.hasPrefix("RulePack_"))
        XCTAssertTrue(filename.hasSuffix(".json"))

        // Extract timestamp from filename
        let timestampString = filename
            .replacingOccurrences(of: "RulePack_", with: "")
            .replacingOccurrences(of: ".json", with: "")
        if let timestamp = Int(timestampString) {
            XCTAssertGreaterThanOrEqual(timestamp, beforeTimestamp)
            XCTAssertLessThanOrEqual(timestamp, afterTimestamp)
        } else {
            XCTFail("Could not extract timestamp from filename")
        }
    }

    // MARK: - Import Rule Pack Tests

    func testImportRulePackFromValidFile() throws {
        // Arrange
        let rule = makeRewriteRule(name: "Import Test Rule")
        let rules = [rule]
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Import Test")

        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Act
        let importedPack = try manager.importRulePack(from: exportURL)

        // Assert
        XCTAssertEqual(importedPack.metadata.name, "Import Test")
        XCTAssertEqual(importedPack.rules.count, 1)
        XCTAssertEqual(importedPack.rules.first?.name, "Import Test Rule")
    }

    func testImportRulePackWithMultipleRulesAndGroups() throws {
        // Arrange
        let rule1 = makeRewriteRule(name: "Rule 1")
        let rule2 = makeRewriteRule(name: "Rule 2")
        let group = makeRuleGroup(name: "Group 1", ruleIds: [rule1.id])
        let rules = [rule1, rule2]
        let groups = [group]
        let metadata = makeRulePackMetadata(name: "Complex Pack")

        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Act
        let importedPack = try manager.importRulePack(from: exportURL)

        // Assert
        XCTAssertEqual(importedPack.rules.count, 2)
        XCTAssertEqual(importedPack.groups.count, 1)
        XCTAssertEqual(importedPack.groups.first?.name, "Group 1")
        XCTAssertEqual(importedPack.groups.first?.rules.count, 1)
    }

    func testImportRulePackFromNonExistentFile() {
        // Arrange
        let nonExistentURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).json")

        // Act & Assert
        XCTAssertThrowsError(try manager.importRulePack(from: nonExistentURL)) { error in
            XCTAssertTrue(error is CocoaError)
        }
    }

    func testImportRulePackFromInvalidJSON() throws {
        // Arrange
        let invalidJSON = "{ invalid json content }"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid_\(UUID().uuidString).json")
        try invalidJSON.write(to: tempURL, atomically: true, encoding: .utf8)
        testFileURL = tempURL

        // Act & Assert
        XCTAssertThrowsError(try manager.importRulePack(from: tempURL)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testImportRulePackFromCorruptedJSON() throws {
        // Arrange
        let corruptedJSON = """
        {
            "metadata": {
                "name": "Test"
            }
        }
        """
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupted_\(UUID().uuidString).json")
        try corruptedJSON.write(to: tempURL, atomically: true, encoding: .utf8)
        testFileURL = tempURL

        // Act & Assert
        XCTAssertThrowsError(try manager.importRulePack(from: tempURL)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testImportExportRoundTrip() throws {
        // Arrange
        let rule1 = makeRewriteRule(
            name: "Rule 1",
            matchURL: "*.example.com",
            modifyHeadersAdd: ["X-Custom": "Value"]
        )
        let rule2 = makeRewriteRule(
            name: "Rule 2",
            enabled: false
        )
        let group = makeRuleGroup(
            name: "Test Group",
            enabled: true,
            ruleIds: [rule1.id, rule2.id]
        )
        let originalRules = [rule1, rule2]
        let originalGroups = [group]
        let originalMetadata = makeRulePackMetadata(
            name: "Round Trip Test",
            version: "2.0.0"
        )

        // Act - Export then import
        let exportURL = try manager.exportRulePack(
            rules: originalRules,
            groups: originalGroups,
            metadata: originalMetadata
        )
        testFileURL = exportURL

        let importedPack = try manager.importRulePack(from: exportURL)

        // Assert - Verify all data survived the round trip
        XCTAssertEqual(importedPack.metadata.name, originalMetadata.name)
        XCTAssertEqual(importedPack.metadata.version, originalMetadata.version)
        XCTAssertEqual(importedPack.rules.count, originalRules.count)
        XCTAssertEqual(importedPack.groups.count, originalGroups.count)

        // Verify rule details
        XCTAssertEqual(importedPack.rules[0].name, "Rule 1")
        XCTAssertEqual(importedPack.rules[0].matchPattern, "*.example.com")
        XCTAssertTrue(importedPack.rules[0].actions.contains(where: { action in
            action.actionType == .setHeader && action.parameters["key"] == "X-Custom" && action.parameters["value"] == "Value"
        }))
        XCTAssertEqual(importedPack.rules[1].name, "Rule 2")
        XCTAssertFalse(importedPack.rules[1].enabled)

        // Verify group details
        XCTAssertEqual(importedPack.groups[0].name, "Test Group")
        XCTAssertTrue(importedPack.groups[0].enabled)
        XCTAssertEqual(importedPack.groups[0].rules.count, 2)
    }

    // MARK: - Merge Rule Pack Tests

    func testMergeRulePackWithReplaceStrategy() {
        // Arrange
        let rule = makeRewriteRule(name: "Test Rule")
        let group = makeRuleGroup(name: "Test Group")
        let metadata = makeRulePackMetadata(name: "Test Pack")
        let pack = RulePack(metadata: metadata, rules: [rule], groups: [group])

        // Act
        manager.mergeRulePack(pack, strategy: .replace)

        // Assert - Verify the method executes without error
        // Note: Actual verification would require checking RewriteManager and RuleGroupManager
        // which are tested separately
    }

    func testMergeRulePackWithMergeStrategy() {
        // Arrange
        let rule = makeRewriteRule(name: "Test Rule")
        let group = makeRuleGroup(name: "Test Group")
        let metadata = makeRulePackMetadata(name: "Test Pack")
        let pack = RulePack(metadata: metadata, rules: [rule], groups: [group])

        // Act
        manager.mergeRulePack(pack, strategy: .merge)

        // Assert - Verify the method executes without error
        // Note: Actual verification would require checking RewriteManager and RuleGroupManager
    }

    func testMergeRulePackWithAskStrategy() {
        // Arrange
        let rule = makeRewriteRule(name: "Test Rule")
        let group = makeRuleGroup(name: "Test Group")
        let metadata = makeRulePackMetadata(name: "Test Pack")
        let pack = RulePack(metadata: metadata, rules: [rule], groups: [group])

        // Act
        manager.mergeRulePack(pack, strategy: .ask)

        // Assert - Verify the method executes without error
        // Note: Ask strategy currently behaves like merge
    }

    func testMergeRulePackWithEmptyPack() {
        // Arrange
        let metadata = makeRulePackMetadata(name: "Empty Pack")
        let pack = RulePack(metadata: metadata, rules: [], groups: [])

        // Act & Assert - Should not throw
        manager.mergeRulePack(pack, strategy: .replace)
        manager.mergeRulePack(pack, strategy: .merge)
        manager.mergeRulePack(pack, strategy: .ask)
    }

    // MARK: - Edge Cases Tests

    func testExportRulePackWithDisabledRule() throws {
        // Arrange
        let rule = makeRewriteRule(name: "Disabled Rule", enabled: false)
        let rules = [rule]
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Disabled Rule Pack")

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertFalse(decoded.rules.first?.enabled ?? true)
    }

    func testExportRulePackWithComplexRuleConfiguration() throws {
        // Arrange
        let rule = makeRewriteRule(
            name: "Complex Rule",
            matchURL: "https://*.api.example.com/v*/users/*",
            enabled: true,
            modifyHeadersAdd: [
                "X-Custom-Header": "Value1",
                "X-Another-Header": "Value2"
            ],
            modifyHeadersSet: [
                "Authorization": "Bearer token"
            ],
            modifyHeadersRemove: ["Cookie", "Set-Cookie"]
        )
        let rules = [rule]
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Complex Pack")

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        let decodedRule = decoded.rules.first
        XCTAssertNotNil(decodedRule)
        XCTAssertEqual(decodedRule?.actions.count, 5)
    }

    func testExportRulePackWithSpecialCharactersInMetadata() throws {
        // Arrange
        let rules: [RewriteRule] = []
        let groups: [RuleGroup] = []
        let metadata = RulePackMetadata(
            name: "Pack with 特殊字符 and émojis 🎉",
            version: "1.0.0-beta+001",
            author: "Test Author <test@example.com>",
            description: "Description with \"quotes\" and 'apostrophes' & special chars: < > & \" '",
            createdAt: Date()
        )

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        XCTAssertEqual(decoded.metadata.name, metadata.name)
        XCTAssertEqual(decoded.metadata.version, metadata.version)
        XCTAssertEqual(decoded.metadata.author, metadata.author)
        XCTAssertEqual(decoded.metadata.description, metadata.description)
    }

    func testExportRulePackWithLargeNumberOfRules() throws {
        // Arrange
        let rules = (0..<100).map { i in
            makeRewriteRule(
                name: "Rule \(i)",
                matchURL: "*.example\(i).com"
            )
        }
        let groups: [RuleGroup] = []
        let metadata = makeRulePackMetadata(name: "Large Pack")

        // Act
        let exportURL = try manager.exportRulePack(
            rules: rules,
            groups: groups,
            metadata: metadata
        )
        testFileURL = exportURL

        // Assert
        let data = try Data(contentsOf: exportURL)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)
        XCTAssertEqual(decoded.rules.count, 100)
        XCTAssertEqual(decoded.rules.first?.name, "Rule 0")
        XCTAssertEqual(decoded.rules.last?.name, "Rule 99")
    }

    // MARK: - Helper Methods

    private func makeRulePackMetadata(
        name: String,
        version: String = "1.0.0",
        author: String = "Test Author",
        description: String = "Test Description",
        createdAt: Date = Date()
    ) -> RulePackMetadata {
        RulePackMetadata(
            name: name,
            version: version,
            author: author,
            description: description,
            createdAt: createdAt
        )
    }
}
