//
//  OverviewSection.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct OverviewSection: View {
    let request: NetworkRequest

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            // TLS Passthrough / Pinning explanation (shown prominently at top)
            TLSPassthroughSection(request: request)

            SectionCard(title: "General") {
                InfoRow(label: "URL", value: request.url)
                Divider()
                InfoRow(label: "Method", value: request.method.rawValue)
                Divider()
                InfoRow(label: "Status Code", value: request.statusCodeText)
                Divider()
                InfoRow(label: "Duration", value: formattedDuration(request.duration))
                Divider()
                InfoRow(label: "Time", value: request.timestamp.formatted(date: .abbreviated, time: .standard))

                if let protocolVersion = request.protocolVersion {
                    Divider()
                    InfoRow(label: "Protocol", value: protocolVersion.displayName)
                }

                Divider()
                InfoRow(label: "Capture Path", value: request.capturePath.displayName)

                if let flowID = request.captureFlowID {
                    Divider()
                    InfoRow(label: "Capture Flow ID", value: "\(flowID)")
                }

                if let metadataVersion = request.captureMetadataVersion {
                    Divider()
                    InfoRow(label: "Capture Metadata Version", value: "v\(metadataVersion)")
                }

                if request.isSSE {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("Stream Type")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("Server-Sent Events (SSE)")
                                .font(.body)
                                .foregroundStyle(DesignSystem.Colors.accent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .accessibilityLabel("Server-sent events stream")
                    }
                }
            }

            // Connection Information
            connectionSection

            // Initiator Information
            if request.initiatorDisplayName != nil || request.initiatorStackTrace != nil {
                SectionCard(title: "Initiator") {
                    if let displayName = request.initiatorDisplayName {
                        InfoRow(label: "Framework", value: displayName)
                        Divider()
                    }

                    if let stackTrace = request.initiatorStackTrace {
                        StackTraceView(stackTrace: stackTrace)
                    }
                }
            }

            // Redirect Information
            if !request.redirectChain.isEmpty {
                SectionCard(title: request.redirectChain.count > 1 ? "Redirects" : "Redirect") {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Location")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(request.redirectChain) { redirect in
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                                if let statusCode = redirect.statusCode {
                                    Text("\(statusCode)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }

                                Text(redirect.location ?? redirect.toURL)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if request.statusColor == .redirect,
                      let locationURL = request.responseHeaders.first(where: { $0.key.lowercased() == "location" })?.value {
                SectionCard(title: "Redirect") {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Location")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(locationURL)
                            .font(.body)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // HTTP Fields
            if hasHTTPFields {
                SectionCard(title: "HTTP Fields") {
                    ForEach(Array(httpFieldSections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 {
                            Divider()
                        }
                        httpFieldView(section)
                    }
                }
            }

            // TLS Alerts
            if let tlsAlerts = request.tlsAlerts, !tlsAlerts.isEmpty {
                SectionCard(title: "TLS Alerts") {
                    ForEach(Array(tlsAlerts.enumerated()), id: \.element.id) { index, alert in
                        if index > 0 {
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            HStack {
                                Image(systemName: alert.level == .fatal ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(alert.level == .fatal ? DesignSystem.Colors.danger : DesignSystem.Colors.warning)
                                    .accessibilityHidden(true)
                                Text(alert.level.displayName)
                                    .font(.caption.bold())
                                    .foregroundStyle(alert.level == .fatal ? DesignSystem.Colors.danger : DesignSystem.Colors.warning)
                                Spacer()
                                Text(alert.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(alert.description.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // Advanced Timing Information
            if let timing = request.timingPhases {
                SectionCard(title: "Performance Timing") {
                    if let dns = timing.dnsLookup {
                        InfoRow(label: "DNS Lookup", value: String(format: "%.2f ms", dns * 1000))
                        Divider()
                    }

                    if let tcp = timing.tcpConnection {
                        InfoRow(label: "TCP Connection", value: String(format: "%.2f ms", tcp * 1000))
                        Divider()
                    }

                    if let tls = timing.tlsHandshake {
                        InfoRow(label: "TLS Handshake", value: String(format: "%.2f ms", tls * 1000))
                        Divider()
                    }

                    if let requestSent = timing.requestSent {
                        InfoRow(label: "Request Sent", value: String(format: "%.2f ms", requestSent * 1000))
                        Divider()
                    }

                    if let ttfb = timing.ttfb {
                        InfoRow(label: "Time to First Byte", value: String(format: "%.2f ms", ttfb * 1000))
                        Divider()
                    }

                    if let content = timing.contentDownload {
                        InfoRow(label: "Content Download", value: String(format: "%.2f ms", content * 1000))
                        Divider()
                    }

                    if let redirect = timing.redirectTime {
                        InfoRow(label: "Redirect Time", value: String(format: "%.2f ms", redirect * 1000))
                        Divider()
                    }

                    InfoRow(label: "Total Time", value: String(format: "%.2f ms", timing.total * 1000))
                }
            }

            // Transfer Sizes
            transferSection

            // TLS/Certificate Information with ALPN
            if let tlsInfo = request.tlsInfo {
                TLSDetailSection(tlsInfo: tlsInfo)
                    .padding(.horizontal)
            }

            // Timeline View
            if request.timingPhases != nil {
                RequestTimelineView(request: request)
                    .padding(.horizontal)
            }
        }
        .padding()
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        let hasRemote = request.remoteAddress != nil
        let hasLocal = request.localAddress != nil
        let hasFlags = request.isCellular || request.isExpensive || request.isConstrained
        let hasProxy = request.isProxyConnection

        if hasRemote || hasLocal || hasFlags || hasProxy {
            SectionCard(title: "Connection", systemImage: "network") {
                // Remote address + port
                if let remote = request.remoteAddress {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Remote")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                            Text(request.remotePort.map { "\(remote) : \($0)" } ?? remote)
                                .font(.body.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

                            if request.isConnectionReused {
                                connectionBadge("Reused", color: DesignSystem.Colors.success)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if hasLocal || hasFlags || hasProxy {
                        Divider()
                    }
                }

                // Local address + port
                if let local = request.localAddress {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Local")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(request.localPort.map { "\(local) : \($0)" } ?? local)
                            .font(.body.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if hasFlags || hasProxy {
                        Divider()
                    }
                }

                // Network path flags (cellular / expensive / constrained)
                if hasFlags {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if request.isCellular {
                            connectionBadge("Cellular", color: DesignSystem.Colors.warning)
                        }
                        if request.isExpensive {
                            connectionBadge("Expensive", color: DesignSystem.Colors.warning)
                        }
                        if request.isConstrained {
                            connectionBadge("Low Data Mode", color: DesignSystem.Colors.warning)
                        }
                        Spacer()
                    }

                    if hasProxy {
                        Divider()
                    }
                }

                // Proxy
                if hasProxy {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.caption)
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("Via Proxy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Request routed through a proxy")
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func connectionBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(DesignSystem.Badge.font)
            .fontWeight(DesignSystem.Badge.fontWeight)
            .foregroundStyle(.white)
            .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
            .padding(.vertical, DesignSystem.Badge.verticalPadding)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius, style: .continuous))
    }

    // MARK: - Transfer Section

    @ViewBuilder
    private var transferSection: some View {
        let reqH = request.requestHeadersSize
        let resH = request.responseHeadersSize
        let reqB = request.requestBodyTransferSize
        let resDecoded = request.responseBodyDecodedSize
        let resWire = request.responseBodyTransferSize

        if reqH != nil || resH != nil || reqB != nil || resDecoded != nil || resWire != nil {
            SectionCard(title: "Transfer", systemImage: "arrow.up.arrow.down") {
                let rows: [(String, String?, Color)] = [
                    ("Request Headers", reqH.map { DesignSystem.formattedBytes($0) }, .primary),
                    ("Response Headers", resH.map { DesignSystem.formattedBytes($0) }, .primary),
                    ("Request Body", reqB.map { DesignSystem.formattedBytes($0) }, .primary),
                    ("Response Body", resDecoded.map { DesignSystem.formattedBytes($0) }, .primary),
                ].filter { $0.1 != nil }

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    transferRow(label: row.0, value: row.1 ?? "", color: row.2)
                }

                // On Wire + Savings (only when wire size differs from decoded)
                if let wire = resWire, let decoded = resDecoded, wire < decoded {
                    Divider()
                    transferRow(label: "On Wire", value: DesignSystem.formattedBytes(wire), color: .secondary)

                    let savings = Int((1.0 - Double(wire) / Double(decoded)) * 100)
                    Divider()
                    transferRow(label: "Compression Savings", value: "\(savings)%", color: DesignSystem.Colors.success)
                }
            }
        }
    }

    private func transferRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        DesignSystem.formattedDuration(duration)
    }

    private enum HTTPFieldSection: Identifiable {
        case userAgent(String)
        case contentType(String)
        case contentEncoding(String)
        case cacheControl(String)
        case authorization(String)
        case queryParameters([URLQueryItem])
        case requestCookies([TraceCore.HTTPCookie])
        case responseCookies([TraceCore.HTTPCookie])

        var id: String {
            switch self {
            case .userAgent:
                "userAgent"
            case .contentType:
                "contentType"
            case .contentEncoding:
                "contentEncoding"
            case .cacheControl:
                "cacheControl"
            case .authorization:
                "authorization"
            case .queryParameters:
                "queryParameters"
            case .requestCookies:
                "requestCookies"
            case .responseCookies:
                "responseCookies"
            }
        }
    }

    private var httpFieldSections: [HTTPFieldSection] {
        var sections: [HTTPFieldSection] = []

        if let userAgent = request.userAgent {
            sections.append(.userAgent(userAgent))
        }

        if let contentType = request.contentType {
            sections.append(.contentType(contentType))
        }

        if let contentEncoding = request.contentEncoding {
            sections.append(.contentEncoding(contentEncoding))
        }

        if let cacheControl = request.cacheControl {
            sections.append(.cacheControl(cacheControl))
        }

        if let authorization = request.authorization {
            sections.append(.authorization(authorization))
        }

        if let queryParams = request.queryParameters, !queryParams.isEmpty {
            sections.append(.queryParameters(queryParams))
        }

        if let cookies = request.requestCookies, !cookies.isEmpty {
            sections.append(.requestCookies(cookies))
        }

        if let cookies = request.responseCookies, !cookies.isEmpty {
            sections.append(.responseCookies(cookies))
        }

        return sections
    }

    @ViewBuilder
    private func httpFieldView(_ section: HTTPFieldSection) -> some View {
        switch section {
        case let .userAgent(userAgent):
            InfoRow(label: "User-Agent", value: userAgent)
        case let .contentType(contentType):
            InfoRow(label: "Content-Type", value: contentType)
        case let .contentEncoding(contentEncoding):
            InfoRow(label: "Content-Encoding", value: contentEncoding)
        case let .cacheControl(cacheControl):
            InfoRow(label: "Cache-Control", value: cacheControl)
        case let .authorization(authorization):
            InfoRow(label: "Authorization", value: maskAuthorizationHeader(authorization))
        case let .queryParameters(queryParams):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Query Parameters")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(queryParams, id: \.name) { param in
                    HStack(alignment: .top) {
                        Text(param.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("=")
                            .foregroundStyle(.tertiary)
                        Text(param.value ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .requestCookies(cookies):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Request Cookies")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(cookies.count) cookie(s)")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .responseCookies(cookies):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Set-Cookie")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(cookies) { cookie in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(cookie.name)=\(cookie.value)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)

                        HStack(spacing: 4) {
                            if let domain = cookie.domain {
                                Text("Domain: \(domain)")
                            }
                            if let path = cookie.path {
                                Text("Path: \(path)")
                            }
                            if cookie.secure {
                                Text("Secure")
                                    .foregroundStyle(DesignSystem.Colors.success)
                            }
                            if cookie.httpOnly {
                                Text("HttpOnly")
                                    .foregroundStyle(DesignSystem.Colors.success)
                            }
                            if let sameSite = cookie.sameSite {
                                Text("SameSite=\(sameSite.rawValue)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Check if the request has any HTTP fields to display
    private var hasHTTPFields: Bool {
        request.userAgent != nil ||
            request.contentType != nil ||
            request.contentEncoding != nil ||
            request.cacheControl != nil ||
            request.authorization != nil ||
            (request.queryParameters != nil && !request.queryParameters!.isEmpty) ||
            (request.requestCookies != nil && !request.requestCookies!.isEmpty) ||
            (request.responseCookies != nil && !request.responseCookies!.isEmpty)
    }

    /// Mask authorization header for security (show only auth type)
    private func maskAuthorizationHeader(_ auth: String) -> String {
        let components = auth.split(separator: " ", maxSplits: 1)
        guard components.count == 2 else { return auth }
        let authType = String(components[0])
        return "\(authType) [REDACTED]"
    }
}

// MARK: - Stack Trace View (Chrome DevTools Style)

struct StackTraceView: View {
    let stackTrace: String
    @State private var isExpanded = false

    private var stackFrames: [StackFrame] {
        stackTrace.split(separator: "\n").compactMap { line in
            StackFrame(rawLine: String(line))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Header with initiator indicator
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.accent)

                Text("Request Initiated By")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.accent)
                }
                .accessibilityLabel(isExpanded ? "Collapse call stack" : "Expand call stack")
            }
            .padding(.bottom, DesignSystem.Spacing.xs)

            if isExpanded {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(Array(stackFrames.enumerated()), id: \.offset) { index, frame in
                        StackFrameView(frame: frame, index: index, totalFrames: stackFrames.count)

                        if index < stackFrames.count - 1 {
                            Divider()
                                .opacity(0.3)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.md)
                .background(DesignSystem.Colors.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stack Frame Data & View

struct StackFrame {
    let index: String
    let function: String
    let file: String
    let lineInfo: String

    init(rawLine: String) {
        // Parse format: "1. 0x103c4a6d4 Trace.RequestManager.fetch(_:) + 456 at /path/to/RequestManager.swift:42"
        let components = rawLine.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)

        // Extract index (e.g., "1.")
        self.index = components.first.map(String.init) ?? ""

        // Function is usually the 3rd-4th component
        var funcName = ""
        var fileInfo = ""

        if rawLine.contains(" at ") {
            let parts = rawLine.split(separator: " at ", maxSplits: 1)
            if let funcPart = parts.first {
                // Extract function name (skip address and keep function)
                let funcComponents = funcPart.split(separator: " ")
                if funcComponents.count >= 2 {
                    funcName = funcComponents.dropFirst().joined(separator: " ")
                        .replacingOccurrences(of: "+ \\d+", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            if parts.count > 1 {
                fileInfo = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        } else {
            funcName = rawLine
                .replacingOccurrences(of: "^\\d+\\.", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

        self.function = funcName.isEmpty ? "Unknown" : funcName
        self.file = fileInfo.isEmpty ? "Unknown" : fileInfo
        self.lineInfo = Self.extractLineInfo(from: fileInfo)
    }

    private static func extractLineInfo(from file: String) -> String {
        // Extract line number like ":42" from path
        if let colonIndex = file.lastIndex(of: ":") {
            return String(file[colonIndex...])
        }
        return ""
    }
}

struct StackFrameView: View {
    let frame: StackFrame
    let index: Int
    let totalFrames: Int

    private var isFirstFrame: Bool {
        index == 0
    }

    private var fileName: String {
        let components = frame.file.split(separator: "/")
        return components.last.map(String.init) ?? frame.file
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                // Index indicator
                Text("\(index + 1)")
                    .font(.caption.bold())
                    .foregroundStyle(isFirstFrame ? DesignSystem.Colors.accent : .secondary)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    // Function name
                    Text(frame.function)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    // File info
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(fileName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !frame.lineInfo.isEmpty {
                            Text(frame.lineInfo)
                                .font(.caption2.monospaced())
                                .foregroundStyle(DesignSystem.Colors.info)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Badge for first frame
                if isFirstFrame {
                    Text("INITIATOR")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(DesignSystem.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .contentShape(Rectangle())
        .textSelection(.enabled)
    }
}

#Preview("OverviewSection") {
    let request = NetworkRequest(
        url: "https://api.example.com/users/123",
        method: .get,
        statusCode: 200,
        timestamp: Date(),
        duration: 0.234,
        requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
        responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
        requestBody: .empty,
        responseBody: .empty
    )
    ScrollView {
        OverviewSection(request: request)
    }
}

#Preview("StackTraceView") {
    StackTraceView(stackTrace: "1. 0x103c4a6d4 Trace.RequestManager.fetch(_:) + 456 at /path/RequestManager.swift:42\n2. 0x103c5b7e8 Trace.NetworkClient.send(_:) + 128 at /path/NetworkClient.swift:87")
        .padding()
}
