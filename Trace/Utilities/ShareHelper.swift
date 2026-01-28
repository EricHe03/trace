//
//  ShareHelper.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//
//  ## iOS Share Sheet Implementation Guide
//
//  This file implements the standard iOS Share Sheet (`UIActivityViewController`)
//  following Apple's best practices and patterns.
//
//  ### Why this implementation?
//  Common issues with Share Sheet implementations:
//  1. **Blank white screen** - Usually caused by:
//     - Empty `activityItems` array
//     - Missing iPad popover anchor configuration
//     - Presenting from wrong view controller
//     - Presenting `UIActivityViewController` from inside a SwiftUI `.sheet`,
//       which leaves the host sheet's background visible behind the share panel
//  2. **"View not in window hierarchy" errors** - Caused by:
//     - Presenting before view is added to window
//     - Presenting from dismissed view controller
//  3. **iPad crashes or failures** - Caused by:
//     - Missing `popoverPresentationController` configuration
//
//  ### Implementation Approaches in this file:
//
//  #### 1. SwiftUI Approach (Recommended): `ShareSheet`
//  - Uses `UIViewControllerRepresentable` wrapper
//  - Presented via SwiftUI `.sheet` modifier
//  - Automatically handles iPad popover configuration
//  - Clears the host view background to avoid a white "canvas" above the share panel
//  - Thread-safe (all operations on main thread)
//  - Example:
//    ```swift
//    @State private var showShare = false
//    Button("Share") { showShare = true }
//        .sheet(isPresented: $showShare) {
//            ShareSheet(items: ["Hello", URL(string: "https://example.com")!])
//        }
//    ```
//
//  #### 2. UIKit Approach: Manual Presentation (NetworkViewActions)
//  - Direct `UIActivityViewController` presentation
//  - Used for non-View contexts
//  - Finds topmost view controller
//  - Manually configures iPad popover
//  - Still thread-safe (Task @MainActor + DispatchQueue.main)
//
//  ### Key Implementation Details:
//  - All presentations on main thread
//  - Empty items array replaced with fallback message
//  - iPad popover always configured (centered, no arrow)
//  - Proper view hierarchy checks before presentation
//  - Completion handlers dismiss sheets properly
//

import Foundation
import os
import TraceCore
import TraceFeatures
import LinkPresentation
import UIKit

enum ShareHelper {
    static let fallbackShareMessage = "Nothing to share"

    // MARK: - Share Items Creation

    /// Creates share items for a network request.
    /// - Parameters:
    ///   - request: The request to share.
    ///   - includeFullDetails: Whether to include formatted request details.
    /// - Returns: Activity items ready for a share sheet.
    static func shareItems(for request: NetworkRequest, includeFullDetails: Bool = false) -> [Any] {
        var items: [Any] = []

        if includeFullDetails {
            let detailedText = formatRequestForSharing(request)
            items.append(detailedText)
        }

        let curl = generateCurlCommand(request)
        items.append(curl)

        return items
    }

