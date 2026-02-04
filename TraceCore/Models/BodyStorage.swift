//
//  BodyStorage.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Compression
import Foundation
#if canImport(TraceCompression)
import TraceCompression
#endif
#if canImport(zlib)
import zlib
#endif

/// Compression information for body data
public struct CompressionInfo: Codable, Equatable {
    public let algorithm: String // "gzip", "br", "deflate", "none", or comma-separated for multiple
    public let compressedSize: Int
    public let decompressedSize: Int
    public let decompressionSuccess: Bool
    public let decompressionTime: TimeInterval?

    public var ratio: Double {
        guard decompressedSize > 0 else { return 1.0 }
        return Double(compressedSize) / Double(decompressedSize)
    }

    public var savingsPercentage: Double {
        guard decompressedSize > 0 else { return 0.0 }
        let saved = decompressedSize - compressedSize
        return (Double(saved) / Double(decompressedSize)) * 100.0
    }
}

/// Storage strategy for request/response bodies
public enum BodyStorage: Codable, Equatable {
    /// Small bodies stored inline (<1MB)
    case inline(Data, charset: String? = nil, compressionInfo: CompressionInfo? = nil)

    /// Large bodies stored in file (>1MB)
    case file(URL, charset: String? = nil, compressionInfo: CompressionInfo? = nil)

    /// Very large bodies truncated with preview (<10MB shown)
    case truncated(Data, totalSize: Int, charset: String? = nil, compressionInfo: CompressionInfo? = nil)

    /// Empty or no body
    case empty

    /// Default size thresholds
    public static var inlineThreshold: Int {
        AppGroupStorage.shared.loadBodyStorageConfig().inlineThreshold
    }

    public static var truncationThreshold: Int {
        AppGroupStorage.shared.loadBodyStorageConfig().truncationThreshold
    }

    public static var previewSize: Int {
        AppGroupStorage.shared.loadBodyStorageConfig().previewSize
    }

    // MARK: - Codable Implementation

    enum CodingKeys: String, CodingKey {
        case type
        case data
        case url
        case totalSize
        case charset
        case compressionInfo
    }

    enum StorageType: String, Codable {
        case inline
        case file
        case truncated
        case empty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StorageType.self, forKey: .type)
        let charset = try container.decodeIfPresent(String.self, forKey: .charset)
        let compressionInfo = try container.decodeIfPresent(CompressionInfo.self, forKey: .compressionInfo)

