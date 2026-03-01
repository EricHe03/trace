//
//  PCAPExportView.swift
//  Trace
//
//  Created by AI Assistant on 2026/01/21.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceProxy
import TraceQUIC
import TraceUI

struct PCAPExportView: View {
    @State private var pcapFiles: [PCAPFileInfo] = []
    @State private var isLoading = true
    @State private var isExportingAll = false
    @State private var shareSheetItem: ShareSheetItem?
    @State private var showingDeleteAlert = false
    @State private var fileToDelete: PCAPFileInfo?
    @State private var toastMessage: String?
    @State private var rawCaptureEnabled = false
    @State private var captureLimitBytes = 10_485_760
    @State private var captureSaveTask: Task<Void, Never>?
    @State private var quicHandlingMode: QUICHandlingMode = .intercept
    @State private var quicEngineStatus: QUICEngineStatus = QUICEngineRuntime.currentStatus()
    @State private var quicDiagnosticsSummary = QUICDiagnosticsSummary()
    @State private var recentQUICFallbackReasons: [String] = []
    @ObservedObject private var vpnManager = VPNManager.shared

    private let vpnLogFileName = "vpn_events.ndjson"

    struct PCAPFileInfo: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let size: Int64
        let modificationDate: Date

        var sizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }

        var dateFormatted: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: modificationDate)
        }
    }

    private struct QUICDiagnosticsSummary {
        var flowsSeen = 0
        var flowsIntercepted = 0
        var flowsPassThrough = 0
        var flowsBlocked = 0
        var flowsTunnelForwarded = 0
    }

    var body: some View {
        Form {
            Section("Packet Capture") {
                Toggle("Enable Raw Packet Capture", isOn: rawCaptureEnabledBinding)
                    .accessibilityHint("Captures raw IP packets and saves them as PCAP files")

                if rawCaptureEnabled {
                    ByteSizeSlider(
                        title: "Capture Size Limit",
                        value: captureLimitBytesBinding,
                        range: minRawCaptureSize ... maxRawCaptureSize,
                        step: rawCaptureStep
                    )
                }

                Text("Captures raw IP packets in PCAP format. Files can be analyzed with Wireshark. Capture stops when limit is reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Network Hardening") {
                Picker("QUIC / HTTP3", selection: quicHandlingModeBinding) {
                    ForEach(QUICHandlingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .accessibilityHint("Choose intercept, pass-through, or block behavior for QUIC/HTTP3")

                Text("`Intercept` attempts HTTP/3 visibility, `Pass Through` preserves connectivity, and `Block` forces non-QUIC behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("QUIC Diagnostics") {
                HStack {
                    Text("Engine")
                    Spacer()
                    Text(quicEngineStatus.availability == .available ? "Available" : "Unavailable")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Engine Version")
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
                    Text("QUIC Flows Seen")
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

            Section("VPN Logs") {
                Button {
                    exportVPNLogs()
                } label: {
                    Label("Export VPN Logs", systemImage: "square.and.arrow.up")
                }
                .accessibilityHint("Exports the VPN extension log file")

                Text("Exports the VPN extension NDJSON log file (vpn_events.ndjson).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Statistics") {
                HStack {
                    Text("Total Files")
                    Spacer()
                    Text("\(pcapFiles.count)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Total Size")
                    Spacer()
                    Text(totalSizeFormatted)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Packet Capture Files") {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if pcapFiles.isEmpty {
                    TraceContentUnavailableView(
                        "No Packet Captures",
                        systemImage: "tray",
                        description: Text("Enable capture and start VPN to collect packets")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(pcapFiles) { file in
                        PCAPFileRow(file: file)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    shareSheetItem = ShareSheetItem([file.url])
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    fileToDelete = file
                                    showingDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    shareSheetItem = ShareSheetItem([file.url])
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Button(role: .destructive) {
                                    fileToDelete = file
                                    showingDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }

            if !pcapFiles.isEmpty {
                Section {
                    Button {
                        shareAllFiles()
                    } label: {
                        if isExportingAll {
                            HStack {
                                ProgressView()
                                Text("Exporting…")
                            }
                        } else {
                            Label("Export All Files", systemImage: "square.and.arrow.up.fill")
                        }
                    }
                    .disabled(isExportingAll)

                    Button(role: .destructive) {
                        showingDeleteAlert = true
                        fileToDelete = nil
                    } label: {
                        Label("Delete All Captures", systemImage: "trash.fill")
                    }
                }
            }
        }
        .navigationTitle("Packet Captures")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSettings()
            loadFiles()
            loadQUICDiagnostics()
        }
        .refreshable {
            loadFiles()
            loadQUICDiagnostics()
        }
        .shareSheet(item: $shareSheetItem)
        .alert("Delete Packet Capture", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                } else {
                    deleteAllFiles()
                }
            }
        } message: {
            if fileToDelete != nil {
                Text("Are you sure you want to delete this packet capture file?")
            } else {
                Text("Are you sure you want to delete all \(pcapFiles.count) packet capture files? This cannot be undone.")
            }
        }
        .toast(message: $toastMessage)
    }

    private let minRawCaptureSize = 1_048_576
    private let maxRawCaptureSize = 500 * 1_048_576
    private let rawCaptureStep = 1_048_576
    private var rawCaptureEnabledBinding: Binding<Bool> {
        Binding(
            get: { rawCaptureEnabled },
            set: { newValue in
                rawCaptureEnabled = newValue
                updateRawCaptureSettings()
            }
        )
    }

    private var captureLimitBytesBinding: Binding<Int> {
        Binding(
            get: { captureLimitBytes },
            set: { newValue in
                captureLimitBytes = newValue
                scheduleRawCaptureSave()
            }
        )
    }

    private var quicHandlingModeBinding: Binding<QUICHandlingMode> {
        Binding(
            get: { quicHandlingMode },
            set: { mode in
                quicHandlingMode = mode
                updateQUICHandlingSettings()
            }
        )
    }

    private var totalSizeFormatted: String {
        let total = pcapFiles.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func loadSettings() {
        Task {
            let hardening = HardeningConfig.shared
            let limitBytes = await hardening.maxRawCaptureSize
            let rawCapture = await hardening.enableRawCapture
            let mode = await hardening.quicHandlingMode
            await MainActor.run {
                rawCaptureEnabled = rawCapture
                captureLimitBytes = max(minRawCaptureSize, min(Int(limitBytes), maxRawCaptureSize))
                quicHandlingMode = mode
            }
        }
    }

    private func loadFiles() {
        isLoading = true
        Task {
            let urls = AppGroupStorage.shared.packetCaptureFiles()
            var fileInfos: [PCAPFileInfo] = []

            for url in urls {
                if let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                   let size = attrs.fileSize,
                   let date = attrs.contentModificationDate {
                    fileInfos.append(PCAPFileInfo(
                        url: url,
                        name: url.lastPathComponent,
                        size: Int64(size),
                        modificationDate: date
                    ))
                }
            }

            await MainActor.run {
                pcapFiles = fileInfos.sorted { $0.modificationDate > $1.modificationDate }
                isLoading = false
            }
            loadQUICDiagnostics()
        }
    }

    private func loadQUICDiagnostics() {
        Task {
            let engineStatus = QUICEngineRuntime.currentStatus()
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

            await MainActor.run {
                quicEngineStatus = engineStatus
                quicDiagnosticsSummary = summary
                recentQUICFallbackReasons = recentReasons
            }
        }
    }

    private func scheduleRawCaptureSave() {
        captureSaveTask?.cancel()
        captureSaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            updateRawCaptureSettings()
        }
    }

    private func updateRawCaptureSettings() {
        Task {
            let clampedBytes = UInt64(max(minRawCaptureSize, min(captureLimitBytes, maxRawCaptureSize)))
            let hardening = HardeningConfig.shared

            await hardening.setEnableRawCapture(rawCaptureEnabled)
            await hardening.setMaxRawCaptureSize(clampedBytes)

            // Notify VPN extension if connected
            if vpnManager.isConnected {
                do {
                    try await vpnManager.sendMessage([
                        "command": "updateHardeningConfig",
                        "hardeningConfig": [
                            "enableRawCapture": rawCaptureEnabled,
                            "maxRawCaptureSize": clampedBytes
                        ]
                    ])
                } catch {
                    await MainActor.run {
                        toastMessage = "Saved locally, but failed to notify VPN: \(error.localizedDescription)"
                    }
                }
            }

            await MainActor.run {
                captureLimitBytes = Int(clampedBytes)
            }
        }
    }

    private func updateQUICHandlingSettings() {
        Task {
            let hardening = HardeningConfig.shared
            await hardening.setQUICHandlingMode(quicHandlingMode)

            if vpnManager.isConnected {
                do {
                    try await vpnManager.sendMessage([
                        "command": "updateHardeningConfig",
                        "hardeningConfig": [
                            "quicHandlingMode": quicHandlingMode.rawValue,
                            // Legacy key for old extension payloads.
                            "blockQUIC": quicHandlingMode.blocksQUIC
                        ]
                    ])
                } catch {
                    await MainActor.run {
                        toastMessage = "Saved locally, but failed to notify VPN: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func shareAllFiles() {
        isExportingAll = true
        Task { [pcapFiles] in
            do {
                let copiedURLs: [URL] = try await Task.detached(priority: .utility) {
                    // Create a temporary directory with all PCAP files
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("PCAPExport-\(Date().timeIntervalSince1970)")
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                    var urls: [URL] = []
                    urls.reserveCapacity(pcapFiles.count)
                    for file in pcapFiles {
                        let destURL = tempDir.appendingPathComponent(file.name)
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.copyItem(at: file.url, to: destURL)
                        urls.append(destURL)
                    }
                    return urls
                }.value

                await MainActor.run {
                    shareSheetItem = ShareSheetItem(copiedURLs.map { $0 as Any })
                }
            } catch {
                await MainActor.run {
                    toastMessage = "Failed to export files: \(error.localizedDescription)"
                }
            }
            await MainActor.run {
                isExportingAll = false
            }
        }
    }

    private func exportVPNLogs() {
        guard let url = AppGroupStorage.shared.appGroupFileURL(for: vpnLogFileName) else {
            toastMessage = "VPN log file not found."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            toastMessage = "VPN log file not found."
            return
        }
        shareSheetItem = ShareSheetItem([url])
    }

    private func deleteFile(_ file: PCAPFileInfo) {
        do {
            try FileManager.default.removeItem(at: file.url)
            loadFiles()
            toastMessage = "File deleted"
        } catch {
            toastMessage = "Failed to delete file: \(error.localizedDescription)"
        }
    }

    private func deleteAllFiles() {
        var deletedCount = 0
        for file in pcapFiles {
            do {
                try FileManager.default.removeItem(at: file.url)
                deletedCount += 1
            } catch {
                toastMessage = "Failed to delete \(file.name): \(error.localizedDescription)"
            }
        }
        loadFiles()
        toastMessage = "Deleted \(deletedCount) file(s)"
    }
}

// MARK: - PCAP File Row

private struct PCAPFileRow: View {
    let file: PCAPExportView.PCAPFileInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: DesignSystem.Spacing.md) {
                    Text(file.sizeFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(file.dateFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name), \(file.sizeFormatted), \(file.dateFormatted)")
        .accessibilityHint("Swipe to share or delete")
    }
}

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
                        .fontWeight(.semibold)
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
                    .fontWeight(.semibold)
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
        var totalEvents = 0
        var parseErrorCount = 0
        var fullTunnelConfigured = false
        var transparentMITMIngressEnabled = false
        var routeMITMCount = 0
        var tunneledParsedCount = 0
        var tunneledResponseCaptureCount = 0
        var httpUpstreamFailureCount = 0

        var pendingSavedRequestIDs = Set<String>()
        var savedSuccessRequestIDs = Set<String>()
        var savedFailureRequestIDs = Set<String>()
        var upstreamFailureSamples: [String] = []

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
                    totalEvents: &totalEvents,
                    parseErrorCount: &parseErrorCount,
                    fullTunnelConfigured: &fullTunnelConfigured,
                    transparentMITMIngressEnabled: &transparentMITMIngressEnabled,
                    routeMITMCount: &routeMITMCount,
                    tunneledParsedCount: &tunneledParsedCount,
                    pendingSavedRequestIDs: &pendingSavedRequestIDs,
                    savedSuccessRequestIDs: &savedSuccessRequestIDs,
                    savedFailureRequestIDs: &savedFailureRequestIDs,
                    tunneledResponseCaptureCount: &tunneledResponseCaptureCount,
                    httpUpstreamFailureCount: &httpUpstreamFailureCount,
                    upstreamFailureSamples: &upstreamFailureSamples
                )
            }
        }

        if !buffer.isEmpty {
            processLine(
                lineData: buffer[...],
                decoder: decoder,
                maxLineBytes: maxLineBytes,
                totalEvents: &totalEvents,
                parseErrorCount: &parseErrorCount,
                fullTunnelConfigured: &fullTunnelConfigured,
                transparentMITMIngressEnabled: &transparentMITMIngressEnabled,
                routeMITMCount: &routeMITMCount,
                tunneledParsedCount: &tunneledParsedCount,
                pendingSavedRequestIDs: &pendingSavedRequestIDs,
                savedSuccessRequestIDs: &savedSuccessRequestIDs,
                savedFailureRequestIDs: &savedFailureRequestIDs,
                tunneledResponseCaptureCount: &tunneledResponseCaptureCount,
                httpUpstreamFailureCount: &httpUpstreamFailureCount,
                upstreamFailureSamples: &upstreamFailureSamples
            )
        }

        let completedRequestIDs = pendingSavedRequestIDs.intersection(savedSuccessRequestIDs)
        let pendingOnlyRequestIDs = pendingSavedRequestIDs
            .subtracting(savedSuccessRequestIDs)
            .subtracting(savedFailureRequestIDs)
            .sorted()

        return SelfCheckReport(
            sourceFileURL: sourceURL,
            generatedAt: Date(),
            totalEvents: totalEvents,
            parseErrorCount: parseErrorCount,
            fullTunnelConfigured: fullTunnelConfigured,
            transparentMITMIngressEnabled: transparentMITMIngressEnabled,
            routeMITMCount: routeMITMCount,
            tunneledParsedCount: tunneledParsedCount,
            pendingSavedCount: pendingSavedRequestIDs.count,
            completedRequestCount: completedRequestIDs.count,
            pendingOnlyCount: pendingOnlyRequestIDs.count,
            savedSuccessCount: savedSuccessRequestIDs.count,
            savedFailureCount: savedFailureRequestIDs.count,
            tunneledResponseCaptureCount: tunneledResponseCaptureCount,
            httpUpstreamFailureCount: httpUpstreamFailureCount,
            pendingOnlyRequestIDs: pendingOnlyRequestIDs,
            upstreamFailureSamples: upstreamFailureSamples
        )
    }

    private static func processLine(
        lineData: Data.SubSequence,
        decoder: JSONDecoder,
        maxLineBytes: Int,
        totalEvents: inout Int,
        parseErrorCount: inout Int,
        fullTunnelConfigured: inout Bool,
        transparentMITMIngressEnabled: inout Bool,
        routeMITMCount: inout Int,
        tunneledParsedCount: inout Int,
        pendingSavedRequestIDs: inout Set<String>,
        savedSuccessRequestIDs: inout Set<String>,
        savedFailureRequestIDs: inout Set<String>,
        tunneledResponseCaptureCount: inout Int,
        httpUpstreamFailureCount: inout Int,
        upstreamFailureSamples: inout [String]
    ) {
        guard !lineData.isEmpty else { return }
        guard lineData.count <= maxLineBytes else {
            parseErrorCount += 1
            return
        }
        let lineBuffer = Data(lineData)
        guard let line = String(data: lineBuffer, encoding: .utf8),
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let event = try? decoder.decode(VPNEventLine.self, from: lineBuffer)
        else {
            parseErrorCount += 1
            return
        }

        totalEvents += 1
        let fields = parseFields(event.msg)

        switch event.type {
        case "startup", "capture_config":
            if let mode = fields["mode"],
               mode == CaptureMode.fullTunnel.rawValue || mode == CaptureMode.fullTunnelDualMITM.rawValue {
                fullTunnelConfigured = true
            }
        case "proxy_ingress_mode":
            let transparentTLS = fields["transparent_tls"] == "true"
            let hybridTCPMITM = fields["hybrid_tcp_mitm"] == "true"
            let dualMITMMode = fields["mode"] == CaptureMode.fullTunnelDualMITM.rawValue
            if transparentTLS, hybridTCPMITM || dualMITMMode {
                transparentMITMIngressEnabled = true
            }
        case "local_socks5_connect_route":
            if fields["route"] == "mitm" {
                routeMITMCount += 1
            }
        case "proxy_nio_tunneled_request":
            guard fields["mode"] == "tunneled_https" else { return }
            if fields["outcome"] == "parsed" {
                tunneledParsedCount += 1
            }
            if fields["outcome"] == "pending_saved",
               let requestID = fields["request_id"], !requestID.isEmpty {
                pendingSavedRequestIDs.insert(requestID)
            }
        case "proxy_request_saved":
            guard let requestID = fields["request_id"], !requestID.isEmpty else { return }
            let outcome = fields["outcome"] ?? "unknown"
            let status = fields["status"] ?? "nil"
            if outcome == "success", status != "nil" {
                savedSuccessRequestIDs.insert(requestID)
            }
            if outcome == "failure" || status.hasPrefix("5") {
                savedFailureRequestIDs.insert(requestID)
            }
        case "proxy_nio_response_capture":
            if fields["mode"] == "tunneled_https" {
                tunneledResponseCaptureCount += 1
            }
        case "proxy_nio_connect_stage":
            if fields["stage"] == "http_upstream",
               fields["outcome"] == "failure" {
                httpUpstreamFailureCount += 1
                if upstreamFailureSamples.count < 5 {
                    upstreamFailureSamples.append(event.msg)
                }
            }
        default:
            break
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

private struct VPNEventLine: Decodable {
    let ts: Double
    let type: String
    let msg: String
}

private enum CheckStatus {
    case pass
    case warn
    case fail

    var title: String {
        switch self {
        case .pass:
            "PASS"
        case .warn:
            "WARN"
        case .fail:
            "FAIL"
        }
    }

    var icon: String {
        switch self {
        case .pass:
            "checkmark.circle.fill"
        case .warn:
            "exclamationmark.triangle.fill"
        case .fail:
            "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pass:
            .green
        case .warn:
            .orange
        case .fail:
            .red
        }
    }
}

private struct SelfCheckReport {
    let sourceFileURL: URL?
    let generatedAt: Date
    let totalEvents: Int
    let parseErrorCount: Int
    let fullTunnelConfigured: Bool
    let transparentMITMIngressEnabled: Bool
    let routeMITMCount: Int
    let tunneledParsedCount: Int
    let pendingSavedCount: Int
    let completedRequestCount: Int
    let pendingOnlyCount: Int
    let savedSuccessCount: Int
    let savedFailureCount: Int
    let tunneledResponseCaptureCount: Int
    let httpUpstreamFailureCount: Int
    let pendingOnlyRequestIDs: [String]
    let upstreamFailureSamples: [String]

    static let empty = SelfCheckReport(
        sourceFileURL: nil,
        generatedAt: Date(),
        totalEvents: 0,
        parseErrorCount: 0,
        fullTunnelConfigured: false,
        transparentMITMIngressEnabled: false,
        routeMITMCount: 0,
        tunneledParsedCount: 0,
        pendingSavedCount: 0,
        completedRequestCount: 0,
        pendingOnlyCount: 0,
        savedSuccessCount: 0,
        savedFailureCount: 0,
        tunneledResponseCaptureCount: 0,
        httpUpstreamFailureCount: 0,
        pendingOnlyRequestIDs: [],
        upstreamFailureSamples: []
    )

    func withGeneratedNow(sourceFile: URL?) -> SelfCheckReport {
        SelfCheckReport(
            sourceFileURL: sourceFile,
            generatedAt: Date(),
            totalEvents: totalEvents,
            parseErrorCount: parseErrorCount,
            fullTunnelConfigured: fullTunnelConfigured,
            transparentMITMIngressEnabled: transparentMITMIngressEnabled,
            routeMITMCount: routeMITMCount,
            tunneledParsedCount: tunneledParsedCount,
            pendingSavedCount: pendingSavedCount,
            completedRequestCount: completedRequestCount,
            pendingOnlyCount: pendingOnlyCount,
            savedSuccessCount: savedSuccessCount,
            savedFailureCount: savedFailureCount,
            tunneledResponseCaptureCount: tunneledResponseCaptureCount,
            httpUpstreamFailureCount: httpUpstreamFailureCount,
            pendingOnlyRequestIDs: pendingOnlyRequestIDs,
            upstreamFailureSamples: upstreamFailureSamples
        )
    }

    var bypassRouteStatus: CheckStatus {
        if routeMITMCount > 0, tunneledParsedCount > 0 {
            return .pass
        }
        if routeMITMCount > 0 || tunneledParsedCount > 0 {
            return .warn
        }
        return .fail
    }

    var requestLifecycleStatus: CheckStatus {
        if pendingSavedCount == 0 {
            return .warn
        }
        if completedRequestCount == 0 {
            return .fail
        }
        if pendingOnlyCount > 0 {
            return .warn
        }
        return .pass
    }

    var responseCaptureStatus: CheckStatus {
        if tunneledResponseCaptureCount > 0 {
            return .pass
        }
        if tunneledParsedCount > 0 {
            return .warn
        }
        return .fail
    }

    var overallStatus: CheckStatus {
        guard fullTunnelConfigured, transparentMITMIngressEnabled else {
            return .fail
        }
        guard bypassRouteStatus != .fail else {
            return .fail
        }
        if requestLifecycleStatus == .fail || responseCaptureStatus == .fail {
            return .fail
        }
        if requestLifecycleStatus == .warn || responseCaptureStatus == .warn || parseErrorCount > 0 {
            return .warn
        }
        return .pass
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PCAPExportView()
    }
}