    /// Creates a temporary file with the content and returns its URL.
    /// - Parameters:
    ///   - content: The file contents.
    ///   - fileName: The file name to write.
    /// - Returns: The file URL when the write succeeds.
    static func createTemporaryFile(content: String, fileName: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            CoreLog.lifecycle.error(
                "event=app.temp_file_create outcome=failure file_name=\(fileName, privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Creates share items for CSV content.
    /// - Parameters:
    ///   - content: The CSV payload.
    ///   - fileName: The file name to use, or `nil` for a timestamped name.
    /// - Returns: Activity items ready for a share sheet.
    static func shareItemsForCSV(content: String, fileName: String? = nil) -> [Any] {
        let finalFileName = sanitizedFileName(
            fileName ?? "export_\(Date().ISO8601Format()).csv",
            defaultExtension: "csv"
        )
        if let fileURL = createTemporaryFile(content: content, fileName: finalFileName) {
            return [fileURL]
        }
        return [content.isEmpty ? fallbackShareMessage : content]
    }

    /// Creates share items for JSON content.
    /// - Parameters:
    ///   - content: The JSON payload.
    ///   - fileName: The file name to use, or `nil` for a timestamped name.
    /// - Returns: Activity items ready for a share sheet.
    static func shareItemsForJSON(content: String, fileName: String? = nil) -> [Any] {
        let finalFileName = sanitizedFileName(
            fileName ?? "export_\(Date().ISO8601Format()).json",
            defaultExtension: "json"
        )
        if let fileURL = createTemporaryFile(content: content, fileName: finalFileName) {
            return [fileURL]
        }
        return [content.isEmpty ? fallbackShareMessage : content]
    }

    /// Creates share items for text content with a custom file name.
    /// - Parameters:
    ///   - content: The text payload.
    ///   - fileName: The file name to use, or `nil` to share raw text.
    /// - Returns: Activity items ready for a share sheet.
    static func shareItemsForText(content: String, fileName: String? = nil) -> [Any] {
        if let fileName {
            let finalFileName = sanitizedFileName(fileName, defaultExtension: "txt")
            if let fileURL = createTemporaryFile(content: content, fileName: finalFileName) {
                return [fileURL]
            }
        }
        return [content.isEmpty ? fallbackShareMessage : content]
    }

    /// Creates share items for binary data with a custom file name.
    /// - Parameters:
    ///   - data: The binary data payload.
    ///   - fileName: The file name to use.
    /// - Returns: Activity items ready for a share sheet.
    static func shareItemsForBinary(data: Data, fileName: String) -> [Any] {
        let finalFileName = sanitizedFileName(fileName, defaultExtension: "bin")
        if let fileURL = createTemporaryFile(data: data, fileName: finalFileName) {
            return [fileURL]
        }
        return data.isEmpty ? [fallbackShareMessage] : [data]
    }

    /// Ensures a safe file name for temporary file creation.
    private static func sanitizedFileName(_ fileName: String, defaultExtension: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let sanitized = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "._ "))
        let base = sanitized.isEmpty ? "export_\(Date().ISO8601Format())" : sanitized
        if base.contains(".") {
            return base
        }
        return "\(base).\(defaultExtension)"
    }