        switch type {
        case .inline:
            let data = try container.decode(Data.self, forKey: .data)
            self = .inline(data, charset: charset, compressionInfo: compressionInfo)
        case .file:
            let url = try container.decode(URL.self, forKey: .url)
            self = .file(url, charset: charset, compressionInfo: compressionInfo)
        case .truncated:
            let data = try container.decode(Data.self, forKey: .data)
            let totalSize = try container.decode(Int.self, forKey: .totalSize)
            self = .truncated(data, totalSize: totalSize, charset: charset, compressionInfo: compressionInfo)
        case .empty:
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .inline(data, charset, compressionInfo):
            try container.encode(StorageType.inline, forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(charset, forKey: .charset)
            try container.encodeIfPresent(compressionInfo, forKey: .compressionInfo)
        case let .file(url, charset, compressionInfo):
            try container.encode(StorageType.file, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(charset, forKey: .charset)
            try container.encodeIfPresent(compressionInfo, forKey: .compressionInfo)
        case let .truncated(data, totalSize, charset, compressionInfo):
            try container.encode(StorageType.truncated, forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(totalSize, forKey: .totalSize)
            try container.encodeIfPresent(charset, forKey: .charset)
            try container.encodeIfPresent(compressionInfo, forKey: .compressionInfo)
        case .empty:
            try container.encode(StorageType.empty, forKey: .type)
        }
    }

    // MARK: - Factory Methods

    /// Create storage from data with automatic strategy selection
    /// - Parameters:
    ///   - data: The body data (may be compressed)
    ///   - charset: Optional character encoding
    ///   - maxSize: Optional maximum size before truncation
    ///   - contentEncoding: Optional Content-Encoding header value (e.g., "gzip", "br", "deflate")
    /// - Returns: BodyStorage instance with decompressed data
    public static func from(data: Data, charset: String? = nil, maxSize: Int? = nil, contentEncoding: String? = nil) -> BodyStorage {
        let effectiveMaxSize = maxSize ?? truncationThreshold
        // Safety: Prevent decompression amplification (zip bombs) by bounding output.
        // We only need to know whether the decoded body exceeds the capture max.
        let decompressionOutputLimit = (effectiveMaxSize == Int.max) ? Int.max : (effectiveMaxSize + 1)

        if data.isEmpty {
            return .empty
        }

        // Decompress data if Content-Encoding is specified and track compression stats
        let processedData: Data
        let compressionInfo: CompressionInfo?

        if let encoding = contentEncoding, !encoding.isEmpty, encoding.lowercased() != "identity" {
            let startTime = Date()
            // Check for multiple encodings (e.g., "gzip, br" or "deflate, gzip")
            let decompressed: Data? = if encoding.contains(",") {
                decompressChained(
                    data,
                    encodings: encoding.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    maxOutputBytes: decompressionOutputLimit
                )
            } else {
                decompressIfNeeded(data, encoding: encoding, maxOutputBytes: decompressionOutputLimit)
            }

            let decompressionTime = Date().timeIntervalSince(startTime)

            if let decompressed {
                processedData = decompressed
                compressionInfo = CompressionInfo(
                    algorithm: encoding,
                    compressedSize: data.count,
                    decompressedSize: decompressed.count,
                    decompressionSuccess: true,
                    decompressionTime: decompressionTime
                )
            } else {
                // Decompression failed or no change
                processedData = data
                compressionInfo = CompressionInfo(
                    algorithm: encoding,
                    compressedSize: data.count,
                    decompressedSize: data.count,
                    decompressionSuccess: false,
                    decompressionTime: decompressionTime
                )
            }
        } else {
            // Auto-detect compression by magic bytes (bounded).
            if let detected = autoDetectAndDecompress(data, maxOutputBytes: decompressionOutputLimit) {
                processedData = detected.data
                compressionInfo = CompressionInfo(
                    algorithm: detected.algorithm,
                    compressedSize: data.count,
                    decompressedSize: detected.data.count,
                    decompressionSuccess: true,
                    decompressionTime: nil
                )
            } else {
                processedData = data
                compressionInfo = nil // No compression
            }
        }

        if processedData.count > effectiveMaxSize {
            // Truncate very large bodies
            let preview = processedData.prefix(previewSize)
            return .truncated(preview, totalSize: processedData.count, charset: charset, compressionInfo: compressionInfo)
        }

        if processedData.count > inlineThreshold {
            // Store large bodies in file
            if let fileURL = saveToFile(data: processedData) {
                return .file(fileURL, charset: charset, compressionInfo: compressionInfo)
            }
            // Fallback to inline if file save fails
            return .inline(processedData, charset: charset, compressionInfo: compressionInfo)
        }

        // Store small bodies inline
        return .inline(processedData, charset: charset, compressionInfo: compressionInfo)
    }

    /// Create storage from string
    public static func from(string: String, charset: String? = "utf-8", maxSize: Int? = nil) -> BodyStorage {
        guard let data = string.data(using: .utf8) else {
            return .empty
        }
        return from(data: data, charset: charset, maxSize: maxSize)
    }

    // MARK: - Data Access

    /// Get the full data (may load from file)
    public func getData() -> Data? {
        switch self {
        case let .inline(data, _, _):
            data
        case let .file(url, _, _):
            try? Data(contentsOf: url)
        case let .truncated(preview, _, _, _):
            preview // Returns preview only
        case .empty:
            nil
        }
    }

    /// Decompress data based on encoding type
    /// Supports gzip, brotli (br), and deflate
    private static func decompressIfNeeded(_ data: Data, encoding: String? = nil, maxOutputBytes: Int? = nil) -> Data? {
        // If encoding is specified, use it to determine decompression method
        if let encoding = encoding?.lowercased() {
            switch encoding {
            case "gzip", "x-gzip":
                return decompressGzip(data, maxOutputBytes: maxOutputBytes)
            case "br", "brotli":
                return decompressBrotli(data, maxOutputBytes: maxOutputBytes)
            case "deflate":
                return decompressDeflate(data, maxOutputBytes: maxOutputBytes)
            case "identity", "":
                return data
            default:
                return nil
            }
        }

        // Auto-detect compression type by magic bytes
        guard let limit = maxOutputBytes else { return data }
        return autoDetectAndDecompress(data, maxOutputBytes: limit)?.data ?? data
    }

    /// Decompress gzip-encoded data
    private static func decompressGzip(_ data: Data, maxOutputBytes: Int? = nil) -> Data? {
        guard let deflated = GzipWrapper.strip(from: data) else { return nil }
        return decompressDeflate(deflated, maxOutputBytes: maxOutputBytes)
    }

    /// Decompress Brotli-encoded data
    private static func decompressBrotli(_ data: Data, maxOutputBytes: Int? = nil) -> Data? {
        #if canImport(TraceCompression)
        return try? BrotliDecoder.decompress(data, maxOutputBytes: maxOutputBytes)
        #else
        return decompress(data: data, algorithm: COMPRESSION_BROTLI, maxOutputBytes: maxOutputBytes)
        #endif
    }

    /// Decompress DEFLATE-encoded data
    private static func decompressDeflate(_ data: Data, maxOutputBytes: Int? = nil) -> Data? {
        #if canImport(TraceCompression)
        return try? DeflateDecoder.decompress(data, maxOutputBytes: maxOutputBytes)
        #else
        guard !data.isEmpty else { return Data() }

        let maxOutput = maxOutputBytes ?? Int.max
        let windowBits: Int32 = hasZlibWrapper(data) ? MAX_WBITS : -MAX_WBITS

        return data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data? in
            guard let baseAddress = sourcePtr.bindMemory(to: UInt8.self).baseAddress else { return nil }

            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: baseAddress)
            stream.avail_in = uInt(data.count)

            let initStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initStatus == Z_OK else { return nil }
            defer { inflateEnd(&stream) }

            var output = Data()
            let bufferSize = 64 * 1024
            var outBuffer = [UInt8](repeating: 0, count: bufferSize)

            var status: Int32 = Z_OK
            while status == Z_OK {
                let produced: Int = outBuffer.withUnsafeMutableBytes { bufferPtr in
                    guard let outBase = bufferPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    stream.next_out = outBase
                    stream.avail_out = uInt(bufferSize)

                    status = inflate(&stream, Z_NO_FLUSH)

                    if status != Z_OK && status != Z_STREAM_END {
                        return 0
                    }

                    return bufferSize - Int(stream.avail_out)
                }

                if status != Z_OK && status != Z_STREAM_END {
                    return nil
                }

                if produced > 0 {
                    let remaining = max(0, maxOutput - output.count)
                    if remaining > 0 {
                        let toAppend = min(produced, remaining)
                        output.append(contentsOf: outBuffer.prefix(toAppend))
                    }
                }

                if output.count >= maxOutput {
                    return output
                }

                if status == Z_STREAM_END {
                    break
                }

                // Safety: If no progress is possible, exit to avoid a tight loop.
                if stream.avail_in == 0 && produced == 0 {
                    break
                }
            }

            return output
        }
        #endif
    }

