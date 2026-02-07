//
//  RequestMapView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UniformTypeIdentifiers

struct RequestMapView: View {
    @ObservedObject private var mapManager = RequestMapManager.shared
    @State private var showingAddMap = false
    @State private var editingMap: RequestMap?
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .mostRecent
    @State private var showingImport = false
    @State private var showingClearAllAlert = false
    @State private var toastMessage: String?

    enum SortOrder: String, CaseIterable {
        case mostRecent = "Most Recent"
        case mostUsed = "Most Used"
        case alphabetical = "A-Z"

        var systemImage: String {
            switch self {
            case .mostRecent: "clock"
            case .mostUsed: "chart.bar"
            case .alphabetical: "textformat"
            }
        }
    }

    var filteredAndSortedMaps: [RequestMap] {
        var maps = mapManager.maps

        // Filter by search
        if !searchText.isEmpty {
            maps = maps.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                    $0.matchPattern.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort
        switch sortOrder {
        case .mostRecent:
            maps.sort { $0.modifiedAt > $1.modifiedAt }
        case .mostUsed:
            maps.sort { $0.hitCount > $1.hitCount }
        case .alphabetical:
            maps.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }

        return maps
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statsHeader
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section {
                    sortSection
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section {
                    if filteredAndSortedMaps.isEmpty {
                        emptyStateContent
                    } else {
                        ForEach(filteredAndSortedMaps) { map in
                            MapRow(map: map)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingMap = map
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                            mapManager.deleteMap(map)
                                            showToast(message: "Map deleted")
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                            mapManager.toggleMap(map)
                                        }
                                    } label: {
                                        Label(
                                            map.enabled ? "Disable" : "Enable",
                                            systemImage: map.enabled ? "pause.circle" : "play.circle"
                                        )
                                        .foregroundStyle(.white)
                                    }
                                    .tint(map.enabled ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
                                }
                        }
                        .onDelete { indices in
                            mapManager.deleteMaps(at: indices)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listStyle(.plain)
            .navigationTitle("Request Mapping")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showingAddMap = true
                        } label: {
                            Label("Add Map", systemImage: "plus")
                        }

                        Button {
                            showingImport = true
                        } label: {
                            Label("Import Maps", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            exportMaps()
                        } label: {
                            Label("Export Maps", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showingClearAllAlert = true
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                        .disabled(mapManager.maps.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search maps")
            .sheet(isPresented: $showingAddMap) {
                RequestMapEditorView(map: nil) { newMap in
                    mapManager.addMap(newMap)
                    showToast(message: "Map added")
                }
            }
            .sheet(item: $editingMap) { map in
                RequestMapEditorView(map: map) { updatedMap in
                    mapManager.updateMap(updatedMap)
                    showToast(message: "Map updated")
                }
            }
            .fileImporter(isPresented: $showingImport, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .toast(message: $toastMessage)
            .alert("Clear All Request Maps", isPresented: $showingClearAllAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    mapManager.clearAllMaps()
                    showToast(message: "All maps cleared")
                }
            } message: {
                Text("Are you sure you want to clear all \(mapManager.maps.count) request maps? This action cannot be undone.")
            }
        }
    }

    private var statsHeader: some View {
        HStack(spacing: DesignSystem.Spacing.lgPlus) {
            StatItem(
                title: "Total",
                value: "\(mapManager.totalMapsCount)",
                color: DesignSystem.Colors.accent
            )
            StatItem(
                title: "Enabled",
                value: "\(mapManager.enabledMapsCount)",
                color: DesignSystem.Colors.success
            )
            StatItem(
                title: "Total Hits",
                value: "\(mapManager.totalHits)",
                color: DesignSystem.Colors.warning
            )
        }
        .padding()
    }

    private var sortSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    FilterChip(
                        title: order.rawValue,
                        isSelected: sortOrder == order
                    ) {
                        sortOrder = order
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private var emptyStateContent: some View {
        TraceContentUnavailableView(
            "No Request Maps",
            systemImage: "map",
            description: Text("Create maps to return mock responses without hitting real servers"),
            actionTitle: "Add Your First Map",
            action: { showingAddMap = true }
        )
    }

    private func exportMaps() {
        do {
            let url = try mapManager.exportMaps()
            showToast(message: "Maps exported to \(url.lastPathComponent)")
        } catch {
            showToast(message: "Failed to export maps")
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            Task {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    await MainActor.run {
                        showToast(message: "File not found")
                    }
                    return
                }

                let canAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if canAccess { url.stopAccessingSecurityScopedResource() }
                }

                do {
                    let importedMaps = try await Task.detached {
                        let data = try Data(contentsOf: url)
                        return try JSONDecoder().decode([RequestMap].self, from: data)
                    }.value
                    await MainActor.run {
                        mapManager.importMaps(importedMaps, merge: true)
                        showToast(message: "Maps imported successfully")
                    }
                } catch {
                    await MainActor.run {
                        showToast(message: "Failed to import maps")
                    }
                }
            }
        case .failure:
            showToast(message: "Failed to import maps")
        }
    }

    private func showToast(message: String) {
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = message
        }
    }
}

// MARK: - Supporting Views

struct MapRow: View {
    let map: RequestMap

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Circle()
                    .fill(map.enabled ? DesignSystem.Colors.success : DesignSystem.Colors.muted)
                    .frame(width: 12, height: 12)

                Text(map.name)
                    .font(.headline)

                Spacer()

                if map.hitCount > 0 {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                        Text("\(map.hitCount)")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(DesignSystem.Colors.warning.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                }
            }

            HStack {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(map.matchPattern)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                    Text("\(map.mockResponse.statusCode)")
                        .font(.caption)
                }
                .foregroundStyle(statusColor(map.mockResponse.statusCode))

                if let bodySize = map.mockResponse.bodyContent?.count {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                        Text(formatBytes(bodySize))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                if map.mockResponse.delay > 0 {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text("\(map.mockResponse.delay)ms")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.rowVertical)
        .opacity(map.enabled ? 1.0 : 0.6)
    }

    private func statusColor(_ code: Int) -> Color {
        DesignSystem.Colors.statusColor(for: code)
    }

    private func formatBytes(_ bytes: Int) -> String {
        DesignSystem.formattedBytes(bytes)
    }
}

#Preview {
    RequestMapView()
}
