//
//  DNSDetailView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct DNSDetailView: View {
    let message: DNSMessage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                if !message.questions.isEmpty {
                    questionsSection
                }

                if !message.answers.isEmpty {
                    answersSection
                }

                if !message.authorities.isEmpty {
                    authoritiesSection
                }

                if !message.additionals.isEmpty {
                    additionalsSection
                }

                networkInfoSection

                if message.responseTime != nil {
                    timingSection
                }
            }
            .padding()
        }
        .navigationTitle("DNS Details")
        .toolbar {
            toolbarContent
        }
    }

    // MARK: - Header Section

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: message.statusIcon)
                    .font(.title)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading) {
                    Text(message.queryDomain ?? "Unknown")
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack {
                        Text(message.isResponse ? "Response" : "Query")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if message.isResponse {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(message.responseCode.displayName)
                                .font(.subheadline)
                                .foregroundStyle(message.isSuccessful ? .green : .red)
                        }
                    }
                }

                Spacer()
            }

            Divider()

            GroupBox("DNS Header") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Transaction ID:")
                            .foregroundStyle(.secondary)
                        Text(String(format: "0x%04X", message.transactionId))
                            .font(.system(.body, design: .monospaced))
                    }

                    GridRow {
                        Text("Opcode:")
                            .foregroundStyle(.secondary)
                        Text(message.opcode.displayName)
                    }

                    GridRow {
                        Text("Flags:")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if message.isAuthoritative {
                                flagBadge("AA", label: "Authoritative answer", color: DesignSystem.Colors.info)
                            }
                            if message.isTruncated {
                                flagBadge("TC", label: "Truncated", color: DesignSystem.Colors.warning)
                            }
                            if message.recursionDesired {
                                flagBadge("RD", label: "Recursion desired", color: DesignSystem.Colors.success)
                            }
                            if message.recursionAvailable {
                                flagBadge("RA", label: "Recursion available", color: DesignSystem.Colors.success)
                            }
                        }
                    }

                    GridRow {
                        Text("Message Size:")
                            .foregroundStyle(.secondary)
                        Text("\(message.messageSize) bytes")
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Questions Section

    @ViewBuilder
    private var questionsSection: some View {
        GroupBox("Questions (\(message.questions.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.questions) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.name)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)

                        HStack {
                            Text("Type:")
                                .foregroundStyle(.secondary)
                            Text(question.type.displayName)
                                .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                                .padding(.vertical, DesignSystem.Badge.verticalPadding)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(DesignSystem.Badge.cornerRadius)

                            Text("Class:")
                                .foregroundStyle(.secondary)
                            Text(question.class.displayName)
                        }
                        .font(.caption)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackgroundColor)
                    .cornerRadius(DesignSystem.CornerRadius.md)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Answers Section

    @ViewBuilder
    private var answersSection: some View {
        GroupBox("Answers (\(message.answers.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.answers) { record in
                    resourceRecordView(record)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Authorities Section

    @ViewBuilder
    private var authoritiesSection: some View {
        GroupBox("Authorities (\(message.authorities.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.authorities) { record in
                    resourceRecordView(record)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Additionals Section

    @ViewBuilder
    private var additionalsSection: some View {
        GroupBox("Additional Records (\(message.additionals.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.additionals) { record in
                    resourceRecordView(record)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Network Info Section

    @ViewBuilder
    private var networkInfoSection: some View {
        GroupBox("Network Information") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Source:")
                        .foregroundStyle(.secondary)
                    Text("\(message.sourceIP):\(message.sourcePort)")
                        .font(.system(.body, design: .monospaced))
                }

                GridRow {
                    Text("Destination:")
                        .foregroundStyle(.secondary)
                    Text("\(message.destIP):\(message.destPort)")
                        .font(.system(.body, design: .monospaced))
                }

                GridRow {
                    Text("Timestamp:")
                        .foregroundStyle(.secondary)
                    timestampText
                }
            }
            .padding(8)
        }
    }

    // MARK: - Timing Section

    @ViewBuilder
    private var timingSection: some View {
        if let responseTime = message.responseTime {
            GroupBox("Timing") {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.purple)
                    Text("Response Time:")
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f ms", responseTime * 1000))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)

                    Spacer()

                    // Performance indicator label based on response time.
                    if responseTime < 0.050 {
                        Text("Fast")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(DesignSystem.CornerRadius.sm)
                    } else if responseTime < 0.200 {
                        Text("Normal")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(DesignSystem.CornerRadius.sm)
                    } else {
                        Text("Slow")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(Color.red.opacity(0.2))
                            .cornerRadius(DesignSystem.CornerRadius.sm)
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Resource Record View

    @ViewBuilder
    private func resourceRecordView(_ record: DNSResourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)

                Spacer()

                Text("\(record.ttl)s TTL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(record.type.displayName)
                    .font(.caption)
                    .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                    .padding(.vertical, DesignSystem.Badge.verticalPadding)
                    .background(recordTypeColor(record.type))
                    .cornerRadius(DesignSystem.Badge.cornerRadius)

                Text(record.class.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(record.dataString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.top, 4)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackgroundColor)
        .cornerRadius(DesignSystem.CornerRadius.md)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                copyToClipboard()
            } label: {
                Label("Copy Details", systemImage: "doc.on.doc")
            }
            .help("Copy DNS details to clipboard")

            if let domain = message.queryDomain {
                Button {
                    setPasteboardString(domain)
                } label: {
                    Label("Copy Domain", systemImage: "doc.on.doc.fill")
                }
                .help("Copy domain name")
            }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if !message.isResponse {
            return DesignSystem.Colors.info
        }
        return message.isSuccessful ? DesignSystem.Colors.success : DesignSystem.Colors.danger
    }

    private func flagBadge(_ text: String, label: String, color: Color) -> some View {
        Text(text)
            .font(DesignSystem.Badge.font)
            .fontWeight(DesignSystem.Badge.fontWeight)
            .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
            .padding(.vertical, DesignSystem.Badge.verticalPadding)
            .background(color.opacity(0.2))
            .cornerRadius(DesignSystem.Badge.cornerRadius)
            .accessibilityLabel(label)
    }

    private func recordTypeColor(_ type: DNSRecordType) -> Color {
        switch type {
        case .a, .aaaa:
            DesignSystem.Colors.success.opacity(0.2)
        case .cname:
            DesignSystem.Colors.info.opacity(0.2)
        case .mx:
            DesignSystem.Colors.favorite.opacity(0.2)
        case .ns:
            DesignSystem.Colors.warning.opacity(0.2)
        case .txt:
            DesignSystem.Colors.accentAlt.opacity(0.2)
        default:
            DesignSystem.Colors.muted.opacity(0.2)
        }
    }

    private var timestampText: Text {
        Text(message.timestamp, style: .date) + Text(" ") + Text(message.timestamp, style: .time)
    }

    private var cardBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private func copyToClipboard() {
        var text = "DNS \(message.isResponse ? "Response" : "Query")\n"
        text += "Domain: \(message.queryDomain ?? "Unknown")\n"
        text += "Transaction ID: \(String(format: "0x%04X", message.transactionId))\n"
        text += "Type: \(message.queryType?.displayName ?? "Unknown")\n"

        if message.isResponse {
            text += "Response Code: \(message.responseCode.displayName)\n"
            if let responseTime = message.responseTime {
                text += "Response Time: \(String(format: "%.2f ms", responseTime * 1000))\n"
            }
            text += "Resolved IPs: \(message.resolvedIPs.joined(separator: ", "))\n"
        }

        text += "\nSource: \(message.sourceIP):\(message.sourcePort)\n"
        text += "Destination: \(message.destIP):\(message.destPort)\n"

        setPasteboardString(text)
    }

    private func setPasteboardString(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DNSDetailView(message: .sampleResponse)
    }
}
