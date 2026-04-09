//
//  StorageSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

/// Displays storage usage and cleanup controls.
struct StorageSettingsView: View {
    @State private var config = DataCleanupManager.CleanupConfiguration()
    @State private var stats = DataCleanupManager.CleanupStats()
    @State private var storageUsage: (total: Int64, requests: Int64, bodies: Int64, logs: Int64) = (0, 0, 0, 0)
    @State private var isCleaningUp = false
    @State private var isCompacting = false
    @State private var toastMessage: String?

    var body: some View {
        Form {
            Section {
                storageUsageRow(label: "Total", bytes: storageUsage.total)
                storageUsageRow(label: "Requests", bytes: storageUsage.requests)
                storageUsageRow(label: "Body Files", bytes: storageUsage.bodies)
                storageUsageRow(label: "Logs", bytes: storageUsage.logs)
            } header: {
                Text("Storage Usage")
            } footer: {
                Text("Storage usage reflects data kept in the app's shared container. You can export logs and packet captures before cleaning up.")
            }

            Section {
                Toggle("Enable Auto Cleanup", isOn: $config.enabled)

                Stepper(value: $config.requestRetentionDays, in: 1 ... 30) {
                    HStack {
                        Text("Keep Requests")
                        Spacer()
                        Text("\(config.requestRetentionDays) days")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $config.bodyFileRetentionDays, in: 1 ... 30) {
                    HStack {
                        Text("Keep Body Files")
                        Spacer()
                        Text("\(config.bodyFileRetentionDays) days")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $config.logRetentionDays, in: 1 ... 30) {
                    HStack {
                        Text("Keep Logs")
                        Spacer()
                        Text("\(config.logRetentionDays) days")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $config.maxStorageMB, in: 100 ... 2000, step: 100) {
                    HStack {
                        Text("Max Storage")
                        Spacer()
                        Text("\(config.maxStorageMB) MB")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Automatic Cleanup")
            }

            Section {
                if let lastCleanup = stats.lastCleanup {
                    HStack {
                        Text("Last Cleanup")
                        Spacer()
                        Text(lastCleanup, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Requests Deleted")
                    Spacer()
                    Text("\(stats.requestsDeleted)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Space Freed")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: stats.bytesFreed, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Statistics")
            }

            Section {
                Button {
                    Task {
                        isCleaningUp = true
                        await DataCleanupManager.shared.performManualCleanup()
                        await loadData()
                        isCleaningUp = false
                    }
                } label: {
                    if isCleaningUp {
                        HStack {
                            ProgressView()
                            Text("Cleaning Up...")
                        }
                    } else {
                        Label("Clean Up Now", systemImage: "trash")
                    }
                }
                .disabled(isCleaningUp || isCompacting)

                Button {
                    Task {
                        isCompacting = true
                        AppGroupStorage.shared.reclaimDatabaseSpace()
                        await loadData()
                        isCompacting = false
                        toastMessage = "Database compacted."
                    }
                } label: {
                    if isCompacting {
                        HStack {
                            ProgressView()
                            Text("Compacting...")
                        }
                    } else {
                        Label("Compact Database", systemImage: "arrow.down.left.and.arrow.up.right")
                    }
                }
                .disabled(isCleaningUp || isCompacting)
            } footer: {
                Text("Compact Database frees unused SQLite space without deleting any data.")
            }
        }
        .navigationTitle("Storage")
        .task {
            await loadData()
        }
        .onChangeCompat(of: config) { newConfig in
            Task {
                await DataCleanupManager.shared.updateConfiguration(newConfig)
            }
        }
        .toast(message: $toastMessage)
    }

    private func storageUsageRow(label: String, bytes: Int64) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .foregroundStyle(.secondary)
        }
    }

    private func loadData() async {
        config = await DataCleanupManager.shared.getConfiguration()
        stats = await DataCleanupManager.shared.getStats()
        storageUsage = await DataCleanupManager.shared.getStorageUsage()
    }
}

#Preview {
    NavigationStack {
        StorageSettingsView()
    }
}
