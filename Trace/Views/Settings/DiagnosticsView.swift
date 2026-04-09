//
//  DiagnosticsView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceQUIC
import TraceUI

struct DiagnosticsView: View {
    @State private var quicEngineStatus: QUICEngineStatus = QUICEngineRuntime.currentStatus()
    @State private var quicDiagnosticsSummary = QUICDiagnosticsSummary()
    @State private var recentQUICFallbackReasons: [String] = []
    @State private var activeConnectionCount = 0
    @State private var activeUDPFlowCount = 0

    private struct QUICDiagnosticsSummary {
        var flowsSeen = 0
        var flowsIntercepted = 0
        var flowsPassThrough = 0
        var flowsBlocked = 0
        var flowsTunnelForwarded = 0
    }

    var body: some View {
        Form {
            Section("QUIC Engine") {
                HStack {
                    Text("Engine")
                    Spacer()
                    Text(quicEngineStatus.availability == .available ? "Available" : "Unavailable")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Version")
                    Spacer()
                    Text(quicEngineStatus.version)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Text("FFI Linked")
                    Spacer()
                    Text(quicEngineStatus.usingQuicheFFI ? "Yes" : "No")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Flows Seen")
                    Spacer()
                    Text("\(quicDiagnosticsSummary.flowsSeen)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Intercepted")
                    Spacer()
                    Text("\(quicDiagnosticsSummary.flowsIntercepted)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Pass Through")
                    Spacer()
                    Text("\(quicDiagnosticsSummary.flowsPassThrough)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Blocked")
                    Spacer()
                    Text("\(quicDiagnosticsSummary.flowsBlocked)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Tunnel Forwarded")
                    Spacer()
                    Text("\(quicDiagnosticsSummary.flowsTunnelForwarded)")
                        .foregroundStyle(.secondary)
                }

                if !recentQUICFallbackReasons.isEmpty {
                    Text("Recent fallback reasons")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(recentQUICFallbackReasons.enumerated()), id: \.offset) { _, reason in
                        Text(reason)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Connections") {
                HStack {
                    Text("Active Connections")
                    Spacer()
                    Text("\(activeConnectionCount)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("UDP Flows")
                    Spacer()
                    Text("\(activeUDPFlowCount)")
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    ConnectionsView()
                } label: {
                    Label("View All Connections", systemImage: "network")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDiagnostics()
        }
        .refreshable {
            await loadDiagnostics()
        }
    }

    private func loadDiagnostics() async {
        quicEngineStatus = QUICEngineRuntime.currentStatus()

        let flows = (try? AppGroupStorage.shared.loadAllUDPFlowMetadata()) ?? []
        let quicFlows = flows
            .filter { $0.detectedProtocol == .quic || $0.hasQUICDiagnostics }
            .sorted { $0.lastActivity > $1.lastActivity }

        var summary = QUICDiagnosticsSummary()
        summary.flowsSeen = quicFlows.count
        for flow in quicFlows {
            switch flow.quicInspectionOutcome {
            case .intercepted:
                summary.flowsIntercepted += 1
            case .passThroughMarked:
                summary.flowsPassThrough += 1
            case .blocked:
                summary.flowsBlocked += 1
            case .tunnelForwarded:
                summary.flowsTunnelForwarded += 1
            case nil:
                break
            }
        }

        let recentReasons = Array(
            quicFlows
                .compactMap { $0.quicFlowMetadata?.failureReason }
                .prefix(5)
        )

        let allFlows = (try? AppGroupStorage.shared.loadAllUDPFlowMetadata()) ?? []
        let packetFlows = (try? AppGroupStorage.shared.loadAllPacketFlowRecords()) ?? []

        await MainActor.run {
            quicDiagnosticsSummary = summary
            recentQUICFallbackReasons = recentReasons
            activeUDPFlowCount = allFlows.count
            activeConnectionCount = packetFlows.count
        }
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