    /// Creates a temporary file with binary data and returns its URL.
    /// - Parameters:
    ///   - data: The binary data to write.
    ///   - fileName: The file name to write.
    /// - Returns: The file URL when the write succeeds.
    static func createTemporaryFile(data: Data, fileName: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            CoreLog.lifecycle.error(
                "event=app.temp_file_create outcome=failure file_name=\(fileName, privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Creates a temporary file by copying an existing file URL.
    /// This avoids loading large files into memory just to share them.
    static func createTemporaryFileCopy(from sourceURL: URL, fileName: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent(sanitizedFileName(fileName, defaultExtension: "bin"))

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return destURL
        } catch {
            CoreLog.lifecycle.error(
                "event=app.temp_file_copy outcome=failure file_name=\(fileName, privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Creates share items for a response body based on its content type.
    /// - Parameters:
    ///   - request: The network request containing the response body.
    ///   - bodyText: Optional pre-loaded text representation of the body.
    ///   - bodyData: Optional pre-loaded binary data of the body.
    /// - Returns: Activity items ready for a share sheet.
    static func shareItemsForResponseBody(
        from request: NetworkRequest,
        bodyText: String? = nil,
        bodyData: Data? = nil
    ) -> [Any] {
        guard !request.responseBody.isEmpty else {
            return ["Response body is empty"]
        }

        let contentType = request.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value
        let contentDisposition = request.responseHeaders.first { $0.key.lowercased() == "content-disposition" }?.value
        let fileName = extractFilename(from: contentDisposition) ?? generateFileName(
            url: request.url,
            contentType: contentType,
            timestamp: request.timestamp
        )
        let safeFileName = sanitizedFileName(fileName, defaultExtension: fileExtension(for: contentType))

        // Handle binary content
        if request.isBinary || contentDisposition?.lowercased().contains("attachment") == true {
            if case let .file(url, _, _) = request.responseBody {
                if let copied = createTemporaryFileCopy(from: url, fileName: safeFileName) {
                    return [copied]
                }
                // Fallback: share the original file URL.
                return [url]
            }
            let data = bodyData ?? request.responseBody.getData()
            if let data {
                return shareItemsForBinary(data: data, fileName: safeFileName)
            }
            return ["Unable to load binary response body"]
        }

        // Handle text content
        let text = bodyText ?? request.responseBody.getString()
        guard let text, !text.isEmpty else {
            return ["Unable to load response body"]
        }

        // Determine file format based on content type
        if let contentType = contentType?.lowercased() {
            if contentType.contains("json") {
                return shareItemsForJSON(content: text, fileName: safeFileName)
            } else if contentType.contains("html") {
                return shareItemsForText(content: text, fileName: safeFileName)
            } else if contentType.contains("xml") {
                return shareItemsForText(content: text, fileName: safeFileName)
            } else if contentType.contains("javascript") {
                return shareItemsForText(content: text, fileName: safeFileName)
            } else if contentType.contains("css") {
                return shareItemsForText(content: text, fileName: safeFileName)
            } else if contentType.contains("csv") {
                return shareItemsForCSV(content: text, fileName: safeFileName)
            }
        }

        // Default to text with appropriate extension
        return shareItemsForText(content: text, fileName: safeFileName)
    }

    /// Creates share items for a request body based on its content type.
    /// - Parameters:
    ///   - request: The network request containing the request body.
    ///   - bodyText: Optional pre-loaded text representation of the body.
    ///   - bodyData: Optional pre-loaded binary data of the body.
    /// - Returns: Activity items ready for a share sheet.
    static func shareItemsForRequestBody(
        from request: NetworkRequest,
        bodyText: String? = nil,
        bodyData: Data? = nil
    ) -> [Any] {
        guard !request.requestBody.isEmpty else {
            return ["Request body is empty"]
        }

        let contentType = request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value
        let fileName = generateFileName(
            url: request.url,
            contentType: contentType,
            timestamp: request.timestamp,
            prefix: "request"
        )
        let safeFileName = sanitizedFileName(fileName, defaultExtension: fileExtension(for: contentType))

        // Check if content type indicates binary
        let isBinary = contentType.map { ct in
            let lower = ct.lowercased()
            return lower.contains("image/") ||
                lower.contains("video/") ||
                lower.contains("audio/") ||
                lower.contains("octet-stream") ||
                lower.contains("application/pdf") ||
                lower.contains("application/zip")
        } ?? false

        // Handle binary content
        if isBinary {
            if case let .file(url, _, _) = request.requestBody {
                if let copied = createTemporaryFileCopy(from: url, fileName: safeFileName) {
                    return [copied]
                }
                return [url]
            }
            let data = bodyData ?? request.requestBody.getData()
            if let data {
                return shareItemsForBinary(data: data, fileName: safeFileName)
            }
            return ["Unable to load binary request body"]
        }

        // Handle text content
        let text = bodyText ?? request.requestBody.getString()
        guard let text, !text.isEmpty else {
            return ["Unable to load request body"]
        }

        // Determine file format based on content type
        if let contentType = contentType?.lowercased() {
            if contentType.contains("json") {
                return shareItemsForJSON(content: text, fileName: safeFileName)
            } else if contentType.contains("html") {
                return shareItemsForText(content: text, fileName: safeFileName)
            } else if contentType.contains("xml") {
                return shareItemsForText(content: text, fileName: safeFileName)
            } else if contentType.contains("javascript") {
                return shareItemsForText(content: text, fileName: safeFileName)
            } else if contentType.contains("css") {
                return shareItemsForText(content: text, fileName: safeFileName)
            } else if contentType.contains("csv") {
                return shareItemsForCSV(content: text, fileName: safeFileName)
            }
        }

        // Default to text with appropriate extension
        return shareItemsForText(content: text, fileName: safeFileName)
    }

    /// Generates a file name based on URL, content type, and timestamp.
    /// - Parameters:
    ///   - url: The request URL.
    ///   - contentType: The Content-Type header value.
    ///   - timestamp: The request timestamp.
    ///   - prefix: Optional prefix for the filename (default: "response").
    /// - Returns: A generated file name with appropriate extension.
    static func generateFileName(
        url: String,
        contentType: String?,
        timestamp: Date,
        prefix: String = "response"
    ) -> String {
        // Try to get filename from URL path
        if let urlObj = URL(string: url) {
            let pathComponent = urlObj.lastPathComponent
            if !pathComponent.isEmpty && pathComponent != "/" {
                // If path component has extension, use it
                if pathComponent.contains(".") {
                    return pathComponent
                }
            }
        }

        // Generate filename based on content type
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: timestamp)

        let ext = fileExtension(for: contentType)
        return "\(prefix)_\(dateString).\(ext)"
    }

    /// Determines the file extension based on content type.
    /// - Parameter contentType: The Content-Type header value.
    /// - Returns: Appropriate file extension (without the dot).
    static func fileExtension(for contentType: String?) -> String {
        guard let contentType = contentType?.lowercased() else {
            return "txt"
        }

        if contentType.contains("json") {
            return "json"
        } else if contentType.contains("html") {
            return "html"
        } else if contentType.contains("xml") {
            return "xml"
        } else if contentType.contains("javascript") {
            return "js"
        } else if contentType.contains("css") {
            return "css"
        } else if contentType.contains("csv") {
            return "csv"
        } else if contentType.contains("pdf") {
            return "pdf"
        } else if contentType.contains("zip") || contentType.contains("x-zip-compressed") {
            return "zip"
        } else if contentType.contains("gzip") || contentType.contains("x-gzip") {
            return "gz"
        } else if contentType.contains("image/png") {
            return "png"
        } else if contentType.contains("image/jpeg") || contentType.contains("image/jpg") {
            return "jpg"
        } else if contentType.contains("image/gif") {
            return "gif"
        } else if contentType.contains("image/webp") {
            return "webp"
        } else if contentType.contains("image/svg") {
            return "svg"
        } else if contentType.contains("video/mp4") {
            return "mp4"
        } else if contentType.contains("video/webm") {
            return "webm"
        } else if contentType.contains("audio/mpeg") {
            return "mp3"
        } else if contentType.contains("audio/wav") {
            return "wav"
        } else if contentType.contains("text/") {
            return "txt"
        } else if contentType.contains("octet-stream") {
            return "bin"
        }

        return "txt"
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

    // MARK: - Formatting

    /// Formats a network request for sharing.
    /// - Parameter request: The request to format.
    /// - Returns: A formatted string representation of the request.
    static func formatRequestForSharing(_ request: NetworkRequest) -> String {
        var text = "Network Request\n\n"
        text += "URL: \(request.url)\n"
        text += "Method: \(request.method.rawValue)\n"
        text += "Status: \(request.statusCodeText)\n"
        text += "Time: \(request.timestamp.formatted(date: .abbreviated, time: .standard))\n"

        if !request.requestHeaders.isEmpty {
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
        }

        if !request.requestBody.isEmpty {
            let contentType = request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value
            let isBinary = contentType.map { ct in
                let lower = ct.lowercased()
                return lower.contains("image/") ||
                    lower.contains("video/") ||
                    lower.contains("audio/") ||
                    lower.contains("octet-stream") ||
                    lower.contains("application/pdf") ||
                    lower.contains("application/zip")
            } ?? false

            if isBinary {
                let size = request.requestBody.totalSize
                text += "\nRequest Body:\n<binary body omitted> (size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))\n"
            } else {
                let maxBytes = BodyStorage.previewSize
                if let body = request.requestBody.getString(maxBytes: maxBytes),
                   !body.isEmpty {
                    text += "\nRequest Body:\n\(body)\n"
                    if request.requestBody.totalSize > maxBytes {
                        text += "\n(Request body truncated to preview)\n"
                    }
                } else {
                    text += "\nRequest Body:\n<not available>\n"
                }
            }
        }

        if !request.responseHeaders.isEmpty {
            text += "\nResponse Headers:\n"
            for header in request.responseHeaders {
                if header.key.lowercased() == "content-type" {
                    let lowerValue = header.value.lowercased()
                    if lowerValue.contains("octet-stream"),
                       let inferred = inferredContentType(from: request.url),
                       inferred.lowercased() != lowerValue {
                        text += "  \(header.key): \(header.value) (inferred: \(inferred))\n"
                        continue
                    }
                }
                text += "  \(header.key): \(header.value)\n"
            }
        }

        if !request.responseBody.isEmpty {
            // Avoid rendering binary bodies (ZIP/PDF/etc.) as text; it can be huge and unreadable.
            let contentDisposition = request.responseHeaders.first { $0.key.lowercased() == "content-disposition" }?.value
            let isAttachment = contentDisposition?.lowercased().contains("attachment") == true
            if request.isBinary || isAttachment {
                let size = request.responseBody.totalSize
                let fileName = extractFilename(from: contentDisposition)
                text += "\nResponse Body:\n<binary body omitted> (size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))\n"
                if let fileName, !fileName.isEmpty {
                    text += "Filename: \(fileName)\n"
                }
            } else {
                let maxBytes = BodyStorage.previewSize
                if let responseBody = request.responseBody.getString(maxBytes: maxBytes),
                   !responseBody.isEmpty {
                    text += "\nResponse Body:\n\(responseBody)\n"
                    if request.responseBody.totalSize > maxBytes {
                        text += "\n(Response body truncated to preview)\n"
                    }
                }
            }
        }

        return text
    }

    private static func extractFilename(from contentDisposition: String?) -> String? {
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

    /// Generates a cURL command for a network request.
    /// - Parameter request: The request to convert.
    /// - Returns: A cURL command string.
    static func generateCurlCommand(_ request: NetworkRequest) -> String {
        CurlCommandGenerator.generate(from: request)
    }

    /// Presents a standard share sheet directly from the topmost view controller.
    /// Use this to avoid an extra SwiftUI sheet host behind the share sheet.
    @MainActor
    static func presentShareSheet(
        items: [Any],
        excludedActivityTypes: [UIActivity.ActivityType]? = nil,
        applicationActivities: [UIActivity]? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        let safeItems = items.isEmpty ? [fallbackShareMessage] : items

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            return
        }

        var presenter = rootViewController
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        let activityItems: [Any] = safeItems.map { item -> Any in
            if let url = item as? URL {
                return ShareURLItemSource(url: url)
            }
            return item
        }

        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        controller.excludedActivityTypes = excludedActivityTypes ?? ActivityHelper.defaultExcludedActivityTypes()

        if UIDevice.current.userInterfaceIdiom == .pad,
           let popover = controller.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        controller.completionWithItemsHandler = { _, _, _, _ in
            if let onComplete {
                Task { @MainActor in
                    onComplete()
                }
            }
        }

        presenter.present(controller, animated: true)
    }

}

// MARK: - SwiftUI View Extension

import SwiftUI

// MARK: - Share Sheet

/// A simple share payload that drives item-based SwiftUI sheet presentation.
struct ShareSheetItem: Identifiable {
    let id = UUID()
    let items: [Any]

    init(_ items: [Any]) {
        self.items = items
    }
}

/// A standard SwiftUI wrapper for `UIActivityViewController` (iOS Share Sheet).
///
/// ## Implementation follows iOS best practices:
/// - Wraps UIKit's `UIActivityViewController` using `UIViewControllerRepresentable`
/// - Automatically configures iPad popover anchor (prevents blank white screen)
/// - Clears host background to avoid a blank white sheet behind the share panel
/// - Presents on main thread
/// - Handles empty `activityItems` gracefully with fallback message
/// - Uses `.sheet` presentation (recommended over manual `present()`)
///
/// ## Usage:
/// ```swift
/// @State private var showingShare = false
/// @State private var shareItems: [Any] = []
///
/// Button("Share") { showingShare = true }
///     .sheet(isPresented: $showingShare) {
///         ShareSheet(items: ["Hello", URL(string: "https://example.com")!])
///     }
/// ```
///
/// ## Common Issues & Fixes:
/// 1. **Blank white screen**: Usually caused by empty `activityItems`, missing iPad popover anchor,
///    or a SwiftUI sheet host showing a default background
///    - Fix: This implementation handles items/popover automatically and uses a clear host background
/// 2. **Not in window hierarchy**: Occurs when presenting from wrong view controller
///    - Fix: Use SwiftUI `.sheet` modifier (this implementation)
/// 3. **iPad presentation failure**: Missing popover anchor
///    - Fix: Automatically configured with centered popover (lines below)
///
@MainActor
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType]?
    var applicationActivities: [UIActivity]?
    @Environment(\.dismiss) private var dismiss

    /// Creates a share sheet with default excluded activities for Trace.
    /// - Parameters:
    ///   - items: The activity items to share (URLs, Strings, Data, etc.).
    ///   - excludedActivityTypes: Activity types to exclude, or `nil` to use defaults.
    ///   - applicationActivities: Custom activities to include.
    init(
        items: [Any],
        excludedActivityTypes: [UIActivity.ActivityType]? = nil,
        applicationActivities: [UIActivity]? = nil
    ) {
        // Prevent blank screen: ensure items array is never empty.
        if items.isEmpty {
            self.items = [ShareHelper.fallbackShareMessage]
        } else {
            self.items = items
        }
        // Rule: Use the app defaults when no exclusions are provided.
        self.excludedActivityTypes = excludedActivityTypes ?? ActivityHelper.defaultExcludedActivityTypes()
        self.applicationActivities = applicationActivities
    }

    func makeUIViewController(context: Context) -> ShareSheetPresenterViewController {
        let controller = ShareSheetPresenterViewController()
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ uiViewController: ShareSheetPresenterViewController, context: Context) {
        uiViewController.configure(
            items: items,
            excludedActivityTypes: excludedActivityTypes,
            applicationActivities: applicationActivities,
            onComplete: { dismiss() }
        )
    }
}

/// A SwiftUI wrapper that applies presentation background fixes for the share sheet.
@MainActor
struct ShareSheetContainer: View {
    let items: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType]?
    var applicationActivities: [UIActivity]?

    var body: some View {
        if #available(iOS 16.4, *) {
            ShareSheet(
                items: items,
                excludedActivityTypes: excludedActivityTypes,
                applicationActivities: applicationActivities
            )
            .presentationBackground(.clear)
        } else {
            ShareSheet(
                items: items,
                excludedActivityTypes: excludedActivityTypes,
                applicationActivities: applicationActivities
            )
        }
    }
}

