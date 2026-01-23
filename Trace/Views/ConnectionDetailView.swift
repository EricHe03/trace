//
//  ConnectionDetailView.swift
//  Trace
//
//  Created by Justin on 2026/01/23.
//

import Charts
import SwiftUI
import TraceCore
import TraceUI

struct ConnectionDetailView: View {
    @StateObject private var viewModel: ConnectionDetailViewModel
    @State private var showingPCAPPicker = false

    init(record: PacketFlowRecord) {
        _viewModel = StateObject(wrappedValue: ConnectionDetailViewModel(record: record))
    }

    var body: some View {
        List {
            summarySection
            protocolSection
            handshakeSection
            terminationSection
            metricsSection
            graphsSection
            anomaliesSection
            streamSection
            packetListSection
            captureNoteSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connection Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Load PCAP") {
                    showingPCAPPicker = true
                    viewModel.refreshPCAPFiles()
                }
            }
        }
        .sheet(isPresented: $showingPCAPPicker) {
            NavigationStack {
                List {
                    if viewModel.pcapFiles.isEmpty {
                        TraceContentUnavailableView(
                            "No PCAP Files",
                            systemImage: "tray",
                            description: Text("Enable raw packet capture to collect PCAP files.")
                        )
                    } else {
                        ForEach(viewModel.pcapFiles) { file in
                            Button {
                                showingPCAPPicker = false
                                viewModel.loadFromPCAP(file)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.displayName)
                                            .font(.body)
                                        if let modified = file.modified {
                                            Text(modified.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Select PCAP")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showingPCAPPicker = false
                        }
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("Analyzing PCAP…")
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(12)
            }
        }
        .alert("PCAP Error", isPresented: Binding(get: { viewModel.loadError != nil }, set: { _ in viewModel.loadError = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.loadError ?? "Unknown error")
        }
    }

    private var activeRecord: PacketFlowRecord {
        viewModel.record
    }

    private var activeMetrics: TCPFlowMetrics? {
        viewModel.analysis?.metrics ?? viewModel.record.tcpMetrics
    }

    private var clientEndpoint: FlowEndpoint? {
        viewModel.analysis?.clientEndpoint ?? viewModel.record.clientEndpoint
    }

    private var serverEndpoint: FlowEndpoint? {
        viewModel.analysis?.serverEndpoint ?? viewModel.record.serverEndpoint
    }

    private var handshake: TCPHandshakeSummary? {
        viewModel.analysis?.handshake ?? viewModel.record.tcpHandshake
    }

    private var termination: TCPTerminationSummary? {
        viewModel.analysis?.termination ?? viewModel.record.tcpTermination
    }

    private var connectionState: FlowConnectionState {
        viewModel.analysis?.state ?? viewModel.record.connectionState
    }

    private var summarySection: some View {
        Section {
            LabeledContent("Source") {
                Text("\(activeRecord.sourceIP):\(activeRecord.sourcePort)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Destination") {
                Text("\(activeRecord.destinationIP):\(activeRecord.destinationPort)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Role Guess") {
                Text(roleGuessText)
            }
            LabeledContent("State") {
                Text(connectionState.rawValue.capitalized)
            }
            LabeledContent("Duration") {
                Text(durationText ?? "—")
            }
            LabeledContent("Captured") {
                Text(viewModel.analysis == nil ? "Live (aggregates)" : "From PCAP")
            }
        } header: {
            Text("Summary")
        }
    }

    private var protocolSection: some View {
        Section {
            LabeledContent("Transport", value: activeRecord.transport.rawValue.uppercased())
            if !activeRecord.protocolHints.isEmpty {
                LabeledContent("Protocol Hints", value: activeRecord.protocolHints.map(\.rawValue).joined(separator: ", "))
            }
            if let sni = activeRecord.tlsSNI {
                LabeledContent("TLS SNI", value: sni)
            }
            if let alpn = activeRecord.alpn, !alpn.isEmpty {
                LabeledContent("ALPN", value: alpn.joined(separator: ", "))
            }
        } header: {
            Text("Protocol Details")
        }
    }

    private var handshakeSection: some View {
        Section {
            if let handshake {
                LabeledContent("SYN") {
                    Text(formatTimestamp(handshake.synTime))
                }
                LabeledContent("SYN-ACK") {
                    Text(formatTimestamp(handshake.synAckTime))
                }
                LabeledContent("ACK") {
                    Text(formatTimestamp(handshake.ackTime))
                }
                if let synRtt = handshake.synRtt {
                    LabeledContent("SYN RTT") {
                        Text(String(format: "%.1f ms", synRtt * 1000))
                    }
                }
                if let options = handshake.clientOptions {
                    LabeledContent("Client Options") {
                        Text(formatOptions(options))
                            .font(.caption)
                    }
                }
                if let options = handshake.serverOptions {
                    LabeledContent("Server Options") {
                        Text(formatOptions(options))
                            .font(.caption)
                    }
                }
            } else {
                Text("No handshake data captured.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Handshake")
        } footer: {
            Text("RTT is estimated from ACK timing and can be biased by delayed ACK or app behavior.")
        }
    }

    private var terminationSection: some View {
        Section {
            if let termination {
                LabeledContent("FIN (Client)") {
                    Text(formatTimestamp(termination.finFromClientTime))
                }
                LabeledContent("FIN (Server)") {
                    Text(formatTimestamp(termination.finFromServerTime))
                }
                LabeledContent("RST (Client)") {
                    Text(formatTimestamp(termination.rstFromClientTime))
                }
                LabeledContent("RST (Server)") {
                    Text(formatTimestamp(termination.rstFromServerTime))
                }
            } else {
                Text("No termination events captured.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Termination")
        }
    }

    private var metricsSection: some View {
        Section {
            if let metrics = activeMetrics {
                metricsGrid(title: leftDirectionTitle, stats: metrics.clientToServer)
                metricsGrid(title: rightDirectionTitle, stats: metrics.serverToClient)
            } else {
                Text("No TCP metrics recorded.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Directional Health")
        }
    }

    private var graphsSection: some View {
        Section {
            if let metrics = activeMetrics {
                if !metrics.seqClient.isEmpty || !metrics.seqServer.isEmpty {
                    SequenceChartView(
                        clientSamples: metrics.seqClient,
                        serverSamples: metrics.seqServer,
                        clientLabel: leftDirectionTitle,
                        serverLabel: rightDirectionTitle
                    )
                }
                if !metrics.throughputClient.isEmpty || !metrics.throughputServer.isEmpty {
                    ThroughputChartView(
                        clientSamples: metrics.throughputClient,
                        serverSamples: metrics.throughputServer,
                        clientLabel: leftDirectionTitle,
                        serverLabel: rightDirectionTitle
                    )
                }
                if !metrics.rttSamples.isEmpty {
                    RTTChartView(samples: metrics.rttSamples)
                }
            } else {
                Text("No graph data available.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Graphs")
        }
    }

    private var anomaliesSection: some View {
        Section {
            if anomalies.isEmpty {
                Text("No anomalies detected.")
                    .foregroundStyle(.secondary)
            } else {
                FlowBadgeGrid(badges: anomalies)
            }
        } header: {
            Text("Anomalies")
        }
    }

    private var streamSection: some View {
        Section {
            if let analysis = viewModel.analysis {
                NavigationLink("View Reassembled Stream") {
                    TCPStreamView(
                        clientStream: analysis.streamClientToServer,
                        serverStream: analysis.streamServerToClient,
                        clientLabel: leftDirectionTitle,
                        serverLabel: rightDirectionTitle
                    )
                }
            } else {
                Text("Load from PCAP to view reassembled stream.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("TCP Stream")
        }
    }

    private var packetListSection: some View {
        Section {
            if let packets = viewModel.analysis?.packets, !packets.isEmpty {
                ForEach(packets) { packet in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(packet.direction == .clientToServer || packet.direction == .sourceToDestination ? leftDirectionTitle : rightDirectionTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(packet.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Seq \(packet.sequence) Ack \(packet.acknowledgment)")
                                .font(.system(.caption, design: .monospaced))
                            Text("Len \(packet.length) Win \(packet.window)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Load from PCAP to view packets.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Packet List (Recent)")
        }
    }

    private var captureNoteSection: some View {
        Section {
            Text("Capture point: TUN (L3). Packet timing and loss are inferred from user-space capture and may differ from on-the-wire behavior.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var durationText: String? {
        let diff = activeRecord.lastSeen.timeIntervalSince(activeRecord.startTime)
        guard diff >= 0 else { return nil }
        if diff < 1 { return "< 1s" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: diff)
    }

    private var roleGuessText: String {
        if let client = clientEndpoint, let server = serverEndpoint {
            return "\(client.ip):\(client.port) (client) → \(server.ip):\(server.port) (server)"
        }
        return "Unknown (SYN initiator not observed)"
    }

    private var leftDirectionTitle: String {
        if let client = clientEndpoint {
            return "Client → Server (\(client.ip))"
        }
        return "Source → Destination"
    }

    private var rightDirectionTitle: String {
        if let server = serverEndpoint {
            return "Server → Client (\(server.ip))"
        }
        return "Destination → Source"
    }

    private var anomalies: [String] {
        var result: [String] = []
        if let handshake, handshake.ackTime == nil, handshake.synTime != nil {
            result.append("Handshake incomplete")
        }
        if connectionState == .reset {
            if let termination, termination.rstFromServerTime != nil {
                result.append("RST by server")
            } else if let termination, termination.rstFromClientTime != nil {
                result.append("RST by client")
            } else {
                result.append("Connection reset")
            }
        }
        if let metrics = activeMetrics {
            if metrics.clientToServer.retransmissions > 3 || metrics.serverToClient.retransmissions > 3 {
                result.append("High retransmissions")
            }
            if metrics.clientToServer.zeroWindowEvents > 0 || metrics.serverToClient.zeroWindowEvents > 0 {
                result.append("Zero window events")
            }
            if metrics.clientToServer.outOfOrder > 5 || metrics.serverToClient.outOfOrder > 5 {
                result.append("Out-of-order heavy")
            }
        }
        return result
    }

    private func formatTimestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func formatOptions(_ options: TCPOptionSummary) -> String {
        var parts: [String] = []
        if let mss = options.mss {
            parts.append("MSS \(mss)")
        }
        if let ws = options.windowScale {
            parts.append("WS \(ws)")
        }
        if options.sackPermitted {
            parts.append("SACK")
        }
        if options.timestampsPermitted {
            parts.append("TS")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " • ")
    }

    private func metricsGrid(title: String, stats: FlowDirectionalStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metricCell("Bytes", value: ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .file))
                metricCell("Packets", value: "\(stats.packets)")
                metricCell("Retrans", value: "\(stats.retransmissions)")
                metricCell("Dup ACK", value: "\(stats.duplicateAcks)")
                metricCell("Out-of-Order", value: "\(stats.outOfOrder)")
                metricCell("Zero Window", value: "\(stats.zeroWindowEvents)")
                metricCell("Win Min", value: stats.windowMin.map { "\($0)" } ?? "—")
                metricCell("Win Avg", value: stats.windowAverage.map { "\($0)" } ?? "—")
            }
        }
        .padding(.vertical, 4)
    }

    private func metricCell(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }
}

private struct FlowBadgeGrid: View {
    let badges: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .cornerRadius(8)
            }
        }
    }
}

private struct SequenceChartView: View {
    let clientSamples: [FlowSeqSample]
    let serverSamples: [FlowSeqSample]
    let clientLabel: String
    let serverLabel: String

    var body: some View {
        Chart {
            ForEach(clientSamples.indices, id: \.self) { index in
                let sample = clientSamples[index]
                LineMark(
                    x: .value("Time", Date(timeIntervalSince1970: sample.timestamp)),
                    y: .value("Seq", sample.sequence)
                )
                .foregroundStyle(.blue)
                .lineStyle(.init(lineWidth: 2))
            }
            ForEach(serverSamples.indices, id: \.self) { index in
                let sample = serverSamples[index]
                LineMark(
                    x: .value("Time", Date(timeIntervalSince1970: sample.timestamp)),
                    y: .value("Seq", sample.sequence)
                )
                .foregroundStyle(.green)
                .lineStyle(.init(lineWidth: 2))
            }
        }
        .frame(height: 200)
        .chartYAxisLabel("Sequence")
        .chartLegend(.visible)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clientLabel).font(.caption2).foregroundStyle(.blue)
                Text(serverLabel).font(.caption2).foregroundStyle(.green)
            }
            .padding(8)
        }
    }
}

private struct ThroughputChartView: View {
    let clientSamples: [FlowTimeSeriesSample]
    let serverSamples: [FlowTimeSeriesSample]
    let clientLabel: String
    let serverLabel: String

    var body: some View {
        Chart {
            ForEach(clientSamples.indices, id: \.self) { index in
                let sample = clientSamples[index]
                LineMark(
                    x: .value("Time", Date(timeIntervalSince1970: sample.timestamp)),
                    y: .value("Bytes/s", sample.value)
                )
                .foregroundStyle(.blue)
            }
            ForEach(serverSamples.indices, id: \.self) { index in
                let sample = serverSamples[index]
                LineMark(
                    x: .value("Time", Date(timeIntervalSince1970: sample.timestamp)),
                    y: .value("Bytes/s", sample.value)
                )
                .foregroundStyle(.green)
            }
        }
        .frame(height: 200)
        .chartYAxisLabel("Bytes/s")
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clientLabel).font(.caption2).foregroundStyle(.blue)
                Text(serverLabel).font(.caption2).foregroundStyle(.green)
            }
            .padding(8)
        }
    }
}

private struct RTTChartView: View {
    let samples: [FlowRTTSample]

    var body: some View {
        Chart {
            ForEach(samples.indices, id: \.self) { index in
                let sample = samples[index]
                PointMark(
                    x: .value("Time", Date(timeIntervalSince1970: sample.timestamp)),
                    y: .value("RTT", sample.rttMillis)
                )
                .foregroundStyle(sample.direction == .clientToServer || sample.direction == .sourceToDestination ? .blue : .green)
            }
        }
        .frame(height: 160)
        .chartYAxisLabel("RTT (ms)")
    }
}

private struct TCPStreamView: View {
    let clientStream: Data
    let serverStream: Data
    let clientLabel: String
    let serverLabel: String

    @State private var direction: StreamDirection = .client
    @State private var viewMode: StreamViewMode = .text

    private enum StreamDirection: String, CaseIterable {
        case client = "Client → Server"
        case server = "Server → Client"
    }

    private enum StreamViewMode: String, CaseIterable {
        case text = "Text"
        case hex = "Hex"
    }

    var body: some View {
        VStack {
            Picker("Direction", selection: $direction) {
                Text(clientLabel).tag(StreamDirection.client)
                Text(serverLabel).tag(StreamDirection.server)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Picker("View Mode", selection: $viewMode) {
                ForEach(StreamViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            let data = direction == .client ? clientStream : serverStream
            let content = viewMode == .text
                ? (BodyStorage.decodeText(from: data) ?? String(decoding: data, as: UTF8.self))
                : hexDump(data)
            CodeViewerView(code: content, language: .plainText)
        }
        .navigationTitle("TCP Stream")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hexDump(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let bytes = [UInt8](data)
        var lines: [String] = []
        let lineLength = 16
        for index in stride(from: 0, to: bytes.count, by: lineLength) {
            let slice = bytes[index ..< min(index + lineLength, bytes.count)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = slice.map { byte -> String in
                if byte >= 32 && byte <= 126 {
                    return String(UnicodeScalar(byte))
                }
                return "."
            }.joined()
            lines.append(String(format: "%04x  %@  %@", index, hex.padding(toLength: 3 * lineLength - 1, withPad: " ", startingAt: 0), ascii))
        }
        return lines.joined(separator: "\n")
    }
}
