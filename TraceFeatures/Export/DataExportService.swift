//
//  DataExportService.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import UniformTypeIdentifiers
#if canImport(TraceCore)
import TraceCore
#endif

/// Errors that can occur during export operations
public enum ExportError: LocalizedError {
    case harExportFailed
    case csvExportFailed
    case fileWriteFailed

    public var errorDescription: String? {
        switch self {
        case .harExportFailed:
            "Failed to export requests to HAR format"
        case .csvExportFailed:
            "Failed to export requests to CSV format"
        case .fileWriteFailed:
            "Failed to write export file"
        }
    }
}

/// Protocol defining data export operations
public protocol DataExportServiceProtocol {
    func exportToHAR(requests: [NetworkRequest]) async throws -> URL
    func exportToCSV(requests: [NetworkRequest]) async throws -> URL
    func importFromHAR(fileURL: URL) async throws -> [NetworkRequest]
    func exportToCURL(request: NetworkRequest) -> String
}

/// Service handling data import/export operations
public final class DataExportService: DataExportServiceProtocol, Sendable {
    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    public func exportToHAR(requests: [NetworkRequest]) async throws -> URL {
        guard let harData = HARExporter.export(requests: requests) else {
            throw ExportError.harExportFailed
        }

        let fileName = "trace-export-\(Date().timeIntervalSince1970).har"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        try harData.write(to: tempURL)
        FeatureLog.export.info("event=export.har outcome=success count=\(requests.count)")

        return tempURL
    }

    public func exportToCSV(requests: [NetworkRequest]) async throws -> URL {
        var csvString = "Timestamp,Method,URL,Status,Duration (ms),Request Size,Response Size\n"

        for request in requests {
            let timestamp = csvEscape(ISO8601DateFormatter().string(from: request.timestamp))
            let method = csvEscape(request.method.rawValue)
            let url = csvEscape(request.url)
            let status = csvEscape(request.statusCode.map { String($0) } ?? "N/A")
            let duration = csvEscape(String(format: "%.2f", request.duration * 1000))
            let requestSize = csvEscape(String(request.requestBody.totalSize))
            let responseSize = csvEscape(String(request.responseBody.totalSize))

            csvString += "\(timestamp),\(method),\(url),\(status),\(duration),\(requestSize),\(responseSize)\n"
        }

        let fileName = "trace-export-\(Date().timeIntervalSince1970).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        try csvString.write(to: tempURL, atomically: true, encoding: .utf8)
        FeatureLog.export.info("event=export.csv outcome=success count=\(requests.count)")

        return tempURL
    }

    public func importFromHAR(fileURL: URL) async throws -> [NetworkRequest] {
        let requests = try HARExporter.import(from: Data(contentsOf: fileURL))
        FeatureLog.export.info("event=import.har outcome=success count=\(requests.count)")
        return requests
    }

    public func exportToCURL(request: NetworkRequest) -> String {
        CurlCommandGenerator.generate(from: request)
    }

    private func csvEscape(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if let first = escaped.first, "=+-@".contains(first) {
            escaped = "'\(escaped)"
        }
        let needsQuotes =
            escaped.contains(",") || escaped.contains("\n") || escaped.contains("\r") || escaped.contains("\"")
        return needsQuotes ? "\"\(escaped)\"" : escaped
    }
}
