//
//  JSONFormatterView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI

/// Presents a tool for validating and formatting JSON input.
public struct JSONFormatterView: View {
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var formatMode: FormatMode = .pretty
    @State private var validationMessage = ""
    @State private var isValid = false
    @State private var toastMessage: String?

    public init() {}

    enum FormatMode: String, CaseIterable {
        case pretty = "Pretty"
        case minified = "Minified"

        var description: String {
            switch self {
            case .pretty:
                "Format with indentation and line breaks"
            case .minified:
                "Remove all whitespace and line breaks"
            }
        }
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lg) {
                // Format picker
                Picker("Format", selection: $formatMode) {
                    ForEach(FormatMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChangeCompat(of: formatMode) {
                    formatJSON()
                }
                .accessibilityLabel("JSON format mode")
                .accessibilityHint("Choose between pretty-printed and minified JSON")

                // Input section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "arrow.down.doc")
                            .foregroundStyle(DesignSystem.Colors.info)
                            .imageScale(.medium)
                        Text("Input JSON")
                            .font(.headline)

                        Spacer()

                        Button("Clear") {
                            inputText = ""
                            outputText = ""
                            validationMessage = ""
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                        .disabled(inputText.isEmpty)
                    }

                    TextEditor(text: $inputText)
                        .frame(minHeight: DesignSystem.Form.textEditorMinHeightLarge)
                        .font(DesignSystem.Typography.monospacedFont)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .padding(DesignSystem.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                .fill(DesignSystem.Form.textEditorBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                .stroke(DesignSystem.Colors.muted.opacity(0.3), lineWidth: 1)
                        )
                        .onChangeCompat(of: inputText) {
                            formatJSON()
                        }
                }
                .padding(.horizontal)

                // Validation status
                if !validationMessage.isEmpty {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isValid ? DesignSystem.Colors.success : DesignSystem.Colors.danger)
                            .imageScale(.medium)

                        Text(validationMessage)
                            .font(.subheadline)
                            .foregroundStyle(isValid ? DesignSystem.Colors.success : DesignSystem.Colors.danger)

                        Spacer()
                    }
                    .padding(DesignSystem.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .fill((isValid ? DesignSystem.Colors.success : DesignSystem.Colors.danger).opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .stroke((isValid ? DesignSystem.Colors.success : DesignSystem.Colors.danger).opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)
                }

                // Output section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "arrow.up.doc")
                            .foregroundStyle(DesignSystem.Colors.success)
                            .imageScale(.medium)
                        Text("Formatted JSON")
                            .font(.headline)

                        Spacer()

                        Button {
                            UIPasteboard.general.string = outputText
                            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                toastMessage = "Copied to clipboard"
                            }
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .tint(DesignSystem.Colors.success)
                        .disabled(outputText.isEmpty)
                    }

                    ScrollView {
                        Text(outputText.isEmpty ? "Formatted JSON will appear here" : outputText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DesignSystem.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                    .fill(DesignSystem.Form.textEditorBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                    .stroke(DesignSystem.Colors.muted.opacity(0.3), lineWidth: 1)
                            )
                            .font(DesignSystem.Typography.monospacedFont)
                            .foregroundStyle(outputText.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: DesignSystem.Form.textEditorMinHeightLarge, maxHeight: DesignSystem.Form.outputMaxHeightLarge)
                }
                .padding(.horizontal)

                Spacer(minLength: DesignSystem.Spacing.md)
            }
            .padding(.vertical)
        }
        .toast(message: $toastMessage)
        .dismissKeyboardOnTapAndScroll()
        .navigationTitle("JSON Formatter")
    }

    private func formatJSON() {
        guard !inputText.isEmpty else {
            outputText = ""
            validationMessage = ""
            return
        }

        guard let data = inputText.data(using: .utf8) else {
            outputText = "Error: Invalid input"
            validationMessage = "Invalid text encoding"
            isValid = false
            return
        }

        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data)

            let formatting: JSONSerialization.WritingOptions = switch formatMode {
            case .pretty:
                [.prettyPrinted, .sortedKeys]
            case .minified:
                []
            }

            let formattedData = try JSONSerialization.data(withJSONObject: jsonObject, options: formatting)

            if let formattedString = String(data: formattedData, encoding: .utf8) {
                outputText = formattedString
                validationMessage = "Valid JSON"
                isValid = true
            } else {
                outputText = "Error: Unable to convert to string"
                validationMessage = "Conversion error"
                isValid = false
            }

        } catch {
            outputText = "Error: \(error.localizedDescription)"
            validationMessage = "Invalid JSON: \(error.localizedDescription)"
            isValid = false
        }
    }
}

#Preview {
    JSONFormatterView()
}
