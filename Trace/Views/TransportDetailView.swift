//
//  TransportDetailView.swift
//  Trace
//
//  Created by Codex on 2026/02/24.
//

import Foundation
import SwiftUI
import TraceCore
import TraceUI

struct TransportDetailView: View {
    let request: TransportRequest

    private var payloadData: Data? {
        request.payload.getData()
    }

    private var packetData: Data? {
        request.packet?.getData()
    }

    private var payloadIsLikelyBinary: Bool {
        guard let payloadData else { return false }
        return ContentSafety.isBinary(payloadData)
    }

    private var packetIsLikelyBinary: Bool {
        guard let packetData else { return false }
        return ContentSafety.isBinary(packetData)
    }

    private var payloadText: String {
        guard let payloadData else { return "" }
        if payloadIsLikelyBinary {
            return "Binary payload (\(payloadData.count) bytes). Auto view shows Hex by default."
        }
        if let decoded = BodyStorage.decodeText(from: payloadData, charset: request.payload.getCharset()) {
            return decoded
        }
        return "Payload could not be decoded as text. Auto view shows Hex by default."
    }

    private var packetText: String {
        guard let packetData else { return "" }
        if packetIsLikelyBinary {
            return "Binary packet (\(packetData.count) bytes). Auto view shows Hex by default."
        }
        if let decoded = BodyStorage.decodeText(from: packetData, charset: request.packet?.getCharset()) {
            return decoded
        }
        return "Packet could not be decoded as text. Auto view shows Hex by default."
    }

    private var payloadContentType: String {
        guard payloadData != nil else { return "application/octet-stream" }
        return payloadIsLikelyBinary ? "application/octet-stream" : "text/plain"
    }

    private var packetContentType: String {
        guard packetData != nil else { return "application/octet-stream" }
        return packetIsLikelyBinary ? "application/octet-stream" : "text/plain"
    }

    private var payloadSizeText: String {
        formattedByteCount(request.payloadBytes)
    }

    private var capturedPayloadSizeText: String {
        formattedByteCount(request.payload.capturedSize)
    }

    private var packetSizeText: String {
        let wireBytes = request.packetBytes ?? request.totalLength
        return formattedByteCount(wireBytes)
    }

    private var capturedPacketSizeText: String {
        guard let packet = request.packet else { return "Not captured" }
        return formattedByteCount(packet.capturedSize)
    }

    private var tcpFlagsText: String? {
        guard let flags = request.tcpFlags else { return nil }
        var names: [String] = []
        if flags & 0x02 != 0 { names.append("SYN") }
        if flags & 0x10 != 0 { names.append("ACK") }
        if flags & 0x01 != 0 { names.append("FIN") }
        if flags & 0x04 != 0 { names.append("RST") }
        if flags & 0x08 != 0 { names.append("PSH") }
        if flags & 0x20 != 0 { names.append("URG") }
        let named = names.isEmpty ? "none" : names.joined(separator: ", ")
        let hex = String(format: "%02X", Int(flags))
        return "0x\(hex) (\(named))"
    }

    var body: some View {
        List {
            summarySection
            wirePacketSection
            payloadSection
            packetMetadataSection
            transportHeaderSection
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
            LabeledContent("Packet (wire)", value: packetSizeText)
            LabeledContent("Packet (captured)", value: capturedPacketSizeText)
            LabeledContent("Payload (wire)", value: payloadSizeText)
            LabeledContent("Payload (captured)", value: capturedPayloadSizeText)
            if request.isPacketTruncated {
                LabeledContent("Packet Capture", value: "Truncated at configured cap")
            }
            if request.payload.isTruncated {
                LabeledContent("Payload Capture", value: "Truncated at configured cap")
            }
            LabeledContent("Parser", value: parserOutcomeDescription(request.parserOutcome))
            if let summary = request.summary, !summary.isEmpty {
                LabeledContent("Summary", value: summary)
            }
            LabeledContent("Flow Key", value: request.flowKey)
        }
    }

    @ViewBuilder
    private var wirePacketSection: some View {
        if request.packet != nil || request.packetBytes != nil {
            Section("Wire Packet") {
                BodyInspectorView(
                    title: "IP Packet",
                    content: packetText,
                    contentType: packetContentType,
                    rawData: packetData,
                    fileName: nil,
                    totalSize: request.packet?.totalSize ?? request.packetBytes
                )
                if request.isPacketTruncated {
                    Text("Packet capture exceeds the configured cap. Only captured bytes are available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    @ViewBuilder
    private var transportHeaderSection: some View {
        switch request.transport {
        case .tcp:
            Section("TCP Header") {
                if let sequence = request.tcpSequenceNumber {
                    LabeledContent("Sequence", value: "\(sequence)")
                }
                if let acknowledgment = request.tcpAcknowledgmentNumber {
                    LabeledContent("Acknowledgment", value: "\(acknowledgment)")
                }
                if let tcpFlagsText {
                    LabeledContent("Flags", value: tcpFlagsText)
                }
                if let windowSize = request.tcpWindowSize {
                    LabeledContent("Window Size", value: "\(windowSize)")
                }
                if let dataOffset = request.tcpDataOffset {
                    LabeledContent("Data Offset", value: "\(dataOffset)")
                }
                if let options = request.tcpOptions {
                    if let mss = options.maximumSegmentSize {
                        LabeledContent("MSS", value: "\(mss)")
                    }
                    if let windowScale = options.windowScale {
                        LabeledContent("Window Scale", value: "\(windowScale)")
                    }
                    if let sackPermitted = options.sackPermitted {
                        LabeledContent("SACK Permitted", value: sackPermitted ? "Yes" : "No")
                    }
                    if let timestamps = options.timestamps {
                        LabeledContent("TS Value", value: "\(timestamps.value)")
                        LabeledContent("TS Echo", value: "\(timestamps.echoReply)")
                    }
                }
            }
        case .udp:
            if let udpLength = request.udpDatagramLength {
                Section("UDP Header") {
                    LabeledContent("Datagram Length", value: "\(udpLength)")
                }
            }
        case .unknown:
            EmptyView()
        }
    }

    private func formattedByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
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
