//
//  DetailView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import os
import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

struct DetailView: View {
    let request: NetworkRequest
    @State private var selectedTab: DetailTab = .overview
    @State private var showingShareSheet = false
    @State private var showingRequestBuilder = false
    @State private var showingReplayResponse = false
    @StateObject private var executor = RequestExecutor()
    @State private var copiedText: String?
    @State private var toastMessage: String?
    @ObservedObject private var favoritesManager = FavoritesManager.shared
    @State private var requestBodyText: String?
    @State private var responseBodyText: String?
    @State private var requestBodyRawData: Data?
    @State private var responseBodyRawData: Data?
    @State private var isRequestBodyPreview = false
    @State private var isResponseBodyPreview = false
    @State private var isLoadingRequestBody = false
    @State private var isLoadingResponseBody = false
    @State private var showingShareResponseBody = false
    @State private var showingShareRequestBody = false

    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case requestHeaders = "Request"
        case responseHeaders = "Response"
        case body = "Body"
        case sse = "SSE Events"
    }

    var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = [.overview, .requestHeaders, .responseHeaders, .body]

        // Add SSE tab if applicable
        if request.isSSE {
            tabs.append(.sse)
        }

        return tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            // Quick Actions Bar
            QuickActionsBar(
                onReplay: { replayRequest() },
                onCopyURL: { copyToClipboard(request.url) },
                onCopyCURL: { copyRequestAsCurl() },
                onShare: { showingShareSheet = true },
                isLoading: executor.isLoading
            )
            .padding(.horizontal)
            .padding(.top, DesignSystem.Spacing.sm)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick actions")

            Picker("Detail Tab", selection: $selectedTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityLabel("Request detail tabs")

            ScrollView {
                switch selectedTab {
                case .overview:
                    OverviewSection(request: request)
                case .requestHeaders:
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        HeadersSection(headers: request.requestHeaders)
                        requestBodyView
                    }
                case .responseHeaders:
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        HeadersSection(headers: request.responseHeaders)
                        responseBodyView
                        compressionInfoView
                    }
                case .body:
                    bodiesView
                case .sse:
                    SSEEventsSection(request: request)
                }
            }
        }
        .navigationTitle("Request Details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: request.id) {
            await loadRequestBody(full: false)
            await loadResponseBody(full: false)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    favoritesManager.toggleFavorite(requestId: request.id)
                } label: {
                    Image(systemName: favoritesManager.isFavorited(requestId: request.id) ? "star.fill" : "star")
                        .foregroundStyle(favoritesManager.isFavorited(requestId: request.id) ? DesignSystem.Colors.favorite : .primary)
                }
                .accessibilityLabel(favoritesManager.isFavorited(requestId: request.id) ? "Remove from favorites" : "Add to favorites")
                .accessibilityHint("Double tap to \(favoritesManager.isFavorited(requestId: request.id) ? "remove from" : "add to") favorites")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        replayRequest()
                    } label: {
                        Label("Replay Request", systemImage: "arrow.clockwise")
                    }
                    .disabled(executor.isLoading)

                    Button {
                        showingRequestBuilder = true
                    } label: {
                        Label("Edit & Send", systemImage: "pencil")
                    }

                    Divider()

                    Button {
                        copyToClipboard(request.url)
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }

                    Button {
                        copyRequestAsCurl()
                    } label: {
                        Label("Copy as cURL", systemImage: "terminal")
                    }

                    Divider()

                    Button {
                        showingShareSheet = true
                    } label: {
                        Label("Share Full Request", systemImage: "square.and.arrow.up")
                    }

                    if !request.responseBody.isEmpty {
                        Button {
                            showingShareResponseBody = true
                        } label: {
                            Label("Share Response Body", systemImage: "arrow.down.doc")
                        }
                    }

                    if !request.requestBody.isEmpty {
                        Button {
                            showingShareRequestBody = true
                        } label: {
                            Label("Share Request Body", systemImage: "arrow.up.doc")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheetContainer(
                items: [
                    formatRequestForSharing(),
                    CurlCommandGenerator.generate(from: request)
                ],
                applicationActivities: ActivityHelper.customActivitiesForRequest()
            )
        }
        .sheet(isPresented: $showingRequestBuilder) {
            RequestBuilderView(existingRequest: request)
        }
        .sheet(isPresented: $showingReplayResponse) {
            if let response = executor.lastResponse {
                NavigationStack {
                    DetailView(request: response)
                        .navigationTitle("Replay Response")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showingReplayResponse = false
                                }
                            }
                        }
                }
            }
        }
        .toast(message: $toastMessage)
        .sheet(isPresented: $showingShareResponseBody) {
            ShareSheetContainer(
                items: ShareHelper.shareItemsForResponseBody(from: request)
            )
        }
        .sheet(isPresented: $showingShareRequestBody) {
            ShareSheetContainer(
                items: ShareHelper.shareItemsForRequestBody(from: request)
            )
        }
    }

    private func copyToClipboard(_ text: String) {
        DesignSystem.Haptics.light()
        UIPasteboard.general.string = text
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = "Copied to clipboard"
        }
    }

    @MainActor
    private func loadRequestBody(full: Bool) async {
        guard !request.requestBody.isEmpty else { return }
        isLoadingRequestBody = true
        let limit = full ? nil : BodyStorage.previewSize

        let contentType = request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value.lowercased()
        let requestBodyIsBinary = Self.isBinaryContentType(contentType)

        if requestBodyIsBinary {
            requestBodyRawData = await Task.detached(priority: .userInitiated) {
                if let limit {
                    return request.requestBody.getPreview(maxBytes: limit)
                }
                return request.requestBody.getData()
            }.value

            let kind = Self.detectBinaryKind(
                data: requestBodyRawData,
                contentType: contentType,
                fileName: nil
            )
            requestBodyText = Self.binarySummaryText(
                kind: kind,
                fileName: nil,
                totalSize: request.requestBody.totalSize,
                previewSize: requestBodyRawData?.count,
                isPreview: !full && request.requestBody.totalSize > BodyStorage.previewSize
            )
        } else {
            // Load raw data for images to support preview rendering.
            if contentType?.hasPrefix("image/") == true {
                requestBodyRawData = await Task.detached(priority: .userInitiated) {
                    if let limit {
                        return request.requestBody.getPreview(maxBytes: limit)
                    }
                    return request.requestBody.getData()
                }.value
            } else {
                requestBodyRawData = nil
            }

            requestBodyText = await Task.detached(priority: .userInitiated) {
                if let limit {
                    return request.requestBody.getString(maxBytes: limit)
                }
                return request.requestBody.getString()
            }.value
        }
        isRequestBodyPreview = !full && request.requestBody.totalSize > BodyStorage.previewSize
        isLoadingRequestBody = false
    }

    @MainActor
    private func loadResponseBody(full: Bool) async {
        guard !request.responseBody.isEmpty else { return }
        isLoadingResponseBody = true
        let limit = full ? nil : BodyStorage.previewSize

        let contentType = request.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value.lowercased()
        let contentDisposition = request.responseHeaders.first { $0.key.lowercased() == "content-disposition" }?.value
        let fileName = Self.attachmentFileName(from: contentDisposition)
        let isAttachment = contentDisposition?.lowercased().contains("attachment") == true
        let responseBodyIsBinary = request.isBinary || Self.isBinaryContentType(contentType) || isAttachment

        if responseBodyIsBinary {
            responseBodyRawData = await Task.detached(priority: .userInitiated) {
                if let limit {
                    return request.responseBody.getPreview(maxBytes: limit)
                }
                return request.responseBody.getData()
            }.value

            let kind = Self.detectBinaryKind(
                data: responseBodyRawData,
                contentType: contentType,
                fileName: fileName
            )
            responseBodyText = Self.binarySummaryText(
                kind: kind,
                fileName: fileName,
                totalSize: request.responseBody.totalSize,
                previewSize: responseBodyRawData?.count,
                isPreview: !full && request.responseBody.totalSize > BodyStorage.previewSize
            )
        } else {
            // Load raw data for images to support preview rendering.
            if contentType?.hasPrefix("image/") == true {
                responseBodyRawData = await Task.detached(priority: .userInitiated) {
                    if let limit {
                        return request.responseBody.getPreview(maxBytes: limit)
                    }
                    return request.responseBody.getData()
                }.value
            } else {
                responseBodyRawData = nil
            }

            responseBodyText = await Task.detached(priority: .userInitiated) {
                if let limit {
                    return request.responseBody.getString(maxBytes: limit)
                }
                return request.responseBody.getString()
            }.value
        }
        isResponseBodyPreview = !full && request.responseBody.totalSize > BodyStorage.previewSize
        isLoadingResponseBody = false
    }

    private func copyRequestAsCurl() {
        DesignSystem.Haptics.light()
        let curl = CurlCommandGenerator.generate(from: request)
        UIPasteboard.general.string = curl
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = "cURL copied to clipboard"
        }
    }

    private func replayRequest() {
        DesignSystem.Haptics.medium()
        Task {
            do {
                let response = try await executor.replay(request)
                // Save the replayed request response to storage
                try AppGroupStorage.shared.saveRequest(response)
                await MainActor.run {
                    DesignSystem.Haptics.success()
                    showingReplayResponse = true
                }
            } catch {
                await MainActor.run {
                    DesignSystem.Haptics.error()
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func formatRequestForSharing() -> String {
        var text = "Network Request\n\n"
        text += "URL: \(request.url)\n"
        text += "Method: \(request.method.rawValue)\n"
        text += "Status: \(request.statusCodeText)\n"
        text += "Time: \(request.timestamp.formatted(date: .abbreviated, time: .standard))\n"
        text += "\nRequest Headers:\n"
        let requestBodyIsEmpty = request.requestBody.isEmpty
        for header in request.requestHeaders {
            if header.key.lowercased() == "content-length",
               requestBodyIsEmpty,
               header.value.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                continue
            }
            text += "  \(header.key): \(header.value)\n"
        }

        if !request.requestBody.isEmpty {
            let contentType = request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value
            let requestBodyIsBinary = Self.isBinaryContentType(contentType)
            if requestBodyIsBinary {
                let size = request.requestBody.totalSize
                text += "\nRequest Body:\n<binary body omitted> (size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))\n"
            } else if let requestBodyText, !requestBodyText.isEmpty {
                text += "\nRequest Body:\n\(requestBodyText)\n"
                if isRequestBodyPreview {
                    text += "\n(Request body truncated to preview)\n"
                }
            } else {
                text += "\nRequest Body:\n<not loaded>\n"
            }
        }
        text += "\nResponse Headers:\n"
        for header in request.responseHeaders {
            if header.key.lowercased() == "content-type" {
                let lowerValue = header.value.lowercased()
                if lowerValue.contains("octet-stream"),
                   let inferred = Self.inferredContentType(from: request.url),
                   inferred.lowercased() != lowerValue {
                    text += "  \(header.key): \(header.value) (inferred: \(inferred))\n"
                    continue
                }
            }
            text += "  \(header.key): \(header.value)\n"
        }

        if !request.responseBody.isEmpty {
            let contentType = request.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value
            let contentDisposition = request.responseHeaders.first { $0.key.lowercased() == "content-disposition" }?.value
            let isAttachment = contentDisposition?.lowercased().contains("attachment") == true
            let responseBodyIsBinary = request.isBinary || Self.isBinaryContentType(contentType) || isAttachment
            if responseBodyIsBinary {
                let size = request.responseBody.totalSize
                let fileName = Self.attachmentFileName(from: contentDisposition)
                text += "\nResponse Body:\n<binary body omitted> (size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))\n"
                if let fileName, !fileName.isEmpty {
                    text += "Filename: \(fileName)\n"
                }
            } else if let responseBodyText, !responseBodyText.isEmpty {
                text += "\nResponse Body:\n\(responseBodyText)\n"
                if isResponseBodyPreview {
                    text += "\n(Response body truncated to preview)\n"
                }
            } else {
                text += "\nResponse Body:\n<not loaded>\n"
            }
        }

        text += "\ncURL Command:\n"
        text += CurlCommandGenerator.generate(from: request)

        return text
    }

    // MARK: - Binary body helpers

    private enum BinaryKind: String {
        case zip = "ZIP"
        case pdf = "PDF"
        case binary = "Binary"
    }

    private static func isBinaryContentType(_ contentType: String?) -> Bool {
        guard let ct = contentType?.lowercased(), !ct.isEmpty else { return false }

        // SVG is XML text, not binary - exclude it
        if ct.contains("image/svg") {
            return false
        }

        // Note: Keep this list aligned with `NetworkRequest.isBinary` (response-side), but usable
        // for request bodies too.
        let binaryIndicators = [
            "image/",
            "video/",
            "audio/",
            "octet-stream",
            "application/pdf",
            "application/zip",
            "application/x-zip-compressed",
            "application/x-gzip",
            "application/gzip",
            "font/"
        ]
        return binaryIndicators.contains { ct.contains($0) }
    }

    private static func inferredContentType(from url: String) -> String? {
        guard let pathExtension = URL(string: url)?.pathExtension.lowercased(),
              !pathExtension.isEmpty else { return nil }

        switch pathExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "svg":
            return "image/svg+xml"
        case "pdf":
            return "application/pdf"
        case "zip":
            return "application/zip"
        case "gz":
            return "application/gzip"
        case "json":
            return "application/json"
        case "html", "htm":
            return "text/html"
        case "css":
            return "text/css"
        case "js":
            return "application/javascript"
        case "txt":
            return "text/plain"
        default:
            return nil
        }
    }

    private static func attachmentFileName(from contentDisposition: String?) -> String? {
        guard let contentDisposition, !contentDisposition.isEmpty else { return nil }

        let parts = contentDisposition
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // RFC 5987: filename*=UTF-8''<percent-encoded>
        if let filenameStar = parts.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
            var value = String(filenameStar.dropFirst("filename*=".count))
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            if let marker = value.range(of: "''") {
                let encoded = String(value[marker.upperBound...])
                return encoded.removingPercentEncoding ?? encoded
            }
            return value.removingPercentEncoding ?? value
        }

        if let filename = parts.first(where: { $0.lowercased().hasPrefix("filename=") }) {
            var value = String(filename.dropFirst("filename=".count))
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value
        }

        return nil
    }

    private static func detectBinaryKind(data: Data?, contentType: String?, fileName: String?) -> BinaryKind {
        if let fileName = fileName?.lowercased() {
            if fileName.hasSuffix(".zip") { return .zip }
            if fileName.hasSuffix(".pdf") { return .pdf }
        }

        if let ct = contentType?.lowercased() {
            if ct.contains("application/zip") { return .zip }
            if ct.contains("application/pdf") { return .pdf }
        }

        if let data, data.count >= 4 {
            // ZIP: PK\x03\x04, PK\x05\x06 (empty archive), PK\x07\x08 (spanned)
            if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||
                data.starts(with: [0x50, 0x4B, 0x05, 0x06]) ||
                data.starts(with: [0x50, 0x4B, 0x07, 0x08]) {
                return .zip
            }

            // PDF: %PDF
            if data.starts(with: [0x25, 0x50, 0x44, 0x46]) {
                return .pdf
            }
        }

        return .binary
    }

    private static func binarySummaryText(
        kind: BinaryKind,
        fileName: String?,
        totalSize: Int,
        previewSize: Int?,
        isPreview: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("\(kind.rawValue) body (\(DesignSystem.formattedBytes(totalSize)))")
        if let fileName, !fileName.isEmpty {
            lines.append("Filename: \(fileName)")
        }
        if let previewSize, previewSize > 0, isPreview {
            lines.append("Showing preview: \(DesignSystem.formattedBytes(previewSize))")
            lines.append("Use Hex view to inspect bytes.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Body View Helpers

    @ViewBuilder
    private var requestBodyView: some View {
        if !request.requestBody.isEmpty {
            if isLoadingRequestBody {
                ProgressView("Loading request body...")
            } else {
                let contentType: String? = request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value
                let copyAction = requestBodyText.map { text in { copyToClipboard(text) } }
                let shareAction = { showingShareRequestBody = true }
                BodySection(
                    title: "Request Body",
                    content: requestBodyText ?? "",
                    contentType: contentType,
                    rawData: requestBodyRawData,
                    fileName: nil,
                    totalSize: request.requestBody.totalSize,
                    onCopy: copyAction,
                    onShare: shareAction
                )
            }

            if isRequestBodyPreview {
                Button("Load Full Request Body") {
                    Task {
                        await loadRequestBody(full: true)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var responseBodyView: some View {
        if !request.responseBody.isEmpty {
            if isLoadingResponseBody {
                ProgressView("Loading response body...")
            } else {
                let contentType: String? = request.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value
                let contentDisposition: String? = request.responseHeaders.first { $0.key.lowercased() == "content-disposition" }?.value
                let fileName = Self.attachmentFileName(from: contentDisposition)
                let copyAction = responseBodyText.map { text in { copyToClipboard(text) } }
                let shareAction = { showingShareResponseBody = true }
                BodySection(
                    title: "Response Body",
                    content: responseBodyText ?? "",
                    contentType: contentType,
                    rawData: responseBodyRawData,
                    fileName: fileName,
                    totalSize: request.responseBody.totalSize,
                    onCopy: copyAction,
                    onShare: shareAction
                )
            }

            if isResponseBodyPreview {
                Button("Load Full Response Body") {
                    Task {
                        await loadResponseBody(full: true)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var compressionInfoView: some View {
        if let compressionInfo = request.responseBody.getCompressionInfo() {
            CompressionInfoView(compressionInfo: compressionInfo)
                .padding(.horizontal)
        }
    }

    private var bodiesView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            requestBodyView
            responseBodyView
            compressionInfoView
            emptyBodyMessage
        }
    }

    @ViewBuilder
    private var emptyBodyMessage: some View {
        let isEmpty: Bool = request.requestBody.isEmpty && request.responseBody.isEmpty
        if isEmpty {
            TraceContentUnavailableView(
                "No Body Content",
                systemImage: "doc.text",
                description: Text("This request has no body data")
            )
            .padding()
        }
    }
}

struct BodySection: View {
    let title: String
    let content: String
    var contentType: String?
    var rawData: Data?
    var fileName: String?
    var totalSize: Int?
    var onCopy: (() -> Void)?
    var onShare: (() -> Void)?

    @State private var viewMode: ViewMode = .auto
    @State private var showingImagePreview = false
    @State private var previewImageData: Data?
    @State private var showFullViewer = false

    enum ViewMode: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case text = "Text"
        case hex = "Hex"

        var id: String { rawValue }
    }

    private var showsFullScreenOption: Bool {
        guard let type = detectedContentType else { return false }
        switch type {
        case .plainText, .binary:
            return false
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            InfoCard(title: title) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    // Row 1: Content type badge + size + actions menu
                    HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                        // Content type badge
                        if let detectedType = detectedContentType {
                            Label(detectedType.displayName, systemImage: detectedType.icon)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, DesignSystem.Spacing.sm)
                                .padding(.vertical, DesignSystem.Spacing.xs)
                                .background(DesignSystem.Colors.accent.opacity(0.1))
                                .foregroundStyle(DesignSystem.Colors.accent)
                                .clipShape(Capsule())
                        }

                        // Size info
                        if let totalSize, totalSize > 0 {
                            Text(DesignSystem.formattedBytes(totalSize))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // Actions menu - consolidates Copy, Share, Full Screen
                        if onCopy != nil || onShare != nil || showsFullScreenOption {
                            Menu {
                                if let onCopy {
                                    Button(action: onCopy) {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }

                                if let onShare {
                                    Button(action: onShare) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                }

                                if showsFullScreenOption {
                                    Divider()
                                    Button {
                                        showFullViewer = true
                                    } label: {
                                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                            }
                            .accessibilityLabel("Body actions")
                            .accessibilityHint("Copy, share, or view full screen")
                        }
                    }

                    // Row 2: View mode picker - full width for better touch targets
                    Picker("View Mode", selection: $viewMode) {
                        ForEach(ViewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Body view mode")

                    // Row 3: File info for binary/attachments
                    if detectedContentType == .binary, let fileName, !fileName.isEmpty {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(fileName)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))
                    }

                    // Content area
                    ScrollView {
                        contentView
                    }
                    .frame(maxHeight: 400)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showingImagePreview) {
            if let previewImageData {
                ImagePreviewView(imageData: previewImageData)
            }
        }
        .sheet(isPresented: $showFullViewer) {
            fullViewerSheet
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .auto:
            autoContentView
        case .text:
            textView
        case .hex:
            hexView
        }
    }

    @ViewBuilder
    private var autoContentView: some View {
        switch detectedContentType {
        case .json:
            JSONViewerView(jsonString: content)
                .frame(minHeight: 200, alignment: .topLeading)

        case .html:
            HTMLViewerView(htmlString: content)
                .frame(minHeight: 200)

        case .xml:
            XMLViewerView(xmlString: content)
                .frame(minHeight: 200)

        case .javascript:
            JavaScriptViewerView(code: content)
                .frame(minHeight: 200)

        case .css:
            CSSViewerView(code: content)
                .frame(minHeight: 200)

        case .image:
            imageView

        case .multipart:
            if let contentType, let data = content.data(using: .utf8) {
                MultipartFormView(data: data, contentType: contentType)
            } else {
                Text("Unable to parse multipart data")
                    .foregroundStyle(.secondary)
            }

        case .plainText, .none:
            textView

        case .binary:
            // Important: Default to the (small) summary text for binary bodies.
            // Rendering a full hex dump can be very expensive and may hang the UI for large files.
            textView
        }
    }

    @ViewBuilder
    private var imageView: some View {
        if let svgData {
            SVGPreviewView(svgData: svgData)
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
        } else if let imageData = imageDataFromContent,
                  let uiImage = UIImage(data: imageData) {
            Button {
                previewImageData = imageData
                showingImagePreview = true
            } label: {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        } else if let image = imageFromContent {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
        } else {
            imageLoadErrorView
        }
    }

    private var imageLoadErrorView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Unable to load image")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let data = rawData ?? content.data(using: .utf8) {
                Text("\(DesignSystem.formattedBytes(data.count)) of data")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
        .background(DesignSystem.Colors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    private var textView: some View {
        Text(content)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var hexView: some View {
        Text(hexRepresentation)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - Full Viewer Sheet

    @ViewBuilder
    private var fullViewerSheet: some View {
        NavigationStack {
            Group {
                switch detectedContentType {
                case .json:
                    JSONViewerView(jsonString: content)
                case .html:
                    HTMLViewerView(htmlString: content)
                case .xml:
                    XMLViewerView(xmlString: content)
                case .javascript:
                    JavaScriptViewerView(code: content)
                case .css:
                    CSSViewerView(code: content)
                case .image:
                    if let svgData {
                        SVGPreviewView(svgData: svgData)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(DesignSystem.Colors.surface)
                    } else if let data = imageDataFromContent {
                        ImagePreviewView(imageData: data)
                    } else if let image = imageFromContent {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Unable to load image")
                            .foregroundStyle(.secondary)
                    }
                default:
                    ScrollView {
                        textView.padding()
                    }
                }
            }
            .navigationTitle(detectedContentType?.displayName ?? "Body")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showFullViewer = false
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let onShare {
                        Button {
                            onShare()
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if let onCopy {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onCopy()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Content Type Detection

    enum DetectedContentType {
        case json
        case html
        case xml
        case javascript
        case css
        case image
        case multipart
        case plainText
        case binary

        var displayName: String {
            switch self {
            case .json: "JSON"
            case .html: "HTML"
            case .xml: "XML"
            case .javascript: "JavaScript"
            case .css: "CSS"
            case .image: "Image"
            case .multipart: "Multipart"
            case .plainText: "Plain Text"
            case .binary: "Binary"
            }
        }

        var icon: String {
            switch self {
            case .json: "curlybraces"
            case .html: "doc.text"
            case .xml: "chevron.left.forwardslash.chevron.right"
            case .javascript: "scroll"
            case .css: "paintbrush"
            case .image: "photo"
            case .multipart: "doc.on.doc"
            case .plainText: "text.alignleft"
            case .binary: "doc.zipper"
            }
        }
    }

    private var detectedContentType: DetectedContentType? {
        // Prefer filename hints for attachments when available.
        if let fileName = fileName?.lowercased(),
           fileName.hasSuffix(".zip") || fileName.hasSuffix(".pdf") {
            return .binary
        }

        guard let ct = contentType?.lowercased() else {
            // Try to detect from content
            return detectFromContent()
        }

        if ct.contains("json") {
            return .json
        }
        if ct.contains("html") {
            return .html
        }
        // SVG should be treated as image, not generic XML
        if ct.contains("image/svg") {
            return .image
        }
        if ct.contains("xml") {
            return .xml
        }
        if ct.contains("javascript") {
            return .javascript
        }
        if ct.contains("css") {
            return .css
        }
        if ct.hasPrefix("image/") {
            return .image
        }
        if ct.contains("multipart") {
            return .multipart
        }
        if ct.contains("text/plain") {
            return .plainText
        }
        if ct.contains("octet-stream") ||
            ct.contains("application/zip") ||
            ct.contains("application/x-zip-compressed") ||
            ct.contains("application/pdf") ||
            ct.contains("application/x-gzip") ||
            ct.contains("application/gzip") ||
            ct.contains("font/") ||
            ct.hasPrefix("video/") ||
            ct.hasPrefix("audio/") {
            return .binary
        }

        return detectFromContent()
    }

    private func detectFromContent() -> DetectedContentType? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // JSON detection
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if let data = content.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return .json
            }
        }

        // HTML detection
        if trimmed.lowercased().contains("<!doctype html") ||
            trimmed.lowercased().contains("<html") {
            return .html
        }

        // XML detection
        if trimmed.hasPrefix("<?xml") || (trimmed.hasPrefix("<") && trimmed.contains("</")) {
            return .xml
        }

        // SVG detection
        if svgData != nil {
            return .image
        }

        return nil
    }

    // MARK: - Computed Properties

    private var hexRepresentation: String {
        let data: Data? = rawData ?? content.data(using: .utf8)
        guard let data else { return "" }

        // Rule: Keep hex rendering bounded to avoid UI stalls on large binary bodies.
        let maxHexBytes = 64 * 1024
        let displayData = data.prefix(maxHexBytes)
        let wasTruncated = data.count > maxHexBytes

        var hex = ""
        for (index, byte) in displayData.enumerated() {
            if index > 0 && index % 16 == 0 {
                hex += "\n"
            } else if index > 0 && index % 8 == 0 {
                hex += "  "
            } else if index > 0 {
                hex += " "
            }

            hex += String(format: "%02X", byte)
        }

        if wasTruncated {
            hex += "\n\n… (truncated, showing first \(DesignSystem.formattedBytes(maxHexBytes)))"
        }

        return hex
    }

    private var imageFromContent: UIImage? {
        // Use raw binary data if available (essential for binary formats like HEIF, WebP, etc.)
        if let rawData {
            return UIImage(data: rawData)
        }

        // Try base64 decoding first
        if let data = Data(base64Encoded: content) {
            return UIImage(data: data)
        }

        // Try direct data conversion (only works for text-based formats)
        if let data = content.data(using: .utf8) {
            return UIImage(data: data)
        }

        return nil
    }

    private var imageDataFromContent: Data? {
        // Use raw binary data if available (essential for binary formats like HEIF, WebP, etc.)
        if let rawData {
            return rawData
        }

        // Try base64 decoding first
        if let data = Data(base64Encoded: content) {
            return data
        }

        // Try direct data conversion (only works for text-based formats)
        return content.data(using: .utf8)
    }

    private var svgData: Data? {
        SVGPreviewHelper.svgData(from: content, contentType: contentType)
    }
}

struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: DesignSystem.Spacing.sm) {
                content
            }
            .padding()
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
            .shadow(
                color: DesignSystem.Shadow.sm.color,
                radius: DesignSystem.Shadow.sm.radius,
                x: DesignSystem.Shadow.sm.x,
                y: DesignSystem.Shadow.sm.y
            )
        }
    }
}

#Preview {
    // Sample request for preview
    let sampleRequest = NetworkRequest(
        url: "https://api.example.com/users/123",
        method: .get,
        statusCode: 200,
        timestamp: Date(),
        duration: 0.234,
        requestHeaders: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Authorization", value: "Bearer token...")
        ],
        responseHeaders: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ],
        requestBody: .empty,
        responseBody: BodyStorage.from(string: """
        {
          "id": 123,
          "name": "John Doe",
          "email": "john@example.com"
        }
        """)
    )

    NavigationStack {
        DetailView(request: sampleRequest)
    }
}
