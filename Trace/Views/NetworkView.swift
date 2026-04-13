//
//  NetworkView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import OSLog
import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UIKit
import UniformTypeIdentifiers

struct NetworkView: View {
    @ObservedObject var viewModel: CaptureViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var webSocketViewModel = WebSocketViewModel()
    @StateObject private var sseViewModel = SSEViewModel()

    @State private var showingFilters = false
    @State private var showingRequestBuilder = false
    @State private var showingFavorites = false
    @State private var showingCurlImport = false
    @State private var showingClearAllAlert = false
    @State private var showingVPNSetupAlert = false
    @State private var toastMessage: String?
    @State private var shareSheetItem: ShareSheetItem?
    @State private var requestToOpen: NetworkRequest?
    @State private var hasLoaded = false
    @State private var cachedFilteredEvents: [NetworkEvent] = []
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingRequestBuilder) {
                RequestBuilderView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingFavorites) {
                NavigationStack {
                    FavoritesListView()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingCurlImport) {
                curlImportView
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .shareSheet(item: $shareSheetItem)
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
            .onAppear {
                syncRefreshLifecycle(for: scenePhase)
            }
            .onChangeCompat(of: scenePhase) { newPhase in
                syncRefreshLifecycle(for: newPhase)
            }
            .modifier(EventRebuildModifier(
                viewModel: viewModel,
                webSocketViewModel: webSocketViewModel,
                sseViewModel: sseViewModel,
                scheduleRebuild: scheduleEventRebuild
            ))
            .alert("Clear All Network Activity", isPresented: $showingClearAllAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    clearAllData()
                }
            } message: {
                Text("Are you sure you want to clear all captured requests, transport events, WebSocket connections, and SSE connections? This action cannot be undone.")
            }
    }

    private var curlImportView: some View {
        CurlImportView { command in
            await actions.importCurlCommand(command)
        }
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
        FeatureLog.capture.info("event=network_view.perform_initial_load outcome=start has_loaded=\(self.hasLoaded, privacy: .public)")
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
                        onShareRequest: { shareSheetItem = ShareSheetItem(actions.shareItems(for: $0)) },
                        contextMenuContent: contextMenuContent
                    )
                }
                .onChangeCompat(of: viewModel.selectedSession) { newValue in
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
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 100)
        }
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.large)
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
                allEventsIsEmpty: viewModel.requests.isEmpty &&
                    viewModel.transportRequests.isEmpty &&
                    webSocketViewModel.connections.isEmpty &&
                    sseViewModel.connections.isEmpty,
                onToggleFilters: { showingFilters = true },
                onShowFavorites: { showingFavorites = true },
                onShowCurlImport: { showingCurlImport = true },
                onClearAll: { showingClearAllAlert = true }
            )
        }
        .overlay {
            if shouldShowEmptyState {
                emptyStateView
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
        FeatureLog.capture.info("event=network_view.load_all_data outcome=start")
        await viewModel.reloadRequests()
        await viewModel.reloadTransportRequests()
        await webSocketViewModel.loadConnections()
        await sseViewModel.loadConnections()
        FeatureLog.capture.info("event=network_view.load_all_data outcome=complete")
    }

    private func syncRefreshLifecycle(for phase: ScenePhase) {
        let isActive = phase == .active
        webSocketViewModel.setSceneActive(isActive)
        sseViewModel.setSceneActive(isActive)
    }

    // MARK: - Computed Properties

    private var filteredEvents: [NetworkEvent] {
        cachedFilteredEvents
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

    @ViewBuilder
    private var emptyStateView: some View {
        if !viewModel.searchText.isEmpty || viewModel.hasActiveFilters {
            // Search or filter resulted in no results
            TraceContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Try adjusting your search or filters"),
                actionTitle: "Clear Filters",
                action: { viewModel.clearFilters() }
            )
        } else if !vpnManager.isConnected {
            // Capture is not active — BottomActionBar is always visible, no duplicate button needed
            TraceContentUnavailableView(
                "No Requests Yet",
                systemImage: "network.slash",
                description: Text("Tap the button below to start capturing network traffic")
            )
        } else {
            // Capture is active but no requests yet
            TraceContentUnavailableView(
                "No Network Activity",
                systemImage: "network",
                description: Text("Network requests will appear here as they're captured")
            )
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
            guard !Task.isCancelled else { return }
            await rebuildEventCaches()
        }
    }

    @MainActor
    private func rebuildEventCaches() async {
        let requestFilterSnapshot = viewModel.makeRequestFilterSnapshot()
        let input = EventBuildInput(
            requestFilterSnapshot: requestFilterSnapshot,
            transportRequests: viewModel.transportRequests,
            webSockets: webSocketViewModel.connections,
            sseConnections: sseViewModel.connections,
            searchText: viewModel.searchText,
            searchScope: viewModel.searchScope,
            enabledTypes: viewModel.filterNetworkEventTypes
        )

        let filtered = await Task.detached(priority: .userInitiated) {
            Self.buildFilteredEvents(from: input)
        }.value

        cachedFilteredEvents = filtered
    }

    private struct EventBuildInput: Sendable {
        let requestFilterSnapshot: CaptureViewModel.RequestFilterSnapshot
        let transportRequests: [TransportRequest]
        let webSockets: [WebSocketConnection]
        let sseConnections: [SSEConnection]
        let searchText: String
        let searchScope: SearchScope
        let enabledTypes: Set<NetworkEventType>
    }

    private nonisolated static func buildFilteredEvents(from input: EventBuildInput) -> [NetworkEvent] {
        var eventArrays: [[NetworkEvent]] = []

        if input.enabledTypes.contains(.http) {
            let filteredRequests = CaptureViewModel.filterRequests(using: input.requestFilterSnapshot)
            eventArrays.append(filteredRequests.map { .httpRequest($0) })
        }

        if input.enabledTypes.contains(.webSocket) {
            let filteredWebSockets = input.webSockets.filter {
                matchesURLSearch($0.url, searchText: input.searchText, searchScope: input.searchScope)
            }
            if !filteredWebSockets.isEmpty {
                eventArrays.append(filteredWebSockets.map { .webSocket($0) })
            }
        }

        if input.enabledTypes.contains(.sse) {
            let filteredSSE = input.sseConnections.filter {
                matchesURLSearch($0.url, searchText: input.searchText, searchScope: input.searchScope)
            }
            if !filteredSSE.isEmpty {
                eventArrays.append(filteredSSE.map { .sse($0) })
            }
        }

        let transportEvents = filteredTransportEvents(
            input.transportRequests,
            searchText: input.searchText,
            searchScope: input.searchScope,
            enabledTypes: input.enabledTypes
        )
        if !transportEvents.isEmpty {
            eventArrays.append(transportEvents)
        }

        guard !eventArrays.isEmpty else { return [] }
        return mergeSortedByTimestampDescending(eventArrays)
    }

    private nonisolated static func matchesURLSearch(
        _ value: String,
        searchText: String,
        searchScope: SearchScope
    ) -> Bool {
        guard !searchText.isEmpty else { return true }
        guard searchScope == .all || searchScope == .url else { return false }
        return value.localizedCaseInsensitiveContains(searchText)
    }

    private nonisolated static func filteredTransportEvents(
        _ requests: [TransportRequest],
        searchText: String,
        searchScope: SearchScope,
        enabledTypes: Set<NetworkEventType>
    ) -> [NetworkEvent] {
        var events: [NetworkEvent] = []
        events.reserveCapacity(requests.count)

        for request in requests {
            let event = NetworkEvent.transportRequest(request)
            guard enabledTypes.contains(event.type) else { continue }
            guard matchesTransportSearch(request, searchText: searchText, searchScope: searchScope) else { continue }
            events.append(event)
        }
        return events
    }

    private nonisolated static func matchesTransportSearch(
        _ request: TransportRequest,
        searchText: String,
        searchScope: SearchScope
    ) -> Bool {
        guard !searchText.isEmpty else { return true }

        let basicSearch = request.endpointSummary.localizedCaseInsensitiveContains(searchText) ||
            request.applicationProtocol.displayName.localizedCaseInsensitiveContains(searchText) ||
            (request.applicationProtocolHint?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            (request.protocolBadgeText?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            (request.summary?.localizedCaseInsensitiveContains(searchText) ?? false)
        let bodySearch: Bool = if searchScope == .body || searchScope == .all {
            request.payload.getString(maxBytes: 32 * 1024)?
                .localizedCaseInsensitiveContains(searchText) ?? false
        } else {
            false
        }

        return switch searchScope {
        case .all:
            basicSearch || bodySearch
        case .url:
            basicSearch
        case .headers:
            false
        case .body:
            bodySearch
        }
    }

    private nonisolated static func mergeSortedByTimestampDescending(_ arrays: [[NetworkEvent]]) -> [NetworkEvent] {
        var indices = Array(repeating: 0, count: arrays.count)
        let totalCount = arrays.reduce(0) { $0 + $1.count }
        var merged: [NetworkEvent] = []
        merged.reserveCapacity(totalCount)

        while merged.count < totalCount {
            var selectedArrayIndex: Int?
            var selectedEvent: NetworkEvent?

            for arrayIndex in arrays.indices {
                let elementIndex = indices[arrayIndex]
                guard elementIndex < arrays[arrayIndex].count else { continue }
                let candidate = arrays[arrayIndex][elementIndex]

                if selectedEvent == nil || (selectedEvent.map { candidate.timestamp > $0.timestamp } ?? false) {
                    selectedEvent = candidate
                    selectedArrayIndex = arrayIndex
                }
            }

            guard let selectedArrayIndex, let selectedEvent else { break }
            merged.append(selectedEvent)
            indices[selectedArrayIndex] += 1
        }

        return merged
    }
}

#Preview {
    NetworkView(viewModel: CaptureViewModel())
}
