//
//  UDPFlowsViewModel.swift
//  Trace
//
//  Created by Justin on 2026/01/21.
//

import Combine
import Foundation
import SwiftUI
import TraceCore

final class UDPFlowsViewModel: ObservableObject {
    enum SortOrder: String, CaseIterable, Identifiable {
        case startTimeAscending
        case startTimeDescending
        case bytesAscending
        case bytesDescending
        case durationAscending
        case durationDescending
        case destinationPortAscending
        case destinationPortDescending
        case datagramsAscending
        case datagramsDescending

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .startTimeAscending:
                "Start Time ↑"
            case .startTimeDescending:
                "Start Time ↓"
            case .bytesAscending:
                "Bytes ↑"
            case .bytesDescending:
                "Bytes ↓"
            case .durationAscending:
                "Duration ↑"
            case .durationDescending:
                "Duration ↓"
            case .destinationPortAscending:
                "Destination Port ↑"
            case .destinationPortDescending:
                "Destination Port ↓"
            case .datagramsAscending:
                "Datagrams ↑"
            case .datagramsDescending:
                "Datagrams ↓"
            }
        }
    }

    struct Statistics {
        let activeFlows: Int
        let totalFlows: Int
        let totalBytes: UInt64
        let totalDatagrams: UInt64
        let detectedProtocols: Set<UDPFlowProtocol>
    }

    @Published var flows: [UDPFlowMetadata] = []
    @Published var searchText = ""
    @Published var activeOnly = false
    @Published var selectedProtocol: UDPFlowProtocol?
    @Published var portFilter = ""
    @Published var sortOrder: SortOrder = .startTimeDescending
    @Published var lastError: String?

    private var isObserving = false

    var filteredFlows: [UDPFlowMetadata] {
        var result = flows

        if !searchText.isEmpty {
            let lowered = searchText.lowercased()
            result = result.filter { flow in
                flow.sourceIP.lowercased().contains(lowered) ||
                    flow.destinationIP.lowercased().contains(lowered) ||
                    String(flow.sourcePort).contains(lowered) ||
                    String(flow.destinationPort).contains(lowered) ||
                    flow.detectedProtocol.displayName.lowercased().contains(lowered)
            }
        }

        if activeOnly {
            result = result.filter(\.isActive)
        }

        if let selectedProtocol {
            result = result.filter { $0.detectedProtocol == selectedProtocol }
        }

        if let port = UInt16(portFilter.trimmingCharacters(in: .whitespacesAndNewlines)) {
            result = result.filter { $0.sourcePort == port || $0.destinationPort == port }
        }

        return applySorting(to: result)
    }

    var statistics: Statistics {
        let activeFlows = flows.count(where: { $0.isActive })
        let totalFlows = flows.count
        let totalBytes = flows.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let totalDatagrams = flows.reduce(UInt64(0)) { $0 + $1.totalDatagrams }
        let protocols = Set(flows.map(\.detectedProtocol))
        return Statistics(
            activeFlows: activeFlows,
            totalFlows: totalFlows,
            totalBytes: totalBytes,
            totalDatagrams: totalDatagrams,
            detectedProtocols: protocols
        )
    }

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        AppGroupStorage.shared.observeNewUDPFlows { [weak self] in
            self?.loadFlows()
        }
    }

    func loadFlows() {
        Task {
            do {
                let loaded = try AppGroupStorage.shared.loadAllUDPFlowMetadata()
                await MainActor.run {
                    self.flows = loaded
                    self.lastError = nil
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func deleteFlow(_ flow: UDPFlowMetadata) {
        do {
            try AppGroupStorage.shared.deleteUDPFlowMetadata(flow.id)
            flows.removeAll { $0.id == flow.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearAll() {
        do {
            try AppGroupStorage.shared.clearAllUDPFlowMetadata()
            flows.removeAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteOlderThan(days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let toDelete = flows.filter { ($0.endTime ?? $0.lastActivity) < cutoff }
        for flow in toDelete {
            try? AppGroupStorage.shared.deleteUDPFlowMetadata(flow.id)
        }
        flows.removeAll { ($0.endTime ?? $0.lastActivity) < cutoff }
    }

    func exportCSV() throws -> URL {
        let formatter = ISO8601DateFormatter()
        var csv = "ID,Source IP,Source Port,Destination IP,Destination Port,Protocol,Bytes From Source,Bytes To Source,Datagrams From Source,Datagrams To Source,Start Time,Last Activity,End Time,Duration (s),Termination\n"

        for flow in filteredFlows {
            let start = formatter.string(from: flow.startTime)
            let last = formatter.string(from: flow.lastActivity)
            let end = flow.endTime.map { formatter.string(from: $0) } ?? ""
            let duration = String(format: "%.3f", flow.duration)
            csv += "\"\(flow.id.uuidString)\",\"\(flow.sourceIP)\",\"\(flow.sourcePort)\",\"\(flow.destinationIP)\",\"\(flow.destinationPort)\",\"\(flow.detectedProtocol.displayName)\",\"\(flow.bytesFromSource)\",\"\(flow.bytesToSource)\",\"\(flow.datagramsFromSource)\",\"\(flow.datagramsToSource)\",\"\(start)\",\"\(last)\",\"\(end)\",\"\(duration)\",\"\(flow.termination.displayName)\"\n"
        }

        return try writeExport(data: Data(csv.utf8), fileName: "udp_flows.csv")
    }

    func exportJSON() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(filteredFlows)
        return try writeExport(data: data, fileName: "udp_flows.json")
    }

    func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0f ms", seconds * 1000)
        }
        if seconds < 60 {
            return String(format: "%.1f s", seconds)
        }
        if seconds < 3600 {
            return String(format: "%.1f min", seconds / 60)
        }
        return String(format: "%.1f hr", seconds / 3600)
    }

    func formatThroughput(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
        if bytesPerSecond < 1024 * 1024 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
    }

    private func applySorting(to flows: [UDPFlowMetadata]) -> [UDPFlowMetadata] {
        switch sortOrder {
        case .startTimeAscending:
            flows.sorted { $0.startTime < $1.startTime }
        case .startTimeDescending:
            flows.sorted { $0.startTime > $1.startTime }
        case .bytesAscending:
            flows.sorted { $0.totalBytes < $1.totalBytes }
        case .bytesDescending:
            flows.sorted { $0.totalBytes > $1.totalBytes }
        case .durationAscending:
            flows.sorted { $0.duration < $1.duration }
        case .durationDescending:
            flows.sorted { $0.duration > $1.duration }
        case .destinationPortAscending:
            flows.sorted { $0.destinationPort < $1.destinationPort }
        case .destinationPortDescending:
            flows.sorted { $0.destinationPort > $1.destinationPort }
        case .datagramsAscending:
            flows.sorted { $0.totalDatagrams < $1.totalDatagrams }
        case .datagramsDescending:
            flows.sorted { $0.totalDatagrams > $1.totalDatagrams }
        }
    }

    private func writeExport(data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("udp_exports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: [.atomic])
        return url
    }
}
