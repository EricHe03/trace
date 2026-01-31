//
//  RequestTimelineView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import Charts
import SwiftUI
import TraceCore

public struct RequestTimelineView: View {
    public let request: NetworkRequest

    public init(request: NetworkRequest) {
        self.request = request
    }

    private func phaseSymbolName(_ phaseName: String) -> String {
        switch phaseName {
        case "DNS Lookup":
            "globe"
        case "TCP Connection":
            "network"
        case "TLS Handshake":
            "lock.fill"
        case "Waiting (TTFB)":
            "hourglass"
        case "Content Download":
            "arrow.down.circle"
        case "Redirects":
            "arrow.triangle.branch"
        default:
            "timer"
        }
    }

    private var timingPhases: [(String, Color, TimeInterval)] {
        guard let timing = request.timingPhases else {
            return []
        }

        var phases: [(String, Color, TimeInterval)] = []

        if let dns = timing.dnsLookup {
            phases.append(("DNS Lookup", DesignSystem.Colors.accentAlt, dns))
        }

        if let tcp = timing.tcpConnection {
            phases.append(("TCP Connection", DesignSystem.Colors.accent, tcp))
        }

        if let tls = timing.tlsHandshake {
            phases.append(("TLS Handshake", DesignSystem.Colors.success, tls))
        }

        if let ttfb = timing.ttfb {
            phases.append(("Waiting (TTFB)", DesignSystem.Colors.warning, ttfb))
        }

        if let content = timing.contentDownload {
            phases.append(("Content Download", DesignSystem.Colors.info, content))
        }

        if let redirect = timing.redirectTime {
            phases.append(("Redirects", DesignSystem.Colors.favorite, redirect))
        }

        return phases
    }

    private var rawTotalTime: TimeInterval {
        request.timingPhases?.total ?? request.duration
    }

    private var totalTime: TimeInterval {
        // Rule: Prevent division by zero when no timing is available.
        max(rawTotalTime, 0.000_001)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Request Timeline")
                        .font(.headline)

                    Text(String(format: "Total: %.2f ms", totalTime * 1000))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                    if request.timingPhases != nil {
                        Label("Detailed", systemImage: "chart.bar.xaxis")
                            .font(.caption)
                            .foregroundStyle(DesignSystem.Colors.success)
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(DesignSystem.Colors.success.opacity(0.1))
                            .clipShape(Capsule())
                    }
            }
            .padding(.bottom, DesignSystem.Spacing.sm)

            if let timing = request.timingPhases {
                TimelineBarChart(phases: timingPhases, totalTime: totalTime)
                    .frame(height: 60)
                    .padding(.bottom, DesignSystem.Spacing.md)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Request timeline bar chart")
                    .accessibilityValue("Total \(String(format: "%.2f milliseconds", totalTime * 1000))")

                VStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(Array(timingPhases.enumerated()), id: \.offset) { _, phase in
                        TimingPhaseRow(
                            name: phase.0,
                            color: phase.1,
                            symbolName: phaseSymbolName(phase.0),
                            duration: phase.2,
                            percentage: (phase.2 / totalTime) * 100
                        )
                    }
                }

            } else {
                SimpleTimelineView(duration: request.duration)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                .fill(DesignSystem.Colors.surface)
                .shadow(
                    color: DesignSystem.Shadow.sm.color,
                    radius: DesignSystem.Shadow.sm.radius,
                    x: DesignSystem.Shadow.sm.x,
                    y: DesignSystem.Shadow.sm.y
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request timeline")
        .accessibilityValue("Total \(String(format: "%.2f milliseconds", totalTime * 1000))")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - Timeline Bar Chart

public struct TimelineBarChart: View {
    public let phases: [(String, Color, TimeInterval)]
    public let totalTime: TimeInterval
    private let minVisibleWidth: CGFloat = 2

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                    let width = geometry.size.width * (phase.2 / totalTime)

                    Rectangle()
                        .fill(phase.1)
                        // Rule: Enforce a minimum width to keep narrow phases visible.
                        .frame(width: max(width, minVisibleWidth))
                        .overlay(
                            Group {
                                if width > 18 {
                                    HStack(spacing: 4) {
                                        if width > 26 {
                                            Image(systemName: phaseSymbolName(phase.0))
                                                .font(.caption2.weight(.semibold))
                                        }
                                        if width > 44 {
                                            Text(String(format: "%.0fms", phase.2 * 1000))
                                                .font(.caption2.weight(.semibold))
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                }
                            }
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(phase.0)
                        .accessibilityValue("\(String(format: "%.2f milliseconds", phase.2 * 1000)), \(String(format: "%.1f percent", (phase.2 / totalTime) * 100))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
        }
    }

    private func phaseSymbolName(_ phaseName: String) -> String {
        switch phaseName {
        case "DNS Lookup":
            "globe"
        case "TCP Connection":
            "network"
        case "TLS Handshake":
            "lock.fill"
        case "Waiting (TTFB)":
            "hourglass"
        case "Content Download":
            "arrow.down.circle"
        case "Redirects":
            "arrow.triangle.branch"
        default:
            "timer"
        }
    }
}

// MARK: - Timing Row

public struct TimingPhaseRow: View {
    public let name: String
    public let color: Color
    public let symbolName: String
    public let duration: TimeInterval
    public let percentage: Double

    public var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: symbolName)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)

                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }

            Text(name)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()

            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xxs) {
                Text(String(format: "%.2f ms", duration * 1000))
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(String(format: "%.1f%%", percentage))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(String(format: "%.2f milliseconds", duration * 1000)), \(String(format: "%.1f percent", percentage))")
    }
}

// MARK: - Simple Timeline (Fallback)

public struct SimpleTimelineView: View {
    public let duration: TimeInterval

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundStyle(DesignSystem.Colors.accent)

                Text("Duration")
                    .font(.subheadline)

                Spacer()

                Text(String(format: "%.2f ms", duration * 1000))
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Rectangle()
                .fill(DesignSystem.Colors.accent)
                .frame(height: 30)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                .overlay(
                    Text(String(format: "%.2f ms", duration * 1000))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                )

            Text("Detailed timing information not available for this request")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, DesignSystem.Spacing.xs)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: DesignSystem.Spacing.lgPlus) {
        RequestTimelineView(request: NetworkRequest(
            id: UUID(),
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.245,
            timingPhases: NetworkTimingPhases(
                dnsLookup: 0.015,
                tcpConnection: 0.035,
                tlsHandshake: 0.085,
                requestSent: 0.010,
                ttfb: 0.065,
                contentDownload: 0.045,
                redirectTime: nil
            )
        ))

        RequestTimelineView(request: NetworkRequest(
            id: UUID(),
            url: "https://api.example.com/posts",
            method: .post,
            statusCode: 201,
            timestamp: Date(),
            duration: 0.150
        ))
    }
    .padding()
}
