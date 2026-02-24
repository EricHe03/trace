//
//  UDPFlowDetailView.swift
//  Trace
//
//  Created by Justin on 2026/01/21.
//

import SwiftUI
import TraceCore
import TraceUI

struct UDPFlowDetailView: View {
    let flow: UDPFlowMetadata
    let viewModel: UDPFlowsViewModel

    @State private var showingExport = false
    @State private var shareSheetItem: ShareSheetItem?
    @State private var toastMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text("\(flow.sourceIP):\(flow.sourcePort)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } label: {
                    Label("Source", systemImage: "arrow.up.right")
                }

                LabeledContent {
                    Text("\(flow.destinationIP):\(flow.destinationPort)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } label: {
                    Label("Destination", systemImage: "arrow.down.left")
                }

                if let portInfo = flow.wellKnownPortDescription {
                    LabeledContent("Service Info", value: portInfo)
                }
            } header: {
                Text("Connection")
            }

            Section {
                LabeledContent("Protocol", value: flow.detectedProtocol.displayName)
                LabeledContent("Status", value: flow.termination.displayName)
                LabeledContent("Bidirectional", value: flow.isBidirectional ? "Yes" : "No")
            } header: {
                Text("Flow Details")
            }

            if flow.detectedProtocol == .quic || flow.hasQUICDiagnostics {
                Section {
                    LabeledContent("Inspection Outcome", value: flow.quicInspectionOutcome?.displayName ?? "Not Evaluated")
                    if let handshake = flow.quicFlowMetadata?.handshakeOutcome {
                        LabeledContent("Handshake", value: handshake.displayName)
                    }
                    if let version = flow.quicFlowMetadata?.version {
                        LabeledContent("Version", value: version)
                    }
                    if let alpn = flow.quicFlowMetadata?.alpn {
                        LabeledContent("ALPN", value: alpn)
                    }
                    if let dcidLength = flow.quicFlowMetadata?.destinationConnectionIDLength {
                        LabeledContent("Destination CID Length", value: "\(dcidLength) bytes")
                    }
                    if let scidLength = flow.quicFlowMetadata?.sourceConnectionIDLength {
                        LabeledContent("Source CID Length", value: "\(scidLength) bytes")
                    }
                    if let reason = flow.quicFlowMetadata?.failureReason {
                        LabeledContent("Fallback Reason", value: reason)
                    }
                    if let sniHash = flow.quicFlowMetadata?.sniHash {
                        LabeledContent("SNI Hash", value: sniHash)
                            .font(.system(.body, design: .monospaced))
                    }
                } header: {
                    Text("QUIC Inspection")
                }
            }