    /// Decompress data with multiple encodings applied in sequence
    /// Encodings are applied in reverse order during decompression
    /// (last encoding applied is first to be removed)
    private static func decompressChained(_ data: Data, encodings: [String], maxOutputBytes: Int? = nil) -> Data? {
        var result = data

        // Process in reverse: if "gzip, br", the data was first gzipped, then brotli'd
        // So we need to unbrotli first, then ungzip
        for encoding in encodings.reversed() {
            guard let decompressed = decompressIfNeeded(result, encoding: encoding, maxOutputBytes: maxOutputBytes) else {
                return nil
            }
            result = decompressed
        }

        return result
    }

    private struct AutoDetectedDecompression {
        let data: Data
        let algorithm: String
    }

    /// Attempts to auto-detect common compression formats (gzip, brotli) and decompresses them with an output limit.
    private static func autoDetectAndDecompress(_ data: Data, maxOutputBytes: Int) -> AutoDetectedDecompression? {
        guard data.count >= 2 else { return nil }

        // Check for gzip magic bytes (0x1F 0x8B).
        let magicBytes = data.prefix(2)
        let isGzip = magicBytes[0] == 0x1F && magicBytes[1] == 0x8B
        if isGzip, let inflated = decompressGzip(data, maxOutputBytes: maxOutputBytes) {
            return AutoDetectedDecompression(data: inflated, algorithm: "gzip")
        }

        #if canImport(TraceCompression)
        if BrotliDecoder.canDecode(data), let inflated = decompressBrotli(data, maxOutputBytes: maxOutputBytes) {
            return AutoDetectedDecompression(data: inflated, algorithm: "br")
        }
        #endif

        return nil
    }

