//
//  ImagePreviewView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI

/// Presents a full-screen preview of image data with zoom and metadata.
public struct ImagePreviewView: View {
    public let imageData: Data
    @Environment(\.dismiss) private var dismiss: DismissAction

    public init(imageData: Data) {
        self.imageData = imageData
    }

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var displayMode: DisplayMode = .fit
    @State private var showInfo = false
    @State private var isLoading = true
    @State private var loadedImage: UIImage?
    @State private var loadError: ImageLoadError?

    /// Maximum recommended image data size (50 MB) before showing a warning.
    private static let largeImageThreshold = 50 * 1024 * 1024

    enum ImageLoadError: LocalizedError {
        case emptyData
        case corruptedData
        case unsupportedFormat
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .emptyData:
                "No image data provided"
            case .corruptedData:
                "The image data appears to be corrupted"
            case .unsupportedFormat:
                "This image format is not supported"
            case let .tooLarge(size):
                "Image too large (\(DesignSystem.formattedBytes(size)))"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .emptyData, .corruptedData:
                "Try downloading the image again"
            case .unsupportedFormat:
                "Try converting to a supported format like PNG or JPEG"
            case .tooLarge:
                "Try using a smaller image"
            }
        }
    }

    enum DisplayMode: String, CaseIterable {
        case fit = "Fit"
        case fill = "Fill"
        case actual = "Actual Size"

        var icon: String {
            switch self {
            case .fit:
                "arrow.up.left.and.arrow.down.right"
            case .fill:
                "arrow.down.left.and.arrow.up.right"
            case .actual:
                "1.magnifyingglass"
            }
        }
    }

    private var isSVG: Bool {
        SVGPreviewHelper.isSVG(data: imageData)
    }

    private var imageInfo: ImageInfo? {
        guard let image = loadedImage else { return nil }
        return ImageInfo(
            width: Int(image.size.width),
            height: Int(image.size.height),
            size: imageData.count,
            format: detectFormat()
        )
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isSVG {
                svgView()
            } else if isLoading {
                loadingView
            } else if let error = loadError {
                errorView(error: error)
            } else if let image = loadedImage {
                imageView(image: image)
            } else {
                TraceContentUnavailableView(
                    "Unable to Load Image",
                    systemImage: "photo",
                    description: Text("The image data could not be loaded")
                )
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Spacer()

                    Button {
                        showInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    if let image = loadedImage {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Image")) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.white)
                                .padding()
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    } else if isSVG {
                        // SVG share - export as PNG
                        Button {
                            // SVG sharing could be implemented here
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.white.opacity(0.5))
                                .padding()
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .disabled(true)
                    }
                }
                .padding()

                Spacer()

                HStack(spacing: DesignSystem.Spacing.lgPlus) {
                    Menu {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Button {
                                withAnimation {
                                    setDisplayMode(mode)
                                }
                            } label: {
                                Label(mode.rawValue, systemImage: mode.icon)
                            }
                        }
                    } label: {
                        Image(systemName: displayMode.icon)
                            .foregroundStyle(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Button {
                        withAnimation {
                            scale = max(0.5, scale - 0.5)
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Button {
                        withAnimation {
                            resetView()
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Button {
                        withAnimation {
                            scale = min(5.0, scale + 0.5)
                        }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .foregroundStyle(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding()
            }

            if showInfo, let info = imageInfo {
                VStack {
                    Spacer()
                    imageInfoCard(info: info)
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .statusBar(hidden: true)
        .task {
            await loadImage()
        }
    }

    // MARK: - Loading

    private func loadImage() async {
        // Skip loading for SVG (handled separately)
        guard !isSVG else {
            isLoading = false
            return
        }

        // Validate data is not empty
        guard !imageData.isEmpty else {
            loadError = .emptyData
            isLoading = false
            return
        }

        // Warn about very large images but still attempt to load
        if imageData.count > Self.largeImageThreshold {
            // Large image - load on background thread to prevent UI blocking
        }

        // Decode on background thread for large images
        if imageData.count > 1024 * 1024 { // > 1 MB
            let data = imageData
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value

            await MainActor.run {
                if let image {
                    loadedImage = image
                } else {
                    loadError = .corruptedData
                }
                isLoading = false
            }
        } else {
            // Small image - decode synchronously
            if let image = UIImage(data: imageData) {
                loadedImage = image
            } else {
                loadError = .corruptedData
            }
            isLoading = false
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

            Text("Loading image...")
                .foregroundStyle(.white.opacity(0.7))
                .font(.subheadline)

            if imageData.count > Self.largeImageThreshold {
                Text("Large image (\(DesignSystem.formattedBytes(imageData.count)))")
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.caption)
            }
        }
    }

    // MARK: - Error View

    private func errorView(error: ImageLoadError) -> some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.yellow)

            Text(error.localizedDescription)
                .font(.headline)
                .foregroundStyle(.white)

            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Button {
                Task {
                    isLoading = true
                    loadError = nil
                    await loadImage()
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.vertical, DesignSystem.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Image View

    @ViewBuilder
    private func imageView(image: UIImage) -> some View {
        zoomableView {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: aspectMode)
        }
    }

    @ViewBuilder
    private func svgView() -> some View {
        zoomableView {
            SVGPreviewView(svgData: imageData)
                .background(Color.clear)
        }
    }

    @ViewBuilder
    private func zoomableView(@ViewBuilder content: () -> some View) -> some View {
        let builtContent = content()
        GeometryReader { geometry in
            builtContent
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            scale *= delta
                            scale = min(max(scale, 0.5), 5.0)
                        }
                        .onEnded { _ in
                            lastScale = 1.0
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var aspectMode: ContentMode {
        switch displayMode {
        case .fit:
            .fit
        case .fill:
            .fill
        case .actual:
            .fit
        }
    }

    // MARK: - Image Info Card

    private func imageInfoCard(info: ImageInfo) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.accent)
                Text("Image Information")
                    .font(.headline)
            }

            Divider()

            VStack(spacing: DesignSystem.Spacing.sm) {
                InfoRow(label: "Dimensions", value: "\(info.width) × \(info.height) px")
                InfoRow(label: "Size", value: DesignSystem.formattedBytes(info.size))
                InfoRow(label: "Format", value: info.format)
                if info.height > 0 {
                    InfoRow(label: "Aspect Ratio", value: String(format: "%.2f", Double(info.width) / Double(info.height)))
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.xl))
    }

    // MARK: - Display Mode

    private func setDisplayMode(_ mode: DisplayMode) {
        displayMode = mode

        switch mode {
        case .fit:
            scale = 1.0
            offset = .zero
            lastOffset = .zero
        case .fill:
            scale = 1.5
            offset = .zero
            lastOffset = .zero
        case .actual:
            if loadedImage != nil {
                // Rationale: Use screen scale so 1 image point maps to 1 screen point.
                let screenScale = UIScreen.main.scale
                scale = screenScale
                offset = .zero
                lastOffset = .zero
            }
        }
    }

    private func resetView() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
        displayMode = .fit
    }

    // MARK: - Helpers

    private func detectFormat() -> String {
        // Rationale: Detect format from magic numbers to avoid a full decode pass.
        guard imageData.count >= 4 else { return "Unknown" }

        let bytes = [UInt8](imageData.prefix(16))

        // PNG: 89 50 4E 47
        if bytes.count >= 4 &&
            bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "PNG"
        }

        // JPEG: FF D8 FF
        if bytes.count >= 3 &&
            bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "JPEG"
        }

        // GIF: 47 49 46
        if bytes.count >= 3 &&
            bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            return "GIF"
        }

        // BMP: 42 4D
        if bytes.count >= 2 &&
            bytes[0] == 0x42 && bytes[1] == 0x4D {
            return "BMP"
        }

        // TIFF (little-endian): 49 49 2A 00 or (big-endian): 4D 4D 00 2A
        if bytes.count >= 4 &&
            ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00) ||
                (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)) {
            return "TIFF"
        }

        // ICO: 00 00 01 00
        if bytes.count >= 4 &&
            bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x01 && bytes[3] == 0x00 {
            return "ICO"
        }

        // WebP: RIFF....WEBP (need at least 12 bytes)
        if bytes.count >= 12 &&
            bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
            bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return "WebP"
        }

        // HEIC/HEIF/AVIF: ftyp box at byte 4-7, brand at byte 8-11 (need at least 12 bytes)
        if bytes.count >= 12 &&
            bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let brandBytes = Array(bytes[8 ..< 12])
            let brand = String(bytes: brandBytes, encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) {
                return "HEIC/HEIF"
            }
            if ["avif", "avis"].contains(brand) {
                return "AVIF"
            }
        }

        return "Unknown"
    }
}

// MARK: - Supporting Types

/// Describes basic image metadata derived from binary data.
public struct ImageInfo {
    public let width: Int
    public let height: Int
    public let size: Int
    public let format: String
}

#Preview {
    if let imageData = UIImage(systemName: "photo")?.pngData() {
        ImagePreviewView(imageData: imageData)
    }
}
