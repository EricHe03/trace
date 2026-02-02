//
//  ImagePreviewTempFile.swift
//  TraceUI
//
//  Created by Justin on 2026/01/28.
//

import Foundation

enum ImagePreviewTempFile {
    static func write(
        data: Data,
        preferredFilename: String? = nil,
        contentType: String? = nil,
        defaultBasename: String = "Image"
    ) throws -> URL {
        let basename = sanitizedBasename(from: preferredFilename) ?? defaultBasename
        let ext = fileExtension(for: data, preferredFilename: preferredFilename, contentType: contentType)
        let filename = "\(basename)-\(UUID().uuidString).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        return url
    }

    static func cleanup(url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func sanitizedBasename(from filename: String?) -> String? {
        guard let filename, !filename.isEmpty else { return nil }
        let lastPath = (filename as NSString).lastPathComponent
        let base = (lastPath as NSString).deletingPathExtension
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fileExtension(for data: Data, preferredFilename: String?, contentType: String?) -> String {
        if let filenameExt = (preferredFilename as NSString?)?.pathExtension.lowercased(), !filenameExt.isEmpty {
            return filenameExt
        }

        if let contentType, let ext = fileExtension(fromContentType: contentType) {
            return ext
        }

        // Magic-number sniffing (kept intentionally small).
        guard data.count >= 12 else { return "img" }
        let bytes = [UInt8](data.prefix(16))

        // PNG: 89 50 4E 47
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "png"
        }

        // JPEG: FF D8 FF
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "jpg"
        }

        // GIF: 47 49 46
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            return "gif"
        }

        // WebP: RIFF....WEBP
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }

        // HEIC/HEIF/AVIF: ftyp box at byte 4-7, brand at byte 8-11
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: Array(bytes[8 ..< 12]), encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return "heic" }
            if ["avif", "avis"].contains(brand) { return "avif" }
        }

        return "img"
    }

    private static func fileExtension(fromContentType contentType: String) -> String? {
        let lower = contentType.lowercased()

        // Strip charset/boundary parameters.
        let typeOnly = lower.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? lower

        switch typeOnly {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/heic", "image/heif":
            return "heic"
        case "image/avif":
            return "avif"
        case "image/svg+xml", "image/svg":
            return "svg"
        case "image/bmp":
            return "bmp"
        case "image/tiff":
            return "tiff"
        default:
            return nil
        }
    }
}