    /// Detects a zlib wrapper per RFC 1950.
    private static func hasZlibWrapper(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }

        let cmf = data[0]
        let flg = data[1]

        // Rule: RFC 1950 requires the CMF lower nibble to be 8 for DEFLATE.
        let cm = cmf & 0x0F
        guard cm == 8 else { return false }

        // Rule: RFC 1950 requires (CMF << 8 | FLG) to be a multiple of 31.
        let check = (UInt16(cmf) << 8) | UInt16(flg)
        return check % 31 == 0
    }

    /// Generic decompression helper using Apple's Compression framework.
    private static func decompress(data: Data, algorithm: compression_algorithm, maxOutputBytes: Int? = nil) -> Data? {
        guard !data.isEmpty else { return Data() }

        let dummyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let dummySrc = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            dummyDst.deallocate()
            dummySrc.deallocate()
        }
        var stream = compression_stream(
            dst_ptr: dummyDst,
            dst_size: 0,
            src_ptr: UnsafePointer(dummySrc),
            src_size: 0,
            state: nil
        )
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        let outputLimit = maxOutputBytes ?? Int.max
        var output = Data()

        return data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data? in
            guard let baseAddress = sourcePtr.baseAddress else { return nil }

            stream.src_ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            stream.src_size = data.count

            repeat {
                let previousSrcSize = stream.src_size
                stream.dst_ptr = destinationBuffer
                stream.dst_size = bufferSize

                status = compression_stream_process(&stream, 0)

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 {
                        let remaining = max(0, outputLimit - output.count)
                        if remaining > 0 {
                            let toAppend = min(produced, remaining)
                            output.append(destinationBuffer, count: toAppend)
                        }
                        if output.count >= outputLimit {
                            return output
                        }
                    }
                    // Safety: If the decoder makes no progress, exit to avoid an infinite loop.
                    // This can happen for malformed / truncated streams where the API keeps returning `.OK`.
                    if status == COMPRESSION_STATUS_OK,
                       produced == 0,
                       stream.src_size == previousSrcSize,
                       stream.dst_size == bufferSize {
                        return output.isEmpty ? nil : output
                    }
                default:
                    return nil
                }
            } while status == COMPRESSION_STATUS_OK

            return output
        }
    }

    /// Get data as string with intelligent encoding detection
    public func getString() -> String? {
        guard let data = getData() else { return nil }
        return Self.decodeString(from: data, charset: getCharset())
    }

    /// Decode raw data with intelligent encoding detection (no storage required)
    public static func decodeText(from data: Data, charset: String? = nil) -> String? {
        decodeString(from: data, charset: charset)
    }

    /// Get data preview as string without loading the entire file into memory.
    public func getString(maxBytes: Int) -> String? {
        guard let data = getPreview(maxBytes: maxBytes) else { return nil }
        return Self.decodeString(from: data, charset: getCharset())
    }

    /// Get stored charset
    public func getCharset() -> String? {
        switch self {
        case let .inline(_, charset, _):
            charset
        case let .file(_, charset, _):
            charset
        case let .truncated(_, _, charset, _):
            charset
        case .empty:
            nil
        }
    }

    /// Get compression information if available
    public func getCompressionInfo() -> CompressionInfo? {
        switch self {
        case let .inline(_, _, compressionInfo):
            compressionInfo
        case let .file(_, _, compressionInfo):
            compressionInfo
        case let .truncated(_, _, _, compressionInfo):
            compressionInfo
        case .empty:
            nil
        }
    }

    /// Convert charset name to String.Encoding
    private static func stringEncoding(from charset: String) -> String.Encoding? {
        let normalizedCharset = charset.lowercased().replacingOccurrences(of: "-", with: "")

        switch normalizedCharset {
        case "utf8":
            return .utf8
        case "utf16":
            return .utf16
        case "utf32":
            return .utf32
        case "iso88591", "latin1":
            return .isoLatin1
        case "iso88592", "latin2":
            return .isoLatin2
        case "gb2312", "gbk", "gb18030", "gb_18030_2000":
            let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            let encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: encoding)
        case "big5":
            let cfEncoding = CFStringEncoding(CFStringEncodings.big5.rawValue)
            let encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: encoding)
        case "shiftjis", "shift_jis", "sjis":
            return .shiftJIS
        case "eucjp":
            return .japaneseEUC
        case "euckr":
            let cfEncoding = CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
            let encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: encoding)
        case "windows1252", "cp1252":
            return .windowsCP1252
        case "ascii", "usascii":
            return .ascii
        default:
            return nil
        }
    }

    private static func decodeString(from data: Data, charset: String?) -> String? {
        if let charset = charset?.lowercased(),
           let encoding = stringEncoding(from: charset),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }

        let standardEncodings: [String.Encoding] = [
            .utf8, // Most common modern encoding
            .isoLatin1, // HTTP default if no charset specified
            .windowsCP1252, // Windows Western European
            .shiftJIS, // Japanese
            .japaneseEUC // Japanese
        ]

        for encoding in standardEncodings {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }

        let cfEncodings: [CFStringEncoding] = [
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue), // Chinese Simplified
            CFStringEncoding(CFStringEncodings.big5.rawValue), // Traditional Chinese
            CFStringEncoding(CFStringEncodings.EUC_KR.rawValue) // Korean
        ]

        for cfEncoding in cfEncodings {
            let encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let decoded = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
                return decoded
            }
        }

        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Get preview data (fast, no full file I/O for large files)
    public func getPreview(maxBytes: Int = 1024) -> Data? {
        switch self {
        case let .inline(data, _, _):
            return data.prefix(maxBytes)
        case let .file(url, _, _):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
            return data
        case let .truncated(preview, _, _, _):
            return preview.prefix(maxBytes)
        case .empty:
            return nil
        }
    }

    /// Get total size in bytes
    public var totalSize: Int {
        switch self {
        case let .inline(data, _, _):
            data.count
        case let .file(url, _, _):
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        case let .truncated(_, totalSize, _, _):
            totalSize
        case .empty:
            0
        }
    }

    /// Check if body is truncated
    public var isTruncated: Bool {
        if case .truncated = self {
            return true
        }
        return false
    }

    /// Check if body is stored in file
    public var isFile: Bool {
        if case .file = self {
            return true
        }
        return false
    }

    /// Check if body is empty
    public var isEmpty: Bool {
        if case .empty = self {
            return true
        }
        return totalSize == 0
    }

    // MARK: - File Management

    /// Save data to file in App Group storage (or temp directory if not available)
    private static func saveToFile(data: Data) -> URL? {
        guard let containerURL = bodyContainerURL() else { return nil }

        let bodiesDir = containerURL.appendingPathComponent("Bodies")
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)

        let fileName = UUID().uuidString + ".bin"
        let fileURL = bodiesDir.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return fileURL
        } catch {
            return nil
        }
    }

    /// Resolve the container used for body files, respecting the configured App Group and fallback.
    private static func bodyContainerURL() -> URL? {
        if let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConfiguration.appGroupIdentifier
        ) {
            return groupContainer
        }

        // Fallback to the same location AppGroupStorage uses for simulator/test environments.
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documentsURL.appendingPathComponent("AppGroupFallback")
        }

        return nil
    }

    /// Delete file if stored as file
    public func deleteFile() {
        if case let .file(url, _, _) = self {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Cleanup orphaned body files older than specified days
    public static func cleanupOldFiles(olderThanDays days: Int = 7) {
        guard let containerURL = bodyContainerURL() else { return }

        let bodiesDir = containerURL.appendingPathComponent("Bodies")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bodiesDir,
            includingPropertiesForKeys: [.creationDateKey]
        ) else {
            return
        }

        let cutoffDate = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)

        for file in files {
            guard let creationDate = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate else {
                continue
            }

            if creationDate < cutoffDate {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - Convenience Extensions

public extension BodyStorage {
    /// Convert to legacy String format for backward compatibility
    func toLegacyString() -> String? {
        getString()
    }

    /// Create from legacy String format
    static func fromLegacyString(_ string: String?, maxSize: Int? = nil) -> BodyStorage {
        guard let string, !string.isEmpty else {
            return .empty
        }
        return from(string: string, maxSize: maxSize)
    }

    /// Extract charset from Content-Type header value
    /// - Parameter contentType: The Content-Type header value (e.g., "text/html; charset=utf-8")
    /// - Returns: The extracted charset (e.g., "utf-8"), or nil if not found
    static func extractCharset(from contentType: String?) -> String? {
        guard let contentType else { return nil }

        // Look for charset parameter in Content-Type header
        // Examples:
        // - "text/html; charset=utf-8"
        // - "application/json; charset=GB2312"
        // - "text/plain; charset=ISO-8859-1"
        let components = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }

        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)

                if key == "charset" {
                    // Remove quotes if present
                    var charset = value
                    if charset.hasPrefix("\"") && charset.hasSuffix("\"") {
                        charset = String(charset.dropFirst().dropLast())
                    }
                    return charset
                }
            }
        }

        return nil
    }

    /// Extract charset from HTTP headers array
    /// - Parameter headers: Array of TraceHTTPHeader objects
    /// - Returns: The extracted charset, or nil if not found
    static func extractCharset(from headers: [TraceHTTPHeader]) -> String? {
        // Find Content-Type header
        let contentTypeHeader = headers.first { $0.key.lowercased() == "content-type" }
        return extractCharset(from: contentTypeHeader?.value)
    }

    /// Extract charset from headers dictionary
    /// - Parameter headers: Dictionary of header key-value pairs
    /// - Returns: The extracted charset, or nil if not found
    static func extractCharset(from headers: [String: String]) -> String? {
        // Find Content-Type header (case-insensitive)
        for (key, value) in headers {
            if key.lowercased() == "content-type" {
                return extractCharset(from: value)
            }
        }
        return nil
    }
}
