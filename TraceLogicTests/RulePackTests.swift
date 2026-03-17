//
//  RulePackTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

final class RulePackTests: XCTestCase {
    // MARK: - RulePackMetadata Tests

    func testRulePackMetadataInitialization() {
        let metadata = RulePackMetadata(
            name: "Test Pack",
            version: "1.0.0",
            author: "Test Author",
            description: "Test description"
        )

        XCTAssertEqual(metadata.name, "Test Pack")
        XCTAssertEqual(metadata.version, "1.0.0")
        XCTAssertEqual(metadata.author, "Test Author")
        XCTAssertEqual(metadata.description, "Test description")
        XCTAssertNotNil(metadata.createdAt)
    }

    func testRulePackMetadataWithCustomDate() {
        let customDate = Date(timeIntervalSince1970: 1_000_000)
        let metadata = RulePackMetadata(
            name: "Test",
            version: "2.0",
            author: "Author",
            description: "Desc",
            createdAt: customDate
        )

        XCTAssertEqual(metadata.createdAt, customDate)
    }

    func testRulePackMetadataCodable() throws {
        let original = RulePackMetadata(
            name: "API Rules Pack",
            version: "1.2.3",
            author: "John Doe",
            description: "Collection of API testing rules"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RulePackMetadata.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.author, original.author)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - RulePack Tests

    func testRulePackInitialization() {
        let metadata = RulePackMetadata(
            name: "Test Pack",
            version: "1.0.0",
            author: "Test",
            description: "Test"
        )
        let rules: [RewriteRule] = []
        let groups: [RuleGroup] = []

        let pack = RulePack(metadata: metadata, rules: rules, groups: groups)

        XCTAssertEqual(pack.metadata.name, "Test Pack")
        XCTAssertTrue(pack.rules.isEmpty)
        XCTAssertTrue(pack.groups.isEmpty)
    }

    func testRulePackWithRulesAndGroups() {
        let metadata = RulePackMetadata(
            name: "Full Pack",
            version: "1.0.0",
            author: "Author",
            description: "Description"
        )

        let rule1 = RewriteRule(
            name: "Rule 1",
            ruleType: .block,
            matchPattern: "*.example.com"
        )
        let rule2 = RewriteRule(
            name: "Rule 2",
            ruleType: .redirect,
            matchPattern: "test.com"
        )

        let group1 = RuleGroup(name: "Group 1", rules: [rule1.id])
        let group2 = RuleGroup(name: "Group 2", rules: [rule2.id])

        let pack = RulePack(
            metadata: metadata,
            rules: [rule1, rule2],
            groups: [group1, group2]
        )

        XCTAssertEqual(pack.rules.count, 2)
        XCTAssertEqual(pack.groups.count, 2)
        XCTAssertEqual(pack.metadata.name, "Full Pack")
    }

    func testRulePackCodable() throws {
        let metadata = RulePackMetadata(
            name: "Encodable Pack",
            version: "2.0.0",
            author: "Test Author",
            description: "Test Description"
        )

        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            matchPattern: "*.api.com"
        )

        let group = RuleGroup(
            name: "Test Group",
            rules: [rule.id],
            priority: 10
        )

        let original = RulePack(
            metadata: metadata,
            rules: [rule],
            groups: [group]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RulePack.self, from: data)

        XCTAssertEqual(decoded.metadata.name, original.metadata.name)
        XCTAssertEqual(decoded.metadata.version, original.metadata.version)
        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertEqual(decoded.groups.count, 1)
        XCTAssertEqual(decoded.rules.first?.name, "Test Rule")
        XCTAssertEqual(decoded.groups.first?.name, "Test Group")
    }

    // MARK: - MergeStrategy Tests

    func testMergeStrategyRawValues() {
        XCTAssertEqual(MergeStrategy.replace.rawValue, "replace")
        XCTAssertEqual(MergeStrategy.merge.rawValue, "merge")
        XCTAssertEqual(MergeStrategy.ask.rawValue, "ask")
    }

    func testMergeStrategyCodable() throws {
        let strategies: [MergeStrategy] = [.replace, .merge, .ask]

        for strategy in strategies {
            let data = try JSONEncoder().encode(strategy)
            let decoded = try JSONDecoder().decode(MergeStrategy.self, from: data)
            XCTAssertEqual(decoded, strategy)
        }
    }

    // MARK: - Edge Cases

    func testRulePackWithEmptyCollections() throws {
        let metadata = RulePackMetadata(
            name: "Empty Pack",
            version: "0.0.1",
            author: "Nobody",
            description: "Empty"
        )

        let pack = RulePack(metadata: metadata, rules: [], groups: [])

        XCTAssertTrue(pack.rules.isEmpty)
        XCTAssertTrue(pack.groups.isEmpty)

        let data = try JSONEncoder().encode(pack)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)

