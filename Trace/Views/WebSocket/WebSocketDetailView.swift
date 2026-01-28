//
//  WebSocketDetailView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct WebSocketDetailView: View {
    let connection: WebSocketConnection

    @State private var searchText = ""
    @State private var filterDirection: WebSocketDirection?
    @State private var filterMessageType: WebSocketMessageType?
    @State private var selectedMessage: WebSocketMessage?
    @State private var showingFilters = false

    var body: some View {
        List {
            // Connection Info Section
            Section("Connection") {
                LabeledContent("URL", value: connection.url)
                LabeledContent("Status", value: connection.status.displayName)
                LabeledContent("Started", value: connection.startTime, format: .dateTime)

                if let endTime = connection.endTime {
                    LabeledContent("Ended", value: endTime, format: .dateTime)
                }

                if let duration = connection.duration {
                    LabeledContent("Duration", value: formattedDuration(duration))
                }

                if let closeCode = connection.closeCode {
                    LabeledContent("Close Code", value: String(closeCode))
                }

                if let closeReason = connection.closeReason {
                    LabeledContent("Close Reason", value: closeReason)
                }
            }

            // Statistics Section
            Section("Statistics") {
                LabeledContent("Total Messages", value: String(connection.messageCount))
                LabeledContent("Sent", value: String(connection.sentMessageCount))
                LabeledContent("Received", value: String(connection.receivedMessageCount))
            }

            // Messages Section
            Section {
                if filteredMessages.isEmpty {
                    messagesEmptyState
                } else {
                    ForEach(filteredMessages) { message in
                        Button {
                            selectedMessage = message
                        } label: {
                            WebSocketMessageRow(message: message)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } header: {
                HStack {
                    Text("Messages")
                    Spacer()
                    if hasActiveFilters {
                        Text("\(filteredMessages.count) of \(connection.messages.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("WebSocket Details")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search messages")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Label("Filter", systemImage: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hasActiveFilters ? DesignSystem.Colors.accent : .primary)
                }
            }
        }
        .sheet(item: $selectedMessage) { message in
            WebSocketMessageDetailView(message: message)
        }
        .sheet(isPresented: $showingFilters) {
            WebSocketMessageFiltersView(
                filterDirection: $filterDirection,
                filterMessageType: $filterMessageType,
                hasActiveFilters: hasActiveFilters,
                onClear: clearFilters
            )
        }
    }

    private var filteredMessages: [WebSocketMessage] {
        var filtered = connection.messages

        // Apply direction filter
        if let direction = filterDirection {
            filtered = filtered.filter { $0.direction == direction }
        }

        // Apply message type filter
        if let type = filterMessageType {
            filtered = filtered.filter { $0.messageType == type }
        }

        // Apply search filter
        if !searchText.isEmpty {
            filtered = filtered.filter { message in
                if let text = message.textPayload {
                    return text.localizedCaseInsensitiveContains(searchText)
                }
                return message.hexPayload.localizedCaseInsensitiveContains(searchText)
            }
        }

        return filtered
    }

    private var hasActiveFilters: Bool {
        filterDirection != nil || filterMessageType != nil
    }

    @ViewBuilder
    private var messagesEmptyState: some View {
        if connection.messages.isEmpty {
            TraceContentUnavailableView(
                "No Messages",
                systemImage: "message",
                description: Text("Messages will appear here as they are sent and received")
            )
            .listRowBackground(Color.clear)
        } else {
            // Filters resulted in no messages
            TraceContentUnavailableView(
                "No Messages Match",
                systemImage: "magnifyingglass",
                description: Text("Try adjusting your search or filters")
            )
            .listRowBackground(Color.clear)
        }
    }

    private func clearFilters() {
        filterDirection = nil
        filterMessageType = nil
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        DesignSystem.formattedDuration(duration)
    }
}

struct WebSocketMessageRow: View {
    let message: WebSocketMessage

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.smPlus) {
            HStack {
                // Direction indicator
                Text(message.direction.symbol)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.smPlus)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(directionColor(message.direction.color))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))

                // Message type
                Text(message.messageType.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(typeColor(message.messageType))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))

                Spacer()

                // Size
                Text(message.sizeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Preview
            Text(message.preview)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(.secondary)

            // Timestamp
            Text(message.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    private func directionColor(_ status: StatusColor) -> Color {
        switch status {
        case .success: DesignSystem.Colors.success
        case .redirect: DesignSystem.Colors.accent
        case .clientError: DesignSystem.Colors.warning
        case .serverError: DesignSystem.Colors.danger
        case .info: DesignSystem.Colors.info
        case .warning: DesignSystem.Colors.favorite
        case .unknown: DesignSystem.Colors.muted
        }
    }

    private func typeColor(_ type: WebSocketMessageType) -> Color {
        switch type {
        case .text: DesignSystem.Colors.accent
        case .binary: DesignSystem.Colors.accentAlt
        case .ping, .pong: DesignSystem.Colors.muted
        case .close: DesignSystem.Colors.danger
        case .continuation: DesignSystem.Colors.warning
        }
    }
}

struct WebSocketMessageDetailView: View {
    let message: WebSocketMessage
    @Environment(\.dismiss) private var dismiss
    @State private var viewMode: ViewMode = .text

    enum ViewMode: String, CaseIterable {
        case text = "Text"
        case hex = "Hex"
        case raw = "Raw"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    // Metadata
                    GroupBox("Metadata") {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            HStack {
                                Text("Direction:")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(message.direction.displayName)
                                    .fontWeight(.medium)
                            }

                            Divider()

                            HStack {
                                Text("Type:")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(message.messageType.displayName)
                                    .fontWeight(.medium)
                            }

                            Divider()

                            HStack {
                                Text("Size:")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(message.sizeString)
                                    .fontWeight(.medium)
                            }

                            Divider()

                            HStack {
                                Text("Timestamp:")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(message.timestamp, format: .dateTime)
                                    .fontWeight(.medium)
                            }

                            if !message.isFinal {
                                Divider()
                                HStack {
                                    Text("Final Frame:")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("No (Fragmented)")
                                        .fontWeight(.medium)
                                        .foregroundStyle(DesignSystem.Colors.warning)
                                }
                            }

                            if message.isMasked {
                                Divider()
                                HStack {
                                    Text("Masked:")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Yes")
                                        .fontWeight(.medium)
                                }
                            }
                        }
                    }

                    // Payload
                    GroupBox("Payload") {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                            // View mode picker
                            Picker("View Mode", selection: $viewMode) {
                                ForEach(ViewMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Divider()

                            // Content based on view mode
                            switch viewMode {
                            case .text:
                                if let text = message.textPayload {
                                    Text(text)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                } else {
                                    Text("Not displayable as text")
                                        .foregroundStyle(.secondary)
                                        .italic()
                                }

                            case .hex:
                                Text(message.hexPayload)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)

                            case .raw:
                                Text(String(data: message.payload, encoding: .utf8) ?? "Binary data")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Message Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct WebSocketMessageFiltersView: View {
    @Binding var filterDirection: WebSocketDirection?
    @Binding var filterMessageType: WebSocketMessageType?
    let hasActiveFilters: Bool
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Direction") {
                    Picker("Filter by Direction", selection: $filterDirection) {
                        Text("All").tag(WebSocketDirection?.none)
                        ForEach(WebSocketDirection.allCases, id: \.self) { direction in
                            Text(direction.displayName).tag(WebSocketDirection?.some(direction))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Message Type") {
                    Picker("Filter by Type", selection: $filterMessageType) {
                        Text("All").tag(WebSocketMessageType?.none)
                        ForEach(WebSocketMessageType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(WebSocketMessageType?.some(type))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        onClear()
                    }
                    .disabled(!hasActiveFilters)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        WebSocketDetailView(
            connection: WebSocketConnection(
                url: "wss://example.com/socket",
                messages: [
                    WebSocketMessage(
                        direction: .sent,
                        payload: "Hello, WebSocket!".data(using: .utf8)!,
                        messageType: .text
                    ),
                    WebSocketMessage(
                        direction: .received,
                        payload: "Hello, Client!".data(using: .utf8)!,
                        messageType: .text
                    )
                ],
                status: .open
            )
        )
    }
}
