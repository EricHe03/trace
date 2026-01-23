//
//  NetworkView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UIKit
import UniformTypeIdentifiers

struct NetworkView: View {
    @ObservedObject var viewModel: CaptureViewModel
    @StateObject private var webSocketViewModel = WebSocketViewModel()
    @StateObject private var sseViewModel = SSEViewModel()

    @State private var showingFilters = false
    @State private var showingRequestBuilder = false
    @State private var showingFavorites = false
    @State private var showingCurlImport = false
    @State private var showingVPNSetupAlert = false
    @State private var toastMessage: String?
    @State private var selectedRequest: NetworkRequest?
    @State private var requestToOpen: NetworkRequest?
    @State private var hasLoaded = false
    @State private var cachedEvents: [NetworkEvent] = []
    @State private var cachedFilteredEvents: [NetworkEvent] = []
    @State private var cachedEventCounts: [NetworkEventType: Int] = [:]
    @State private var eventRebuildTask: Task<Void, Never>?

    @ObservedObject private var vpnManager = VPNManager.shared
    private let isSimulator = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    private var actions: NetworkViewActions {
        NetworkViewActions(viewModel: viewModel, toastMessage: $toastMessage)
    }

    var body: some View {
        NavigationStack {
            contentWithSheets
        }
    }

    private var contentWithSheets: some View {
        contentStack
            .sheet(isPresented: $showingFilters) {
                FiltersView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingRequestBuilder) {
                RequestBuilderView()
            }
            .sheet(isPresented: $showingFavorites) {
                NavigationStack {
                    FavoritesListView()
                }
            }
            .sheet(isPresented: $showingCurlImport) {
                curlImportView
            }
            .sheet(item: $selectedRequest) { request in
                shareSheet(for: request)
            }
            .modifier(RequestNavigationDestinationModifier(requestToOpen: $requestToOpen))
            .toast(message: $toastMessage, bottomPadding: 80)
            .modifier(RequestSelectionModifier(
                viewModel: viewModel,
                requestToOpen: $requestToOpen,
                toastMessage: $toastMessage
            ))
            .task {
                await performInitialLoad()
            }
            .modifier(EventRebuildModifier(
                viewModel: viewModel,
                webSocketViewModel: webSocketViewModel,
                sseViewModel: sseViewModel,
                scheduleRebuild: scheduleEventRebuild
            ))
    }

    private var curlImportView: some View {
        CurlImportView { request in
            actions.importCurlRequest(request)
        }
    }

    private func shareSheet(for request: NetworkRequest) -> some View {
        ShareSheet(items: actions.shareItems(for: request))
    }

    private struct RequestNavigationDestinationModifier: ViewModifier {
        @Binding var requestToOpen: NetworkRequest?

