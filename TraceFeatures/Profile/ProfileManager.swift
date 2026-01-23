//
//  ProfileManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Combine
import Foundation
import TraceCore

@MainActor
public final class ProfileManager: ObservableObject {
    public static let shared = ProfileManager()

    private let baseManager: PersistentCollectionManager<Profile>
    private var cancellables: Set<AnyCancellable> = []
    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    public var profiles: [Profile] {
        baseManager.items
    }

    private init() {
        self.baseManager = PersistentCollectionManager(
            fileName: "Profiles.json",
            notificationName: "ProfilesChanged",
            logger: FeatureLog.profile,
            itemName: "profile"
        )

        baseManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    public func createProfile(_ profile: Profile) {
        baseManager.add(profile)
    }

    public func activateProfile(_ profileId: UUID) {
        var updated = profiles
        for index in updated.indices {
            updated[index].isActive = updated[index].id == profileId
        }
        baseManager.importItems(updated, merge: false)
    }

    public func deactivateProfile() {
        var updated = profiles
        for index in updated.indices {
            updated[index].isActive = false
        }
        baseManager.importItems(updated, merge: false)
    }

    public func getActiveProfile() -> Profile? {
        profiles.first(where: { $0.isActive })
    }

    public func updateProfile(_ profile: Profile) {
        baseManager.update(profile)
    }

    public func deleteProfile(_ profile: Profile) {
        baseManager.delete(profile)
    }

    public func reloadIfNeeded() {
        baseManager.reloadIfNeeded()
    }
}
