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
                            Text("STREAM TYPE")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

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

            // Redirect Information
            if !request.redirectChain.isEmpty {
                SectionCard(title: request.redirectChain.count > 1 ? "Redirects" : "Redirect") {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("LOCATION")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

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
                        Text("LOCATION")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

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
                Text("QUERY PARAMETERS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

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
                Text("REQUEST COOKIES")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text("\(cookies.count) cookie(s)")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .responseCookies(cookies):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("SET-COOKIE")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

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
