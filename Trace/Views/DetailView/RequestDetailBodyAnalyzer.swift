//
//  RequestDetailBodyAnalyzer.swift
//  Trace
//
//  Created by Justin on 2026/02/06.
//

import Foundation

enum RequestDetailBodyAnalyzer {
    enum BinaryKind: String {
        case zip = "ZIP"
        case pdf = "PDF"
        case binary = "Binary"
    }

    static func isBinaryContentType(_ contentType: String?) -> Bool {
        guard let ct = contentType?.lowercased(), !ct.isEmpty else { return false }

        if ct.contains("image/svg") {
            return false
        }

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

    static func inferredContentType(from url: String) -> String? {
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

    static func attachmentFileName(from contentDisposition: String?) -> String? {
        guard let contentDisposition, !contentDisposition.isEmpty else { return nil }

        let parts = contentDisposition
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

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

    static func detectBinaryKind(data: Data?, contentType: String?, fileName: String?) -> BinaryKind {
        if let fileName = fileName?.lowercased() {
            if fileName.hasSuffix(".zip") { return .zip }
            if fileName.hasSuffix(".pdf") { return .pdf }
        }

        if let ct = contentType?.lowercased() {
            if ct.contains("application/zip") { return .zip }
            if ct.contains("application/pdf") { return .pdf }
        }

        if let data, data.count >= 4 {
            if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||
                data.starts(with: [0x50, 0x4B, 0x05, 0x06]) ||
                data.starts(with: [0x50, 0x4B, 0x07, 0x08]) {
                return .zip
            }

            if data.starts(with: [0x25, 0x50, 0x44, 0x46]) {
                return .pdf
            }
        }

        return .binary
    }

    static func binarySummaryText(
        kind: BinaryKind,
        fileName: String?,
        receivedSize: Int?,
        capturedSize: Int,
        previewSize: Int?,
        isPreview: Bool,
        isTruncated: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("\(kind.rawValue) body")

        if let receivedSize, receivedSize > 0 {
            lines.append("Received: \(formattedBytes(receivedSize))")
        }

        lines.append("Captured: \(formattedBytes(capturedSize))")

        if let fileName, !fileName.isEmpty {
            lines.append("Filename: \(fileName)")
        }

        if isTruncated {
            lines.append("Truncated at capture limit.")
        }

        if let previewSize, previewSize > 0, isPreview {
            lines.append("Loaded in viewer: \(formattedBytes(previewSize))")
            lines.append("Use Hex view to inspect bytes.")
        }

        return lines.joined(separator: "\n")
    }

    private static func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
