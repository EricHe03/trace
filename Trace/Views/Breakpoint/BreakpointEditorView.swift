//
//  BreakpointEditorView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

struct BreakpointEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let pausedRequest: PausedRequest
    let onAction: (BreakpointAction, PausedRequestModifications) -> Void

    @State private var url: String
    @State private var method: HTTPMethod
    @State private var headers: [TraceHTTPHeader]
    @State private var bodyText: String
    @State private var statusCode: Int?
    @State private var statusMessage: String?
    @State private var selectedTab: Tab = .overview
    @State private var showingAddHeader = false

    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case headers = "Headers"
        case body = "Body"

        var systemImage: String {
            switch self {
            case .overview: "info.circle"
            case .headers: "list.bullet"
            case .body: "doc.text"
            }
        }
    }

    init(pausedRequest: PausedRequest, onAction: @escaping (BreakpointAction, PausedRequestModifications) -> Void) {
        self.pausedRequest = pausedRequest
        self.onAction = onAction

        _url = State(initialValue: pausedRequest.url)
        _method = State(initialValue: pausedRequest.method)
        _headers = State(initialValue: pausedRequest.headers)

        let bodyString = pausedRequest.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        _bodyText = State(initialValue: bodyString)

        _statusCode = State(initialValue: pausedRequest.statusCode)
        _statusMessage = State(initialValue: pausedRequest.statusMessage)
    }

    var hasModifications: Bool {
        url != pausedRequest.url ||
            method != pausedRequest.method ||
            headers != pausedRequest.headers ||
            bodyText != (pausedRequest.body.flatMap { String(data: $0, encoding: .utf8) } ?? "") ||
            statusCode != pausedRequest.statusCode ||
            statusMessage != pausedRequest.statusMessage
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Warning banner
                warningBanner

                // Tab selection
                tabPicker

                // Content
                TabView(selection: $selectedTab) {
                    overviewTab
                        .tag(Tab.overview)

                    headersTab
                        .tag(Tab.headers)

                    bodyTab
                        .tag(Tab.body)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Action buttons
                actionButtons
            }
            .navigationTitle("Breakpoint")
            .navigationBarTitleDisplayMode(.inline)
            .dismissKeyboardOnTapAndScroll()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        performAction(.drop)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DesignSystem.Colors.danger)
                    }
                }
            }
            .sheet(isPresented: $showingAddHeader) {
                HeaderEditorView { key, value in
                    headers.append(TraceHTTPHeader(key: key, value: value))
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var warningBanner: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(breakpointTitle)
                    .font(.headline)

                Text("Waiting for your action")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if hasModifications {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding()
        .background(DesignSystem.Colors.warning.opacity(0.1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(breakpointTitle)".lowercased())
        .accessibilityValue(hasModifications ? "Edits made" : "No edits")
        .accessibilityHint("Review details and choose an action at the bottom")
    }

    private var tabPicker: some View {
        Picker("Tab", selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding()
    }

    private var overviewTab: some View {
        Form {
            Section("Request Info") {
                Picker("Method", selection: $method) {
                    ForEach(HTTPMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("URL", text: $url, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }

            if pausedRequest.breakpointType == .response {
                Section("Response Info") {
                    HStack {
                        TextField("Status Code", value: $statusCode, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 80)

                        TextField("Status Message", text: Binding(
                            get: { statusMessage ?? "" },
                            set: { statusMessage = $0 }
                        ))
                    }
                }
            }

            Section("Statistics") {
                HStack {
                    Text("Headers")
                    Spacer()
                    Text("\(headers.count)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Body Size")
                    Spacer()
                    Text(formatBytes(bodyText.utf8.count))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Paused At")
                    Spacer()
                    Text(pausedRequest.pausedAt, style: .time)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .dismissKeyboardOnTapAndScroll()
    }

    private var headersTab: some View {
        VStack {
            List {
                ForEach(headers) { header in
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text(header.key)
                            .font(.headline)

                        Text(header.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { indices in
                    headers.remove(atOffsets: indices)
                }
            }

            Button {
                showingAddHeader = true
            } label: {
                Label("Add Header", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private var bodyTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Body Content")
                    .font(.headline)

                Spacer()

                Text(formatBytes(bodyText.utf8.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.systemGroupedBackground))

            TextEditor(text: $bodyText)
                .font(DesignSystem.Typography.monospacedFont)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .formTextEditorStyle()
        }
    }

    private var actionButtons: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.md) {
                Button {
                    performAction(.continue)
                } label: {
                    Label("Continue", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    performAction(.drop)
                } label: {
                    Label("Drop", systemImage: "trash.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(DesignSystem.Colors.danger)
            }

            Button {
                performAction(.continueAndDisable)
            } label: {
                Text("Continue & Disable Breakpoints")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }

    private func performAction(_ action: BreakpointAction) {
        let modifications = PausedRequestModifications(
            url: url != pausedRequest.url ? url : nil,
            method: method != pausedRequest.method ? method : nil,
            headers: headers != pausedRequest.headers ? headers : nil,
            body: bodyText != (pausedRequest.body.flatMap { String(data: $0, encoding: .utf8) } ?? "") ? bodyText.data(using: .utf8) : nil,
            statusCode: statusCode != pausedRequest.statusCode ? statusCode : nil,
            statusMessage: statusMessage != pausedRequest.statusMessage ? statusMessage : nil
        )

        onAction(action, modifications)
        dismiss()
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var breakpointTitle: String {
        switch pausedRequest.breakpointType {
        case .request:
            "Request Paused"
        case .response:
            "Response Paused"
        case .stream:
            "Stream Event Paused"
        case .both:
            "Breakpoint Paused"
        }
    }
}

// MARK: - Breakpoint Configuration View

struct BreakpointConfigView: View {
    @State private var breakpointManager = BreakpointManager.shared
    @State private var config: BreakpointConfiguration = .init()
    @State private var pausedRequests: [PausedRequest] = []
    @State private var selectedRequest: PausedRequest?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable Breakpoints", isOn: binding(\.enabled))
                } footer: {
                    Text("Pause requests/responses for manual editing")
                }

                if config.enabled {
                    Section("Breakpoint Type") {
                        Picker("When to Break", selection: binding(\.breakpointType)) {
                            ForEach(BreakpointType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section("Match Criteria") {
                        Picker("Match Type", selection: binding(\.matchType)) {
                            ForEach(MatchType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }

                        TextField("Pattern (leave empty for all)", text: Binding(
                            get: { config.matchPattern ?? "" },
                            set: { config.matchPattern = $0.isEmpty ? nil : $0 }
                        ))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    }

                    if !pausedRequests.isEmpty {
                        Section {
                            Text("\(pausedRequests.count) request\(pausedRequests.count == 1 ? "" : "s") paused")
                                .foregroundStyle(DesignSystem.Colors.warning)

                            Button("Resume All") {
                                resumeAllRequests()
                            }
                            .buttonStyle(.borderedProminent)
                        } header: {
                            Text("Paused Requests")
                        }
                    }
                }
            }
            .dismissKeyboardOnTapAndScroll()
            .navigationTitle("Breakpoints")
            .task {
                await loadConfig()
                await loadPausedRequests()
            }
            .onReceive(NotificationCenter.default.publisher(for: .breakpointTriggered)) { _ in
                Task {
                    await loadPausedRequests()
                }
            }
            .sheet(item: $selectedRequest) { request in
                BreakpointEditorView(pausedRequest: request) { action, modifications in
                    Task {
                        await handleBreakpointAction(requestId: request.id, action: action, modifications: modifications)
                    }
                }
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BreakpointConfiguration, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                config[keyPath: keyPath] = newValue
                Task {
                    await breakpointManager.updateConfiguration(config)
                }
            }
        )
    }

    private func loadConfig() async {
        config = await breakpointManager.getConfiguration()
    }

    private func loadPausedRequests() async {
        pausedRequests = await breakpointManager.getAllPausedRequests()
    }

    private func resumeAllRequests() {
        Task {
            await breakpointManager.resumeAllRequests(action: .continue)
            await loadPausedRequests()
        }
    }

    private func handleBreakpointAction(requestId: String, action: BreakpointAction, modifications: PausedRequestModifications) async {
        // Apply modifications if any
        if modifications.url != nil || modifications.method != nil || modifications.headers != nil || modifications.body != nil {
            await breakpointManager.updatePausedRequest(id: requestId, modifications: modifications)
        }

        // Resume the request
        await breakpointManager.resumeRequest(id: requestId, action: action)

        // If continueAndDisable, disable breakpoints
        if action == .continueAndDisable {
            await breakpointManager.setEnabled(false)
            config.enabled = false
        }

        // Reload paused requests
        await loadPausedRequests()
    }
}

#Preview {
    let pausedRequest = PausedRequest(
        id: "123",
        url: "https://api.example.com/users",
        method: .get,
        headers: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Authorization", value: "Bearer token123")
        ],
        body: Data("{\"test\": \"data\"}".utf8),
        breakpointType: .request
    )

    BreakpointEditorView(pausedRequest: pausedRequest) { _, _ in }
}
