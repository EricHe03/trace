//
//  UDPFlowManager.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import os
import TraceCore
import TraceNetworking
import TracePacket

final class UDPFlowManager {
    private struct FlowKey: Hashable {
        let sourceIP: String
        let sourcePort: UInt16
        let destinationIP: String
        let destinationPort: UInt16

        static func normalized(
            sourceIP: String,
            sourcePort: UInt16,
            destinationIP: String,
            destinationPort: UInt16
        ) -> FlowKey {
            let left = "\(sourceIP):\(sourcePort)"
            let right = "\(destinationIP):\(destinationPort)"
            if left <= right {
                return FlowKey(
                    sourceIP: sourceIP,
                    sourcePort: sourcePort,
                    destinationIP: destinationIP,
                    destinationPort: destinationPort
                )
            }
            return FlowKey(
                sourceIP: destinationIP,
                sourcePort: destinationPort,
                destinationIP: sourceIP,
                destinationPort: sourcePort
            )
        }
    }

    private struct FlowState {
        var metadata: UDPFlowMetadata
    }

    private let queue = DispatchQueue(label: "com.trace.vpn.udp_flow_manager", qos: .utility, attributes: .concurrent)
    private let queueKey = DispatchSpecificKey<Void>()
    private var flows: [FlowKey: FlowState] = [:]
    private var dirtyFlows: Set<FlowKey> = []
    private var cleanupTimer: DispatchSourceTimer?
    private var persistTimer: DispatchSourceTimer?
    private let idleTimeout: TimeInterval
    private let flowLimit: Int
    private let logSampler = LogSampler()

    init(idleTimeout: TimeInterval = 120, flowLimit: Int = 5000) {
        self.idleTimeout = idleTimeout
        self.flowLimit = max(1, flowLimit)
        queue.setSpecific(key: queueKey, value: ())
        startTimers()
    }

    deinit {
        shutdown()
    }

