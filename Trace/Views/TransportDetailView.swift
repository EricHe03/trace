//
//  TransportDetailView.swift
//  Trace
//
//  Created by Codex on 2026/02/24.
//

import SwiftUI
import TraceCore
import TraceUI

struct TransportDetailView: View {
    let request: TransportRequest

    private var payloadData: Data? {
        request.payload.getData()
    }

    private var payloadText: String {
        guard let payloadData else { return "" }
        if let decoded = BodyStorage.decodeText(from: payloadData, charset: request.payload.getCharset()) {
            return decoded
        }
        return "Binary payload (\(payloadData.count) bytes). Switch Body Inspector to Hex for full bytes."
    }

    private var payloadContentType: String {
        guard let payloadData else { return "application/octet-stream" }
        if BodyStorage.decodeText(from: payloadData, charset: request.payload.getCharset()) != nil {
            return "text/plain"
        }
        return "application/octet-stream"
    }

    private var payloadSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(request.payloadBytes))
    }

    private var capturedPayloadSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(request.payload.capturedSize))
    }

    var body: some View {
        List {
            summarySection
            payloadSection
            packetMetadataSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Transport Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summarySection: some View {
        Section("Summary") {
            LabeledContent("Protocol", value: request.applicationProtocol.displayName)
            LabeledContent("Transport", value: request.transport.rawValue.uppercased())
            LabeledContent("Source", value: "\(request.sourceIP):\(request.sourcePort)")
            LabeledContent("Destination", value: "\(request.destinationIP):\(request.destinationPort)")
            LabeledContent("Timestamp") {
                Text(request.timestamp.formatted(date: .numeric, time: .standard))
            }
            LabeledContent("Payload (wire)", value: payloadSizeText)
            LabeledContent("Payload (captured)", value: capturedPayloadSizeText)
            if request.payload.isTruncated {
                LabeledContent("Capture", value: "Truncated at configured cap")
            }
            LabeledContent("Parser", value: parserOutcomeDescription(request.parserOutcome))
            if let summary = request.summary, !summary.isEmpty {
                LabeledContent("Summary", value: summary)
            }
            LabeledContent("Flow Key", value: request.flowKey)
        }
    }

    @ViewBuilder
    private var payloadSection: some View {
        Section("Payload") {
            BodyInspectorView(
                title: "Payload",
                content: payloadText,
                contentType: payloadContentType,
                rawData: payloadData,
                fileName: nil,
                totalSize: request.payload.totalSize
            )
            if request.payload.isTruncated {
                Text("Payload exceeds the configured capture cap. Only captured bytes are available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var packetMetadataSection: some View {
        Section("Packet Metadata") {
            LabeledContent("IP Version", value: "\(request.ipVersion)")
            LabeledContent("Protocol Number", value: "\(request.protocolNumber)")
            LabeledContent("Header Length", value: "\(request.ipHeaderLength)")
            LabeledContent("Total Length", value: "\(request.totalLength)")
            LabeledContent("Hop Limit", value: "\(request.hopLimit)")
            LabeledContent("Fragment Offset", value: "\(request.fragmentOffset)")
            LabeledContent("More Fragments", value: request.moreFragments ? "Yes" : "No")
        }
    }

    private func parserOutcomeDescription(_ outcome: TransportParserOutcome) -> String {
        switch outcome {
        case .parsed:
            return "Parsed"
        case .fallbackSignatureOnly:
            return "Port Signature Fallback"
        case .fallbackUnknown:
            return "Unknown"
        }
    }
}
