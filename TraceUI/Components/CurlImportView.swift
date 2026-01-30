//
//  CurlImportView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/14.
//

import SwiftUI
import TraceCore
import TraceFeatures

public struct CurlImportView: View {
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var curlCommand = ""
    @State private var parsedRequest: NetworkRequest?
    @State private var toastMessage: String?

    public var onImport: ((NetworkRequest) -> Void)?

    public init(onImport: ((NetworkRequest) -> Void)? = nil) {
        self.onImport = onImport
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Import cURL Command", systemImage: "square.and.arrow.down")
                        .font(.headline)

                    Text("Paste a cURL command to import it as a request. Most common options are supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("cURL Command")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    TextEditor(text: $curlCommand)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(.separator), lineWidth: 1)
                        )
                }

                Button {
                    parseCommand()
                } label: {
                    Label("Parse", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(curlCommand.isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Import cURL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Import") {
                        if let request = parsedRequest {
                            onImport?(request)
                            dismiss()
                        }
                    }
                    .disabled(parsedRequest == nil)
                }
            }
            .toast(message: $toastMessage)
            .keyboardDismissToolbar()
        }
    }

    private func parseCommand() {
        do {
            parsedRequest = try CurlParser.parse(curlCommand)
            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                toastMessage = "Parsed successfully"
            }
        } catch {
            parsedRequest = nil
            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                toastMessage = "Parse error: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    CurlImportView()
}