        func body(content: Content) -> some View {
            if #available(iOS 17.0, *) {
                content.navigationDestination(item: $requestToOpen) { request in
                    DetailView(request: request)
                }
            } else {
                content.sheet(item: $requestToOpen) { request in
                    DetailView(request: request)
                }
            }
        }
    }

    private func performInitialLoad() async {
        if !hasLoaded {
            await loadAllData()
            hasLoaded = true
        }
        await rebuildEventCaches()
    }

    private var contentStack: some View {
        ZStack(alignment: .bottom) {
            listArea
            bottomActionBar
        }
    }

    private var listArea: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    NetworkListContent(
                        viewModel: viewModel,
                        filteredEvents: filteredEvents,
                        webSocketViewModel: webSocketViewModel,
                        sseViewModel: sseViewModel,
                        isSimulator: isSimulator,
                        effectiveGroupingMode: effectiveGroupingMode,
                        onToggleFavorite: { actions.toggleFavorite($0) },
                        onDeleteRequest: { actions.deleteRequest($0) },
                        onShareRequest: { actions.shareRequest($0, selectedRequest: $selectedRequest) },
                        contextMenuContent: contextMenuContent
                    )
                }
                .onChange(of: viewModel.selectedSession) { newValue in
                    guard let session = newValue else { return }
                    guard shouldGroupRequests else {
                        viewModel.selectedSession = nil
                        return
                    }
                    viewModel.groupingMode = .bySession
                    DispatchQueue.main.async {
                        proxy.scrollTo(session.id, anchor: .top)
                    }
                    viewModel.selectedSession = nil
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Network")
        .searchable(
            text: $viewModel.searchText,
            prompt: "Search URL, headers, or body"
        )
        .searchScopes($viewModel.searchScope) {
            Text("All").tag(SearchScope.all)
            Text("URL").tag(SearchScope.url)
            Text("Headers").tag(SearchScope.headers)
            Text("Body").tag(SearchScope.body)
        }
        .toolbar {
            NetworkViewToolbar(
                viewModel: viewModel,
                allEventsIsEmpty: allEvents.isEmpty,
                onToggleFilters: { showingFilters = true },
                onShowFavorites: { showingFavorites = true },
                onShowCurlImport: { showingCurlImport = true },
                onClearAll: clearAllData
            )
        }
        .overlay {
            if shouldShowEmptyState {
                TraceContentUnavailableView(
                    viewModel.searchText.isEmpty ? "No Network Activity" : "No Results",
                    systemImage: viewModel.searchText.isEmpty ? "network.slash" : "magnifyingglass",
                    description: Text(viewModel.searchText.isEmpty ? "Network events will appear here when capture is active" : "Try a different search term or filter")
                )
            }
        }
        .refreshable {
            await loadAllData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFavorites)) { _ in
            showingFavorites = true
        }
    }

    private var bottomActionBar: some View {
        BottomActionBar(
            isCapturing: vpnManager.isConnected,
            onToggleCapture: {
                Task {
                    if vpnManager.isConnected {
                        vpnManager.stop()
                    } else {
                        do {
                            try await vpnManager.start()
                        } catch {
                            await MainActor.run {
                                withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                    if let vpnError = error as? VPNError, vpnError == .notConfigured {
                                        showingVPNSetupAlert = true
                                    } else {
                                        toastMessage = "VPN error: \(error.localizedDescription)"
                                    }
                                }
                            }
                        }
                    }
                }
            },
            onNewRequest: {
                showingRequestBuilder = true
            }
        )
        .padding()
        .alert("VPN Not Configured", isPresented: $showingVPNSetupAlert) {
            Button("Add Configuration") {
                Task {
                    do {
                        try await vpnManager.requestVPNPermission()
                    } catch {
                        await MainActor.run {
                            toastMessage = "Failed to add VPN configuration: \(error.localizedDescription)"
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("VPN configuration is required to capture network traffic. Would you like to add it now?")
        }
    }

    // MARK: - Type Filter Helpers

    private func toggleEventType(_ type: NetworkEventType) {
        if viewModel.filterNetworkEventTypes.contains(type) {
            viewModel.filterNetworkEventTypes.remove(type)
        } else {
            viewModel.filterNetworkEventTypes.insert(type)
        }
    }

    // MARK: - Data Loading

    private func loadAllData() async {
        await viewModel.reloadRequests()
        await webSocketViewModel.loadConnections()
        await sseViewModel.loadConnections()
    }

    // MARK: - Computed Properties

    private var allEvents: [NetworkEvent] {
        cachedEvents
    }

    private var filteredEvents: [NetworkEvent] {
        cachedFilteredEvents
    }

    private var eventCountByType: [NetworkEventType: Int] {
        cachedEventCounts
    }

    var shouldShowEmptyState: Bool {
        switch effectiveGroupingMode {
        case .none:
            filteredEvents.isEmpty
        case .byDomain:
            viewModel.groupedRequests.domainGroups.isEmpty
        case .bySession, .hierarchical:
            viewModel.groupedRequests.sessionGroups.isEmpty
        }
    }

    // MARK: - Grouping Helpers

    private var shouldGroupRequests: Bool {
        viewModel.filterNetworkEventTypes.count == 1 && viewModel.filterNetworkEventTypes.contains(.http)
    }

    private var effectiveGroupingMode: RequestGroupingMode {
        shouldGroupRequests ? viewModel.groupingMode : .none
    }

    // MARK: - Actions

    private func clearAllData() {
        actions.clearAllData(
            webSocketViewModel: webSocketViewModel,
            sseViewModel: sseViewModel
        )
    }

    private func contextMenuContent(for request: NetworkRequest) -> AnyView {
        AnyView(
            Group {
                Button {
                    actions.copyURL(request)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }

                Button {
                    actions.copyAsCurl(request)
                } label: {
                    Label("Copy as cURL", systemImage: "terminal")
                }

                Button {
                    actions.replayRequest(request)
                } label: {
                    Label("Replay Request", systemImage: "arrow.clockwise")
                }

                Divider()

                Button {
                    actions.shareRequest(request)
                } label: {
                    Label("Share Request", systemImage: "square.and.arrow.up")
                }

                if !request.responseBody.isEmpty {
                    Button {
                        actions.shareResponseBody(request)
                    } label: {
                        Label("Share Response Body", systemImage: "arrow.down.doc")
                    }
                }

                Divider()

                let isFavorited = FavoritesManager.shared.isFavorited(requestId: request.id)
                Button {
                    actions.toggleFavorite(request)
                } label: {
                    Label(
                        isFavorited ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isFavorited ? "star.slash" : "star"
                    )
                }

                Button(role: .destructive) {
                    actions.deleteRequest(request)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        )
    }

    private func scheduleEventRebuild() {
        eventRebuildTask?.cancel()
        eventRebuildTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await rebuildEventCaches()
        }
    }

    @MainActor
    private func rebuildEventCaches() async {
        let httpRequests = viewModel.filteredRequests
        let webSockets = webSocketViewModel.connections
        let sseConnections = sseViewModel.connections
        let searchText = viewModel.searchText
        let enabledTypes = viewModel.filterNetworkEventTypes

        let results = await Task.detached(priority: .userInitiated) {
            var events: [NetworkEvent] = []
            events.reserveCapacity(httpRequests.count + webSockets.count + sseConnections.count)
            events.append(contentsOf: httpRequests.map { .httpRequest($0) })
            events.append(contentsOf: webSockets.map { .webSocket($0) })
            events.append(contentsOf: sseConnections.map { .sse($0) })

            var counts: [NetworkEventType: Int] = [:]
            for event in events {
                counts[event.type, default: 0] += 1
            }

            var filtered = events.filter { enabledTypes.contains($0.type) }
            if !searchText.isEmpty {
                filtered = filtered.filter { event in
                    switch event {
                    case .httpRequest:
                        true
                    case let .webSocket(connection):
                        connection.url.localizedCaseInsensitiveContains(searchText)
                    case let .sse(connection):
                        connection.url.localizedCaseInsensitiveContains(searchText)
                    }
                }
            }
            filtered.sort { $0.timestamp > $1.timestamp }

            return (events, filtered, counts)
        }.value

        cachedEvents = results.0
        cachedFilteredEvents = results.1
        cachedEventCounts = results.2
    }
}

#Preview {
    NetworkView(viewModel: CaptureViewModel())
}