            Section {
                LabeledContent("Start") {
                    Text(flow.startTime.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Last Activity") {
                    Text(flow.lastActivity.formatted(date: .abbreviated, time: .standard))
                }
                if let end = flow.endTime {
                    LabeledContent("End") {
                        Text(end.formatted(date: .abbreviated, time: .standard))
                    }
                }
                LabeledContent("Duration", value: viewModel.formatDuration(flow.duration))
            } header: {
                Text("Timing")
            }

            Section {
                LabeledContent("Data Sent") {
                    Text(viewModel.formatBytes(flow.bytesFromSource))
                        .monospacedDigit()
                }
                LabeledContent("Data Received") {
                    Text(viewModel.formatBytes(flow.bytesToSource))
                        .monospacedDigit()
                }
                LabeledContent("Total Data") {
                    Text(viewModel.formatBytes(flow.totalBytes))
                        .monospacedDigit()
                }

                LabeledContent("Packets Sent") {
                    Text("\(flow.datagramsFromSource)")
                        .monospacedDigit()
                }
                LabeledContent("Packets Received") {
                    Text("\(flow.datagramsToSource)")
                        .monospacedDigit()
                }

                LabeledContent("Throughput", value: viewModel.formatThroughput(flow.throughputBytesPerSecond))
                LabeledContent("Avg Packet Size", value: String(format: "%.1f B", flow.averageDatagramSize))
            } header: {
                Text("Traffic Stats")
            }

            Section("Recent Packets") {
                if flow.recentDatagrams.isEmpty {
                    TraceContentUnavailableView(
                        "No Packets Captured",
                        systemImage: "arrow.up.arrow.down",
                        description: Text("Packet details are not available for this flow")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(flow.recentDatagrams) { datagram in
                        HStack {
                            Image(systemName: datagram.direction == .sourceToDestination ? "arrow.up.right" : "arrow.down.left")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            Text(viewModel.formatBytes(UInt64(datagram.size)))
                                .font(.caption.monospacedDigit())

                            Spacer()

                            Text(datagram.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("UDP Flow")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .confirmationDialog("Export Flow", isPresented: $showingExport, titleVisibility: .visible) {
            Button("Export JSON") {
                exportJSON()
            }
            Button("Export Text") {
                exportText()
            }
            Button("Cancel", role: .cancel) {}
        }
        .shareSheet(item: $shareSheetItem)
        .toast(message: $toastMessage)
    }

    private var sourceRatioText: String {
        guard flow.totalBytes > 0 else { return "0%" }
        let ratio = Double(flow.bytesFromSource) / Double(flow.totalBytes)
        return String(format: "%.0f%%", ratio * 100)
    }

    private var datagramsPerSecondText: String {
        guard flow.duration > 0 else { return "0" }
        let rate = Double(flow.totalDatagrams) / flow.duration
        return String(format: "%.2f", rate)
    }

    private func exportJSON() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(flow)
            let url = try writeExport(data: data, fileName: "udp_flow_\(flow.id.uuidString).json")
            shareSheetItem = ShareSheetItem([url])
        } catch {
            toastMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func exportText() {
        let quicDetails: String = {
            guard flow.detectedProtocol == .quic || flow.hasQUICDiagnostics else { return "" }
            let inspection = flow.quicInspectionOutcome?.displayName ?? "Not Evaluated"
            let handshake = flow.quicFlowMetadata?.handshakeOutcome.displayName ?? "-"
            let version = flow.quicFlowMetadata?.version ?? "-"
            let alpn = flow.quicFlowMetadata?.alpn ?? "-"
            let dcidLength = flow.quicFlowMetadata?.destinationConnectionIDLength.map { "\($0)" } ?? "-"
            let scidLength = flow.quicFlowMetadata?.sourceConnectionIDLength.map { "\($0)" } ?? "-"
            let failure = flow.quicFlowMetadata?.failureReason ?? "-"
            return """

            QUIC Inspection:
              Outcome: \(inspection)
              Handshake: \(handshake)
              Version: \(version)
              ALPN: \(alpn)
              Destination CID Length: \(dcidLength)
              Source CID Length: \(scidLength)
              Fallback Reason: \(failure)
            """
        }()

        let text = """
        UDP Flow \(flow.id.uuidString)

        Connection:
          Source: \(flow.sourceIP):\(flow.sourcePort)
          Destination: \(flow.destinationIP):\(flow.destinationPort)
          Protocol: \(flow.detectedProtocol.displayName)
          Status: \(flow.termination.displayName)

        Timing:
          Start: \(flow.startTime)
          Last Activity: \(flow.lastActivity)
          End: \(flow.endTime?.description ?? "-")
          Duration: \(viewModel.formatDuration(flow.duration))

        Data Transfer:
          Bytes From Source: \(flow.bytesFromSource)
          Bytes To Source: \(flow.bytesToSource)
          Datagrams From Source: \(flow.datagramsFromSource)
          Datagrams To Source: \(flow.datagramsToSource)
          Total Bytes: \(flow.totalBytes)
          Total Datagrams: \(flow.totalDatagrams)
          Throughput: \(viewModel.formatThroughput(flow.throughputBytesPerSecond))
          Avg Datagram: \(String(format: "%.1f", flow.averageDatagramSize)) B
        \(quicDetails)
        """

        do {
            let url = try writeExport(data: Data(text.utf8), fileName: "udp_flow_\(flow.id.uuidString).txt")
            shareSheetItem = ShareSheetItem([url])
        } catch {
            toastMessage = "Export failed: \(error.localizedDescription)"
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
