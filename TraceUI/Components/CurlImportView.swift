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
    @State private var analyzedPlan: CurlCommandPlan?
    @State private var toastMessage: String?

    public var onImport: ((String) -> Void)?

    public init(onImport: ((String) -> Void)? = nil) {
        self.onImport = onImport
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Import cURL Command", systemImage: "square.and.arrow.down")
                        .font(.headline)

                    Text("Paste a cURL command to analyze and execute with fail-fast diagnostics.")
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
                    analyzeCommand()
                } label: {
                    Label("Analyze", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(curlCommand.isEmpty)

                if let plan = analyzedPlan {
                    analysisSummary(plan: plan)
                }

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
                        if let plan = analyzedPlan, !plan.hasBlockingDiagnostics {
                            onImport?(curlCommand)
                            dismiss()
                        }
                    }
                    .disabled(importDisabled)
                }
            }
            .toast(message: $toastMessage)
            .dismissKeyboardOnTapAndScroll()
        }
    }

    private var importDisabled: Bool {
        guard let plan = analyzedPlan else { return true }
        return plan.hasBlockingDiagnostics
    }

    private func analysisSummary(plan: CurlCommandPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analysis")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Transfers: \(plan.transfers.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if plan.diagnostics.isEmpty {
                Text("No diagnostics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.diagnostics) { diagnostic in
                            HStack(alignment: .top, spacing: 8) {
                                Text(diagnostic.severity.rawValue.uppercased())
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(color(for: diagnostic.severity))
                                    .frame(width: 56, alignment: .leading)

                                Text(diagnostic.message)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    private func color(for severity: CurlDiagnosticSeverity) -> Color {
        switch severity {
        case .info:
            .blue
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private func analyzeCommand() {
        let plan = CurlCommandExecutor().analyze(curlCommand)
        analyzedPlan = plan

        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            if plan.hasBlockingDiagnostics {
                toastMessage = "Blocking issues: \(plan.blockingDiagnostics.count)"
            } else {
                toastMessage = "Ready: \(plan.transfers.count) transfer(s)"
            }
        }
    }
}

#Preview {
    CurlImportView()
}