        XCTAssertTrue(decoded.rules.isEmpty)
        XCTAssertTrue(decoded.groups.isEmpty)
    }

    func testRulePackWithManyRules() throws {
        let metadata = RulePackMetadata(
            name: "Large Pack",
            version: "1.0.0",
            author: "Author",
            description: "Pack with many rules"
        )

        let rules = (0 ..< 100).map { i in
            RewriteRule(
                name: "Rule \(i)",
                ruleType: .block,
                matchPattern: "test\(i).com"
            )
        }

        let pack = RulePack(metadata: metadata, rules: rules, groups: [])

        XCTAssertEqual(pack.rules.count, 100)

        let data = try JSONEncoder().encode(pack)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)

        XCTAssertEqual(decoded.rules.count, 100)
    }

    func testRulePackMetadataWithEmptyStrings() throws {
        let metadata = RulePackMetadata(
            name: "",
            version: "",
            author: "",
            description: ""
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RulePackMetadata.self, from: data)

        XCTAssertEqual(decoded.name, "")
        XCTAssertEqual(decoded.version, "")
        XCTAssertEqual(decoded.author, "")
        XCTAssertEqual(decoded.description, "")
    }

    func testRulePackMetadataWithSpecialCharacters() throws {
        let metadata = RulePackMetadata(
            name: "Pack @#$%^&*()",
            version: "1.0.0-beta+build.123",
            author: "Author <email@example.com>",
            description: "Description with émojis 📦 and üñíçødé"
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RulePackMetadata.self, from: data)

        XCTAssertEqual(decoded.name, metadata.name)
        XCTAssertEqual(decoded.version, metadata.version)
        XCTAssertEqual(decoded.author, metadata.author)
        XCTAssertEqual(decoded.description, metadata.description)
    }

    func testRulePackMetadataWithVeryLongStrings() throws {
        let longString = String(repeating: "A", count: 10000)
        let metadata = RulePackMetadata(
            name: longString,
            version: "1.0.0",
            author: longString,
            description: longString
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RulePackMetadata.self, from: data)

        XCTAssertEqual(decoded.name.count, 10000)
        XCTAssertEqual(decoded.author.count, 10000)
        XCTAssertEqual(decoded.description.count, 10000)
    }

    func testRulePackWithComplexRuleGroups() throws {
        let metadata = RulePackMetadata(
            name: "Complex Pack",
            version: "1.0.0",
            author: "Test",
            description: "Complex rule relationships"
        )

        let rule1 = RewriteRule(name: "R1", ruleType: .block, matchPattern: "a.com")
        let rule2 = RewriteRule(name: "R2", ruleType: .redirect, matchPattern: "b.com")
        let rule3 = RewriteRule(name: "R3", ruleType: .modifyRequest, matchPattern: "c.com")

        let group1 = RuleGroup(name: "G1", rules: [rule1.id, rule2.id], priority: 100)
        let group2 = RuleGroup(name: "G2", rules: [rule2.id, rule3.id], priority: 50)
        let group3 = RuleGroup(name: "G3", rules: [rule1.id, rule3.id], priority: 75)

        let pack = RulePack(
            metadata: metadata,
            rules: [rule1, rule2, rule3],
            groups: [group1, group2, group3]
        )

        XCTAssertEqual(pack.rules.count, 3)
        XCTAssertEqual(pack.groups.count, 3)

        let data = try JSONEncoder().encode(pack)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)

        XCTAssertEqual(decoded.rules.count, 3)
        XCTAssertEqual(decoded.groups.count, 3)

        // Verify group priorities are preserved
        let sortedGroups = decoded.groups.sorted { $0.priority > $1.priority }
        XCTAssertEqual(sortedGroups[0].name, "G1")
        XCTAssertEqual(sortedGroups[1].name, "G3")
        XCTAssertEqual(sortedGroups[2].name, "G2")
    }

    func testRulePackDatePrecision() throws {
        let now = Date()
        let metadata = RulePackMetadata(
            name: "Date Test",
            version: "1.0.0",
            author: "Test",
            description: "Testing date precision",
            createdAt: now
        )

        let pack = RulePack(metadata: metadata, rules: [], groups: [])

        let data = try JSONEncoder().encode(pack)
        let decoded = try JSONDecoder().decode(RulePack.self, from: data)

        XCTAssertEqual(
            decoded.metadata.createdAt.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    // MARK: - JSON Compatibility Tests

    func testRulePackJSONStructure() throws {
        let metadata = RulePackMetadata(
            name: "JSON Test",
            version: "1.0.0",
            author: "Test",
            description: "Test"
        )

        let pack = RulePack(metadata: metadata, rules: [], groups: [])

        let encoder = JSONEncoder()
        let data = try encoder.encode(pack)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertNotNil(json?["metadata"])
        XCTAssertNotNil(json?["rules"])
        XCTAssertNotNil(json?["groups"])

        let metadataJson = json?["metadata"] as? [String: Any]
        XCTAssertNotNil(metadataJson?["name"])
        XCTAssertNotNil(metadataJson?["version"])
        XCTAssertNotNil(metadataJson?["author"])
        XCTAssertNotNil(metadataJson?["description"])
        XCTAssertNotNil(metadataJson?["createdAt"])
    }

    func testRulePackRoundTripWithPrettyPrinting() throws {
        let metadata = RulePackMetadata(
            name: "Pretty Print",
            version: "1.0.0",
            author: "Test",
            description: "Test pretty printing"
        )

        let rule = RewriteRule(name: "Rule", ruleType: .block, matchPattern: "*.com")
        let pack = RulePack(metadata: metadata, rules: [rule], groups: [])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pack)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RulePack.self, from: data)

        XCTAssertEqual(decoded.metadata.name, pack.metadata.name)
        XCTAssertEqual(decoded.rules.count, 1)
    }

    func testRulePackMutability() {
        let metadata = RulePackMetadata(
            name: "Original",
            version: "1.0.0",
            author: "Author",
            description: "Original description"
        )

        var pack = RulePack(metadata: metadata, rules: [], groups: [])

        XCTAssertTrue(pack.rules.isEmpty)
        XCTAssertTrue(pack.groups.isEmpty)

        let newRule = RewriteRule(name: "New Rule", ruleType: .block, matchPattern: "test.com")
        let newGroup = RuleGroup(name: "New Group", rules: [newRule.id])

        pack.rules.append(newRule)
        pack.groups.append(newGroup)

        XCTAssertEqual(pack.rules.count, 1)
        XCTAssertEqual(pack.groups.count, 1)
    }
}