/// Presents `UIActivityViewController` and ensures proper iPad popover configuration.
///
/// This view controller handles the actual presentation of the iOS Share Sheet.
/// It ensures:
/// - Presentation only occurs when view is in window hierarchy
/// - iPad popover anchor is set (centered, no arrow)
/// - Completion handler dismisses the SwiftUI sheet
/// - Thread-safe execution on main thread
///
@MainActor
final class ShareSheetPresenterViewController: UIViewController {
    private struct Configuration {
        let items: [Any]
        let excludedActivityTypes: [UIActivity.ActivityType]?
        let applicationActivities: [UIActivity]?
        let onComplete: () -> Void
    }

    private var configuration: Configuration?
    private var hasPresented = false

    func configure(
        items: [Any],
        excludedActivityTypes: [UIActivity.ActivityType]?,
        applicationActivities: [UIActivity]?,
        onComplete: @escaping () -> Void
    ) {
        configuration = Configuration(
            items: items,
            excludedActivityTypes: excludedActivityTypes,
            applicationActivities: applicationActivities,
            onComplete: onComplete
        )
        presentIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentIfNeeded()
    }

    private func presentIfNeeded() {
        // Prevent duplicate presentations.
        guard !hasPresented else { return }

        // Ensure view is loaded and in window hierarchy (prevents "not in window hierarchy" error).
        guard isViewLoaded, view.window != nil else { return }

        // Ensure configuration is set.
        guard let configuration else { return }

        hasPresented = true

        // Create UIActivityViewController on main thread.
        let activityItems: [Any] = configuration.items.map { item -> Any in
            if let url = item as? URL {
                return ShareURLItemSource(url: url)
            }
            return item
        }

        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: configuration.applicationActivities
        )
        controller.excludedActivityTypes = configuration.excludedActivityTypes

