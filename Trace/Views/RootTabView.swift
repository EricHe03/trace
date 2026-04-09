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
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
