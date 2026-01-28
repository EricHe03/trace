//
//  MultipartFormView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures

/// Presents a parsed multipart/form-data payload with summaries and previews.
public struct MultipartFormView: View {
    public let data: Data
    public let contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    @State private var parts: [MultipartParser.Part] = []
    @State private var expandedParts: Set<Int> = []
    @State private var selectedImagePart: MultipartParser.Part?

    public var body: some View {
        Group {
            if parts.isEmpty {
                emptyOrErrorState
            } else {
                ScrollView {
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        summarySection

                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            partCard(part: part, index: index)
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            parseParts()
        }
        .sheet(item: $selectedImagePart) { part in
            if let data = part.data as Data? {
                ImagePreviewSheet(imageData: data, filename: part.filename ?? "Image", contentType: part.contentType)
            }
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(DesignSystem.Colors.accent)
                Text("Multipart Form Data")
                    .font(.headline)
            }

            HStack(spacing: DesignSystem.Spacing.lgPlus) {
                StatItem(title: "Parts", value: "\(parts.count)")
                StatItem(title: "Files", value: "\(parts.filter(\.isFile).count)")
                StatItem(title: "Fields", value: "\(parts.count(where: { !$0.isFile }))")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    // MARK: - Part Card

    private func partCard(part: MultipartParser.Part, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Button {
                withAnimation {
                    if expandedParts.contains(index) {
                        expandedParts.remove(index)
                    } else {
                        expandedParts.insert(index)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: part.isFile ? "doc.fill" : "character.textbox")
                        .foregroundStyle(part.isFile ? DesignSystem.Colors.warning : DesignSystem.Colors.accent)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        if let name = part.name {
                            Text(name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }

                        HStack(spacing: DesignSystem.Spacing.sm) {
                            if let filename = part.filename {
                                Text(filename)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let contentType = part.contentType {
                                Text(contentType)
                                    .font(.caption2)
                                    .badgeStyle(backgroundColor: DesignSystem.Colors.surfaceSubtle, foregroundColor: .primary)
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: expandedParts.contains(index) ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            if expandedParts.contains(index) {
                Divider()

                if !part.headers.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.smPlus) {
                        Text("Headers")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        ForEach(Array(part.headers.keys.sorted()), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text("\(key):")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(part.headers[key] ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.surfaceSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                }

                contentPreview(for: part)
            }
        }
        .padding()
        .background(DesignSystem.Colors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg))
    }

    // MARK: - Content Preview

    @ViewBuilder
    private func contentPreview(for part: MultipartParser.Part) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Content")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(part.data.count) bytes")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let contentType = part.contentType {
                if contentType.starts(with: "image/") {
                    if SVGPreviewHelper.isSVG(data: part.data, contentType: part.contentType, filename: part.filename) {
                        Button {
                            selectedImagePart = part
                        } label: {
                            SVGPreviewView(svgData: part.data)
                                .frame(maxHeight: 200)
                                .background(DesignSystem.Colors.surface)
                                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                        }
                    } else if let uiImage = UIImage(data: part.data) {
                        Button {
                            selectedImagePart = part
                        } label: {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                        }
                    } else {
                        // Image content type but failed to decode - show error state
                        imageLoadFailedView(dataSize: part.data.count)
                    }
                } else if contentType.starts(with: "text/") || part.stringValue != nil {
                    if let text = part.stringValue {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .padding(DesignSystem.Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesignSystem.Colors.surfaceSubtle)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                            .textSelection(.enabled)
                    }
                } else {
                    binaryDataPreview(data: part.data)
                }
            } else if let text = part.stringValue {
                // Edge case: Treat missing content type as text when a string value exists.
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .padding(DesignSystem.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignSystem.Colors.surfaceSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                    .textSelection(.enabled)
            } else {
                binaryDataPreview(data: part.data)
            }
        }
    }

    private func binaryDataPreview(data: Data) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Binary Data")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " "))
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(3)
                .foregroundStyle(.secondary)
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surfaceSubtle)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    private func imageLoadFailedView(dataSize: Int) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Unable to decode image")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(DesignSystem.formattedBytes(dataSize))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceSubtle)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    // MARK: - Empty State

    private var emptyOrErrorState: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("Unable to Parse")
                .font(.headline)

            Text("Could not parse multipart data")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Parsing

    private func parseParts() {
        guard let boundary = MultipartParser.extractBoundary(from: contentType) else {
            CoreLog.lifecycle.warning(
                "event=multipart.parse outcome=failure reason=missing_boundary content_type=\(contentType, privacy: .private)"
            )
            return
        }

        parts = MultipartParser.parse(data: data, boundary: boundary)

        // Rationale: Auto-expand the first part so the content is immediately visible.
        if !parts.isEmpty {
            expandedParts.insert(0)
        }
    }
}

// MARK: - Supporting Views

/// Presents a full-screen preview for multipart image data.
public struct ImagePreviewSheet: View {
    public let imageData: Data
    public let filename: String
    public let contentType: String?
    @Environment(\.dismiss) private var dismiss: DismissAction

    @State private var isPreparing = true
    @State private var prepareError: String?
    @State private var tempURL: URL?

    private var isSVG: Bool {
        SVGPreviewHelper.isSVG(data: imageData, contentType: contentType, filename: filename)
    }

    public var body: some View {
        Group {
            if isSVG {
                NavigationStack {
                    SVGPreviewView(svgData: imageData, isScrollable: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DesignSystem.Colors.surface)
                        .navigationTitle(filename)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { dismiss() }
                            }
                        }
                }
            } else if let tempURL {
                QuickLookPreviewController(url: tempURL, title: filename) {
                    dismiss()
                }
            } else if let prepareError {
                TraceContentUnavailableView(
                    "Unable to Preview Image",
                    systemImage: "photo",
                    description: Text(prepareError)
                )
            } else {
                loadingView
            }
        }
        .task { await preparePreview() }
        .onDisappear { ImagePreviewTempFile.cleanup(url: tempURL) }
    }

    private var loadingView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            ProgressView()
            Text("Loading \(filename)...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(message: String) -> some View {
        TraceContentUnavailableView(
            "Unable to Load Image",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
    }

    private func preparePreview() async {
        guard isPreparing else { return }
        isPreparing = false

        guard !isSVG else { return }

        guard !imageData.isEmpty else {
            prepareError = "No image data available"
            return
        }

        let data = imageData
        let preferredFilename = filename
        let contentType = contentType

        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try ImagePreviewTempFile.write(data: data, preferredFilename: preferredFilename, contentType: contentType)
            }.value
            await MainActor.run {
                tempURL = url
            }
        } catch {
            prepareError = error.localizedDescription
        }
    }
}

// MARK: - Identifiable Wrapper

extension MultipartParser.Part: Identifiable {
    public var id: String {
        "\(name ?? "")_\(filename ?? "")_\(data.hashValue)"
    }
}

#Preview {
    MultipartFormView(
        data: Data(),
        contentType: "multipart/form-data; boundary=----WebKitFormBoundary"
    )
}
