//
//  ScriptEditorView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UIKit

struct ScriptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let script: Script?
    let onSave: (Script) -> Void

    @State private var name: String
    @State private var enabled: Bool
    @State private var scriptType: ScriptType
    @State private var matchType: MatchType
    @State private var matchPattern: String
    @State private var code: String
    @State private var validationResult: ScriptValidationResult = .valid
    @State private var isValidating = false
    @State private var validationTask: Task<Void, Never>?

    private let scriptManager = ScriptManager.shared

    init(script: Script?, onSave: @escaping (Script) -> Void) {
        self.script = script
        self.onSave = onSave

        _name = State(initialValue: script?.name ?? "")
        _enabled = State(initialValue: script?.enabled ?? true)
        _scriptType = State(initialValue: script?.scriptType ?? .request)
        _matchType = State(initialValue: script?.matchType ?? .wildcard)
        _matchPattern = State(initialValue: script?.matchPattern ?? "")
        _code = State(initialValue: script?.code ?? """
        // Modify the request/response
        // Available objects: request, response (for response scripts)
        // Example:
        // request.headers['X-Custom'] = 'value';
        // response.statusCode = 200;

        """)
    }

    var isValid: Bool {
        !name.isEmpty && !code.isEmpty
    }

    private var canSave: Bool {
        isValid && validationResult.isValid && !isValidating
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Configuration section
                Form {
                    Section("Basic Information") {
                        TextField("Script Name", text: $name)

                        Toggle("Enabled", isOn: $enabled)
                    }

                    Section("Execution") {
                        Picker("Script Type", selection: $scriptType) {
                            ForEach(ScriptType.allCases, id: \.self) { type in
                                VStack(alignment: .leading) {
                                    Text(type.displayName)
                                    Text(type.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(type)
                            }
                        }
                    }

                    Section("Match Criteria") {
                        Picker("Match Type", selection: $matchType) {
                            ForEach(MatchType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            TextField("Pattern (leave empty for all)", text: $matchPattern)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Text(matchTypeHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 350)

                // Code editor section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("JavaScript Code")
                        .font(.headline)
                        .padding(.horizontal)
                    .padding(.top, DesignSystem.Spacing.sm)

                    HStack {
                        if isValidating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: validationIcon)
                                .foregroundStyle(validationColor)
                        }

                        Text(isValidating ? "Validating syntax…" : validationMessage)
                            .font(.caption)
                            .foregroundStyle(isValidating ? .secondary : validationColor)

                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background((isValidating ? DesignSystem.Colors.muted : validationColor).opacity(0.1))

                    TextEditor(text: $code)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                .stroke(DesignSystem.Colors.muted.opacity(0.2), lineWidth: 1)
                        )
                        .formTextEditorStyle()
                        .accessibilityLabel("JavaScript code")
                        .onChangeCompat(of: code) {
                            scheduleValidation()
                        }
                }
            }
            .navigationTitle(script == nil ? "New Script" : "Edit Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveScript()
                    }
                    .disabled(!canSave)
                }
            }
            .dismissKeyboardOnTapAndScroll()
            .onAppear {
                scheduleValidation()
            }
            .onDisappear {
                validationTask?.cancel()
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

    private var validationIcon: String {
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "info.circle"
        }
        return validationResult.isValid ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var validationColor: Color {
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DesignSystem.Colors.muted
        }
        return validationResult.isValid ? DesignSystem.Colors.success : DesignSystem.Colors.danger
    }

    private var validationMessage: String {
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter script code to validate syntax"
        } else if validationResult.isValid {
            return "Script syntax is valid"
        } else {
            return validationResult.errorMessage ?? "Invalid script"
        }
    }

    private func scheduleValidation() {
        validationTask?.cancel()
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationResult = .valid
            isValidating = false
            return
        }

        isValidating = true
        let codeSnapshot = code
        validationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard codeSnapshot == code else { return }
            validationResult = scriptManager.validateScript(codeSnapshot)
            isValidating = false
        }
    }

    private func validateBeforeSave() -> Bool {
        validationTask?.cancel()
        isValidating = false
        validationResult = scriptManager.validateScript(code)
        if validationResult.isValid {
            return true
        }
        UIAccessibility.post(notification: .announcement, argument: validationMessage)
        return false
    }

    private func saveScript() {
        guard validateBeforeSave() else { return }

        let newScript = Script(
            id: script?.id ?? UUID(),
            name: name,
            enabled: enabled,
            scriptType: scriptType,
            matchType: matchType,
            matchPattern: matchPattern.isEmpty ? nil : matchPattern,
            code: code,
            createdAt: script?.createdAt ?? Date(),
            modifiedAt: Date(),
            executionCount: script?.executionCount ?? 0
        )

        onSave(newScript)
        dismiss()
    }
}

#Preview {
    ScriptEditorView(script: nil) { _ in }
}
