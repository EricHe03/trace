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
    @State private var isAnalyzing = false
    @State private var isImporting = false
    @State private var toastMessage: String?
    @State private var analysisTask: Task<Void, Never>?

    public var onImport: ((String) async -> ImportOutcome)?

    public init(onImport: ((String) async -> ImportOutcome)? = nil) {
        self.onImport = onImport
    }

    public var body: some View {
        NavigationStack {
            Form {
                // MARK: Command Input
                Section {
                    TextEditor(text: $curlCommand)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .frame(minHeight: DesignSystem.Form.textEditorMinHeightLarge)
                        .accessibilityLabel("cURL command")
                } header: {
                    Text("Command")
                } footer: {
                    analysisStatusFooter
                }

            }
            .navigationTitle("Import cURL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Import") {
                            startImport()
                        }
                        .bold()
                        .disabled(importDisabled)
                    }
                }
            }
            .dismissKeyboardOnTapAndScroll()
            .onChangeCompat(of: curlCommand) {
                scheduleAnalysis()
            }
            .onDisappear {
                analysisTask?.cancel()
            }
            .toast(message: $toastMessage)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Private

    private var importDisabled: Bool {
        guard let plan = analyzedPlan else { return true }
        return isAnalyzing || plan.hasBlockingDiagnostics || onImport == nil
    }

    @ViewBuilder
    private var analysisStatusFooter: some View {
        if !curlCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isAnalyzing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Analyzing…")
                }
                .foregroundStyle(.secondary)
            } else if let plan = analyzedPlan {
                if plan.hasBlockingDiagnostics {
                    Label("Fix blocking issues before importing.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(DesignSystem.Colors.danger)
                } else {
                    Label("Ready to import.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.success)
                }
            }
        }
    }

    private func startImport() {
        guard let plan = analyzedPlan, !plan.hasBlockingDiagnostics else { return }
        guard let onImport else { return }

        isImporting = true
        let commandToImport = curlCommand

        Task {
            let outcome = await onImport(commandToImport)
            await MainActor.run {
                isImporting = false

                switch outcome {
                case .success:
                    dismiss()
                case let .failure(message):
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage = message
                    }
                case let .permissionRequired(message):
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage = message
                    }
                }
            }
        }
    }

    private func scheduleAnalysis() {
        analysisTask?.cancel()

        let trimmed = curlCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            analyzedPlan = nil
            isAnalyzing = false
            return
        }

        isAnalyzing = true
        let commandSnapshot = curlCommand

        analysisTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            let plan = await Task.detached(priority: .userInitiated) {
                CurlCommandAnalyzer().analyze(commandSnapshot)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard commandSnapshot == curlCommand else { return }
                analyzedPlan = plan
                isAnalyzing = false
            }
        }
    }
}

#Preview {
    CurlImportView()
}