        // Required on iPad: Set popover anchor to prevent blank screen or crash.
        if UIDevice.current.userInterfaceIdiom == .pad,
           let popover = controller.popoverPresentationController {
            popover.sourceView = view
            // Center the popover with no arrow (common iOS pattern for centered modals)
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        let onComplete = configuration.onComplete
        controller.completionWithItemsHandler = { _, _, _, _ in
            // Dismiss on main thread.
            Task { @MainActor in
                onComplete()
            }
        }

        // Present on main thread.
        DispatchQueue.main.async { [weak self] in
            self?.present(controller, animated: true)
        }
    }
}

/// Provides LinkPresentation metadata so the share sheet shows a header/preview.
final class ShareURLItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let title: String

    init(url: URL, title: String? = nil) {
        self.url = url
        let fallbackTitle = url.lastPathComponent.isEmpty
            ? (url.host ?? url.absoluteString)
            : url.lastPathComponent
        self.title = (title?.isEmpty == false ? title! : fallbackTitle)
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any {
        url
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }
}

extension View {
    /// Presents a standard iOS Share Sheet with proper iPad support.
    ///
    /// This is a convenience wrapper that follows iOS best practices:
    /// - Uses SwiftUI `.sheet` presentation (recommended over manual UIViewController presentation)
    /// - Automatically handles iPad popover configuration
    /// - Ensures main thread execution
    ///
    /// ## Example:
    /// ```swift
    /// @State private var showShare = false
    ///
    /// Button("Share") { showShare = true }
    ///     .shareSheet(isPresented: $showShare, items: ["Hello", URL(string: "https://example.com")!])
    /// ```
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls sheet presentation.
    ///   - items: The activity items to share (URLs, Strings, Data, UIImage, etc.).
    ///   - applicationActivities: Optional custom activities to include.
    /// - Returns: A view that presents the share sheet when triggered.
    func shareSheet(
        isPresented: Binding<Bool>,
        items: [Any],
        applicationActivities: [UIActivity]? = nil
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            ShareSheetContainer(
                items: items,
                applicationActivities: applicationActivities
            )
        }
    }
}
