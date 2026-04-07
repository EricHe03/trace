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
    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case headers = "Headers"
        case body = "Body"
        case raw = "Raw"

        var systemImage: String {
            switch self {
            case .overview: "info.circle"
            case .headers: "list.bullet"
            case .body: "doc.text"
            case .raw: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let pausedRequest: PausedRequest
    let onAction: (BreakpointAction, PausedRequestModifications) -> Void

    @State private var url: String
    @State private var methodToken: String
    @State private var headers: [TraceHTTPHeader]
    @State private var bodyText: String
    @State private var statusCode: Int?
    @State private var statusMessage: String?
    @State private var selectedTab: Tab = .overview
    @State private var previousSelectedTab: Tab = .overview
    @State private var rawMessage: String
    @State private var showingAddHeader = false
    @State private var validationError: String?

    init(
        pausedRequest: PausedRequest,
        onAction: @escaping (BreakpointAction, PausedRequestModifications) -> Void
    ) {
        self.pausedRequest = pausedRequest
        self.onAction = onAction

        _url = State(initialValue: pausedRequest.effectiveUrl)
        _methodToken = State(initialValue: pausedRequest.effectiveMethodToken)
        _headers = State(initialValue: pausedRequest.effectiveHeaders)
        _bodyText = State(initialValue: String(decoding: pausedRequest.effectiveBody ?? Data(), as: UTF8.self))
        _statusCode = State(initialValue: pausedRequest.effectiveStatusCode)
        _statusMessage = State(initialValue: pausedRequest.effectiveStatusMessage)
        _rawMessage = State(initialValue: BreakpointRawMessage.serialize(pausedRequest))
    }

    private var originalBodyText: String {
        String(decoding: pausedRequest.body ?? Data(), as: UTF8.self)
    }

    private var normalizedMethodToken: String {
        methodToken.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var hasModifications: Bool {
        !draftModifications().isEmpty
    }

    var body: some View {
        NavigationStack {
            editorContent
        }
        .interactiveDismissDisabled()
    }

    private var editorContent: some View {
        syncedEditorContent
    }

    private var syncedEditorContent: some View {
        presentedEditorContent
            .onChange(of: selectedTab) { newValue in
                handleSelectedTabChange(oldValue: previousSelectedTab, newValue: newValue)
                previousSelectedTab = newValue
            }
            .onChange(of: url) { _ in
                syncRawMessageFromDraft()
            }
            .onChange(of: methodToken) { _ in
                syncRawMessageFromDraft()
            }
            .onChange(of: headers) { _ in
                syncRawMessageFromDraft()
            }
            .onChange(of: bodyText) { _ in
                syncRawMessageFromDraft()
            }
            .onChange(of: statusCode) { _ in
                syncRawMessageFromDraft()
            }
            .onChange(of: statusMessage) { _ in
                syncRawMessageFromDraft()
            }
    }

    private var presentedEditorContent: some View {
        navigationConfiguredEditorContent
            .sheet(isPresented: $showingAddHeader) {
                HeaderEditorView { key, value in
                    headers.append(TraceHTTPHeader(key: key, value: value))
                    syncRawMessageFromDraft()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert("Invalid Breakpoint Edit", isPresented: validationErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationError ?? "Unknown error")
            }
    }

    private var navigationConfiguredEditorContent: some View {
        editorMainContent
            .navigationTitle("Breakpoint")
            .navigationBarTitleDisplayMode(.inline)
            .dismissKeyboardOnTapAndScroll()
            .toolbar {
                dropToolbarItem
            }
    }

    private var editorMainContent: some View {
        VStack(spacing: 0) {
            warningBanner
            tabPicker

            TabView(selection: $selectedTab) {
                overviewTab.tag(Tab.overview)
                headersTab.tag(Tab.headers)
                bodyTab.tag(Tab.body)
                rawTab.tag(Tab.raw)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            actionButtons
        }
    }

    private var dropToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                performAction(.drop)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.danger)
            }
            .accessibilityLabel("Drop request")
        }
    }

    private func handleSelectedTabChange(oldValue: Tab, newValue: Tab) {
        if oldValue == .raw && newValue != .raw {
            _ = applyRawMessageToDraft()
        } else if newValue == .raw {
            syncRawMessageFromDraft()
        }
    }

    private var warningBanner: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(DesignSystem.Colors.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(breakpointTitle)
                    .font(.headline)

                Text("Traffic is paused until you decide how to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if hasModifications {
                Label("Edited", systemImage: "pencil.circle.fill")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
        }
        .padding()
        .background(DesignSystem.Colors.warning.opacity(0.1))
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
            Section("Message") {
                if pausedRequest.breakpointType == .request || pausedRequest.breakpointType == .both {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Method")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: DesignSystem.Spacing.sm) {
                            TextField("GET", text: $methodToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(DesignSystem.Typography.monospacedFont)

                            Menu("Common") {
                                ForEach(HTTPMethod.allCases, id: \.self) { method in
                                    Button(method.rawValue) {
                                        methodToken = method.rawValue
                                    }
                                }
                            }
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
                    HStack {
                        TextField("Status Code", value: $statusCode, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 96)

                        TextField("Reason Phrase", text: Binding(
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
    }

    private var headersTab: some View {
        Form {
            Section {
                if headers.isEmpty {
                    Text("No headers")
                        .foregroundStyle(.secondary)
                }

                ForEach(headers.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        TextField("Header Name", text: headerKeyBinding(for: index))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        TextField("Header Value", text: headerValueBinding(for: index))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                }
                .onDelete { indices in
                    headers.remove(atOffsets: indices)
                }

                Button {
                    showingAddHeader = true
                } label: {
                    Label("Add Header", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("Edit headers directly here or switch to Raw for full HTTP message editing.")
            }
        }
    }

    private var bodyTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Body")
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

    private var rawTab: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    Text("Raw HTTP Message")
                        .font(.headline)
                    Text(rawTabHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reload") {
                    syncRawMessageFromDraft()
                }
                .font(.caption)
            }
            .padding()
            .background(Color(.systemGroupedBackground))

            TextEditor(text: $rawMessage)
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
                    performAction(.cancel)
                } label: {
                    Label("Continue Without Edits", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button {
                    performAction(.drop)
                } label: {
                    Label("Drop", systemImage: "trash.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(DesignSystem.Colors.danger)

                Button {
                    performAction(.continueAndDisable)
                } label: {
                    Label("Continue & Disable", systemImage: "pause.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
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

    private var rawTabHint: String {
        switch pausedRequest.breakpointType {
        case .response:
            "Edit the full status line, headers, and body."
        case .request, .both:
            "Edit the full request line, headers, and body."
        case .stream:
            "Edit the stream payload directly."
        }
    }

    private var validationErrorBinding: Binding<Bool> {
        Binding(
            get: { validationError != nil },
            set: { isPresented in
                if !isPresented {
                    validationError = nil
                }
            }
        )
    }

    private func performAction(_ action: BreakpointAction) {
        if selectedTab == .raw, !applyRawMessageToDraft() {
            return
        }

        if action.appliesModifications,
           (pausedRequest.breakpointType == .request || pausedRequest.breakpointType == .both),
           normalizedMethodToken.isEmpty {
            validationError = "The edited HTTP method is empty."
            return
        }

        if action.appliesModifications,
           (pausedRequest.breakpointType == .request || pausedRequest.breakpointType == .both),
           URL(string: url) == nil {
            validationError = "The edited URL is not valid."
            return
        }

        let modifications = action.appliesModifications ? draftModifications() : .init()
        onAction(action, modifications)
        dismiss()
    }

    private func draftModifications() -> PausedRequestModifications {
        let methodTokenValue = (pausedRequest.breakpointType == .request || pausedRequest.breakpointType == .both)
            ? normalizedMethodToken
            : nil
        let methodChanged = methodTokenValue != nil && methodTokenValue != pausedRequest.methodToken

        return PausedRequestModifications(
            url: (pausedRequest.breakpointType == .request || pausedRequest.breakpointType == .both) && url != pausedRequest.url ? url : nil,
            method: methodChanged ? HTTPMethod(rawValue: methodTokenValue ?? "") : nil,
            methodToken: methodChanged ? methodTokenValue : nil,
            headers: headers != pausedRequest.headers ? headers : nil,
            body: bodyText != originalBodyText ? Data(bodyText.utf8) : nil,
            statusCode: statusCode != pausedRequest.statusCode ? statusCode : nil,
            statusMessage: statusMessage != pausedRequest.statusMessage ? statusMessage : nil
        )
    }

    private func applyRawMessageToDraft() -> Bool {
        do {
            let rawModifications = try BreakpointRawMessage.parse(rawMessage, for: pausedRequest)
            mergeParsedRawModifications(rawModifications)
            validationError = nil
            return true
        } catch {
            validationError = error.localizedDescription
            return false
        }
    }

    private func mergeParsedRawModifications(_ modifications: PausedRequestModifications) {
        if let url = modifications.url {
            self.url = url
        }
        if let methodToken = modifications.resolvedMethodToken {
            self.methodToken = methodToken
        }
        if let headers = modifications.headers {
            self.headers = headers
        }
        if let body = modifications.body {
            self.bodyText = String(decoding: body, as: UTF8.self)
        }
        if modifications.statusCode != nil {
            self.statusCode = modifications.statusCode
        }
        if modifications.statusMessage != nil {
            self.statusMessage = modifications.statusMessage
        }
    }

    private func syncRawMessageFromDraft() {
        rawMessage = BreakpointRawMessage.serialize(draftPausedRequest())
    }

    private func draftPausedRequest() -> PausedRequest {
        var draft = pausedRequest
        if pausedRequest.breakpointType == .request || pausedRequest.breakpointType == .both {
            draft.modifiedUrl = url
            draft.modifiedMethod = HTTPMethod(rawValue: normalizedMethodToken)
            draft.modifiedMethodToken = normalizedMethodToken
        }
        draft.modifiedHeaders = headers
        draft.modifiedBody = Data(bodyText.utf8)
        draft.modifiedStatusCode = statusCode
        draft.modifiedStatusMessage = statusMessage
        return draft
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func headerKeyBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { headers[index].key },
            set: { newValue in
                headers[index] = TraceHTTPHeader(
                    key: newValue,
                    value: headers[index].value,
                    indexingPolicy: headers[index].indexingPolicy
                )
            }
        )
    }

    private func headerValueBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { headers[index].value },
            set: { newValue in
                headers[index] = TraceHTTPHeader(
                    key: headers[index].key,
                    value: newValue,
                    indexingPolicy: headers[index].indexingPolicy
                )
            }
        )
    }
}

// MARK: - Breakpoint Configuration View

struct BreakpointConfigView: View {
    private let breakpointManager = BreakpointManager.shared

    @State private var config: BreakpointConfiguration = .init()
    @State private var pausedRequests: [PausedRequest] = []
    @State private var selectedRequest: PausedRequest?
    @State private var showingConditionEditor = false
    @State private var pendingSelectionID: String?
    @State private var breakpointObserverToken: AppGroupStorageObserverToken?
    @State private var shouldAutoPresentLatestPausedRequest: Bool

    init(autoPresentLatestPausedRequest: Bool = false) {
        _shouldAutoPresentLatestPausedRequest = State(initialValue: autoPresentLatestPausedRequest)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable Breakpoints", isOn: binding(\.enabled))
                } footer: {
                    Text("Pause matching requests, responses, or stream events and edit them before continuing.")
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

                        TextField(
                            "Pattern (leave empty for all traffic)",
                            text: matchPatternBinding
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }

                    Section("Execution") {
                        Picker("Mode", selection: binding(\.executionMode)) {
                            ForEach(BreakpointExecutionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        Text(config.executionMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Max Hits (optional)", text: maxHitsBinding)
                            .keyboardType(.numberPad)
                    }

                    if config.breakpointType == .request || config.breakpointType == .both {
                        Section {
                            ForEach(HTTPMethod.allCases, id: \.self) { method in
                                Toggle(method.rawValue, isOn: methodBinding(method))
                            }
                        } header: {
                            Text("HTTP Methods")
                        } footer: {
                            Text("Leave all methods off to match any request method.")
                        }
                    }

                    if config.breakpointType == .response || config.breakpointType == .both {
                        Section {
                            TextField("Example: 200, 201, 404, 500", text: statusCodesBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } header: {
                            Text("Status Codes")
                        } footer: {
                            Text("Leave empty to match any response status.")
                        }
                    }

                    Section {
                        if config.conditions.isEmpty {
                            Text("No additional conditions")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(config.conditions.indices, id: \.self) { index in
                            let condition = config.conditions[index]
                            HStack {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                                    Text(condition.type.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(condition.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button(role: .destructive) {
                                    updateConfig { $0.conditions.remove(at: index) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        Button {
                            showingConditionEditor = true
                        } label: {
                            Label("Add Condition", systemImage: "plus.circle.fill")
                        }
                    } header: {
                        Text("Conditions")
                    } footer: {
                        Text("All conditions must match before a breakpoint triggers.")
                    }

                    pausedRequestsSection
                }
            }
            .dismissKeyboardOnTapAndScroll()
            .navigationTitle("Breakpoints")
            .task {
                await loadConfig()
                await loadPausedRequests()
                startObservingBreakpointChanges()
            }
            .onReceive(NotificationCenter.default.publisher(for: .breakpointTriggered)) { notification in
                pendingSelectionID = notification.userInfo?[BreakpointNotificationKey.requestId.rawValue] as? String
                Task {
                    await loadPausedRequests()
                    if let pendingSelectionID {
                        selectedRequest = pausedRequests.first(where: { $0.id == pendingSelectionID }) ?? pausedRequests.first
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .breakpointResumed)) { _ in
                Task {
                    await loadPausedRequests()
                    if let selectedRequest,
                       !pausedRequests.contains(where: { $0.id == selectedRequest.id }) {
                        self.selectedRequest = pausedRequests.first
                    }
                }
            }
            .onDisappear {
                breakpointObserverToken?.cancel()
                breakpointObserverToken = nil
            }
            .sheet(item: $selectedRequest) { request in
                BreakpointEditorView(pausedRequest: request) { action, modifications in
                    Task {
                        await handleBreakpointAction(requestId: request.id, action: action, modifications: modifications)
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingConditionEditor) {
                BreakpointConditionEditorView { condition in
                    updateConfig { $0.conditions.append(condition) }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var pausedRequestsSection: some View {
        Section("Paused Traffic") {
            if pausedRequests.isEmpty {
                Text("No active breakpoint hits")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pausedRequests.sorted(by: { $0.pausedAt > $1.pausedAt })) { request in
                    Button {
                        selectedRequest = request
                    } label: {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                            Text(pausedTitle(for: request))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)

                            Text(request.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                Button("Resume All") {
                    resumeAllRequests()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BreakpointConfiguration, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                updateConfig { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private var maxHitsBinding: Binding<String> {
        Binding(
            get: { config.maxHits.map(String.init) ?? "" },
            set: { newValue in
                updateConfig {
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    $0.maxHits = Int(trimmed)
                }
            }
        )
    }

    private var matchPatternBinding: Binding<String> {
        Binding(
            get: { config.matchPattern ?? "" },
            set: { newValue in
                updateConfig { $0.matchPattern = newValue.isEmpty ? nil : newValue }
            }
        )
    }

    private var statusCodesBinding: Binding<String> {
        Binding(
            get: { config.statusCodes.sorted().map(String.init).joined(separator: ", ") },
            set: { newValue in
                updateConfig { configuration in
                    configuration.statusCodes = Set(
                        newValue
                            .split(separator: ",")
                            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    )
                }
            }
        )
    }

    private func methodBinding(_ method: HTTPMethod) -> Binding<Bool> {
        Binding(
            get: { config.methods.contains(method) },
            set: { isOn in
                updateConfig { configuration in
                    if isOn {
                        configuration.methods.insert(method)
                    } else {
                        configuration.methods.remove(method)
                    }
                }
            }
        )
    }

    private func updateConfig(_ mutate: (inout BreakpointConfiguration) -> Void) {
        mutate(&config)
        let updatedConfig = config
        Task {
            await breakpointManager.updateConfiguration(updatedConfig)
        }
    }

    private func loadConfig() async {
        config = await breakpointManager.getConfiguration()
    }

    private func loadPausedRequests() async {
        pausedRequests = await breakpointManager.getAllPausedRequests()

        if let pendingSelectionID {
            selectedRequest = pausedRequests.first(where: { $0.id == pendingSelectionID }) ?? pausedRequests.first
            self.pendingSelectionID = nil
            shouldAutoPresentLatestPausedRequest = false
            return
        }

        if shouldAutoPresentLatestPausedRequest {
            selectedRequest = pausedRequests.first
            shouldAutoPresentLatestPausedRequest = false
            return
        }

        if let selectedRequest,
           let refreshedRequest = pausedRequests.first(where: { $0.id == selectedRequest.id }) {
            self.selectedRequest = refreshedRequest
        }
    }

    private func resumeAllRequests() {
        Task {
            await breakpointManager.resumeAllRequests(action: .continue)
            await loadPausedRequests()
        }
    }

    private func handleBreakpointAction(
        requestId: String,
        action: BreakpointAction,
        modifications: PausedRequestModifications
    ) async {
        if action.appliesModifications, !modifications.isEmpty {
            await breakpointManager.updatePausedRequest(id: requestId, modifications: modifications)
        }

        await breakpointManager.resumeRequest(id: requestId, action: action)

        if action == .continueAndDisable {
            await breakpointManager.setEnabled(false)
            config.enabled = false
        }

        await loadPausedRequests()
    }

    private func pausedTitle(for request: PausedRequest) -> String {
        switch request.breakpointType {
        case .response:
            if let statusCode = request.statusCode {
                return "\(statusCode) Response"
            }
            return "Response"
        case .stream:
            return "Stream Event"
        case .request, .both:
            return request.methodToken
        }
    }

    private func startObservingBreakpointChanges() {
        guard breakpointObserverToken == nil else { return }
        breakpointObserverToken = AppGroupStorage.shared.observeBreakpointChanges {
            Task { @MainActor in
                await loadPausedRequests()
            }
        }
    }
}

private struct BreakpointConditionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (BreakpointCondition) -> Void

    @State private var type: ConditionType = .headerExists
    @State private var parameter = ""
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Condition Type", selection: $type) {
                    ForEach(ConditionType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                if type.requiresParameter {
                    TextField(parameterPlaceholder, text: $parameter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if type.requiresValue {
                    TextField(valuePlaceholder, text: $value, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .dismissKeyboardOnTapAndScroll()
            .navigationTitle("New Condition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(BreakpointCondition(type: type, parameter: parameter, value: value))
                        dismiss()
                    }
                    .disabled((type.requiresParameter && parameter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (type.requiresValue && value.isEmpty))
                }
            }
        }
    }

    private var parameterPlaceholder: String {
        switch type {
        case .headerExists, .headerEquals, .headerContains, .headerRegex:
            "Header name"
        case .queryParamExists, .queryParamEquals, .queryParamContains, .queryParamRegex:
            "Query parameter name"
        case .bodyContains, .bodyRegex:
            "Applies to request or response body"
        }
    }

    private var valuePlaceholder: String {
        switch type {
        case .headerEquals, .queryParamEquals:
            "Exact value"
        case .headerContains, .bodyContains, .queryParamContains:
            "Contains text"
        case .headerRegex, .bodyRegex, .queryParamRegex:
            "Regular expression"
        case .headerExists, .queryParamExists:
            ""
        }
    }
}

private extension BreakpointCondition {
    var summary: String {
        switch type {
        case .headerExists, .queryParamExists:
            parameter
        case .headerEquals, .headerContains, .headerRegex, .bodyContains, .bodyRegex, .queryParamEquals, .queryParamContains, .queryParamRegex:
            if parameter.isEmpty {
                value
            } else {
                "\(parameter) -> \(value)"
            }
        }
    }
}

private extension PausedRequestModifications {
    var isEmpty: Bool {
        url == nil &&
            method == nil &&
            methodToken == nil &&
            headers == nil &&
            body == nil &&
            statusCode == nil &&
            statusMessage == nil
    }
}

#Preview {
    let pausedRequest = PausedRequest(
        id: "123",
        url: "https://api.example.com/users?debug=1",
        method: .post,
        headers: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Authorization", value: "Bearer token123")
        ],
        body: Data("{\"test\": \"data\"}".utf8),
        breakpointType: .request
    )

    BreakpointEditorView(pausedRequest: pausedRequest) { _, _ in }
}
