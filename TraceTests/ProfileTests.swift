//
//  ProfileTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class ProfileTests: XCTestCase {

    // MARK: - Initialization Tests

    func testProfileInitialization() {
        let profile = Profile(name: "Test Profile")

        XCTAssertEqual(profile.name, "Test Profile")
        XCTAssertNil(profile.description)
        XCTAssertTrue(profile.ruleGroups.isEmpty)
        XCTAssertFalse(profile.isActive)
        XCTAssertNotNil(profile.id)
        XCTAssertNotNil(profile.createdAt)
    }

    func testProfileInitializationWithAllParameters() {
        let id = UUID()
        let createdAt = Date()
        let ruleGroups = [UUID(), UUID(), UUID()]

        let profile = Profile(
            id: id,
            name: "Production Profile",
            description: "Profile for production environment",
            ruleGroups: ruleGroups,
            isActive: true,
            createdAt: createdAt
        )

        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.name, "Production Profile")
        XCTAssertEqual(profile.description, "Profile for production environment")
        XCTAssertEqual(profile.ruleGroups, ruleGroups)
        XCTAssertTrue(profile.isActive)
        XCTAssertEqual(profile.createdAt, createdAt)
    }

    func testProfileDefaultValues() {
        let profile = Profile(name: "Default Test")

        XCTAssertNil(profile.description)
        XCTAssertTrue(profile.ruleGroups.isEmpty)
        XCTAssertFalse(profile.isActive, "Default isActive should be false")
    }

    // MARK: - Codable Tests

    func testProfileEncodeDecode() throws {
        let ruleGroups = [UUID(), UUID()]
        let original = Profile(
            name: "API Testing",
            description: "Profile for API tests",
            ruleGroups: ruleGroups,
            isActive: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Profile.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.ruleGroups, original.ruleGroups)
        XCTAssertEqual(decoded.isActive, original.isActive)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testProfileEncodeDecodeWithNilDescription() throws {
        let original = Profile(
            name: "No Description Profile",
            description: nil,
            ruleGroups: [],
            isActive: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertNil(decoded.description)
        XCTAssertEqual(decoded.name, original.name)
    }

    func testProfileEncodeDecodeEmptyRuleGroups() throws {
        let original = Profile(name: "Empty", ruleGroups: [])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertTrue(decoded.ruleGroups.isEmpty)
    }

    func testProfileEncodeDecodeMultipleRuleGroups() throws {
        let ruleGroups = [UUID(), UUID(), UUID(), UUID(), UUID()]
        let original = Profile(name: "Many Rules", ruleGroups: ruleGroups)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertEqual(decoded.ruleGroups.count, 5)
        XCTAssertEqual(decoded.ruleGroups, original.ruleGroups)
    }

    // MARK: - Identifiable Tests

    func testProfileIdentifiable() {
        let profile1 = Profile(name: "Profile 1")
        let profile2 = Profile(name: "Profile 2")

        XCTAssertNotEqual(profile1.id, profile2.id, "Each profile should have a unique ID")
    }

    func testProfileWithSameIDButDifferentContent() {
        let id = UUID()
        let profile1 = Profile(id: id, name: "Name 1", isActive: false)
        let profile2 = Profile(id: id, name: "Name 2", isActive: true)

        XCTAssertEqual(profile1.id, profile2.id)
        XCTAssertNotEqual(profile1.name, profile2.name)
    }

    // MARK: - Equatable Tests

    func testProfileEquatable() {
        let id = UUID()
        let ruleGroups = [UUID()]
        let createdAt = Date()

        let profile1 = Profile(
            id: id,
            name: "Test",
            description: "Description",
            ruleGroups: ruleGroups,
            isActive: true,
            createdAt: createdAt
        )

        let profile2 = Profile(
            id: id,
            name: "Test",
            description: "Description",
            ruleGroups: ruleGroups,
            isActive: true,
            createdAt: createdAt
        )

        XCTAssertEqual(profile1, profile2)
    }

    func testProfileNotEqualWithDifferentIDs() {
        let profile1 = Profile(name: "Same Name")
        let profile2 = Profile(name: "Same Name")

        XCTAssertNotEqual(profile1, profile2, "Profiles with different IDs should not be equal")
    }

    func testProfileNotEqualWithDifferentFields() {
        let id = UUID()

        let profile1 = Profile(id: id, name: "Name 1", isActive: false)
        let profile2 = Profile(id: id, name: "Name 2", isActive: true)

        // Even though they have the same ID, they differ in other fields
        XCTAssertNotEqual(profile1, profile2)
    }

    // MARK: - Edge Cases

    func testProfileWithEmptyName() throws {
        let profile = Profile(name: "")

        XCTAssertEqual(profile.name, "")

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertEqual(decoded.name, "")
    }

    func testProfileWithVeryLongName() throws {
        let longName = String(repeating: "A", count: 10000)
        let profile = Profile(name: longName)

        XCTAssertEqual(profile.name.count, 10000)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertEqual(decoded.name, longName)
    }

    func testProfileWithSpecialCharacters() throws {
        let specialName = "Test @#$%^&*()_+-=[]{}|;:',.<>?/~`"
        let specialDescription = "Description with émojis 🚀 and üñíçødé"

        let profile = Profile(
            name: specialName,
            description: specialDescription
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertEqual(decoded.name, specialName)
        XCTAssertEqual(decoded.description, specialDescription)
    }

    func testProfileWithManyRuleGroups() throws {
        let manyRuleGroups = (0..<1000).map { _ in UUID() }
        let profile = Profile(name: "Many Rules", ruleGroups: manyRuleGroups)

        XCTAssertEqual(profile.ruleGroups.count, 1000)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertEqual(decoded.ruleGroups.count, 1000)
        XCTAssertEqual(decoded.ruleGroups, manyRuleGroups)
    }

    func testProfileWithDuplicateRuleGroupIDs() {
        let duplicateID = UUID()
        let ruleGroups = [duplicateID, duplicateID, duplicateID]

        let profile = Profile(name: "Duplicates", ruleGroups: ruleGroups)

        XCTAssertEqual(profile.ruleGroups.count, 3)
        XCTAssertEqual(profile.ruleGroups[0], profile.ruleGroups[1])
        XCTAssertEqual(profile.ruleGroups[1], profile.ruleGroups[2])
    }

    func testProfileDatePrecision() throws {
        let now = Date()
        let profile = Profile(name: "Date Test", createdAt: now)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        // Allow for small floating point differences
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testProfileMutability() {
        var profile = Profile(name: "Original")

        XCTAssertEqual(profile.name, "Original")
        XCTAssertFalse(profile.isActive)

        profile.name = "Modified"
        profile.isActive = true
        profile.description = "New description"
        profile.ruleGroups = [UUID()]

        XCTAssertEqual(profile.name, "Modified")
        XCTAssertTrue(profile.isActive)
        XCTAssertEqual(profile.description, "New description")
        XCTAssertEqual(profile.ruleGroups.count, 1)
    }

    // MARK: - JSON Compatibility Tests

    func testProfileJSONKeys() throws {
        let profile = Profile(
            name: "Test",
            description: "Description",
            ruleGroups: [UUID()],
            isActive: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(profile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertNotNil(json?["id"])
        XCTAssertNotNil(json?["name"])
        XCTAssertNotNil(json?["description"])
        XCTAssertNotNil(json?["ruleGroups"])
        XCTAssertNotNil(json?["isActive"])
        XCTAssertNotNil(json?["createdAt"])
    }

    func testProfileRoundTripWithPrettyPrinting() throws {
        let profile = Profile(
            name: "Pretty Print Test",
            description: "Testing JSON formatting"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(profile)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Profile.self, from: data)

        XCTAssertEqual(decoded, profile)
    }
}
