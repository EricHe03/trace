//
//  ScriptListView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UniformTypeIdentifiers

struct ScriptListView: View {
    @ObservedObject private var scriptManager = ScriptManager.shared
    @State private var showingAddScript = false
    @State private var editingScript: Script?
    @State private var showingTemplates = false
    @State private var searchText = ""
    @State private var filterScriptType: ScriptType?
    @State private var showingImport = false
    @State private var toastMessage: String?

    var filteredScripts: [Script] {
        var scripts = scriptManager.scripts

        if !searchText.isEmpty {
            scripts = scripts.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                    $0.code.localizedCaseInsensitiveContains(searchText)
            }
        }

        if let scriptType = filterScriptType {
            scripts = scripts.filter { $0.scriptType == scriptType }
        }

        return scripts
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
                    if filteredScripts.isEmpty {
                        emptyStateContent
                    } else {
                        ForEach(filteredScripts) { script in
                            ScriptRow(script: script)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingScript = script
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                            scriptManager.deleteScript(script)
                                            showToast(message: "Script deleted")
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .accessibilityLabel("Delete script")
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                            scriptManager.toggleScript(script)
                                        }
                                    } label: {
                                        Label(
                                            script.enabled ? "Disable" : "Enable",
                                            systemImage: script.enabled ? "pause.circle" : "play.circle"
                                        )
                                        .foregroundStyle(.white)
                                    }
                                    .tint(script.enabled ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
                                    .accessibilityLabel(script.enabled ? "Disable script" : "Enable script")
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityHint("Double tap to edit script")
                        }
                        .onDelete { indices in
                            scriptManager.deleteScripts(at: indices)
                        }
                    }
                }
                .listRowInsets(DesignSystem.List.rowInsets)
            }
            .listStyle(.plain)
            .navigationTitle("Scripts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showingAddScript = true
                        } label: {
                            Label("New Script", systemImage: "plus")
                        }

                        Button {
                            showingTemplates = true
                        } label: {
                            Label("Load Template", systemImage: "doc.text")
                        }

                        Button {
                            showingImport = true
                        } label: {
                            Label("Import Scripts", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            exportScripts()
                        } label: {
                            Label("Export Scripts", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            scriptManager.clearAllScripts()
                            showToast(message: "All scripts cleared")
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                    .accessibilityHint("Double tap to create, import, export, or clear scripts")
                }
            }
            .searchable(text: $searchText, prompt: "Search scripts")
            .sheet(isPresented: $showingAddScript) {
                ScriptEditorView(script: nil) { newScript in
                    scriptManager.addScript(newScript)
                    showToast(message: "Script added")
                }
            }
            .sheet(item: $editingScript) { script in
                ScriptEditorView(script: script) { updatedScript in
                    scriptManager.updateScript(updatedScript)
                    showToast(message: "Script updated")
                }
            }
            .sheet(isPresented: $showingTemplates) {
                ScriptTemplatesView { template in
                    scriptManager.loadTemplate(template)
                    showToast(message: "Template loaded")
                }
            }
            .fileImporter(isPresented: $showingImport, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .toast(message: $toastMessage)
        }
    }

    private var statsHeader: some View {
        HStack(spacing: DesignSystem.Spacing.lgPlus) {
            StatItem(
                title: "Total",
                value: "\(scriptManager.totalScriptsCount)",
                color: DesignSystem.Colors.accent
            )
            StatItem(
                title: "Enabled",
                value: "\(scriptManager.enabledScriptsCount)",
                color: DesignSystem.Colors.success
            )
            StatItem(
                title: "Executions",
                value: "\(scriptManager.totalExecutions)",
                color: DesignSystem.Colors.accentAlt
            )
        }
        .padding()
    }

    private var filterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.md) {
                FilterChip(
                    title: "All",
                    isSelected: filterScriptType == nil,
                    count: scriptManager.totalScriptsCount
                ) {
                    filterScriptType = nil
                }

                ForEach(ScriptType.allCases, id: \.self) { type in
                    FilterChip(
                        title: type.displayName,
                        isSelected: filterScriptType == type,
                        count: scriptManager.scriptsCount(for: type)
                    ) {
                        filterScriptType = type
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private var emptyStateContent: some View {
        TraceContentUnavailableView(
            "No Scripts",
            systemImage: "chevron.left.forwardslash.chevron.right",
            description: Text("Create JavaScript scripts to modify requests and responses"),
            actionTitle: "New Script",
            action: { showingAddScript = true }
        )
    }

    private func exportScripts() {
        do {
            let url = try scriptManager.exportScripts()
            showToast(message: "Scripts exported to \(url.lastPathComponent)")
        } catch {
            showToast(message: "Failed to export scripts")
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            do {
                try scriptManager.importScripts(from: url, merge: true)
                showToast(message: "Scripts imported successfully")
            } catch {
                showToast(message: "Failed to import scripts")
            }
        case .failure:
            showToast(message: "Failed to import scripts")
        }
    }

    private func showToast(message: String) {
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = message
        }
    }
}

// MARK: - Supporting Views

struct ScriptRow: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Circle()
                    .fill(script.enabled ? DesignSystem.Colors.success : DesignSystem.Colors.muted)
                    .frame(width: 12, height: 12)

                Text(script.name)
                    .font(.headline)

                Spacer()

                ScriptTypeBadge(type: script.scriptType)
            }

            if let pattern = script.matchPattern, !pattern.isEmpty {
                HStack {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(pattern)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if script.executionCount > 0 {
                HStack(spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "play.circle")
                            .font(.caption)
                        Text("\(script.executionCount) executions")
                            .font(.caption)
                    }
                    .foregroundStyle(DesignSystem.Colors.accentAlt)
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.rowVertical)
        .opacity(script.enabled ? 1.0 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(script.name), \(script.scriptType.displayName), \(script.enabled ? "enabled" : "disabled")\(script.executionCount > 0 ? ", \(script.executionCount) executions" : "")")
    }
}

struct ScriptTypeBadge: View {
    let type: ScriptType

    var body: some View {
        Text(type.displayName)
            .badgeStyle(backgroundColor: backgroundColor)
    }

    private var backgroundColor: Color {
        switch type {
        case .request: DesignSystem.Colors.accent
        case .response: DesignSystem.Colors.accentAlt
        case .both: DesignSystem.Colors.success
        }
    }
}

struct ScriptTemplatesView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Script) -> Void

    var body: some View {
        NavigationStack {
            List(Script.templates) { template in
                Button {
                    onSelect(template)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack {
                            Text(template.name)
                                .font(.headline)

                            Spacer()

                            ScriptTypeBadge(type: template.scriptType)
                        }

                        Text(template.code.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .navigationTitle("Script Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ScriptListView()
}
