//
//  RewriteRulesView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UniformTypeIdentifiers

struct RewriteRulesView: View {
    @ObservedObject private var rewriteManager = RewriteManager.shared
    @State private var showingAddRule = false
    @State private var editingRule: RewriteRule?
    @State private var searchText = ""
    @State private var filterRuleType: RuleType?
    @State private var showingImport = false
    @State private var showingExport = false
    @State private var toastMessage: String?
    @State private var showingClearAllAlert = false

    var filteredRules: [RewriteRule] {
        var rules = rewriteManager.rules

        if !searchText.isEmpty {
            rules = rules.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                    $0.matchPattern.localizedCaseInsensitiveContains(searchText)
            }
        }

        if let ruleType = filterRuleType {
            rules = rules.filter { $0.ruleType == ruleType }
        }

        return rules
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
                    if filteredRules.isEmpty {
                        emptyStateContent
                    } else {
                        ForEach(filteredRules) { rule in
                            RuleRow(rule: rule)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingRule = rule
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                            rewriteManager.deleteRule(rule)
                                            showToast(message: "Rule deleted")
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .accessibilityLabel("Delete rule")
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                            rewriteManager.toggleRule(rule)
                                        }
                                    } label: {
                                        Label(
                                            rule.enabled ? "Disable" : "Enable",
                                            systemImage: rule.enabled ? "pause.circle" : "play.circle"
                                        )
                                        .foregroundStyle(.white)
                                    }
                                    .tint(rule.enabled ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
                                    .accessibilityLabel(rule.enabled ? "Disable rule" : "Enable rule")
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityHint("Double tap to edit rule")
                        }
                        .onMove { source, destination in
                            rewriteManager.moveRules(from: source, to: destination)
                        }
                        .onDelete { indices in
                            rewriteManager.deleteRules(at: indices)
                        }
                    }
                }
                .listRowInsets(DesignSystem.List.rowInsets)
            }
            .listStyle(.plain)
            .navigationTitle("Rewrite Rules")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showingAddRule = true
                        } label: {
                            Label("Add Rule", systemImage: "plus")
                        }

                        Divider()

                        Button {
                            showingImport = true
                        } label: {
                            Label("Import Rules", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            exportRules()
                        } label: {
                            Label("Export Rules", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showingClearAllAlert = true
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                    .accessibilityHint("Double tap to add, import, export, or clear rules")
                }
            }
            .searchable(text: $searchText, prompt: "Search rules")
            .sheet(isPresented: $showingAddRule) {
                RewriteRuleEditorView(rule: nil) { newRule in
                    rewriteManager.addRule(newRule)
                    showToast(message: "Rule added")
                }
            }
            .sheet(item: $editingRule) { rule in
                RewriteRuleEditorView(rule: rule) { updatedRule in
                    rewriteManager.updateRule(updatedRule)
                    showToast(message: "Rule updated")
                }
            }
            .fileImporter(isPresented: $showingImport, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .toast(message: $toastMessage)
            .alert("Clear All Rules", isPresented: $showingClearAllAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
                    rewriteManager.clearAllRules()
                    showToast(message: "All rules cleared")
                }
            } message: {
                Text("Are you sure you want to delete all rewrite rules? This action cannot be undone.")
            }
        }
    }

    private var statsHeader: some View {
        HStack(spacing: DesignSystem.Spacing.lgPlus) {
            StatItem(
                title: "Total",
                value: "\(rewriteManager.totalRulesCount)",
                color: DesignSystem.Colors.accent
            )
            StatItem(
                title: "Enabled",
                value: "\(rewriteManager.enabledRulesCount)",
                color: DesignSystem.Colors.success
            )
            StatItem(
                title: "Disabled",
                value: "\(rewriteManager.totalRulesCount - rewriteManager.enabledRulesCount)",
                color: DesignSystem.Colors.muted
            )
        }
        .padding()
    }

    private var filterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.md) {
                FilterChip(
                    title: "All",
                    isSelected: filterRuleType == nil,
                    count: rewriteManager.totalRulesCount
                ) {
                    filterRuleType = nil
                }

                ForEach(RuleType.allCases.filter { $0 != .map }, id: \.self) { type in
                    FilterChip(
                        title: type.displayName,
                        isSelected: filterRuleType == type,
                        count: rewriteManager.rulesCount(for: type)
                    ) {
                        filterRuleType = type
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private var emptyStateContent: some View {
        TraceContentUnavailableView(
            "No Rewrite Rules",
            systemImage: "arrow.triangle.branch",
            description: Text("Create rules to modify requests and responses on the fly"),
            actionTitle: "Add Your First Rule",
            action: { showingAddRule = true }
        )
    }

    private func exportRules() {
        do {
            let url = try rewriteManager.exportRules()
            showToast(message: "Rules exported to \(url.lastPathComponent)")
        } catch {
            showToast(message: "Failed to export rules")
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            Task {
                // Check if file exists before attempting to access
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
                    let importedRules = try await Task.detached {
                        let data = try Data(contentsOf: url)
                        return try JSONDecoder().decode([RewriteRule].self, from: data)
                    }.value
                    await MainActor.run {
                        rewriteManager.importRules(importedRules, merge: true)
                        showToast(message: "Rules imported successfully")
                    }
                } catch {
                    await MainActor.run {
                        if error is DecodingError {
                            showToast(message: "Failed to import rules: invalid file format")
                        } else {
                            showToast(message: "Failed to import rules: \(error.localizedDescription)")
                        }
                    }
                }
            }
        case let .failure(error):
            showToast(message: "Failed to import rules: \(error.localizedDescription)")
        }
    }

    private func showToast(message: String) {
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = message
        }
    }
}

// MARK: - Supporting Views

struct RuleRow: View {
    let rule: RewriteRule

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: rule.enabled ? "checkmark.circle.fill" : "slash.circle.fill")
                    .foregroundStyle(rule.enabled ? DesignSystem.Colors.success : DesignSystem.Colors.muted)
                    .accessibilityHidden(true)

                Text(rule.name)
                    .font(.headline)

                Spacer()

                RuleTypeBadge(type: rule.ruleType)
            }

            HStack {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(rule.matchPattern)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if !rule.actions.isEmpty {
                    Text("\(rule.actions.count) action\(rule.actions.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.rowVertical)
        .opacity(rule.enabled ? 1.0 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rule.name), \(rule.ruleType.displayName), \(rule.enabled ? "enabled" : "disabled"), matches \(rule.matchPattern)")
    }
}

struct RuleTypeBadge: View {
    let type: RuleType

    var body: some View {
        Label(type.displayName, systemImage: iconName)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .badgeStyle(backgroundColor: backgroundColor)
            .accessibilityLabel(type.displayName)
    }

    private var backgroundColor: Color {
        switch type {
        case .redirect: DesignSystem.Colors.accent
        case .modifyRequest: DesignSystem.Colors.warning
        case .modifyResponse: DesignSystem.Colors.accentAlt
        case .block: DesignSystem.Colors.danger
        case .map: DesignSystem.Colors.success
        }
    }

    private var iconName: String {
        switch type {
        case .redirect:
            "arrowshape.turn.up.right"
        case .modifyRequest:
            "square.and.pencil"
        case .modifyResponse:
            "arrow.triangle.2.circlepath"
        case .block:
            "hand.raised.fill"
        case .map:
            "link"
        }
    }
}

#Preview {
    RewriteRulesView()
}