    func recordDatagram(ipPacket: IPPacket, udpPacket: UDPPacket) {
        let sourceIP = ipPacket.source.description
        let destinationIP = ipPacket.destination.description
        let key = FlowKey.normalized(
            sourceIP: sourceIP,
            sourcePort: udpPacket.sourcePort,
            destinationIP: destinationIP,
            destinationPort: udpPacket.destinationPort
        )
        let now = Date()

        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            if self.flows[key] == nil {
                self.evictIfNeeded(now: now)
                let metadata = UDPFlowMetadata(
                    sourceIP: key.sourceIP,
                    destinationIP: key.destinationIP,
                    sourcePort: key.sourcePort,
                    destinationPort: key.destinationPort,
                    startTime: now,
                    lastActivity: now,
                    termination: .active
                )
                self.flows[key] = FlowState(metadata: metadata)
            }

            guard var state = self.flows[key] else { return }
            let isFromSource = sourceIP == state.metadata.sourceIP && udpPacket.sourcePort == state.metadata.sourcePort
            let payloadSize = UInt64(udpPacket.payload.count)

            if isFromSource {
                state.metadata.bytesFromSource += payloadSize
                state.metadata.datagramsFromSource += 1
            } else {
                state.metadata.bytesToSource += payloadSize
                state.metadata.datagramsToSource += 1
            }

            let direction: UDPFlowDirection = isFromSource ? .sourceToDestination : .destinationToSource
            state.metadata.recentDatagrams.append(
                UDPDatagramSample(timestamp: now, size: udpPacket.payload.count, direction: direction)
            )
            if state.metadata.recentDatagrams.count > 10 {
                state.metadata.recentDatagrams.removeFirst(state.metadata.recentDatagrams.count - 10)
            }

            if state.metadata.detectedProtocol == .unknown {
                if let detected = self.detectProtocol(
                    sourcePort: udpPacket.sourcePort,
                    destinationPort: udpPacket.destinationPort,
                    payload: udpPacket.payload,
                    sourceIP: sourceIP,
                    destinationIP: destinationIP
                ) {
                    state.metadata.detectedProtocol = detected
                }
            }

            state.metadata.lastActivity = now
            state.metadata.termination = .active

            self.flows[key] = state
            self.dirtyFlows.insert(key)
        }
    }

    func recordQUICInspection(
        ipPacket: IPPacket,
        udpPacket: UDPPacket,
        outcome: QUICInspectionOutcome,
        metadata: QUICFlowMetadata
    ) {
        let sourceIP = ipPacket.source.description
        let destinationIP = ipPacket.destination.description
        let key = FlowKey.normalized(
            sourceIP: sourceIP,
            sourcePort: udpPacket.sourcePort,
            destinationIP: destinationIP,
            destinationPort: udpPacket.destinationPort
        )
        let now = Date()

        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            if self.flows[key] == nil {
                self.evictIfNeeded(now: now)
                let created = UDPFlowMetadata(
                    sourceIP: key.sourceIP,
                    destinationIP: key.destinationIP,
                    sourcePort: key.sourcePort,
                    destinationPort: key.destinationPort,
                    startTime: now,
                    lastActivity: now,
                    termination: .active,
                    detectedProtocol: .quic
                )
                self.flows[key] = FlowState(metadata: created)
            }

            guard var state = self.flows[key] else { return }
            state.metadata.detectedProtocol = .quic
            state.metadata.quicInspectionOutcome = outcome
            state.metadata.quicFlowMetadata = metadata
            state.metadata.lastActivity = now

            self.flows[key] = state
            self.dirtyFlows.insert(key)
        }
    }

    func flush() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            persistDirtyFlows()
            return
        }
        queue.sync(flags: .barrier) {
            persistDirtyFlows()
        }
    }

    func shutdown() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            shutdownOnQueue()
            return
        }
        queue.sync(flags: .barrier) {
            shutdownOnQueue()
        }
    }

    private func detectProtocol(
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data,
        sourceIP: String,
        destinationIP: String
    ) -> UDPFlowProtocol? {
        let classification = UDPProtocolClassifier.classify(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload,
            sourceIP: sourceIP,
            destinationIP: destinationIP
        )

        switch classification.applicationProtocol {
        case .dns:
            return .dns
        case .mdns:
            return .mdns
        case .ntp:
            return .ntp
        case .dhcpv4, .dhcpv6:
            return .dhcp
        case .snmp:
            return .snmp
        case .quic:
            return .quic
        case .http, .tls:
            return nil
        case .unknown:
            return nil
        }
    }

    private func startTimers() {
        let cleanupTimer = DispatchSource.makeTimerSource(queue: queue)
        cleanupTimer.schedule(deadline: .now() + 60, repeating: 60)
        cleanupTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.queue.async(flags: .barrier) { [weak self] in
                self?.cleanupExpiredFlows()
            }
        }
        cleanupTimer.resume()
        self.cleanupTimer = cleanupTimer

        let persistTimer = DispatchSource.makeTimerSource(queue: queue)
        persistTimer.schedule(deadline: .now() + 5, repeating: 5)
        persistTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.queue.async(flags: .barrier) { [weak self] in
                self?.persistDirtyFlows()
            }
        }
        persistTimer.resume()
        self.persistTimer = persistTimer
    }

    private func stopTimers() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
        persistTimer?.cancel()
        persistTimer = nil
    }

    private func shutdownOnQueue() {
        stopTimers()
        persistDirtyFlows()
        guard !flows.isEmpty else { return }

        let shutdownTime = Date()
        for key in Array(flows.keys) {
            guard var state = flows[key] else { continue }
            state.metadata.termination = .closed
            state.metadata.endTime = shutdownTime
            do {
                try AppGroupStorage.shared.saveUDPFlowMetadata(state.metadata)
            } catch {
                if logSampler.shouldLog(event: "vpn.udp_flow_store", key: "shutdown", first: 3, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.udp_flow_store outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        flows.removeAll(keepingCapacity: false)
        dirtyFlows.removeAll(keepingCapacity: false)
    }

    private func cleanupExpiredFlows() {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        var expiredKeys: [FlowKey] = []

        for (key, state) in flows where state.metadata.lastActivity < cutoff {
            expiredKeys.append(key)
        }

        for key in expiredKeys {
            if var state = flows[key] {
                state.metadata.termination = .timeout
                state.metadata.endTime = state.metadata.lastActivity
                do {
                    try AppGroupStorage.shared.saveUDPFlowMetadata(state.metadata)
                } catch {
                    if logSampler.shouldLog(event: "vpn.udp_flow_store", key: "timeout", first: 3, every: 200) {
                        VPNLog.tunnel.warning("event=vpn.udp_flow_store outcome=failure error=\(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            flows.removeValue(forKey: key)
            dirtyFlows.remove(key)
        }
    }

    private func persistDirtyFlows() {
        guard !dirtyFlows.isEmpty else { return }
        let keys = dirtyFlows
        dirtyFlows.removeAll()

        for key in keys {
            guard let state = flows[key] else { continue }
            do {
                try AppGroupStorage.shared.saveUDPFlowMetadata(state.metadata)
            } catch {
                if logSampler.shouldLog(event: "vpn.udp_flow_store", key: "write_failure", first: 3, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.udp_flow_store outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func evictIfNeeded(now: Date) {
        guard flows.count >= flowLimit else { return }
        guard let oldest = flows.min(by: { $0.value.metadata.lastActivity < $1.value.metadata.lastActivity }) else { return }
        var state = oldest.value
        state.metadata.termination = .evicted
        state.metadata.endTime = now
        do {
            try AppGroupStorage.shared.saveUDPFlowMetadata(state.metadata)
        } catch {
            if logSampler.shouldLog(event: "vpn.udp_flow_store", key: "evicted", first: 3, every: 200) {
                VPNLog.tunnel.warning("event=vpn.udp_flow_store outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
        }
        flows.removeValue(forKey: oldest.key)
        dirtyFlows.remove(oldest.key)
    }
}
