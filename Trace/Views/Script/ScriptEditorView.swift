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
    @State private var showValidation = false

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
                    HStack {
                        Text("JavaScript Code")
                            .font(.headline)
                            .padding(.horizontal)

                        Spacer()

                        Button {
                            validateCode()
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: validationIcon)
                                    .foregroundStyle(validationColor)
                                Text("Validate")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal)
                    }
                    .padding(.top, DesignSystem.Spacing.sm)

                    if showValidation {
                        HStack {
                            Image(systemName: validationIcon)
                                .foregroundStyle(validationColor)

                            Text(validationMessage)
                                .font(.caption)
                                .foregroundStyle(validationColor)

                            Spacer()

                            Button {
                                showValidation = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(DesignSystem.Colors.muted)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(validationColor.opacity(0.1))
                    }

                    TextEditor(text: $code)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                .stroke(DesignSystem.Colors.muted.opacity(0.2), lineWidth: 1)
                        )
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
                    .disabled(!isValid)
                }
            }
            .keyboardDismissToolbar()
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
        validationResult.isValid ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var validationColor: Color {
        validationResult.isValid ? DesignSystem.Colors.success : DesignSystem.Colors.danger
    }

    private var validationMessage: String {
        if validationResult.isValid {
            "Script syntax is valid"
        } else {
            validationResult.errorMessage ?? "Invalid script"
        }
    }

    private func validateCode() {
        validationResult = scriptManager.validateScript(code)
        showValidation = true
    }

    private func saveScript() {
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
