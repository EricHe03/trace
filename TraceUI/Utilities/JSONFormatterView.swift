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
            VStack(spacing: DesignSystem.Spacing.lgPlus) {
                Picker("Format", selection: $formatMode) {
                    ForEach(FormatMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: formatMode) { _ in
                    formatJSON()
                }
                .accessibilityLabel("JSON format mode")
                .accessibilityHint("Choose between pretty-printed and minified JSON")

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("Input JSON")
                            .font(.headline)

                        Spacer()

                        Button("Clear") {
                            inputText = ""
                            outputText = ""
                            validationMessage = ""
                        }
                        .font(.subheadline)
                        .disabled(inputText.isEmpty)

                        Button("Validate") {
                            validateJSON()
                        }
                        .font(.subheadline)
                        .disabled(inputText.isEmpty)
                    }

                    TextEditor(text: $inputText)
                        .frame(minHeight: DesignSystem.Form.textEditorMinHeightLarge)
                        .font(DesignSystem.Typography.monospacedFont)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .formTextEditorStyle()
                        .onChange(of: inputText) { _ in
                            formatJSON()
                        }
                }
                .padding(.horizontal)

                if !validationMessage.isEmpty {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isValid ? DesignSystem.Colors.success : DesignSystem.Colors.danger)

                        Text(validationMessage)
                            .font(.subheadline)
                            .foregroundStyle(isValid ? DesignSystem.Colors.success : DesignSystem.Colors.danger)

                        Spacer()
                    }
                    .padding()
                    .background(isValid ? DesignSystem.Colors.success.opacity(0.1) : DesignSystem.Colors.danger.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("Formatted JSON")
                            .font(.headline)

                        Spacer()

                        Button {
                            UIPasteboard.general.string = outputText
                            withAnimation {
                                toastMessage = "Copied to clipboard"
                            }
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.subheadline)
                        }
                        .disabled(outputText.isEmpty)
                    }

                    ScrollView {
                        Text(outputText.isEmpty ? "Formatted JSON will appear here" : outputText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DesignSystem.Spacing.md)
                            .background(DesignSystem.Form.textEditorBackground)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Form.textEditorCornerRadius))
                            .font(DesignSystem.Typography.monospacedFont)
                            .foregroundStyle(outputText.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: DesignSystem.Form.textEditorMinHeightLarge, maxHeight: DesignSystem.Form.outputMaxHeightLarge)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.vertical)
        }
        .toast(message: $toastMessage)
        .keyboardDismissToolbar()
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

    private func validateJSON() {
        formatJSON()
    }
}

#Preview {
    JSONFormatterView()
}
