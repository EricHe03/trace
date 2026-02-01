//
//  RuleGroupTests.swift
//  TraceTests
//
//  Created by Claude ​Code on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class RuleGroupTests: XCTestCase {

    // MARK: - Initialization Tests

    func testRuleGroupInitialization() {
        let ruleGroup = RuleGroup(name: "Test Group")

        XCTAssertEqual(ruleGroup.name, "Test Group")
        XCTAssertTrue(ruleGroup.enabled)
        XCTAssertTrue(ruleGroup.rules.isEmpty)
        XCTAssertEqual(ruleGroup.priority, 0)
        XCTAssertEqual(ruleGroup.failurePolicy, .failOpen)
        XCTAssertNil(ruleGroup.description)
        XCTAssertNotNil(ruleGroup.id)
    }

    func testRuleGroupInitializationWithAllParameters() {
        let id = UUID()
        let rules = [UUID(), UUID(), UUID()]

        let ruleGroup = RuleGroup(
            id: id,
            name: "Production Rules",
            enabled: false,
            rules: rules,
            priority: 100,
            failurePolicy: .failClosed,
            description: "Critical production rules"
        )

        XCTAssertEqual(ruleGroup.id, id)
        XCTAssertEqual(ruleGroup.name, "Production Rules")
        XCTAssertFalse(ruleGroup.enabled)
        XCTAssertEqual(ruleGroup.rules, rules)
        XCTAssertEqual(ruleGroup.priority, 100)
        XCTAssertEqual(ruleGroup.failurePolicy, .failClosed)
        XCTAssertEqual(ruleGroup.description, "Critical production rules")
    }

    func testRuleGroupDefaultValues() {
        let ruleGroup = RuleGroup(name: "Defaults")

        XCTAssertTrue(ruleGroup.enabled, "Default enabled should be true")
        XCTAssertTrue(ruleGroup.rules.isEmpty, "Default rules should be empty")
        XCTAssertEqual(ruleGroup.priority, 0, "Default priority should be 0")
        XCTAssertEqual(ruleGroup.failurePolicy, .failOpen, "Default policy should be failOpen")
        XCTAssertNil(ruleGroup.description, "Default description should be nil")
    }

    // MARK: - FailurePolicy Tests

    func testFailurePolicyRawValues() {
        XCTAssertEqual(FailurePolicy.failOpen.rawValue, "failOpen")
        XCTAssertEqual(FailurePolicy.failClosed.rawValue, "failClosed")
        XCTAssertEqual(FailurePolicy.failMock.rawValue, "failMock")
    }

    func testFailurePolicyCodable() throws {
        let policies: [FailurePolicy] = [.failOpen, .failClosed, .failMock]

        for policy in policies {
            let data = try JSONEncoder().encode(policy)
            let decoded = try JSONDecoder().decode(FailurePolicy.self, from: data)
            XCTAssertEqual(decoded, policy)
        }
    }

    // MARK: - Codable Tests

    func testRuleGroupEncodeDecode() throws {
        let rules = [UUID(), UUID()]
        let original = RuleGroup(
            name: "API Rules",
            enabled: true,
            rules: rules,
            priority: 50,
            failurePolicy: .failMock,
            description: "Rules for API testing"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RuleGroup.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.enabled, original.enabled)
        XCTAssertEqual(decoded.rules, original.rules)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.failurePolicy, original.failurePolicy)
        XCTAssertEqual(decoded.description, original.description)
    }

    func testRuleGroupEncodeDecodeWithNilDescription() throws {
        let original = RuleGroup(
            name: "No Description",
            description: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

        XCTAssertNil(decoded.description)
        XCTAssertEqual(decoded.name, original.name)
    }

    func testRuleGroupEncodeDecodeEmptyRules() throws {
        let original = RuleGroup(name: "Empty", rules: [])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

        XCTAssertTrue(decoded.rules.isEmpty)
    }

    // MARK: - Identifiable Tests

    func testRuleGroupIdentifiable() {
        let group1 = RuleGroup(name: "Group 1")
        let group2 = RuleGroup(name: "Group 2")

        XCTAssertNotEqual(group1.id, group2.id, "Each rule group should have a unique ID")
    }

    // MARK: - Equatable Tests

    func testRuleGroupEquatable() {
        let id = UUID()
        let rules = [UUID()]

        let group1 = RuleGroup(
            id: id,
            name: "Test",
            enabled: true,
            rules: rules,
            priority: 10,
            failurePolicy: .failOpen,
            description: "Description"
        )

        let group2 = RuleGroup(
            id: id,
            name: "Test",
            enabled: true,
            rules: rules,
            priority: 10,
            failurePolicy: .failOpen,
            description: "Description"
        )

        XCTAssertEqual(group1, group2)
    }

    func testRuleGroupNotEqualWithDifferentIDs() {
        let group1 = RuleGroup(name: "Same Name")
        let group2 = RuleGroup(name: "Same Name")

        XCTAssertNotEqual(group1, group2, "Groups with different IDs should not be equal")
    }

    func testRuleGroupNotEqualWithDifferentFields() {
        let id = UUID()

        let group1 = RuleGroup(id: id, name: "Name 1", priority: 10)
        let group2 = RuleGroup(id: id, name: "Name 2", priority: 20)

        XCTAssertNotEqual(group1, group2)
    }

    // MARK: - Priority Tests

    func testRuleGroupWithNegativePriority() throws {
        let group = RuleGroup(name: "Negative", priority: -100)

        XCTAssertEqual(group.priority, -100)

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

        XCTAssertEqual(decoded.priority, -100)
    }

    func testRuleGroupWithHighPriority() throws {
        let group = RuleGroup(name: "High", priority: Int.max)

        XCTAssertEqual(group.priority, Int.max)

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

        XCTAssertEqual(decoded.priority, Int.max)
    }

    // MARK: - Toggleable Protocol Tests

    func testRuleGroupToggleable() {
        var group = RuleGroup(name: "Toggleable", enabled: true)

        XCTAssertTrue(group.enabled)

        group.enabled = false
        XCTAssertFalse(group.enabled)

        group.enabled = true
        XCTAssertTrue(group.enabled)
    }

    // MARK: - Edge Cases

    func testRuleGroupWithEmptyName() throws {
        let group = RuleGroup(name: "")

        XCTAssertEqual(group.name, "")

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

        XCTAssertEqual(decoded.name, "")
    }

    func testRuleGroupWithVeryLongName() throws {
        let longName = String(repeating: "X", count: 5000)
        let group = RuleGroup(name: longName)

        XCTAssertEqual(group.name.count, 5000)

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

        XCTAssertEqual(decoded.name, longName)
    }

    func testRuleGroupWithSpecialCharacters() throws {
        let specialName = "Group @#$%^&*()_+-=[]{}|;:',.<>?/~`"
        let specialDescription = "Description with émojis 🔧 and special chars"

        let group = RuleGroup(
            name: specialName,
            description: specialDescription
        )

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

        XCTAssertEqual(decoded.name, specialName)
        XCTAssertEqual(decoded.description, specialDescription)
    }

    func testRuleGroupWithManyRules() throws {
        let manyRules = (0..<1000).map { _ in UUID() }
        let group = RuleGroup(name: "Many Rules", rules: manyRules)

        XCTAssertEqual(group.rules.count, 1000)

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

        XCTAssertEqual(decoded.rules.count, 1000)
        XCTAssertEqual(decoded.rules, manyRules)
    }

    func testRuleGroupWithDuplicateRuleIDs() {
        let duplicateID = UUID()
        let rules = [duplicateID, duplicateID, duplicateID]

        let group = RuleGroup(name: "Duplicates", rules: rules)

        XCTAssertEqual(group.rules.count, 3)
        XCTAssertEqual(group.rules[0], group.rules[1])
        XCTAssertEqual(group.rules[1], group.rules[2])
    }

    func testRuleGroupMutability() {
        var group = RuleGroup(name: "Original")

        XCTAssertEqual(group.name, "Original")
        XCTAssertTrue(group.enabled)
        XCTAssertEqual(group.priority, 0)

        group.name = "Modified"
        group.enabled = false
        group.priority = 99
        group.description = "New description"
        group.rules = [UUID()]
        group.failurePolicy = .failClosed

        XCTAssertEqual(group.name, "Modified")
        XCTAssertFalse(group.enabled)
        XCTAssertEqual(group.priority, 99)
        XCTAssertEqual(group.description, "New description")
        XCTAssertEqual(group.rules.count, 1)
        XCTAssertEqual(group.failurePolicy, .failClosed)
    }

    // MARK: - JSON Compatibility Tests

    func testRuleGroupJSONKeys() throws {
        let group = RuleGroup(
            name: "Test",
            enabled: true,
            rules: [UUID()],
            priority: 50,
            failurePolicy: .failOpen,
            description: "Description"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(group)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertNotNil(json?["id"])
        XCTAssertNotNil(json?["name"])
        XCTAssertNotNil(json?["enabled"])
        XCTAssertNotNil(json?["rules"])
        XCTAssertNotNil(json?["priority"])
        XCTAssertNotNil(json?["failurePolicy"])
        XCTAssertNotNil(json?["description"])
    }

    func testRuleGroupAllFailurePolicies() throws {
        let policies: [FailurePolicy] = [.failOpen, .failClosed, .failMock]

        for policy in policies {
            let group = RuleGroup(
                name: "Test \(policy.rawValue)",
                failurePolicy: policy
            )

            let data = try JSONEncoder().encode(group)
            let decoded = try JSONDecoder().decode(RuleGroup.self, from: data)

            XCTAssertEqual(decoded.failurePolicy, policy)
        }
    }
}
