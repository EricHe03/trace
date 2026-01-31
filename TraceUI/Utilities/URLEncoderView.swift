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
            VStack(spacing: DesignSystem.Spacing.lgPlus) {
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

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("Input")
                            .font(.headline)

                        Spacer()

                        Button("Clear") {
                            inputText = ""
                            outputText = ""
                        }
                        .font(.subheadline)
                        .disabled(inputText.isEmpty)
                    }

                    TextEditor(text: $inputText)
                        .frame(minHeight: DesignSystem.Form.textEditorMinHeightMedium)
                        .font(DesignSystem.Typography.monospacedFont)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .formTextEditorStyle()
                        .onChangeCompat(of: inputText) {
                            processText()
                        }
                }
                .padding(.horizontal)

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
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
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
                        .disabled(outputText.isEmpty)
                    }

                    ScrollView {
                        Text(outputText.isEmpty ? "Result will appear here" : outputText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DesignSystem.Spacing.md)
                            .background(DesignSystem.Form.textEditorBackground)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Form.textEditorCornerRadius))
                            .font(DesignSystem.Typography.monospacedFont)
                            .foregroundStyle(outputText.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: DesignSystem.Form.textEditorMinHeightMedium, maxHeight: DesignSystem.Form.outputMaxHeight)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.vertical)
        }
        .toast(message: $toastMessage)
        .keyboardDismissToolbar()
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
