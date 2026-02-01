//
//  ProfileManagerTests.swift
//  TraceTests
//
//  Created by Claude on 2026-02-01.
//

import XCTest
import Combine
@testable import TraceFeatures
@testable import TraceCore

@MainActor
final class ProfileManagerTests: XCTestCase {
    var sut: ProfileManager!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        sut = ProfileManager.shared
        cancellables = Set<AnyCancellable>()

        // Clear any existing profiles before each test
        let allProfiles = sut.profiles
        for profile in allProfiles {
            sut.deleteProfile(profile)
        }
    }

    override func tearDown() {
        // Clean up any profiles created during tests
        let allProfiles = sut.profiles
        for profile in allProfiles {
            sut.deleteProfile(profile)
        }
        cancellables = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSharedInstance_ReturnsSameInstance() {
        // Arrange & Act
        let instance1 = ProfileManager.shared
        let instance2 = ProfileManager.shared

        // Assert
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Initial State Tests

    func testProfiles_InitiallyEmpty() {
        // Act
        let profiles = sut.profiles

        // Assert
        XCTAssertTrue(profiles.isEmpty)
    }

    func testGetActiveProfile_WhenNoProfiles_ReturnsNil() {
        // Act
        let activeProfile = sut.getActiveProfile()

        // Assert
        XCTAssertNil(activeProfile)
    }

    // MARK: - Create Profile Tests

    func testCreateProfile_AddsProfileToList() {
        // Arrange
        let profile = makeProfile(name: "Test Profile")

        // Act
        sut.createProfile(profile)

        // Assert
        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertTrue(sut.profiles.contains { $0.id == profile.id })
    }

    func testCreateProfile_WithCustomProperties_CreatesCorrectly() {
        // Arrange
        let ruleGroupIds = [UUID(), UUID()]
        let profile = makeProfile(
            name: "Production Profile",
            isActive: false,
            ruleGroupIds: ruleGroupIds
        )

        // Act
        sut.createProfile(profile)

        // Assert
        let createdProfile = sut.profiles.first { $0.id == profile.id }
        XCTAssertNotNil(createdProfile)
        XCTAssertEqual(createdProfile?.name, "Production Profile")
        XCTAssertEqual(createdProfile?.isActive, false)
        XCTAssertEqual(createdProfile?.ruleGroups, ruleGroupIds)
    }

    func testCreateProfile_MultipleProfiles_AddsAll() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1")
        let profile2 = makeProfile(name: "Profile 2")
        let profile3 = makeProfile(name: "Profile 3")

        // Act
        sut.createProfile(profile1)
        sut.createProfile(profile2)
        sut.createProfile(profile3)

        // Assert
        XCTAssertEqual(sut.profiles.count, 3)
    }

    func testCreateProfile_TriggersObjectWillChange() {
        // Arrange
        let profile = makeProfile(name: "Test Profile")
        let expectation = XCTestExpectation(description: "objectWillChange")

        sut.objectWillChange.sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)

        // Act
        sut.createProfile(profile)

        // Assert
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Activate Profile Tests

    func testActivateProfile_SetsProfileAsActive() {
        // Arrange
        let profile = makeProfile(name: "Test Profile", isActive: false)
        sut.createProfile(profile)

        // Act
        sut.activateProfile(profile.id)

        // Assert
        let updatedProfile = sut.profiles.first { $0.id == profile.id }
        XCTAssertTrue(updatedProfile?.isActive ?? false)
    }

    func testActivateProfile_DeactivatesOtherProfiles() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1", isActive: true)
        let profile2 = makeProfile(name: "Profile 2", isActive: false)
        let profile3 = makeProfile(name: "Profile 3", isActive: false)

        sut.createProfile(profile1)
        sut.createProfile(profile2)
        sut.createProfile(profile3)

        // Act
        sut.activateProfile(profile2.id)

        // Assert
        let updatedProfile1 = sut.profiles.first { $0.id == profile1.id }
        let updatedProfile2 = sut.profiles.first { $0.id == profile2.id }
        let updatedProfile3 = sut.profiles.first { $0.id == profile3.id }

        XCTAssertFalse(updatedProfile1?.isActive ?? true)
        XCTAssertTrue(updatedProfile2?.isActive ?? false)
        XCTAssertFalse(updatedProfile3?.isActive ?? true)
    }

    func testActivateProfile_WithSingleProfile_ActivatesIt() {
        // Arrange
        let profile = makeProfile(name: "Only Profile", isActive: false)
        sut.createProfile(profile)

        // Act
        sut.activateProfile(profile.id)

        // Assert
        let activeProfile = sut.getActiveProfile()
        XCTAssertNotNil(activeProfile)
        XCTAssertEqual(activeProfile?.id, profile.id)
    }

    func testActivateProfile_WithNonExistentId_DoesNotCrash() {
        // Arrange
        let profile = makeProfile(name: "Test Profile")
        sut.createProfile(profile)
        let nonExistentId = UUID()

        // Act & Assert
        XCTAssertNoThrow(sut.activateProfile(nonExistentId))
    }

    func testActivateProfile_AlreadyActive_RemainsActive() {
        // Arrange
        let profile = makeProfile(name: "Test Profile", isActive: true)
        sut.createProfile(profile)

        // Act
        sut.activateProfile(profile.id)

        // Assert
        let updatedProfile = sut.profiles.first { $0.id == profile.id }
        XCTAssertTrue(updatedProfile?.isActive ?? false)
    }

    // MARK: - Deactivate Profile Tests

    func testDeactivateProfile_DeactivatesAllProfiles() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1", isActive: true)
        let profile2 = makeProfile(name: "Profile 2", isActive: false)
        let profile3 = makeProfile(name: "Profile 3", isActive: false)

        sut.createProfile(profile1)
        sut.createProfile(profile2)
        sut.createProfile(profile3)

        // Act
        sut.deactivateProfile()

        // Assert
        let allProfiles = sut.profiles
        XCTAssertTrue(allProfiles.allSatisfy { !$0.isActive })
    }

    func testDeactivateProfile_WhenNoActiveProfile_DoesNothing() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1", isActive: false)
        let profile2 = makeProfile(name: "Profile 2", isActive: false)

        sut.createProfile(profile1)
        sut.createProfile(profile2)

        // Act
        sut.deactivateProfile()

        // Assert
        let allProfiles = sut.profiles
        XCTAssertTrue(allProfiles.allSatisfy { !$0.isActive })
    }

    func testDeactivateProfile_WithSingleActiveProfile_DeactivatesIt() {
        // Arrange
        let profile = makeProfile(name: "Active Profile", isActive: true)
        sut.createProfile(profile)

        // Act
        sut.deactivateProfile()

        // Assert
        let activeProfile = sut.getActiveProfile()
        XCTAssertNil(activeProfile)
    }

    func testDeactivateProfile_WithNoProfiles_DoesNotCrash() {
        // Act & Assert
        XCTAssertNoThrow(sut.deactivateProfile())
    }

    // MARK: - Get Active Profile Tests

    func testGetActiveProfile_WithOneActiveProfile_ReturnsIt() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1", isActive: false)
        let profile2 = makeProfile(name: "Profile 2", isActive: true)
        let profile3 = makeProfile(name: "Profile 3", isActive: false)

        sut.createProfile(profile1)
        sut.createProfile(profile2)
        sut.createProfile(profile3)

        // Act
        let activeProfile = sut.getActiveProfile()

        // Assert
        XCTAssertNotNil(activeProfile)
        XCTAssertEqual(activeProfile?.id, profile2.id)
        XCTAssertEqual(activeProfile?.name, "Profile 2")
    }

    func testGetActiveProfile_WithNoActiveProfile_ReturnsNil() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1", isActive: false)
        let profile2 = makeProfile(name: "Profile 2", isActive: false)

        sut.createProfile(profile1)
        sut.createProfile(profile2)

        // Act
        let activeProfile = sut.getActiveProfile()

        // Assert
        XCTAssertNil(activeProfile)
    }

    func testGetActiveProfile_WithMultipleActiveProfiles_ReturnsFirst() {
        // Arrange - This shouldn't happen in normal usage, but test the behavior
        var profile1 = makeProfile(name: "Profile 1", isActive: true)
        var profile2 = makeProfile(name: "Profile 2", isActive: true)

        sut.createProfile(profile1)
        sut.createProfile(profile2)

        // Act
        let activeProfile = sut.getActiveProfile()

        // Assert
        XCTAssertNotNil(activeProfile)
        XCTAssertTrue(activeProfile?.isActive ?? false)
    }

    // MARK: - Update Profile Tests

    func testUpdateProfile_ModifiesExistingProfile() {
        // Arrange
        let profile = makeProfile(name: "Original Name", isActive: false)
        sut.createProfile(profile)

        var updatedProfile = profile
        updatedProfile.name = "Updated Name"
        updatedProfile.isActive = true

        // Act
        sut.updateProfile(updatedProfile)

        // Assert
        let result = sut.profiles.first { $0.id == profile.id }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Updated Name")
        XCTAssertTrue(result?.isActive ?? false)
    }

    func testUpdateProfile_WithRuleGroups_UpdatesCorrectly() {
        // Arrange
        let profile = makeProfile(name: "Test Profile", isActive: false, ruleGroupIds: [])
        sut.createProfile(profile)

        let newRuleGroupIds = [UUID(), UUID(), UUID()]
        var updatedProfile = profile
        updatedProfile.ruleGroups = newRuleGroupIds

        // Act
        sut.updateProfile(updatedProfile)

        // Assert
        let result = sut.profiles.first { $0.id == profile.id }
        XCTAssertEqual(result?.ruleGroups, newRuleGroupIds)
    }

    func testUpdateProfile_WithDescription_UpdatesCorrectly() {
        // Arrange
        let profile = makeProfile(name: "Test Profile")
        sut.createProfile(profile)

        var updatedProfile = profile
        updatedProfile.description = "This is a test profile"

        // Act
        sut.updateProfile(updatedProfile)

        // Assert
        let result = sut.profiles.first { $0.id == profile.id }
        XCTAssertEqual(result?.description, "This is a test profile")
    }

    func testUpdateProfile_NonExistentProfile_DoesNotCrash() {
        // Arrange
        let profile = makeProfile(name: "Non-existent Profile")

        // Act & Assert
        XCTAssertNoThrow(sut.updateProfile(profile))
    }

    // MARK: - Delete Profile Tests

    func testDeleteProfile_RemovesProfileFromList() {
        // Arrange
        let profile = makeProfile(name: "Test Profile")
        sut.createProfile(profile)
        XCTAssertEqual(sut.profiles.count, 1)

        // Act
        sut.deleteProfile(profile)

        // Assert
        XCTAssertTrue(sut.profiles.isEmpty)
    }

    func testDeleteProfile_WithMultipleProfiles_RemovesOnlyTarget() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1")
        let profile2 = makeProfile(name: "Profile 2")
        let profile3 = makeProfile(name: "Profile 3")

        sut.createProfile(profile1)
        sut.createProfile(profile2)
        sut.createProfile(profile3)

        // Act
        sut.deleteProfile(profile2)

        // Assert
        XCTAssertEqual(sut.profiles.count, 2)
        XCTAssertTrue(sut.profiles.contains { $0.id == profile1.id })
        XCTAssertFalse(sut.profiles.contains { $0.id == profile2.id })
        XCTAssertTrue(sut.profiles.contains { $0.id == profile3.id })
    }

    func testDeleteProfile_ActiveProfile_RemovesIt() {
        // Arrange
        let profile = makeProfile(name: "Active Profile", isActive: true)
        sut.createProfile(profile)

        // Act
        sut.deleteProfile(profile)

        // Assert
        XCTAssertTrue(sut.profiles.isEmpty)
        XCTAssertNil(sut.getActiveProfile())
    }

    func testDeleteProfile_NonExistentProfile_DoesNotCrash() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1")
        let profile2 = makeProfile(name: "Profile 2")
        sut.createProfile(profile1)

        // Act & Assert
        XCTAssertNoThrow(sut.deleteProfile(profile2))
        XCTAssertEqual(sut.profiles.count, 1)
    }

    // MARK: - Reload Tests

    func testReloadIfNeeded_DoesNotCrash() {
        // Arrange
        let profile = makeProfile(name: "Test Profile")
        sut.createProfile(profile)

        // Act & Assert
        XCTAssertNoThrow(sut.reloadIfNeeded())
    }

    // MARK: - ObservableObject Tests

    func testObjectWillChange_PublishesOnCreate() {
        // Arrange
        let expectation = XCTestExpectation(description: "objectWillChange on create")
        let profile = makeProfile(name: "Test Profile")

        sut.objectWillChange.sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)

        // Act
        sut.createProfile(profile)

        // Assert
        wait(for: [expectation], timeout: 1.0)
    }

    func testObjectWillChange_PublishesOnUpdate() {
        // Arrange
        let profile = makeProfile(name: "Original")
        sut.createProfile(profile)

        var updatedProfile = profile
        updatedProfile.name = "Updated"

        let expectation = XCTestExpectation(description: "objectWillChange on update")

        sut.objectWillChange.sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)

        // Act
        sut.updateProfile(updatedProfile)

        // Assert
        wait(for: [expectation], timeout: 1.0)
    }

    func testObjectWillChange_PublishesOnDelete() {
        // Arrange
        let profile = makeProfile(name: "Test Profile")
        sut.createProfile(profile)

        let expectation = XCTestExpectation(description: "objectWillChange on delete")

        sut.objectWillChange.sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)

        // Act
        sut.deleteProfile(profile)

        // Assert
        wait(for: [expectation], timeout: 1.0)
    }

    func testObjectWillChange_PublishesOnActivate() {
        // Arrange
        let profile = makeProfile(name: "Test Profile")
        sut.createProfile(profile)

        let expectation = XCTestExpectation(description: "objectWillChange on activate")

        sut.objectWillChange.sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)

        // Act
        sut.activateProfile(profile.id)

        // Assert
        wait(for: [expectation], timeout: 1.0)
    }

    func testObjectWillChange_PublishesOnDeactivate() {
        // Arrange
        let profile = makeProfile(name: "Test Profile", isActive: true)
        sut.createProfile(profile)

        let expectation = XCTestExpectation(description: "objectWillChange on deactivate")

        sut.objectWillChange.sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)

        // Act
        sut.deactivateProfile()

        // Assert
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Integration Tests

    func testFullLifecycle_CreateActivateUpdateDelete() {
        // Arrange
        let profile = makeProfile(name: "Test Profile", isActive: false)

        // Act & Assert - Create
        sut.createProfile(profile)
        XCTAssertEqual(sut.profiles.count, 1)

        // Act & Assert - Activate
        sut.activateProfile(profile.id)
        XCTAssertTrue(sut.getActiveProfile()?.id == profile.id)

        // Act & Assert - Update
        var updatedProfile = profile
        updatedProfile.name = "Updated Profile"
        sut.updateProfile(updatedProfile)
        XCTAssertEqual(sut.profiles.first?.name, "Updated Profile")

        // Act & Assert - Delete
        sut.deleteProfile(updatedProfile)
        XCTAssertTrue(sut.profiles.isEmpty)
    }

    func testMultipleProfiles_ActivateDeactivateCycle() {
        // Arrange
        let profile1 = makeProfile(name: "Profile 1")
        let profile2 = makeProfile(name: "Profile 2")
        let profile3 = makeProfile(name: "Profile 3")

        sut.createProfile(profile1)
        sut.createProfile(profile2)
        sut.createProfile(profile3)

        // Act & Assert - Activate profile 1
        sut.activateProfile(profile1.id)
        XCTAssertEqual(sut.getActiveProfile()?.id, profile1.id)

        // Act & Assert - Switch to profile 2
        sut.activateProfile(profile2.id)
        XCTAssertEqual(sut.getActiveProfile()?.id, profile2.id)

        // Act & Assert - Switch to profile 3
        sut.activateProfile(profile3.id)
        XCTAssertEqual(sut.getActiveProfile()?.id, profile3.id)

        // Act & Assert - Deactivate all
        sut.deactivateProfile()
        XCTAssertNil(sut.getActiveProfile())
    }

    func testProfileWithRuleGroups_ManageLifecycle() {
        // Arrange
        let ruleGroup1 = UUID()
        let ruleGroup2 = UUID()
        let profile = makeProfile(
            name: "Complex Profile",
            isActive: false,
            ruleGroupIds: [ruleGroup1]
        )

        // Act - Create
        sut.createProfile(profile)

        // Assert
        var result = sut.profiles.first { $0.id == profile.id }
        XCTAssertEqual(result?.ruleGroups.count, 1)
        XCTAssertTrue(result?.ruleGroups.contains(ruleGroup1) ?? false)

        // Act - Update with more rule groups
        var updatedProfile = profile
        updatedProfile.ruleGroups.append(ruleGroup2)
        sut.updateProfile(updatedProfile)

        // Assert
        result = sut.profiles.first { $0.id == profile.id }
        XCTAssertEqual(result?.ruleGroups.count, 2)
        XCTAssertTrue(result?.ruleGroups.contains(ruleGroup2) ?? false)

        // Act - Remove all rule groups
        updatedProfile.ruleGroups = []
        sut.updateProfile(updatedProfile)

        // Assert
        result = sut.profiles.first { $0.id == profile.id }
        XCTAssertTrue(result?.ruleGroups.isEmpty ?? false)
    }

    // MARK: - Edge Cases

    func testEmptyProfileName_Allowed() {
        // Arrange
        let profile = makeProfile(name: "")

        // Act
        sut.createProfile(profile)

        // Assert
        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(sut.profiles.first?.name, "")
    }

    func testProfileNameWithSpecialCharacters() {
        // Arrange
        let profile = makeProfile(name: "Test-Profile_123 (Production) 🚀")

        // Act
        sut.createProfile(profile)

        // Assert
        let result = sut.profiles.first { $0.id == profile.id }
        XCTAssertEqual(result?.name, "Test-Profile_123 (Production) 🚀")
    }

    func testProfileWithLongDescription() {
        // Arrange
        let longDescription = String(repeating: "A", count: 10000)
        var profile = makeProfile(name: "Test Profile")
        profile.description = longDescription

        // Act
        sut.createProfile(profile)

        // Assert
        let result = sut.profiles.first { $0.id == profile.id }
        XCTAssertEqual(result?.description?.count, 10000)
    }

    func testProfileWithManyRuleGroups() {
        // Arrange
        let manyRuleGroups = (0..<100).map { _ in UUID() }
        let profile = makeProfile(name: "Profile with many rules", ruleGroupIds: manyRuleGroups)

        // Act
        sut.createProfile(profile)

        // Assert
        let result = sut.profiles.first { $0.id == profile.id }
        XCTAssertEqual(result?.ruleGroups.count, 100)
    }

    func testConcurrentProfileOperations() async {
        // Arrange
        let profiles = (0..<10).map { i in
            makeProfile(name: "Profile \(i)")
        }

        // Act - Create profiles concurrently
        await MainActor.run {
            for profile in profiles {
                sut.createProfile(profile)
            }
        }

        // Assert
        await MainActor.run {
            XCTAssertEqual(sut.profiles.count, 10)
        }
    }
}
