//
//  FullTunnelSelfCheckView.swift
//  Trace
//
//  Created by AI Assistant on 2026/03/06.
//

import SwiftUI
import TraceCore
import TraceUI

struct FullTunnelSelfCheckView: View {
    @State private var report = SelfCheckReport.empty
    @State private var isLoading = true
    @State private var toastMessage: String?
    @State private var loadTask: Task<Void, Never>?

    private let vpnLogFileName = "vpn_events.ndjson"

    var body: some View {
        Form {
            Section("Summary") {
                HStack {
                    Label(report.overallStatus.title, systemImage: report.overallStatus.icon)
                        .foregroundStyle(report.overallStatus.color)
                        .bold()
                    Spacer()
                }

                if let sourceURL = report.sourceFileURL {
                    LabeledContent("Log File", value: sourceURL.lastPathComponent)
                } else {
                    LabeledContent("Log File", value: vpnLogFileName)
                }
                LabeledContent("Evaluated Events", value: "\(report.totalEvents)")
                LabeledContent("Generated At") {
                    Text(report.generatedAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            Section("Strict Checks") {
                checkRow(
                    title: "Full Tunnel mode is active",
                    status: report.fullTunnelConfigured ? .pass : .fail,
                    detail: report.fullTunnelConfigured ? "Detected mode=fullTunnel or fullTunnelDualMITM." : "No fullTunnel/fullTunnelDualMITM startup or capture_config marker found."
                )
                checkRow(
                    title: "Transparent TCP MITM ingress is enabled",
                    status: report.transparentMITMIngressEnabled ? .pass : .fail,
                    detail: report.transparentMITMIngressEnabled
                        ? "Detected transparent_tls=true with hybrid_tcp_mitm=true, or mode=fullTunnelDualMITM."
                        : "Expected transparent_tls=true with hybrid_tcp_mitm=true, or mode=fullTunnelDualMITM."
                )
                checkRow(
                    title: "Bypass-proxy route reached MITM",
                    status: report.bypassRouteStatus,
                    detail: "route=mitm count: \(report.routeMITMCount), tunneled_https parsed: \(report.tunneledParsedCount)"
                )
                checkRow(
                    title: "Tunneled requests completed",
                    status: report.requestLifecycleStatus,
                    detail: "pending_saved: \(report.pendingSavedCount), completed: \(report.completedRequestCount), pending_only: \(report.pendingOnlyCount)"
                )
                checkRow(
                    title: "Response capture recorded",
                    status: report.responseCaptureStatus,
                    detail: "proxy_nio_response_capture mode=tunneled_https count: \(report.tunneledResponseCaptureCount)"
                )
            }

            Section("Counters") {
                LabeledContent("route=mitm (local_socks5_connect_route)", value: "\(report.routeMITMCount)")
                LabeledContent("proxy_nio_tunneled_request parsed", value: "\(report.tunneledParsedCount)")
                LabeledContent("proxy_nio_tunneled_request pending_saved", value: "\(report.pendingSavedCount)")
                LabeledContent("proxy_request_saved success (non-nil status)", value: "\(report.savedSuccessCount)")
                LabeledContent("proxy_request_saved failure / 5xx", value: "\(report.savedFailureCount)")
                LabeledContent("proxy_nio_response_capture (tunneled_https)", value: "\(report.tunneledResponseCaptureCount)")
                LabeledContent("http_upstream failures", value: "\(report.httpUpstreamFailureCount)")
                if report.parseErrorCount > 0 {
                    LabeledContent("Log parse errors", value: "\(report.parseErrorCount)")
                }
            }

            if !report.pendingOnlyRequestIDs.isEmpty {
                Section("Pending Without Completion") {
                    Text("These request IDs were saved as pending but never reached success/failure in the current log window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(report.pendingOnlyRequestIDs, id: \.self) { requestID in
                        Text(requestID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            if !report.upstreamFailureSamples.isEmpty {
                Section("Upstream Failure Samples") {
                    ForEach(Array(report.upstreamFailureSamples.enumerated()), id: \.offset) { _, sample in
                        Text(sample)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Precision Markers") {
                Text("判定依据只使用结构化字段：mode/outcome/request_id/status/route，不使用模糊字符串猜测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("核心闭环：local_socks5_connect_route(route=mitm) -> proxy_nio_tunneled_request(mode=tunneled_https, pending_saved) -> proxy_request_saved(outcome=success, same request_id) -> proxy_nio_response_capture(mode=tunneled_https).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Full Tunnel Self-Check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") {
                    loadReport()
                }
                .disabled(isLoading)
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .onAppear {
            loadReport()
        }
        .refreshable {
            loadReport()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
        .toast(message: $toastMessage)
    }

    private func checkRow(title: String, status: CheckStatus, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(status.title, systemImage: status.icon)
                    .foregroundStyle(status.color)
                    .font(.subheadline)
                    .bold()
                Text(title)
                    .font(.subheadline)
                Spacer()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func loadReport() {
        loadTask?.cancel()
        isLoading = true
        let logFileName = vpnLogFileName
        loadTask = Task(priority: .utility) {
            let computed = Self.buildReport(logFileName: logFileName)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                report = computed
                isLoading = false
            }
        }
    }

    private static func buildReport(logFileName: String) -> SelfCheckReport {
        let sourceURL = AppGroupStorage.shared.appGroupFileURL(for: logFileName)
        guard let sourceURL else {
            return .empty.withGeneratedNow(sourceFile: nil)
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return .empty.withGeneratedNow(sourceFile: sourceURL)
        }

        let decoder = JSONDecoder()
        var accumulator = SelfCheckAccumulator()

        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else {
            return .empty.withGeneratedNow(sourceFile: sourceURL)
        }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let maxLineBytes = 512 * 1024
        var buffer = Data()

        while let chunk = try? handle.read(upToCount: chunkSize),
              !chunk.isEmpty {
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                processLine(
                    lineData: lineData,
                    decoder: decoder,
                    maxLineBytes: maxLineBytes,
                    accumulator: &accumulator
                )
            }
        }

        if !buffer.isEmpty {
            processLine(
                lineData: buffer[...],
                decoder: decoder,
                maxLineBytes: maxLineBytes,
                accumulator: &accumulator
            )
        }

        let completedRequestIDs = accumulator.pendingSavedRequestIDs.intersection(accumulator.savedSuccessRequestIDs)
        let pendingOnlyRequestIDs = accumulator.pendingSavedRequestIDs
            .subtracting(accumulator.savedSuccessRequestIDs)
            .subtracting(accumulator.savedFailureRequestIDs)
            .sorted()

        return SelfCheckReport(
            sourceFileURL: sourceURL,
            generatedAt: Date(),
            totalEvents: accumulator.totalEvents,
            parseErrorCount: accumulator.parseErrorCount,
            fullTunnelConfigured: accumulator.fullTunnelConfigured,
            transparentMITMIngressEnabled: accumulator.transparentMITMIngressEnabled,
            routeMITMCount: accumulator.routeMITMCount,
            tunneledParsedCount: accumulator.tunneledParsedCount,
            pendingSavedCount: accumulator.pendingSavedRequestIDs.count,
            completedRequestCount: completedRequestIDs.count,
            pendingOnlyCount: pendingOnlyRequestIDs.count,
            savedSuccessCount: accumulator.savedSuccessRequestIDs.count,
            savedFailureCount: accumulator.savedFailureRequestIDs.count,
            tunneledResponseCaptureCount: accumulator.tunneledResponseCaptureCount,
            httpUpstreamFailureCount: accumulator.httpUpstreamFailureCount,
            pendingOnlyRequestIDs: pendingOnlyRequestIDs,
            upstreamFailureSamples: accumulator.upstreamFailureSamples
        )
    }

    private struct SelfCheckAccumulator {
        var totalEvents = 0
        var parseErrorCount = 0
        var fullTunnelConfigured = false
        var transparentMITMIngressEnabled = false
        var routeMITMCount = 0
        var tunneledParsedCount = 0
        var pendingSavedRequestIDs = Set<String>()
        var savedSuccessRequestIDs = Set<String>()
        var savedFailureRequestIDs = Set<String>()
        var tunneledResponseCaptureCount = 0
        var httpUpstreamFailureCount = 0
        var upstreamFailureSamples: [String] = []
    }

    private static func processLine(
        lineData: Data.SubSequence,
        decoder: JSONDecoder,
        maxLineBytes: Int,
        accumulator: inout SelfCheckAccumulator
    ) {
        guard !lineData.isEmpty else { return }
        guard lineData.count <= maxLineBytes else {
            accumulator.parseErrorCount += 1
            return
        }
        let lineBuffer = Data(lineData)
        guard let line = String(data: lineBuffer, encoding: .utf8),
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let event = try? decoder.decode(VPNEventLine.self, from: lineBuffer)
        else {
            accumulator.parseErrorCount += 1
            return
        }

        accumulator.totalEvents += 1
        let fields = parseFields(event.msg)
        apply(event, fields: fields, accumulator: &accumulator)
    }

    private static func apply(
        _ event: VPNEventLine,
        fields: [String: String],
        accumulator: inout SelfCheckAccumulator
    ) {
        switch event.type {
        case "startup", "capture_config":
            applyStartupMarker(fields: fields, accumulator: &accumulator)
        case "proxy_ingress_mode":
            applyIngressMode(fields: fields, accumulator: &accumulator)
        case "local_socks5_connect_route":
            applyConnectRoute(fields: fields, accumulator: &accumulator)
        case "proxy_nio_tunneled_request":
            applyTunneledRequest(fields: fields, accumulator: &accumulator)
        case "proxy_request_saved":
            applySavedRequest(fields: fields, accumulator: &accumulator)
        case "proxy_nio_response_capture":
            applyResponseCapture(fields: fields, accumulator: &accumulator)
        case "proxy_nio_connect_stage":
            applyConnectStage(event: event, fields: fields, accumulator: &accumulator)
        default:
            break
        }
    }

    private static func applyStartupMarker(fields: [String: String], accumulator: inout SelfCheckAccumulator) {
        if let mode = fields["mode"],
           mode == CaptureMode.fullTunnel.rawValue || mode == CaptureMode.fullTunnelDualMITM.rawValue {
            accumulator.fullTunnelConfigured = true
        }
    }

    private static func applyIngressMode(fields: [String: String], accumulator: inout SelfCheckAccumulator) {
        let transparentTLS = fields["transparent_tls"] == "true"
        let hybridTCPMITM = fields["hybrid_tcp_mitm"] == "true"
        let dualMITMMode = fields["mode"] == CaptureMode.fullTunnelDualMITM.rawValue
        if transparentTLS, hybridTCPMITM || dualMITMMode {
            accumulator.transparentMITMIngressEnabled = true
        }
    }

    private static func applyConnectRoute(fields: [String: String], accumulator: inout SelfCheckAccumulator) {
        if fields["route"] == "mitm" {
            accumulator.routeMITMCount += 1
        }
    }

    private static func applyTunneledRequest(fields: [String: String], accumulator: inout SelfCheckAccumulator) {
        guard fields["mode"] == "tunneled_https" else { return }
        if fields["outcome"] == "parsed" {
            accumulator.tunneledParsedCount += 1
        }
        if fields["outcome"] == "pending_saved",
           let requestID = fields["request_id"], !requestID.isEmpty {
            accumulator.pendingSavedRequestIDs.insert(requestID)
        }
    }

    private static func applySavedRequest(fields: [String: String], accumulator: inout SelfCheckAccumulator) {
        guard let requestID = fields["request_id"], !requestID.isEmpty else { return }
        let outcome = fields["outcome"] ?? "unknown"
        let status = fields["status"] ?? "nil"
        if outcome == "success", status != "nil" {
            accumulator.savedSuccessRequestIDs.insert(requestID)
        }
        if outcome == "failure" || status.hasPrefix("5") {
            accumulator.savedFailureRequestIDs.insert(requestID)
        }
    }

    private static func applyResponseCapture(fields: [String: String], accumulator: inout SelfCheckAccumulator) {
        if fields["mode"] == "tunneled_https" {
            accumulator.tunneledResponseCaptureCount += 1
        }
    }

    private static func applyConnectStage(
        event: VPNEventLine,
        fields: [String: String],
        accumulator: inout SelfCheckAccumulator
    ) {
        if fields["stage"] == "http_upstream",
           fields["outcome"] == "failure" {
            accumulator.httpUpstreamFailureCount += 1
            if accumulator.upstreamFailureSamples.count < 5 {
                accumulator.upstreamFailureSamples.append(event.msg)
            }
        }
    }

    private static func parseFields(_ message: String) -> [String: String] {
        var fields: [String: String] = [:]
        for token in message.split(separator: " ") {
            guard let separatorIndex = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<separatorIndex])
            guard !key.isEmpty else { continue }
            let valueStart = token.index(after: separatorIndex)
            let value = valueStart < token.endIndex ? String(token[valueStart...]) : ""
            fields[key] = value
        }
        return fields
    }
}
