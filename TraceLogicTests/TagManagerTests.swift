//
//  TagManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026-02-01.
//

@testable import TraceCore
@testable import TraceFeatures
import XCTest

@MainActor
final class TagManagerTests: XCTestCase {
    var sut: TagManager!

    override func setUp() {
        super.setUp()
        sut = TagManager.shared

        // Clear any existing rules before each test
        let allRules = RewriteManager.shared.rules
        for rule in allRules {
            RewriteManager.shared.deleteRule(rule)
        }
    }

    override func tearDown() {
        // Clean up any rules created during tests
        let allRules = RewriteManager.shared.rules
        for rule in allRules {
            RewriteManager.shared.deleteRule(rule)
        }
        sut = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSharedInstance_ReturnsSameInstance() {
        // Arrange & Act
        let instance1 = TagManager.shared
        let instance2 = TagManager.shared

        // Assert
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Get All Tags Tests

    func testGetAllTags_WithNoRules_ReturnsEmptySet() {
        // Act
        let tags = sut.getAllTags()

        // Assert
        XCTAssertTrue(tags.isEmpty)
    }

    func testGetAllTags_WithRulesWithoutTags_ReturnsEmptySet() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: []
        )
        RewriteManager.shared.createRule(rule)

        // Act
        let tags = sut.getAllTags()

        // Assert
        XCTAssertTrue(tags.isEmpty)
    }

