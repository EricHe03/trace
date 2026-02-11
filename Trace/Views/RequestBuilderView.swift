//
//  RequestBuilderView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

struct RequestBuilderView: View {
    private enum Field: Hashable {
        case url
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var executor = RequestExecutor()
    @FocusState private var focusedField: Field?
    @State private var url = ""
    @State private var method: HTTPMethod = .get
    @State private var headers: [HeaderPair] = [
        HeaderPair(key: "Content-Type", value: "application/json")
    ]
    @State private var requestBody = ""
    @State private var followRedirects = true

    @State private var showResponse = false
    @State private var shouldDismissBuilderAfterResponse = false
    @State private var toastMessage: String?
    @State private var didLoadExistingBody = false

    /// For editing existing request
    var existingRequest: NetworkRequest?

    init(existingRequest: NetworkRequest? = nil) {
        self.existingRequest = existingRequest

        if let request = existingRequest {
            _url = State(initialValue: request.url)
            _method = State(initialValue: request.method)
            _headers = State(initialValue: request.requestHeaders.map { HeaderPair(key: $0.key, value: $0.value) })
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // URL Section
                Section("Request") {
                    // Method picker
                    Picker("Method", selection: $method) {
                        ForEach([HTTPMethod.get, .post, .put, .delete, .patch, .head, .options], id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .accessibilityLabel("HTTP Method")

                    // URL field
                    TextField("URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .focused($focusedField, equals: .url)
                        .onSubmit {
                            if focusedField == .url {
                                focusedField = nil
                            }
                        }
                        .accessibilityLabel("Request URL")
                        .accessibilityHint("Enter the URL for the request")

                    Toggle("Follow Redirects", isOn: $followRedirects)
                        .accessibilityLabel("Follow redirects")
                }

                // Headers Section
                Section {
                    ForEach(headers.indices, id: \.self) { index in
                        HStack {
                            TextField("Header Name", text: $headers[index].key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .frame(maxWidth: .infinity)

                            TextField("Value", text: $headers[index].value)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .frame(maxWidth: .infinity)

                            Button(action: {
                                headers.remove(at: index)
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(DesignSystem.Colors.danger)
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Remove header")
                        }
                    }

                    Button(action: {
                        headers.append(HeaderPair(key: "", value: ""))
                    }) {
                        Label("Add Header", systemImage: "plus.circle.fill")
                    }
                    .accessibilityHint("Double tap to add a new header field")
                } header: {
                    Text("Headers (\(headers.count))")
                }

                // Body Section
                if method != .get && method != .head {
                    Section("Request Body") {
                        TextEditor(text: $requestBody)
                            .frame(minHeight: DesignSystem.Form.textEditorMinHeightLarge)
                            .font(DesignSystem.Typography.monospacedFont)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .formTextEditorStyle()
                            .accessibilityLabel("Request body")
                            .accessibilityHint("Enter the request body content")

                        HStack {
                            Button("Clear") {
                                requestBody = ""
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clear request body")

                            Spacer()

                            Menu {
                                Button("Format as JSON") {
                                    formatJSON()
                                }
                            } label: {
                                Label("Body Tools", systemImage: "ellipsis.circle")
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Request body tools")
                            .accessibilityHint("Contains optional formatting actions for the request body")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                }

                // Actions Section
                Section {
                    Button(action: sendRequest) {
                        HStack {
                            if executor.isLoading {
                                ProgressView()
                                    .accessibilityLabel("Sending request")
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text(executor.isLoading ? "Sending..." : "Send Request")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(url.isEmpty || executor.isLoading)
                    .accessibilityLabel(executor.isLoading ? "Sending request" : "Send Request")
                    .accessibilityHint("Double tap to send the HTTP request")

                    Button("Copy as cURL") {
                        copyAsCURL()
                    }
                    .accessibilityLabel("Copy as cURL")
                    .accessibilityHint("Double tap to copy the request as a cURL command")
                }
            }
            .navigationTitle(existingRequest != nil ? "Edit Request" : "Request Builder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showResponse, onDismiss: handleResponseDismissed) {
                if let response = executor.lastResponse {
                    NavigationStack {
                        DetailView(request: response)
                            .navigationTitle("Response")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") {
                                        showResponse = false
                                    }
                                }
                            }
                    }
                }
            }
            .toast(message: $toastMessage)
            .dismissKeyboardOnTapAndScroll()
            .task(id: existingRequest?.id) {
                await loadExistingRequestBodyIfNeeded()
            }
        }
    }

    // MARK: - Actions

    private func sendRequest() {
        Task {
            let builder = resolvedBuilder()

            do {
                let response = try await executor.execute(builder)
                // Save the manual request response to storage
                try AppGroupStorage.shared.saveRequest(response)
                await MainActor.run {
                    shouldDismissBuilderAfterResponse = true
                    showResponse = true
                }
            } catch {
                await MainActor.run {
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func handleResponseDismissed() {
        guard shouldDismissBuilderAfterResponse else { return }
        shouldDismissBuilderAfterResponse = false

        NotificationCenter.default.post(
            name: .openTab,
            object: nil,
            userInfo: ["tab": "network"]
        )
        dismiss()
    }

    private func copyAsCURL() {
        let builder = resolvedBuilder()

        UIPasteboard.general.string = builder.toCURL()

        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = "Copied cURL to clipboard"
        }
    }

    private func formatJSON() {
        guard let data = requestBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let formattedString = String(data: formatted, encoding: .utf8) else {
            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                toastMessage = "Invalid JSON"
            }
            return
        }

        requestBody = formattedString
    }

    private func resolvedBuilder() -> RequestBuilder {
        let baseHeaders = headers
            .filter { !$0.key.isEmpty }
            .map { TraceHTTPHeader(key: $0.key, value: $0.value) }
        let headerDictionary = Dictionary(uniqueKeysWithValues: baseHeaders.map { ($0.key, $0.value) })

        return RequestBuilder(
            url: url,
            method: method,
            headers: headerDictionary,
            body: requestBody.isEmpty ? nil : requestBody,
            followRedirects: followRedirects
        )
    }

    @MainActor
    private func loadExistingRequestBodyIfNeeded() async {
        guard let request = existingRequest else { return }
        guard !didLoadExistingBody else { return }
        didLoadExistingBody = true

        let bodyText = await Task.detached(priority: .userInitiated) {
            request.requestBody.getString() ?? ""
        }.value
        if requestBody.isEmpty {
            requestBody = bodyText
        }
    }
}

// MARK: - Helper Models

struct HeaderPair: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

// MARK: - Preview

#Preview {
    RequestBuilderView()
}

#Preview("With Existing Request") {
    let request = NetworkRequest(
        url: "https://example.com/api/endpoint",
        method: .post,
        statusCode: 200,
        timestamp: Date(),
        duration: 0.5,
        requestHeaders: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Authorization", value: "Bearer <token>")
        ],
        responseHeaders: [],
        requestBody: BodyStorage.from(string: "{\"key\": \"value\"}"),
        responseBody: .empty
    )

    RequestBuilderView(existingRequest: request)
}
