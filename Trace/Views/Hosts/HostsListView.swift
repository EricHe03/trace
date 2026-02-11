//
//  HostsListView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UniformTypeIdentifiers

struct HostsListView: View {
    @ObservedObject private var hostsManager = HostsManager.shared
    @State private var showingAddEntry = false
    @State private var editingEntry: HostEntry?
    @State private var searchText = ""
    @State private var filterStatus: FilterStatus = .all
    @State private var showingImport = false
    @State private var shareSheetItem: ShareSheetItem?
    @State private var showingClearAllAlert = false
    @State private var toastMessage: String?

    enum FilterStatus: String, CaseIterable {
        case all = "All"
        case enabled = "Enabled"
        case disabled = "Disabled"
    }

    var filteredEntries: [HostEntry] {
        var entries = hostsManager.entries

        if !searchText.isEmpty {
            entries = entries.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                    $0.hostname.localizedCaseInsensitiveContains(searchText) ||
                    $0.targetIP.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch filterStatus {
        case .all:
            break
        case .enabled:
            entries = entries.filter(\.enabled)
        case .disabled:
            entries = entries.filter { !$0.enabled }
        }

        return entries
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
                    filterSection
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section {
                    if filteredEntries.isEmpty {
                        emptyStateContent
                    } else {
                        ForEach(filteredEntries) { entry in
                            HostEntryRow(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingEntry = entry
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                            hostsManager.deleteEntry(entry)
                                            showToast(message: "Entry deleted")
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .accessibilityLabel("Delete host entry")
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                            hostsManager.toggleEntry(entry)
                                        }
                                    } label: {
                                        Label(
                                            entry.enabled ? "Disable" : "Enable",
                                            systemImage: entry.enabled ? "pause.circle" : "play.circle"
                                        )
                                        .foregroundStyle(.white)
                                    }
                                    .tint(entry.enabled ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
                                    .accessibilityLabel(entry.enabled ? "Disable host entry" : "Enable host entry")
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityHint("Double tap to edit host entry")
                        }
                    }
                }
                .listRowInsets(DesignSystem.List.rowInsets)
            }
            .listStyle(.plain)
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showingImport = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            exportEntries()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button {
                            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                hostsManager.enableAll()
                                showToast(message: "All entries enabled")
                            }
                        } label: {
                            Label("Enable All", systemImage: "checkmark.circle")
                        }

                        Button {
                            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                hostsManager.disableAll()
                                showToast(message: "All entries disabled")
                            }
                        } label: {
                            Label("Disable All", systemImage: "pause.circle")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showingClearAllAlert = true
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                        .disabled(hostsManager.entries.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                    .accessibilityHint("Double tap to add, import, export, enable, disable, or clear host entries")
                }
            }
            .searchable(text: $searchText, prompt: "Search hosts")
            .sheet(isPresented: $showingAddEntry) {
                HostEditorView(entry: nil)
            }
            .sheet(item: $editingEntry) { entry in
                HostEditorView(entry: entry)
            }
            .fileImporter(
                isPresented: $showingImport,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result: result)
            }
            .shareSheet(item: $shareSheetItem)
            .toast(message: $toastMessage)
            .alert("Clear All Host Entries", isPresented: $showingClearAllAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        hostsManager.clearAll()
                        showToast(message: "All entries cleared")
                    }
                }
            } message: {
                Text("Are you sure you want to clear all \(hostsManager.entries.count) host entries? This action cannot be undone.")
            }
        }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        HStack(spacing: DesignSystem.Spacing.lgPlus) {
            StatItem(
                title: "Total",
                value: "\(hostsManager.totalCount)",
                color: DesignSystem.Colors.accent
            )

            StatItem(
                title: "Enabled",
                value: "\(hostsManager.enabledCount)",
                color: DesignSystem.Colors.success
            )

            StatItem(
                title: "Disabled",
                value: "\(hostsManager.disabledCount)",
                color: DesignSystem.Colors.warning
            )
        }
        .padding()
    }

    // MARK: - Filter Section

    private var filterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ForEach(FilterStatus.allCases, id: \.self) { status in
                    FilterChip(
                        title: status.rawValue,
                        isSelected: filterStatus == status
                    ) {
                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                            filterStatus = status
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Empty State

    private var emptyStateContent: some View {
        Group {
            if searchText.isEmpty {
                TraceContentUnavailableView(
                    "No Host Entries",
                    systemImage: "network",
                    description: Text("Create host entries to override DNS resolution"),
                    actionTitle: "Add Entry",
                    action: { showingAddEntry = true }
                )
            } else {
                TraceContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term")
                )
            }
        }
    }

    // MARK: - Import/Export

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }

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
                    let data = try await Task.detached {
                        try Data(contentsOf: url)
                    }.value
                    try await MainActor.run {
                        try hostsManager.importEntries(from: data, merge: true)
                        showToast(message: "Entries imported successfully")
                    }
                } catch {
                    await MainActor.run {
                        showToast(message: "Import failed: \(error.localizedDescription)")
                    }
                }
            }

        case let .failure(error):
            showToast(message: "Import failed: \(error.localizedDescription)")
        }
    }

    private func exportEntries() {
        guard let fileURL = hostsManager.exportToFile() else {
            showToast(message: "Export failed")
            return
        }

        shareSheetItem = ShareSheetItem([fileURL])
        showToast(message: "Exporting entries...")
    }

    // MARK: - Toast

    private func showToast(message: String) {
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = message
        }
    }
}

// MARK: - Host Entry Row

struct HostEntryRow: View {
    let entry: HostEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Circle()
                    .fill(entry.enabled ? DesignSystem.Colors.success : DesignSystem.Colors.muted)
                    .frame(width: 12, height: 12)

                Text(entry.name)
                    .font(.headline)

                Spacer()
            }

            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(entry.hostname)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(entry.targetIP)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let port = entry.targetPort {
                    Text(":\(port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !entry.isValid {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text("Invalid entry")
                        .font(.caption)
                }
                .foregroundStyle(DesignSystem.Colors.danger)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.rowVertical)
        .opacity(entry.enabled ? 1.0 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.enabled ? "enabled" : "disabled"), \(entry.hostname) maps to \(entry.targetIP)\(entry.targetPort.map { " port \($0)" } ?? "")\(!entry.isValid ? ", invalid entry" : "")")
    }
}

#Preview {
    HostsListView()
}
