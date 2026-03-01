//
//  ImagePreviewView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import UIKit

/// Presents a full-screen image preview using standard iOS preview UI (Quick Look) when possible.
public struct ImagePreviewView: View {
    public let imageData: Data
    public let preferredFilename: String?
    public let contentType: String?
    public let title: String
    @Environment(\.dismiss) private var dismiss: DismissAction

    public init(
        imageData: Data,
        preferredFilename: String? = nil,
        contentType: String? = nil,
        title: String = "Image"
    ) {
        self.imageData = imageData
        self.preferredFilename = preferredFilename
        self.contentType = contentType
        self.title = title
    }

    private var isSVG: Bool {
        SVGPreviewHelper.isSVG(data: imageData)
    }

    @State private var isPreparing = true
    @State private var prepareError: String?
    @State private var tempURL: URL?

    public var body: some View {
        Group {
            if isSVG {
                SVGPreviewView(svgData: imageData, isScrollable: true)
                    .background(Color.black)
            } else if let tempURL {
                QuickLookPreviewController(url: tempURL, title: title) {
                    dismiss()
                }
            } else if let prepareError {
                TraceContentUnavailableView(
                    "Unable to Preview Image",
                    systemImage: "photo",
                    description: Text(prepareError)
                )
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .task {
            await preparePreview()
        }
        .onDisappear {
            ImagePreviewTempFile.cleanup(url: tempURL)
        }
    }

    private func preparePreview() async {
        guard isPreparing else { return }
        isPreparing = false

        guard !isSVG else { return }

        guard !imageData.isEmpty else {
            prepareError = "No image data provided"
            return
        }

        let data = imageData
        let preferredFilename = preferredFilename
        let contentType = contentType
        let defaultBasename = title
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try ImagePreviewTempFile.write(
                    data: data,
                    preferredFilename: preferredFilename,
                    contentType: contentType,
                    defaultBasename: defaultBasename
                )
            }.value
            await MainActor.run {
                tempURL = url
            }
        } catch {
            prepareError = error.localizedDescription
        }
    }
}

#Preview {
    if let imageData = UIImage(systemName: "photo")?.pngData() {
        ImagePreviewView(imageData: imageData)
    }
}
