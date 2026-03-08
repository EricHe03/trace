//
//  PacketTunnelProvider+BackgroundTasks.swift
//  TraceVPN
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import OSLog
import TraceCore
import TraceProxy
import TraceSecurity

extension PacketTunnelProvider {
    func startCertificateCleanupTask() {
        certificateCleanupTask?.cancel()
        certificateCleanupTask = Task {
            let interval = Duration.seconds(300)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                TLSHandler.clearExpiredCertificates()
            }
        }
    }

    func startMetricsTask() {
        let runtimeState = runtimeState
        metricsTask?.cancel()
        metricsTask = Task {
            let interval = Duration.seconds(60)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                let metrics = await ProxyNetworkMetrics.shared.getAllMetrics()
                let summary = metrics.formatSummary()
                let summaryHash = LogRedaction.hash(summary)
                let connectionCount = await runtimeState.proxyConnectionCount()
                let mem = Self.currentMemorySnapshot()
                VPNLog.tunnel.debug(
                    "event=vpn.metrics_snapshot outcome=success summary_hash=\(summaryHash) summary_len=\(summary.count) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
                await runtimeState.appendEventLog(
                    type: "metrics",
                    msg: "summary_hash=\(summaryHash) summary_len=\(summary.count) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
            }
        }
    }

    func startHeartbeatTask() {
        let runtimeState = runtimeState
        let lifecycle = lifecycle
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            let interval = Duration.seconds(30)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                let invocationID = await lifecycle.currentInvocationID()
                let snapshot = await runtimeState.heartbeatSnapshot(invocationID: invocationID)
                let heartbeatEvent = LogEvent.vpnTunnel("heartbeat")
                    .with("id", value: snapshot.invocationID ?? "none")
                    .with("stopping", value: snapshot.isStopping)
                    .with("proxy_running", value: snapshot.proxyRunning)
                VPNLog.tunnel.debug("\(heartbeatEvent)")
            }
        }
    }
}
