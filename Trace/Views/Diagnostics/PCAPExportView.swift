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
    @State private var blockQUICEnabled = true
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
                Toggle("Block QUIC (HTTP/3)", isOn: blockQUICEnabledBinding)
                    .accessibilityHint("Blocks QUIC to force HTTP/2 for easier capture")

                Text("Blocks QUIC (UDP/443). Disable if apps rely on HTTP/3.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .refreshable {
            loadFiles()
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

    private var blockQUICEnabledBinding: Binding<Bool> {
        Binding(
            get: { blockQUICEnabled },
            set: { newValue in
                blockQUICEnabled = newValue
                updateQUICBlockingSettings()
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
            let blockQUIC = await hardening.blockQUIC
            await MainActor.run {
                rawCaptureEnabled = rawCapture
                captureLimitBytes = max(minRawCaptureSize, min(Int(limitBytes), maxRawCaptureSize))
                blockQUICEnabled = blockQUIC
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

    private func updateQUICBlockingSettings() {
        Task {
            let hardening = HardeningConfig.shared
            await hardening.setBlockQUIC(blockQUICEnabled)

            if vpnManager.isConnected {
                do {
                    try await vpnManager.sendMessage([
                        "command": "updateHardeningConfig",
                        "hardeningConfig": [
                            "blockQUIC": blockQUICEnabled
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

// MARK: - Preview

#Preview {
    NavigationStack {
        PCAPExportView()
    }
}
