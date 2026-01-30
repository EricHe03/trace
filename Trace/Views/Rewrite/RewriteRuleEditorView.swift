//
//  RewriteRuleEditorView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI
#if canImport(UIKit)
import UIKit
#endif

struct RewriteRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let rule: RewriteRule?
    let onSave: (RewriteRule) -> Void

    @State private var name: String
    @State private var enabled: Bool
    @State private var ruleType: RuleType
    @State private var matchType: MatchType
    @State private var matchPattern: String
    @State private var actions: [RewriteAction]
    @State private var tags: String
    @State private var stopProcessing: Bool
    @State private var matchingStrategy: MatchingStrategy
    @State private var showingAddAction = false
    @State private var matchPatternError: String?
    @State private var matchPatternAnnouncementTask: Task<Void, Never>?
    @State private var lastAnnouncedMatchPatternError: String?

    init(rule: RewriteRule?, onSave: @escaping (RewriteRule) -> Void) {
        self.rule = rule
        self.onSave = onSave

        _name = State(initialValue: rule?.name ?? "")
        _enabled = State(initialValue: rule?.enabled ?? true)
        _ruleType = State(initialValue: rule?.ruleType ?? .redirect)
        _matchType = State(initialValue: rule?.matchType ?? .wildcard)
        _matchPattern = State(initialValue: rule?.matchPattern ?? "")
        _actions = State(initialValue: rule?.actions ?? [])
        _tags = State(initialValue: rule?.tags.sorted().joined(separator: ", ") ?? "")
        _stopProcessing = State(initialValue: rule?.stopProcessing ?? false)
        _matchingStrategy = State(initialValue: rule?.matchingStrategy ?? .allMatches)
    }

    var isValid: Bool {
        !name.isEmpty && !matchPattern.isEmpty && matchPatternError == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Information") {
                    TextField("Rule Name", text: $name)

                    Toggle("Enabled", isOn: $enabled)

                    TextField("Tags (comma-separated)", text: $tags)
                        .autocapitalization(.none)
                }

                Section("Match Criteria") {
                    Picker("Rule Type", selection: $ruleType) {
                        ForEach(RuleType.allCases.filter { $0 != .map }, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    Picker("Match Type", selection: $matchType) {
                        ForEach(MatchType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    Picker("Matching Strategy", selection: $matchingStrategy) {
                        Text("All Matches").tag(MatchingStrategy.allMatches)
                        Text("First Match").tag(MatchingStrategy.firstMatch)
                    }

                    Toggle("Stop Processing After Match", isOn: $stopProcessing)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        TextField("Match Pattern", text: $matchPattern)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Match pattern")
                            .onChange(of: matchPattern) { _ in
                                validateMatchPattern(announceIfError: true)
                            }
                            .onChange(of: matchType) { _ in
                                validateMatchPattern(announceIfError: true)
                            }

                        Text(matchTypeHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let matchPatternError {
                            Text(matchPatternError)
                                .font(.caption)
                                .foregroundStyle(DesignSystem.Colors.danger)
                                .accessibilityLabel("Match pattern error")
                                .accessibilityValue(matchPatternError)
                        }
                    }
                }

                Section {
                    ForEach(actions) { action in
                        ActionRow(action: action)
                    }
                    .onDelete { indices in
                        actions.remove(atOffsets: indices)
                    }
                    .onMove { source, destination in
                        actions.move(fromOffsets: source, toOffset: destination)
                    }

                    Button {
                        showingAddAction = true
                    } label: {
                        Label("Add Action", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    Text("Actions are executed in order when this rule matches")
                        .font(.caption)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDismissToolbar()
            .navigationTitle(rule == nil ? "New Rule" : "Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveRule()
                    }
                    .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showingAddAction) {
                ActionEditorView { newAction in
                    actions.append(newAction)
                }
            }
            .onAppear {
                validateMatchPattern(announceIfError: false)
            }
            .onDisappear {
                matchPatternAnnouncementTask?.cancel()
            }
        }
    }

    private var matchTypeHint: String {
        switch matchType {
        case .wildcard:
            "Example: *.example.com or */api/*"
        case .regex:
            "Example: ^https://.*\\.example\\.com/.*$"
        case .exact:
            "Example: https://api.example.com/users"
        case .contains:
            "Example: /api/users"
        }
    }

    private func saveRule() {
        let newRule = RewriteRule(
            id: rule?.id ?? UUID(),
            name: name,
            enabled: enabled,
            ruleType: ruleType,
            matchType: matchType,
            matchPattern: matchPattern,
            matchCriteria: MatchCriteria(url: URLMatcher(matchType: matchType, pattern: matchPattern)),
            stopProcessing: stopProcessing,
            matchingStrategy: matchingStrategy,
            actions: actions,
            priority: rule?.priority ?? 0,
            tags: Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }),
            createdAt: rule?.createdAt ?? Date(),
            modifiedAt: Date()
        )

        onSave(newRule)
        dismiss()
    }

    private func validateMatchPattern(announceIfError: Bool) {
        let trimmed = matchPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            matchPatternError = nil
            lastAnnouncedMatchPatternError = nil
            return
        }

        switch matchType {
        case .regex:
            do {
                _ = try NSRegularExpression(pattern: trimmed, options: [])
                matchPatternError = nil
                lastAnnouncedMatchPatternError = nil
            } catch {
                let message = "Invalid regex: \(error.localizedDescription)"
                matchPatternError = message
                if announceIfError {
                    scheduleMatchPatternAnnouncement(message)
                }
            }
        default:
            matchPatternError = nil
            lastAnnouncedMatchPatternError = nil
        }
    }

    private func scheduleMatchPatternAnnouncement(_ message: String) {
#if canImport(UIKit)
        guard UIAccessibility.isVoiceOverRunning else { return }
        guard lastAnnouncedMatchPatternError != message else { return }

        lastAnnouncedMatchPatternError = message
        matchPatternAnnouncementTask?.cancel()
        matchPatternAnnouncementTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
#else
        _ = message
#endif
    }
}

