//
//  RootTabView.swift
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

struct RootTabView: View {
    @ObservedObject var viewModel: CaptureViewModel
    @State private var selectedTab: Tab = .network
    @State private var showingOnboarding = false
    @State private var showingBreakpointInspector = false
    @State private var breakpointObserverToken: AppGroupStorageObserverToken?
    @ObservedObject private var vpnManager = VPNManager.shared

    enum Tab {
        case network
        case tools
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Network Tab - Shows all network activity (HTTP, WebSocket, SSE) with filtering
            NetworkView(viewModel: viewModel)
                .tabItem {
                    Label("Network", systemImage: "network")
                }
                .tag(Tab.network)
                .accessibilityLabel("Network tab")
                .accessibilityHint("View captured network requests and activity")

            // Tools Tab
            ToolsTabView()
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .tag(Tab.tools)
                .accessibilityLabel("Tools tab")
                .accessibilityHint("Access traffic modification and utility tools")

            // Settings Tab
            SettingsTabView(viewModel: viewModel, showingOnboarding: $showingOnboarding)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(Tab.settings)
                .accessibilityLabel("Settings tab")
                .accessibilityHint("Configure app settings and preferences")
        }
        .modifier(SidebarAdaptableModifier())
        .onAppear {
            checkOnboarding()
            startObservingBreakpointChanges()
            presentBreakpointInspectorIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .viewRequest)) { notification in
            guard let requestIdString = notification.userInfo?["requestId"] as? String,
                  let requestId = UUID(uuidString: requestIdString) else {
                return
            }
            selectedTab = .network
            viewModel.selectedRequestId = requestId
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTab)) { notification in
            guard let tabValue = notification.userInfo?["tab"] as? String else { return }
            switch tabValue {
            case "network":
                selectedTab = .network
            case "tools":
                selectedTab = .tools
            case "settings":
                selectedTab = .settings
            default:
                break
            }
        }
        .onChangeCompat(of: viewModel.selectedSession) { newValue in
            if newValue != nil {
                selectedTab = .network
            }
        }
        .onChangeCompat(of: viewModel.selectedRequestId) { newValue in
            if newValue != nil {
                selectedTab = .network
            }
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView {
                showingOnboarding = false
                // Initialize VPN after onboarding is complete
                // This loads any existing configuration without triggering permission popup
                vpnManager.initializeIfNeeded()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingBreakpointInspector) {
            BreakpointConfigView(autoPresentLatestPausedRequest: true)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onDisappear {
            breakpointObserverToken?.cancel()
            breakpointObserverToken = nil
        }
        .dismissKeyboardOnTapAndScroll()
    }

    private func checkOnboarding() {
        let hasCompleted = UserDefaults.standard.bool(forKey: TraceUserDefaultsKey.hasCompletedOnboarding)
        if !hasCompleted {
            showingOnboarding = true
        } else {
            // Onboarding already complete, initialize VPN
            vpnManager.initializeIfNeeded()
        }
    }

    private func startObservingBreakpointChanges() {
        guard breakpointObserverToken == nil else { return }
        breakpointObserverToken = AppGroupStorage.shared.observeBreakpointChanges {
            Task { @MainActor in
                presentBreakpointInspectorIfNeeded()
            }
        }
    }

    @MainActor
    private func presentBreakpointInspectorIfNeeded() {
        guard let pausedRequests = try? AppGroupStorage.shared.loadAllPausedBreakpointRequests(),
              !pausedRequests.isEmpty else {
            return
        }

        selectedTab = .tools
        showingBreakpointInspector = true
    }
}

// MARK: - Tools Tab View

struct ToolsTabView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Traffic Modification") {
                    NavigationLink {
                        RewriteRulesView()
                    } label: {
                        Label("Rewrite Rules", systemImage: "doc.text")
                    }

                    NavigationLink {
                        RequestMapView()
                    } label: {
                        Label("Request Maps", systemImage: "map")
                    }

                    NavigationLink {
                        ScriptListView()
                    } label: {
                        Label("Scripts", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    NavigationLink {
                        HostsListView()
                    } label: {
                        Label("Hosts", systemImage: "network")
                    }

                    NavigationLink {
                        BreakpointConfigView()
                    } label: {
                        Label("Breakpoints", systemImage: "pause.circle")
                    }
                }

                Section("Utilities") {
                    NavigationLink {
                        Base64ToolView()
                    } label: {
                        Label("Base64", systemImage: "arrow.left.arrow.right.circle")
                    }

                    NavigationLink {
                        TimestampToolView()
                    } label: {
                        Label("Timestamp", systemImage: "clock")
                    }

                    NavigationLink {
                        HashToolView()
                    } label: {
                        Label("Hash", systemImage: "number")
                    }

                    NavigationLink {
                        URLEncoderView()
                    } label: {
                        Label("URL Encoder", systemImage: "link")
                    }

                    NavigationLink {
                        JSONFormatterView()
                    } label: {
                        Label("JSON Formatter", systemImage: "curlybraces")
                    }
                }
            }
            .navigationTitle("Tools")
            .listStyle(.insetGrouped)
        }
    }
}

// MARK: - Settings Tab View

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
                Section {
                    NavigationLink {
                        CaptureRulesView()
                    } label: {
                        Label("Capture Rules", systemImage: "line.3.horizontal.decrease.circle")
                    }

                    NavigationLink {
                        CaptureSettingsView(vpnManager: vpnManager)
                    } label: {
                        Label("Capture Mode", systemImage: "record.circle")
                    }

                    NavigationLink {
                        NetworkConditionProfilesView(viewModel: viewModel)
                    } label: {
                        HStack {
                            Label("Network Conditions", systemImage: "speedometer")
                            Spacer()
                            if viewModel.throttlingEnabled, let condition = viewModel.selectedNetworkCondition {
                                Text(condition.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Off")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        ConnectionSettingsView()
                    } label: {
                        Label("Connections", systemImage: "network")
                    }
                } header: {
                    Text("Capture Configuration")
                }

                Section {
                    NavigationLink {
                        CertificateGuideView()
                    } label: {
                        Label("HTTPS Certificate", systemImage: "checkmark.seal")
                    }

                    NavigationLink {
                        MITMSecurityView()
                    } label: {
                        Label("MITM & Security", systemImage: "shield")
                    }

                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                } header: {
                    Text("Security & Certificates")
                }

                Section {
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
                        FullTunnelSelfCheckView()
                    } label: {
                        Label("Full Tunnel Self-Check", systemImage: "checklist")
                    }

                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        Label("Storage & Cleanup", systemImage: "externaldrive")
                    }

                    HStack {
                        Label("Total Requests", systemImage: "chart.bar")
                        Spacer()
                        Text("\(viewModel.requests.count)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Data Management")
                }

                if !viewModel.requests.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            showingClearAlert = true
                        } label: {
                            Label("Clear All Requests", systemImage: "trash")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label("Advanced", systemImage: "wrench.and.screwdriver")
                    }
                } header: {
                    Text("General")
                }

                Section {
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
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .alert("Clear All Requests", isPresented: $showingClearAlert) {
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

// MARK: - SidebarAdaptableModifier

private struct SidebarAdaptableModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}

#Preview {
    RootTabView(viewModel: CaptureViewModel())
}
