//
//  URLEncoderView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI

/// Presents a URL encode/decode tool with component and full-URL modes.
public struct URLEncoderView: View {
    @State private var mode: Mode = .encode
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var encodingMode: EncodingMode = .component
    @State private var toastMessage: String?

    public init() {}

    enum Mode: String, CaseIterable {
        case encode = "Encode"
        case decode = "Decode"
    }

    enum EncodingMode: String, CaseIterable {
        case component = "Component"
        case full = "Full URL"

        var description: String {
            switch self {
            case .component:
                "Encode individual URL components (query parameters, path segments)"
            case .full:
                "Encode the entire URL while preserving URL structure"
            }
        }
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
                .accessibilityLabel("URL encoding mode")
                .accessibilityHint("Choose between encoding and decoding URLs")

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
                    }

                    TextEditor(text: $inputText)
                        .frame(minHeight: DesignSystem.Form.textEditorMinHeightMedium)
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
                            processText()
                        }
                }
                .padding(.horizontal)

                // Encoding options (only for encode mode)
                if mode == .encode {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Picker("Encoding Mode", selection: $encodingMode) {
                            ForEach(EncodingMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChangeCompat(of: encodingMode) {
                            processText()
                        }

                        Text(encodingMode.description)
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
                }

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
                    }

                    ScrollView {
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
                    }
                    .frame(minHeight: DesignSystem.Form.textEditorMinHeightMedium, maxHeight: DesignSystem.Form.outputMaxHeight)
                }
                .padding(.horizontal)

                Spacer(minLength: DesignSystem.Spacing.md)
            }
            .padding(.vertical)
        }
        .toast(message: $toastMessage)
        .dismissKeyboardOnTapAndScroll()
        .navigationTitle("URL Encoder")
    }

    private func processText() {
        guard !inputText.isEmpty else {
            outputText = ""
            return
        }

        switch mode {
        case .encode:
            encodeURL()
        case .decode:
            decodeURL()
        }
    }

    private func encodeURL() {
        switch encodingMode {
        case .component:
            // Rule: Encode components with query-safe characters to preserve separators.
            if let encoded = inputText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                outputText = encoded
            } else {
                outputText = "Error: Unable to encode"
            }

        case .full:
            // Rule: Encode full URLs while preserving fragment and path structure.
            if let encoded = inputText.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
                outputText = encoded
            } else {
                outputText = "Error: Unable to encode"
            }
        }
    }

    private func decodeURL() {
        if let decoded = inputText.removingPercentEncoding {
            outputText = decoded
        } else {
            outputText = "Error: Invalid URL encoding"
        }
    }
}

#Preview {
    URLEncoderView()
}
