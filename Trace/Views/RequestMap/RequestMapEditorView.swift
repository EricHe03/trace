//
//  RequestMapEditorView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI
import UIKit
import UniformTypeIdentifiers

struct RequestMapEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let map: RequestMap?
    let onSave: (RequestMap) -> Void

    @State private var name: String
    @State private var enabled: Bool
    @State private var matchType: MatchType
    @State private var matchPattern: String
    @State private var statusCode: Int
    @State private var statusMessage: String
    @State private var headers: [TraceHTTPHeader]
    @State private var bodySource: BodySource
    @State private var bodyContent: String
    @State private var bodyFilePath: String
    @State private var scriptContent: String
    @State private var delay: Int
    @State private var showingAddHeader = false
    @State private var showingFilePicker = false
    @State private var scriptValidationError: String?
    @State private var toastMessage: String?
    @ScaledMetric(relativeTo: .body) private var textEditorHeight: CGFloat = 200

    init(map: RequestMap?, onSave: @escaping (RequestMap) -> Void) {
        self.map = map
        self.onSave = onSave

        _name = State(initialValue: map?.name ?? "")
        _enabled = State(initialValue: map?.enabled ?? true)
        _matchType = State(initialValue: map?.matchType ?? .wildcard)
        _matchPattern = State(initialValue: map?.matchPattern ?? "")
        _statusCode = State(initialValue: map?.mockResponse.statusCode ?? 200)
        _statusMessage = State(initialValue: map?.mockResponse.statusMessage ?? "OK")
        _headers = State(initialValue: map?.mockResponse.headers ?? [])
        _bodySource = State(initialValue: map?.mockResponse.bodySource ?? .inline)

        let bodyText = map?.mockResponse.bodyContent.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        _bodyContent = State(initialValue: bodyText)
        _bodyFilePath = State(initialValue: map?.mockResponse.bodyFilePath ?? "")
        _scriptContent = State(initialValue: map?.mockResponse.scriptContent ?? Self.defaultScript)
        _delay = State(initialValue: map?.mockResponse.delay ?? 0)
    }

    private static let defaultScript = """
    // Generate response body dynamically
    // Available variables: requestUrl, requestMethod, timestamp
    // Use setBody(string) or return a string

    return stringifyJSON({
        "message": "Mock response",
        "url": requestUrl,
        "method": requestMethod,
        "timestamp": new Date(timestamp * 1000).toISOString()
    }, 2);
    """

    var isValid: Bool {
        !name.isEmpty && !matchPattern.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Information") {
                    TextField("Map Name", text: $name)

                    Toggle("Enabled", isOn: $enabled)
                }

                Section("Match Criteria") {
                    Picker("Match Type", selection: $matchType) {
                        ForEach(MatchType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        TextField("Match Pattern", text: $matchPattern)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        Text(matchTypeHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Mock Response") {
                    HStack {
                        TextField("Status Code", value: $statusCode, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 80)

                        TextField("Status Message", text: $statusMessage)
                    }

                    HStack {
                        Text("Delay")
                        Spacer()
                        TextField("ms", value: $delay, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Text("ms")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Response Headers") {
                    ForEach(headers) { header in
                        HStack {
                            Text(header.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)

                            Text(header.value)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                    .onDelete { indices in
                        headers.remove(atOffsets: indices)
                    }

                    Button {
                        showingAddHeader = true
                    } label: {
                        Label("Add Header", systemImage: "plus.circle")
                    }
                }

                Section {
                    Picker("Body Source", selection: $bodySource) {
                        ForEach(BodySource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }

                    if bodySource == .inline {
                        inlineBodyEditor
                    } else if bodySource == .file {
                        fileBodyEditor
                    } else {
                        scriptBodyEditor
                    }
                } header: {
                    Text("Response Body")
                }

                Section {
                    HStack {
                        Text("Preview")
                            .font(.headline)

                        Spacer()

                        Text("\(statusCode) \(statusMessage)")
                            .font(.caption)
                            .foregroundStyle(statusColor(statusCode))
                    }

                    if !headers.isEmpty {
                        Text("\(headers.count) header\(headers.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !bodyContent.isEmpty {
                        Text("Body: \(formatBytes(bodyContent.utf8.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if delay > 0 {
                        Text("Delay: \(delay)ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .dismissKeyboardOnTapAndScroll()
            .navigationTitle(map == nil ? "New Map" : "Edit Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveMap()
                    }
                    .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showingAddHeader) {
                HeaderEditorView { key, value in
                    headers.append(TraceHTTPHeader(key: key, value: value))
                }
            }
        }
        .toast(message: $toastMessage)
    }

    private var matchTypeHint: String {
        switch matchType {
        case .wildcard:
            "Example: *.example.com or */api/*"
        case .regex:
            "Example: ^https://.*\\.example\\.com/.*$"
        case .exact:
            "Example: https://api.example.com/users"
        case .contains:
            "Example: /api/users"
        }
    }

    // MARK: - Body Source Editors

    @ViewBuilder
    private var inlineBodyEditor: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Response Body")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $bodyContent)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: textEditorHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .stroke(DesignSystem.Colors.muted.opacity(0.2), lineWidth: 1)
                )
                .formTextEditorStyle()
        }

        HStack {
            Text("Size")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(formatBytes(bodyContent.utf8.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileBodyEditor: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("File Path")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Path or filename", text: $bodyFilePath)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .font(.system(.body, design: .monospaced))

                Button {
                    showingFilePicker = true
                } label: {
                    Image(systemName: "folder")
                }
            }

            Text("Enter an absolute path or a filename in the MockFiles folder. Files are stored in the app's shared container.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !bodyFilePath.isEmpty {
                HStack {
                    Image(systemName: fileExistsIndicator.0)
                        .foregroundStyle(fileExistsIndicator.1)
                    Text(fileExistsIndicator.2)
                        .font(.caption)
                        .foregroundStyle(fileExistsIndicator.1)
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.json, .xml, .html, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                // Copy file to MockFiles directory
                copyFileToMockFiles(url)
            }
        }
    }

    private var fileExistsIndicator: (String, Color, String) {
        // Check if file exists
        if bodyFilePath.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: bodyFilePath) {
                ("checkmark.circle.fill", DesignSystem.Colors.success, "File found")
            } else {
                ("xmark.circle.fill", DesignSystem.Colors.danger, "File not found")
            }
        } else {
            // Relative path - will be resolved at runtime
            ("info.circle", DesignSystem.Colors.info, "Will be resolved from MockFiles folder")
        }
    }

    private func copyFileToMockFiles(_ sourceURL: URL) {
        guard sourceURL.startAccessingSecurityScopedResource() else { return }
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfiguration.appGroupIdentifier) else {
            return
        }

        let mockFilesDir = containerURL.appendingPathComponent("MockFiles", isDirectory: true)

        // Create MockFiles directory if needed
        try? FileManager.default.createDirectory(at: mockFilesDir, withIntermediateDirectories: true)

        let destURL = mockFilesDir.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            bodyFilePath = sourceURL.lastPathComponent
        } catch {
            bodyFilePath = sourceURL.path
            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                toastMessage = "Failed to copy file: \(error.localizedDescription)"
            }
        }
    }

    private var scriptBodyEditor: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("JavaScript")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reset") {
                    scriptContent = Self.defaultScript
                }
                .font(.caption)
            }

            TextEditor(text: $scriptContent)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: textEditorHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .stroke(DesignSystem.Colors.muted.opacity(0.2), lineWidth: 1)
                )
                .formTextEditorStyle()
                .onChangeCompat(of: scriptContent) {
                    validateScript()
                }

            if let error = scriptValidationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Available: requestUrl, requestMethod, timestamp, parseJSON(), stringifyJSON(), setBody()")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func validateScript() {
        // Basic syntax validation - just check if it parses
        // Full validation happens at execution time
        scriptValidationError = nil

        guard !scriptContent.isEmpty else { return }

        // Simple check for common syntax errors
        let bracketCount = scriptContent.count(where: { $0 == "{" }) - scriptContent.count(where: { $0 == "}" })
        let parenCount = scriptContent.count(where: { $0 == "(" }) - scriptContent.count(where: { $0 == ")" })

        if bracketCount != 0 {
            scriptValidationError = "Unbalanced braces"
        } else if parenCount != 0 {
            scriptValidationError = "Unbalanced parentheses"
        }

        if let scriptValidationError {
            UIAccessibility.post(notification: .announcement, argument: scriptValidationError)
        }
    }

    private func statusColor(_ code: Int) -> Color {
        DesignSystem.Colors.statusColor(for: code)
    }

    private func formatBytes(_ bytes: Int) -> String {
        DesignSystem.formattedBytes(bytes)
    }

    private func saveMap() {
        let mockResponse = MockResponse(
            statusCode: statusCode,
            statusMessage: statusMessage,
            headers: headers,
            bodySource: bodySource,
            bodyContent: bodySource == .inline ? bodyContent.data(using: .utf8) : nil,
            bodyFilePath: bodySource == .file ? bodyFilePath : nil,
            scriptContent: bodySource == .script ? scriptContent : nil,
            delay: delay
        )

        let newMap = RequestMap(
            id: map?.id ?? UUID(),
            name: name,
            enabled: enabled,
            matchType: matchType,
            matchPattern: matchPattern,
            mockResponse: mockResponse,
            createdAt: map?.createdAt ?? Date(),
            modifiedAt: Date(),
            hitCount: map?.hitCount ?? 0
        )

        onSave(newMap)
        dismiss()
    }
}

struct HeaderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String) -> Void

    @State private var key = ""
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Header Name", text: $key)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                TextField("Header Value", text: $value)
                    .autocorrectionDisabled()
            }
            .dismissKeyboardOnTapAndScroll()
            .navigationTitle("Add Header")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(key, value)
                        dismiss()
                    }
                    .disabled(key.isEmpty)
                }
            }
        }
    }
}

#Preview {
    RequestMapEditorView(map: nil) { _ in }
}
