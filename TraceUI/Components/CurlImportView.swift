//
//  CurlImportView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/14.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TraceCore
import TraceFeatures

public struct CurlImportView: View {
    public enum ImportOutcome: Equatable, Sendable {
        case success(message: String)
        case permissionRequired(message: String)
        case failure(message: String)
    }

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var curlCommand = ""
    @State private var analyzedPlan: CurlCommandPlan?
    @State private var isImporting = false
    @State private var importOutcome: ImportOutcome?

    public var onImport: ((String) async -> ImportOutcome)?

    public init(onImport: ((String) async -> ImportOutcome)? = nil) {
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
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

                if let importOutcome {
                    importOutcomeView(importOutcome)
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
                    Button(isImporting ? "Importing..." : "Import") {
                        startImport()
                    }
                    .disabled(importDisabled || isImporting)
                }
            }
            .dismissKeyboardOnTapAndScroll()
            .onChangeCompat(of: curlCommand) {
                analyzedPlan = nil
                importOutcome = nil
            }
        }
    }

    private var importDisabled: Bool {
        guard let plan = analyzedPlan else { return true }
        return plan.hasBlockingDiagnostics || onImport == nil
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

    @ViewBuilder
    private func importOutcomeView(_ outcome: ImportOutcome) -> some View {
        let style = style(for: outcome)

        VStack(alignment: .leading, spacing: 8) {
            Label(style.title, systemImage: style.icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(style.color)

            Text(style.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .permissionRequired = outcome {
                Button("Open Settings") {
                    openAppSettings()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(style.color.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(style.color.opacity(0.25), lineWidth: 1)
        )
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

    private func startImport() {
        guard let plan = analyzedPlan, !plan.hasBlockingDiagnostics else { return }
        guard let onImport else { return }

        isImporting = true
        importOutcome = nil
        let commandToImport = curlCommand

        Task {
            let outcome = await onImport(commandToImport)
            await MainActor.run {
                isImporting = false
                withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                    importOutcome = outcome
                }

                if case .success = outcome {
                    dismiss()
                }
            }
        }
    }

    private func analyzeCommand() {
        analyzedPlan = CurlCommandExecutor().analyze(curlCommand)
        importOutcome = nil
    }

    private func style(for outcome: ImportOutcome) -> (title: String, message: String, icon: String, color: Color) {
        switch outcome {
        case let .success(message):
            return ("Import complete", message, "checkmark.circle.fill", DesignSystem.Colors.success)
        case let .permissionRequired(message):
            return ("Network access required", message, "exclamationmark.triangle.fill", DesignSystem.Colors.warning)
        case let .failure(message):
            return ("Import couldn't finish", message, "xmark.circle.fill", DesignSystem.Colors.danger)
        }
    }

    private func openAppSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

#Preview {
    CurlImportView()
}
