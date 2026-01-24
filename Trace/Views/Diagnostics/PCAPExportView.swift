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
    @State private var showingShareSheet = false
    @State private var selectedFile: PCAPFileInfo?
    @State private var showingDeleteAlert = false
    @State private var fileToDelete: PCAPFileInfo?
    @State private var toastMessage: String?
    @State private var rawCaptureEnabled = false
    @State private var captureLimitMB = 10
    @State private var blockQUICEnabled = true
    @State private var shareItems: [URL] = []
    @State private var showingAllFilesShare = false
    @State private var isRestoringSettings = false
    @ObservedObject private var vpnManager = VPNManager.shared

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
        List {
            // Configuration Section
            Section {
                Toggle("Enable Raw Packet Capture", isOn: $rawCaptureEnabled)
                    .onChange(of: rawCaptureEnabled) { _ in
                        guard !isRestoringSettings else { return }
                        updateRawCaptureSettings()
                    }

                if rawCaptureEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Capture Size Limit")
                            .font(.subheadline)

                        HStack {
                            TextField("Size", value: $captureLimitMB, format: .number)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)

                            Text("MB")
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Apply") {
                                updateRawCaptureSettings()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text("Packet Capture Settings")
            } footer: {
                Text("Captures raw IP packets in PCAP format. Files can be analyzed with Wireshark. Capture stops when limit is reached.")
            }

            Section {
                Toggle("Block QUIC (HTTP/3)", isOn: $blockQUICEnabled)
                    .onChange(of: blockQUICEnabled) { _ in
                        guard !isRestoringSettings else { return }
                        updateQUICBlockingSettings()
                    }
            } header: {
                Text("Network Hardening")
            } footer: {
                Text("Blocks QUIC (UDP/443). Disable if apps rely on HTTP/3 for streaming.")
            }

            // Statistics Section
            Section("Statistics") {
                HStack {
                    Label("Total Files", systemImage: "doc.fill")
                    Spacer()
                    Text("\(pcapFiles.count)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Total Size", systemImage: "internaldrive.fill")
                    Spacer()
                    Text(totalSizeFormatted)
                        .foregroundStyle(.secondary)
                }
            }

            // Files Section
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if pcapFiles.isEmpty {
                    HStack {
                        Image(systemName: "tray.fill")
                            .foregroundStyle(.secondary)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Packet Captures")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Enable capture and start VPN to collect packets")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(pcapFiles) { file in
                        PCAPFileRow(file: file, onShare: {
                            selectedFile = file
                            showingShareSheet = true
                        }, onDelete: {
                            fileToDelete = file
                            showingDeleteAlert = true
                        })
                    }
                }
            } header: {
                HStack {
                    Text("Packet Capture Files")
                    Spacer()
                    if !pcapFiles.isEmpty {
                        Button {
                            loadFiles()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                }
            }

            // Actions Section
            if !pcapFiles.isEmpty {
                Section {
                    Button {
                        shareAllFiles()
                    } label: {
                        Label("Export All Files", systemImage: "square.and.arrow.up.fill")
                    }

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
        .sheet(isPresented: $showingShareSheet) {
            if let file = selectedFile {
                ShareSheet(items: [file.url])
            }
        }
        .sheet(isPresented: $showingAllFilesShare) {
            ShareSheet(items: shareItems)
        }
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

    private var totalSizeFormatted: String {
        let total = pcapFiles.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func loadSettings() {
        Task {
            let config = await HardeningConfig.shared
            let limitBytes = config.maxRawCaptureSize
            let captureLimit = Int(limitBytes / 1_048_576)
            await MainActor.run {
                isRestoringSettings = true
                rawCaptureEnabled = config.enableRawCapture
                captureLimitMB = captureLimit
                blockQUICEnabled = config.blockQUIC
                isRestoringSettings = false
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
                pcapFiles = fileInfos
                isLoading = false
            }
        }
    }

    private func updateRawCaptureSettings() {
        Task {
            let limitBytes = UInt64(max(1, captureLimitMB)) * 1_048_576
            let config = await HardeningConfig.shared

            config.setEnableRawCapture(rawCaptureEnabled)
            config.setMaxRawCaptureSize(limitBytes)

            // Notify VPN extension if connected
            if vpnManager.isConnected {
                try? await vpnManager.sendMessage([
                    "command": "updateHardeningConfig",
                    "enableRawCapture": rawCaptureEnabled,
                    "maxRawCaptureSize": limitBytes
                ])
            }

            await MainActor.run {
                toastMessage = rawCaptureEnabled
                    ? "Packet capture enabled (\(captureLimitMB) MB limit)"
                    : "Packet capture disabled"
            }
        }
    }

    private func updateQUICBlockingSettings() {
        Task {
            let config = await HardeningConfig.shared
            config.setBlockQUIC(blockQUICEnabled)

            if vpnManager.isConnected {
                try? await vpnManager.sendMessage([
                    "command": "updateHardeningConfig",
                    "hardeningConfig": [
                        "blockQUIC": blockQUICEnabled
                    ]
                ])
            }

            await MainActor.run {
                toastMessage = blockQUICEnabled ? "QUIC blocked" : "QUIC allowed"
            }
        }
    }

    private func shareAllFiles() {
        selectedFile = nil

        // Create a temporary directory with all PCAP files
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCAPExport-\(Date().timeIntervalSince1970)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            var copiedURLs: [URL] = []
            for file in pcapFiles {
                let destURL = tempDir.appendingPathComponent(file.name)
                try FileManager.default.copyItem(at: file.url, to: destURL)
                copiedURLs.append(destURL)
            }

            // ✅ Use SwiftUI sheet with ShareSheet wrapper (proper iPad popover support)
            shareItems = copiedURLs
            showingAllFilesShare = true
        } catch {
            toastMessage = "Failed to export files: \(error.localizedDescription)"
        }
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
                print("Failed to delete \(file.name): \(error)")
            }
        }
        loadFiles()
        toastMessage = "Deleted \(deletedCount) file(s)"
    }
}

// MARK: - PCAP File Row

private struct PCAPFileRow: View {
    let file: PCAPExportView.PCAPFileInfo
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 12) {
                        Label(file.sizeFormatted, systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Label(file.dateFormatted, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    onShare()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PCAPExportView()
    }
}