    func testGetAllTags_WithSingleRule_ReturnsAllTags() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: ["api", "production", "auth"]
        )
        RewriteManager.shared.createRule(rule)

        // Act
        let tags = sut.getAllTags()

        // Assert
        XCTAssertEqual(tags.count, 3)
        XCTAssertTrue(tags.contains("api"))
        XCTAssertTrue(tags.contains("production"))
        XCTAssertTrue(tags.contains("auth"))
    }

    func testGetAllTags_WithMultipleRules_ReturnsUniqueTags() {
        // Arrange
        let rule1 = RewriteRule(
            name: "Rule 1",
            ruleType: .modifyRequest,
            tags: ["api", "production"]
        )
        let rule2 = RewriteRule(
            name: "Rule 2",
            ruleType: .modifyResponse,
            tags: ["api", "staging"]
        )
        let rule3 = RewriteRule(
            name: "Rule 3",
            ruleType: .block,
            tags: ["security"]
        )

        RewriteManager.shared.createRule(rule1)
        RewriteManager.shared.createRule(rule2)
        RewriteManager.shared.createRule(rule3)

        // Act
        let tags = sut.getAllTags()

        // Assert
        XCTAssertEqual(tags.count, 4)
        XCTAssertTrue(tags.contains("api"))
        XCTAssertTrue(tags.contains("production"))
        XCTAssertTrue(tags.contains("staging"))
        XCTAssertTrue(tags.contains("security"))
    }

    func testGetAllTags_WithDuplicateTags_ReturnsUniqueSet() {
        // Arrange
        let rule1 = RewriteRule(
            name: "Rule 1",
            ruleType: .modifyRequest,
            tags: ["api", "test"]
        )
        let rule2 = RewriteRule(
            name: "Rule 2",
            ruleType: .modifyResponse,
            tags: ["api", "test"]
        )

        RewriteManager.shared.createRule(rule1)
        RewriteManager.shared.createRule(rule2)

        // Act
        let tags = sut.getAllTags()

        // Assert
        XCTAssertEqual(tags.count, 2)
        XCTAssertTrue(tags.contains("api"))
        XCTAssertTrue(tags.contains("test"))
    }

    // MARK: - Get Rules With Tag Tests

    func testGetRulesWithTag_WithNoRules_ReturnsEmptyArray() {
        // Act
        let rules = sut.getRules(withTag: "nonexistent")

        // Assert
        XCTAssertTrue(rules.isEmpty)
    }

    func testGetRulesWithTag_WithNonMatchingTag_ReturnsEmptyArray() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: ["api", "production"]
        )
        RewriteManager.shared.createRule(rule)

        // Act
        let rules = sut.getRules(withTag: "staging")

        // Assert
        XCTAssertTrue(rules.isEmpty)
    }

    func testGetRulesWithTag_WithMatchingTag_ReturnsFilteredRules() {
        // Arrange
        let rule1 = RewriteRule(
            name: "Rule 1",
            ruleType: .modifyRequest,
            tags: ["api", "production"]
        )
        let rule2 = RewriteRule(
            name: "Rule 2",
            ruleType: .modifyResponse,
            tags: ["api", "staging"]
        )
        let rule3 = RewriteRule(
            name: "Rule 3",
            ruleType: .block,
            tags: ["security"]
        )

        RewriteManager.shared.createRule(rule1)
        RewriteManager.shared.createRule(rule2)
        RewriteManager.shared.createRule(rule3)

        // Act
        let rules = sut.getRules(withTag: "api")

        // Assert
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.contains { $0.name == "Rule 1" })
        XCTAssertTrue(rules.contains { $0.name == "Rule 2" })
        XCTAssertFalse(rules.contains { $0.name == "Rule 3" })
    }

    func testGetRulesWithTag_WithSingleMatchingRule_ReturnsOneRule() {
        // Arrange
        let rule1 = RewriteRule(
            name: "Rule 1",
            ruleType: .modifyRequest,
            tags: ["api"]
        )
        let rule2 = RewriteRule(
            name: "Rule 2",
            ruleType: .modifyResponse,
            tags: ["security"]
        )

        RewriteManager.shared.createRule(rule1)
        RewriteManager.shared.createRule(rule2)

        // Act
        let rules = sut.getRules(withTag: "security")

        // Assert
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.name, "Rule 2")
    }

    func testGetRulesWithTag_IsCaseSensitive() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: ["API"]
        )
        RewriteManager.shared.createRule(rule)

        // Act
        let rulesUpperCase = sut.getRules(withTag: "API")
        let rulesLowerCase = sut.getRules(withTag: "api")

        // Assert
        XCTAssertEqual(rulesUpperCase.count, 1)
        XCTAssertTrue(rulesLowerCase.isEmpty)
    }

    // MARK: - Add Tag Tests

    func testAddTag_ToExistingRule_AddsTag() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: ["api"]
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.addTag("production", to: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertTrue(updatedRule?.tags.contains("production") ?? false)
        XCTAssertTrue(updatedRule?.tags.contains("api") ?? false)
        XCTAssertEqual(updatedRule?.tags.count, 2)
    }

    func testAddTag_ToRuleWithoutTags_CreatesFirstTag() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: []
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.addTag("newTag", to: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertTrue(updatedRule?.tags.contains("newTag") ?? false)
        XCTAssertEqual(updatedRule?.tags.count, 1)
    }

    func testAddTag_DuplicateTag_DoesNotDuplicate() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: ["api"]
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.addTag("api", to: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertTrue(updatedRule?.tags.contains("api") ?? false)
        XCTAssertEqual(updatedRule?.tags.count, 1)
    }

    func testAddTag_ToNonExistentRule_DoesNotCrash() {
        // Arrange
        let nonExistentId = UUID()

        // Act & Assert
        XCTAssertNoThrow(sut.addTag("test", to: nonExistentId))
    }

    func testAddTag_MultipleTagsSequentially_AddsAllTags() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: []
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.addTag("tag1", to: rule.id)
        sut.addTag("tag2", to: rule.id)
        sut.addTag("tag3", to: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertEqual(updatedRule?.tags.count, 3)
        XCTAssertTrue(updatedRule?.tags.contains("tag1") ?? false)
        XCTAssertTrue(updatedRule?.tags.contains("tag2") ?? false)
        XCTAssertTrue(updatedRule?.tags.contains("tag3") ?? false)
    }

    func testAddTag_EmptyString_AddsEmptyTag() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: []
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.addTag("", to: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertTrue(updatedRule?.tags.contains("") ?? false)
    }

    // MARK: - Remove Tag Tests

    func testRemoveTag_FromExistingRule_RemovesTag() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: ["api", "production"]
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.removeTag("production", from: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertFalse(updatedRule?.tags.contains("production") ?? true)
        XCTAssertTrue(updatedRule?.tags.contains("api") ?? false)
        XCTAssertEqual(updatedRule?.tags.count, 1)
    }

    func testRemoveTag_NonExistentTag_DoesNothing() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: ["api"]
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.removeTag("nonexistent", from: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertTrue(updatedRule?.tags.contains("api") ?? false)
        XCTAssertEqual(updatedRule?.tags.count, 1)
    }

    func testRemoveTag_LastTag_LeavesEmptySet() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: ["api"]
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.removeTag("api", from: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertTrue(updatedRule?.tags.isEmpty ?? false)
    }

    func testRemoveTag_FromNonExistentRule_DoesNotCrash() {
        // Arrange
        let nonExistentId = UUID()

        // Act & Assert
        XCTAssertNoThrow(sut.removeTag("test", from: nonExistentId))
    }

    func testRemoveTag_FromRuleWithoutTags_DoesNotCrash() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: []
        )
        RewriteManager.shared.createRule(rule)

        // Act & Assert
        XCTAssertNoThrow(sut.removeTag("test", from: rule.id))
    }

    // MARK: - Integration Tests

    func testAddAndRemoveTag_WorksTogether() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: []
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.addTag("test1", to: rule.id)
        sut.addTag("test2", to: rule.id)
        sut.removeTag("test1", from: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertEqual(updatedRule?.tags.count, 1)
        XCTAssertTrue(updatedRule?.tags.contains("test2") ?? false)
        XCTAssertFalse(updatedRule?.tags.contains("test1") ?? true)
    }

    func testGetAllTags_AfterAddingAndRemovingTags_ReturnsCorrectTags() {
        // Arrange
        let rule1 = RewriteRule(name: "Rule 1", ruleType: .modifyRequest, tags: ["api"])
        let rule2 = RewriteRule(name: "Rule 2", ruleType: .modifyResponse, tags: ["security"])

        RewriteManager.shared.createRule(rule1)
        RewriteManager.shared.createRule(rule2)

        // Act
        sut.addTag("production", to: rule1.id)
        sut.addTag("staging", to: rule2.id)
        sut.removeTag("api", from: rule1.id)

        // Assert
        let allTags = sut.getAllTags()
        XCTAssertEqual(allTags.count, 3)
        XCTAssertTrue(allTags.contains("production"))
        XCTAssertTrue(allTags.contains("security"))
        XCTAssertTrue(allTags.contains("staging"))
        XCTAssertFalse(allTags.contains("api"))
    }

    func testGetRulesWithTag_AfterModifyingTags_ReturnsUpdatedResults() {
        // Arrange
        let rule1 = RewriteRule(name: "Rule 1", ruleType: .modifyRequest, tags: ["api"])
        let rule2 = RewriteRule(name: "Rule 2", ruleType: .modifyResponse, tags: ["security"])

        RewriteManager.shared.createRule(rule1)
        RewriteManager.shared.createRule(rule2)

        // Act
        sut.addTag("api", to: rule2.id)
        let apiRules = sut.getRules(withTag: "api")

        // Assert
        XCTAssertEqual(apiRules.count, 2)
        XCTAssertTrue(apiRules.contains { $0.name == "Rule 1" })
        XCTAssertTrue(apiRules.contains { $0.name == "Rule 2" })
    }

    // MARK: - Edge Cases

    func testMultipleTagsWithSpecialCharacters() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: []
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.addTag("api-v1", to: rule.id)
        sut.addTag("test_env", to: rule.id)
        sut.addTag("prod.us-west", to: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertEqual(updatedRule?.tags.count, 3)
        XCTAssertTrue(updatedRule?.tags.contains("api-v1") ?? false)
        XCTAssertTrue(updatedRule?.tags.contains("test_env") ?? false)
        XCTAssertTrue(updatedRule?.tags.contains("prod.us-west") ?? false)
    }

    func testTagsWithWhitespace() {
        // Arrange
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            tags: []
        )
        RewriteManager.shared.createRule(rule)

        // Act
        sut.addTag("tag with spaces", to: rule.id)

        // Assert
        let updatedRule = RewriteManager.shared.rules.first { $0.id == rule.id }
        XCTAssertNotNil(updatedRule)
        XCTAssertTrue(updatedRule?.tags.contains("tag with spaces") ?? false)
    }
}
