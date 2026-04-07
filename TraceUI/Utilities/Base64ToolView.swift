//
//  Base64ToolView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI

/// Presents a Base64 encode/decode tool with URL-safe support.
public struct Base64ToolView: View {
    @State private var mode: Mode = .encode
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var useURLSafe = false
    @State private var toastMessage: String?

    public init() {}

    enum Mode: String, CaseIterable {
        case encode = "Encode"
        case decode = "Decode"
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lg) {
                // Mode picker
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChangeCompat(of: mode) {
                    processText()
                }
                .accessibilityLabel("Base64 mode")
                .accessibilityHint("Choose between encoding and decoding")

                // Input section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "arrow.down.doc")
                            .foregroundStyle(DesignSystem.Colors.info)
                            .imageScale(.medium)
                        Text("Input")
                            .font(.headline)

                        Spacer()

                        Button("Clear") {
                            inputText = ""
                            outputText = ""
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                        .disabled(inputText.isEmpty)
                        .accessibilityLabel("Clear input")
                        .accessibilityHint("Double tap to clear the input text")
                    }

                    TextEditor(text: $inputText)
                        .frame(minHeight: DesignSystem.Form.textEditorMinHeightMedium)
                        .font(DesignSystem.Typography.monospacedFont)
                        .textInputAutocapitalization(.never)
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
                            processText()
                        }
                        .accessibilityLabel("Input text")
                        .accessibilityHint("Enter text to encode or decode")
                }
                .padding(.horizontal)

                // Options section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Toggle("URL-Safe Base64", isOn: $useURLSafe)
                        .onChangeCompat(of: useURLSafe) {
                            processText()
                        }
                        .accessibilityHint("Use URL-safe Base64 encoding")

                    Text("URL-safe replaces + with - and / with _")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .fill(DesignSystem.Colors.muted.opacity(0.1))
                )
                .padding(.horizontal)

                // Output section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "arrow.up.doc")
                            .foregroundStyle(DesignSystem.Colors.success)
                            .imageScale(.medium)
                        Text("Output")
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
                        .accessibilityLabel("Copy output")
                        .accessibilityHint("Double tap to copy the output to clipboard")
                    }

                    Text(outputText.isEmpty ? "Result will appear here" : outputText)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal)

                Spacer(minLength: DesignSystem.Spacing.md)
            }
            .padding(.vertical)
        }
        .toast(message: $toastMessage)
        .dismissKeyboardOnTapAndScroll()
        .navigationTitle("Base64")
    }

    private func processText() {
        guard !inputText.isEmpty else {
            outputText = ""
            return
        }

        switch mode {
        case .encode:
            encodeText()
        case .decode:
            decodeText()
        }
    }

    private func encodeText() {
        guard let data = inputText.data(using: .utf8) else {
            outputText = "Error: Invalid input text"
            return
        }

        var encoded = data.base64EncodedString()

        if useURLSafe {
            encoded = encoded
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        outputText = encoded
    }

    private func decodeText() {
        var input = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        if useURLSafe {
            input = input
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")

            // Rule: Add padding to restore a length divisible by 4.
            let remainder = input.count % 4
            if remainder > 0 {
                input += String(repeating: "=", count: 4 - remainder)
            }
        }

        guard let data = Data(base64Encoded: input),
              let decoded = String(data: data, encoding: .utf8) else {
            outputText = "Error: Invalid Base64 string"
            return
        }

        outputText = decoded
    }
}

#Preview {
    Base64ToolView()
}
