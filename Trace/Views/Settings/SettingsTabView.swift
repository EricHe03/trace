//
//  SettingsTabView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import os
import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UniformTypeIdentifiers

struct SettingsTabView: View {
    @ObservedObject var viewModel: CaptureViewModel
    @Binding var showingOnboarding: Bool
    @State private var showingClearAlert = false
    @State private var showingHARImport = false
    @State private var shareSheetItem: ShareSheetItem?
    @State private var toastMessage: String?
    @ObservedObject private var vpnManager = VPNManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    NavigationLink {
                        CaptureRulesView()
                    } label: {
                        Label("Capture Rules", systemImage: "line.3.horizontal.decrease.circle")
                    }

                    NavigationLink {
                        CaptureSettingsView(vpnManager: vpnManager)
                    } label: {
                        Label("VPN & Proxy Mode", systemImage: "record.circle")
                    }
                }

                Section("HTTPS Interception") {
                    NavigationLink {
                        CertificateGuideView()
                    } label: {
                        Label("Certificate Setup", systemImage: "checkmark.seal")
                    }

                    NavigationLink {
                        MITMSecurityView()
                    } label: {
                        Label("Interception Rules", systemImage: "shield")
                    }
                }

                Section("Data & Storage") {
                    Button {
                        exportToHAR()
                    } label: {
                        Label("Export HAR", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.requests.isEmpty)

                    Button {
                        showingHARImport = true
                    } label: {
                        Label("Import HAR", systemImage: "square.and.arrow.down")
                    }

                    NavigationLink {
                        PCAPExportView()
                    } label: {
                        Label("Packet Captures", systemImage: "doc")
                    }

                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        Label("Storage", systemImage: "externaldrive")
                    }

                    if !viewModel.requests.isEmpty {
                        Button(role: .destructive) {
                            showingClearAlert = true
                        } label: {
                            Label("Clear \(viewModel.requests.count) Requests", systemImage: "trash")
                        }
                    }
                }

                Section("Notifications") {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }

                Section("General") {
                    NavigationLink {
                        BodyStorageSettingsView()
                    } label: {
                        Label("Body Storage", systemImage: "internaldrive")
                    }

                    NavigationLink {
                        SamplingSettingsView()
                    } label: {
                        Label("Request Sampling", systemImage: "chart.bar")
                    }

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }

                Section("About") {
                    HStack {
                        Label("Version", systemImage: "tag")
                        Spacer()
                        Text(AppVersion.fullVersion)
                            .foregroundStyle(.secondary)
                    }

                    if let githubURL = URL(string: "https://github.com/Trace-iOS/Trace") {
                        Link(destination: githubURL) {
                            Label("GitHub", systemImage: "arrow.up.right.square")
                        }
                    }

                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised.circle")
                    }

                    Button {
                        UserDefaults.standard.set(false, forKey: TraceUserDefaultsKey.hasCompletedOnboarding)
                        showingOnboarding = true
                    } label: {
                        Label("Show Onboarding", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Clear Requests", isPresented: $showingClearAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    viewModel.clearRequests()
                }
            } message: {
                Text("Are you sure you want to clear all captured requests? This action cannot be undone.")
            }
            .shareSheet(item: $shareSheetItem)
            .fileImporter(
                isPresented: $showingHARImport,
                allowedContentTypes: {
                    // Accept both .json and .har extensions so HAR files show up in the picker.
                    if let harType = UTType(filenameExtension: "har") {
                        return [.json, harType]
                    }
                    return [.json]
                }(),
                allowsMultipleSelection: false
            ) { result in
                handleHARImport(result)
            }
            .toast(message: $toastMessage)
        }
    }

    // MARK: - HAR Export/Import

    private func exportToHAR() {
        do {
            let url = try HARExporter.exportToFile(requests: viewModel.requests)
            shareSheetItem = ShareSheetItem([url])
        } catch {
            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                toastMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func handleHARImport(_ result: Result<[URL], Error>) {
        Task {
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }

                // Check if file exists before attempting to access
                guard FileManager.default.fileExists(atPath: url.path) else {
                    CoreLog.storage.warning("event=storage.har_import outcome=failure reason=file_not_found")
                    await MainActor.run {
                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                            toastMessage = "File not found"
                        }
                    }
                    return
                }

                // Access security-scoped resource from Files picker
                let canAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if canAccess { url.stopAccessingSecurityScopedResource() }
                }

                let requests = try HARExporter.importFromFile(url)
                CoreLog.storage.info("event=storage.har_import outcome=success count=\(requests.count)")

                // Save imported requests to storage
                var savedCount = 0
                for request in requests {
                    do {
                        try AppGroupStorage.shared.saveRequest(request)
                        savedCount += 1
                        CoreLog.storage.debug(
                            "event=storage.request_save outcome=success request_id=\(request.id.uuidString, privacy: .public) method=\(request.method.rawValue, privacy: .public) url=\(request.url, privacy: .private(mask: .hash))"
                        )
                    } catch {
                        CoreLog.storage.error(
                            "event=storage.request_save outcome=failure request_id=\(request.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                CoreLog.storage.info(
                    "event=storage.har_import_save outcome=success saved=\(savedCount) total=\(requests.count)"
                )

                // Reload all requests from storage to ensure consistency
                await viewModel.reloadRequests()
                CoreLog.storage.info(
                    "event=storage.requests_reload outcome=success count=\(viewModel.requests.count)"
                )

                await MainActor.run {
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage = "Imported \(requests.count) requests"
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage = "Import failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

private struct SettingsTabViewPreview: View {
    @State private var showingOnboarding = false

    var body: some View {
        SettingsTabView(viewModel: CaptureViewModel(), showingOnboarding: $showingOnboarding)
    }
}

#Preview {
    SettingsTabViewPreview()
}