struct ActionRow: View {
    let action: RewriteAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(action.actionType.displayName)
                .font(.headline)

            if !action.parameters.isEmpty {
                ForEach(Array(action.parameters.keys.sorted()), id: \.self) { key in
                    if let value = action.parameters[key] {
                        HStack {
                            Text(key.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(value)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }
}

struct ActionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (RewriteAction) -> Void

    @State private var actionType: RewriteAction.ActionType = .setHeader
    @State private var parameters: [String: String] = [:]
    @ScaledMetric(relativeTo: .body) private var textEditorHeight: CGFloat = 150

    var body: some View {
        NavigationStack {
            Form {
                Picker("Action Type", selection: $actionType) {
                    ForEach(RewriteAction.ActionType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .accessibilityLabel("Action type")
                .accessibilityHint("Select the type of rewrite action to add")
                .onChange(of: actionType) { newValue in
                    parameters.removeAll()
                    initializeParameters(for: newValue)
                }

                Section("Parameters") {
                    parameterFields
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saveAction()
                    }
                    .accessibilityLabel("Add action")
                }
            }
            .onAppear {
                initializeParameters(for: actionType)
            }
        }
    }

    @ViewBuilder
    private var parameterFields: some View {
        switch actionType {
        case .setHeader:
            TextField("Header Name", text: binding(for: "key"))
                .autocapitalization(.none)
                .accessibilityLabel("Header name")
            TextField("Header Value", text: binding(for: "value"))
                .accessibilityLabel("Header value")

        case .removeHeader:
            TextField("Header Name", text: binding(for: "key"))
                .autocapitalization(.none)
                .accessibilityLabel("Header name")

        case .replaceBody:
            TextField("Pattern (regex)", text: binding(for: "pattern"))
                .autocapitalization(.none)
                .accessibilityLabel("Pattern")
                .accessibilityHint("Regular expression to match in the body")
            TextField("Replacement", text: binding(for: "replacement"))
                .accessibilityLabel("Replacement")

        case .setBody:
            TextEditor(text: binding(for: "content"))
                .frame(minHeight: textEditorHeight)
                .font(.system(.body, design: .monospaced))
                .formTextEditorStyle()
                .accessibilityLabel("Body content")

        case .setStatusCode:
            TextField("Status Code", text: binding(for: "code"))
                .keyboardType(.numberPad)
                .accessibilityLabel("Status code")

        case .addDelay:
            TextField("Delay (milliseconds)", text: binding(for: "milliseconds"))
                .keyboardType(.numberPad)
                .accessibilityLabel("Delay in milliseconds")

        case .redirectTo:
            TextField("Redirect URL", text: binding(for: "url"))
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .accessibilityLabel("Redirect URL")

        case .setQueryParam:
            TextField("Param Name", text: binding(for: "name"))
                .autocapitalization(.none)
                .accessibilityLabel("Query parameter name")
            TextField("Param Value", text: binding(for: "value"))
                .accessibilityLabel("Query parameter value")

        case .removeQueryParam:
            TextField("Param Name", text: binding(for: "name"))
                .autocapitalization(.none)
                .accessibilityLabel("Query parameter name")

        case .setCookie:
            TextField("Cookie Name", text: binding(for: "name"))
                .autocapitalization(.none)
                .accessibilityLabel("Cookie name")
            TextField("Cookie Value", text: binding(for: "value"))
                .accessibilityLabel("Cookie value")

        case .removeCookie:
            TextField("Cookie Name", text: binding(for: "name"))
                .autocapitalization(.none)
                .accessibilityLabel("Cookie name")

        case .base64Encode, .base64Decode, .urlEncode, .urlDecode, .jsonToXml, .xmlToJson,
             .dropConnection, .resetConnection, .corruptData, .timeout, .packetLoss:
            Text("No parameters required")
                .foregroundStyle(.secondary)
                .accessibilityLabel("No parameters required")

        case .compress, .decompress:
            TextField("Algorithm (gzip, deflate, br)", text: binding(for: "algorithm"))
                .autocapitalization(.none)
                .accessibilityLabel("Compression algorithm")

        case .jsonPathSet:
            TextField("JSONPath", text: binding(for: "path"))
                .autocapitalization(.none)
                .accessibilityLabel("JSONPath")
            TextField("Value (JSON)", text: binding(for: "value"))
                .accessibilityLabel("Value")

        case .jsonPathDelete:
            TextField("JSONPath", text: binding(for: "path"))
                .autocapitalization(.none)
                .accessibilityLabel("JSONPath")

        case .throttle:
            TextField("Bandwidth (bytes/sec)", text: binding(for: "bandwidth"))
                .keyboardType(.numberPad)
                .accessibilityLabel("Bandwidth in bytes per second")

        case .addJitter:
            TextField("Base Delay (ms)", text: binding(for: "baseDelay"))
                .keyboardType(.numberPad)
                .accessibilityLabel("Base delay in milliseconds")
            TextField("Variance (ms)", text: binding(for: "variance"))
                .keyboardType(.numberPad)
                .accessibilityLabel("Variance in milliseconds")

        case .setBodyFromTemplate:
            TextEditor(text: binding(for: "template"))
                .frame(minHeight: textEditorHeight)
                .font(.system(.body, design: .monospaced))
                .formTextEditorStyle()
                .accessibilityLabel("Body template")
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { parameters[key] ?? "" },
            set: { parameters[key] = $0 }
        )
    }

    private func initializeParameters(for actionType: RewriteAction.ActionType) {
        switch actionType {
        case .setHeader:
            parameters = ["key": "", "value": ""]
        case .removeHeader:
            parameters = ["key": ""]
        case .replaceBody:
            parameters = ["pattern": "", "replacement": ""]
        case .setBody:
            parameters = ["content": ""]
        case .setStatusCode:
            parameters = ["code": "200"]
        case .addDelay:
            parameters = ["milliseconds": "1000"]
        case .redirectTo:
            parameters = ["url": ""]
        case .setQueryParam:
            parameters = ["name": "", "value": ""]
        case .removeQueryParam:
            parameters = ["name": ""]
        case .setCookie:
            parameters = ["name": "", "value": ""]
        case .removeCookie:
            parameters = ["name": ""]
        case .base64Encode, .base64Decode, .urlEncode, .urlDecode, .jsonToXml, .xmlToJson,
             .dropConnection, .resetConnection, .corruptData, .timeout, .packetLoss:
            parameters = [:]
        case .compress, .decompress:
            parameters = ["algorithm": "gzip"]
        case .jsonPathSet:
            parameters = ["path": "", "value": ""]
        case .jsonPathDelete:
            parameters = ["path": ""]
        case .throttle:
            parameters = ["bandwidth": "10240"]
        case .addJitter:
            parameters = ["baseDelay": "200", "variance": "50"]
        case .setBodyFromTemplate:
            parameters = ["template": ""]
        }
    }

    private func saveAction() {
        let action = RewriteAction(
            actionType: actionType,
            parameters: parameters
        )
        onSave(action)
        dismiss()
    }
}

#Preview {
    RewriteRuleEditorView(rule: nil) { _ in }
}
