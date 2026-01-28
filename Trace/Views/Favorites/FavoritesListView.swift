//
//  FavoritesListView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

struct FavoritesListView: View {
    @ObservedObject private var favoritesManager = FavoritesManager.shared
    @State private var searchText = ""
    @State private var editingFavorite: Favorite?
    @State private var toastMessage: String?
    @Environment(\.dismiss) private var dismiss: DismissAction

    var filteredFavorites: [Favorite] {
        if searchText.isEmpty {
            return favoritesManager.favorites
        }
        return favoritesManager.searchFavorites(query: searchText)
    }

    var body: some View {
        List {
            if filteredFavorites.isEmpty {
                emptyStateView
            } else {
                Section {
                    ForEach(filteredFavorites) { favorite in
                        FavoriteRowView(favorite: favorite)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingFavorite = favorite
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation {
                                        favoritesManager.deleteFavorite(favorite)
                                        showToast(message: "Favorite removed")
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .accessibilityLabel("Delete favorite")
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityHint("Double tap to edit favorite")
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .searchable(text: $searchText, prompt: "Search favorites")
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        withAnimation {
                            favoritesManager.clearAll()
                            showToast(message: "All favorites cleared")
                        }
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                    .disabled(favoritesManager.favorites.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
                .accessibilityHint("Double tap to clear all favorites")
            }
        }
        .sheet(item: $editingFavorite) { favorite in
            FavoriteEditorView(favorite: favorite)
        }
        .toast(message: $toastMessage)
    }

    private var emptyStateView: some View {
        Group {
            if searchText.isEmpty {
                TraceContentUnavailableView(
                    "No Favorites Yet",
                    systemImage: "star",
                    description: Text("Star requests to add them to your favorites")
                )
            } else {
                TraceContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term")
                )
            }
        }
        .listRowBackground(Color.clear)
    }

    private func showToast(message: String) {
        withAnimation {
            toastMessage = message
        }
    }
}

// MARK: - Favorite Row View

struct FavoriteRowView: View {
    let favorite: Favorite

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(DesignSystem.Colors.favorite)
                    .font(.caption)

                Text(favorite.name ?? "Unnamed Favorite")
                    .font(.headline)

                Spacer()

                Text(favorite.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notes = favorite.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text("Request ID: \(favorite.requestId.uuidString.prefix(8))...")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, DesignSystem.Spacing.rowVertical)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(favorite.name ?? "Unnamed Favorite"), created \(favorite.createdAt.formatted(.relative(presentation: .named)))")
    }
}

// MARK: - Favorite Editor View

struct FavoriteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var favoritesManager = FavoritesManager.shared

    let favorite: Favorite

    @State private var name: String
    @State private var notes: String

    init(favorite: Favorite) {
        self.favorite = favorite
        _name = State(initialValue: favorite.name ?? "")
        _notes = State(initialValue: favorite.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Favorite name")

                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3 ... 6)
                        .accessibilityLabel("Favorite notes")
                }

                Section("Information") {
                    LabeledContent("Request ID") {
                        Text(favorite.requestId.uuidString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Created") {
                        Text(favorite.createdAt, style: .date)
                    }

                    LabeledContent("Modified") {
                        Text(favorite.modifiedAt, style: .date)
                    }
                }
            }
            .navigationTitle("Edit Favorite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveFavorite()
                    }
                }
            }
        }
    }

    private func saveFavorite() {
        var updatedFavorite = favorite
        updatedFavorite.name = name.isEmpty ? nil : name
        updatedFavorite.notes = notes.isEmpty ? nil : notes

        favoritesManager.updateFavorite(updatedFavorite)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        FavoritesListView()
    }
}
