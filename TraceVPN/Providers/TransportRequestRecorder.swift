//
//  TransportRequestRecorder.swift
//  TraceVPN
//
//  Created by Codex on 2026/02/24.
//

import Foundation
import OSLog
import TraceCore
import TraceNetworking
import TracePacket
import TraceSecurity

final class TransportRequestRecorder {
    private struct TCPFlowState {
        var lastSeen: Date
        var recordedCount: Int
        var lastPersistedProtocol: TransportApplicationProtocol?
        var lastPersistedOutcome: TransportParserOutcome?
        var lastPersistedSummary: String?
        var probeBuffer: Data
    }

    private let queue = DispatchQueue(label: "com.trace.vpn.transport_request_recorder", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let logSampler = LogSampler()
    private let configRefreshInterval: TimeInterval = 1
    private var lastConfigRefresh: Date = .distantPast
    private var captureBody = true
    private var maxBodySize = 10 * 1024 * 1024

    private let tcpFlowIdleTTL: TimeInterval = 120
    private let tcpFlowCleanupInterval: TimeInterval = 30
    private let tcpFlowLimit = 4096
    private let maxTCPProbeBytes = 32 * 1024
    private let maxTCPRecordsPerFlow = 2
    private var tcpFlows: [String: TCPFlowState] = [:]
    private var lastTCPFlowCleanup: Date = .distantPast

    private let persistFlushInterval: TimeInterval = 0.25
    private let persistBatchLimit = 64
    private var pendingPersistRequests: [TransportRequest] = []
    private var persistFlushWorkItem: DispatchWorkItem?

    init() {
        queue.setSpecific(key: queueKey, value: ())
        refreshCaptureSettingsIfNeeded(force: true, now: Date())
    }

    func shutdown() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            shutdownOnQueue()
            return
        }

        queue.sync { [weak self] in
            self?.shutdownOnQueue()
        }
    }

    func process(ipPacket: IPPacket) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            self.refreshCaptureSettingsIfNeeded(force: false, now: now)
            self.cleanupTCPFlowStateIfNeeded(now: now)

            switch ipPacket.transport {
            case .tcp:
                guard let tcpPacket = TCPParser.parse(ipPacket.payload) else { return }
                self.recordTCP(ipPacket: ipPacket, tcpPacket: tcpPacket, timestamp: now)
            case .udp:
                guard let udpPacket = UDPParser.parse(ipPacket.payload) else { return }
                self.recordUDP(ipPacket: ipPacket, udpPacket: udpPacket, timestamp: now)
            case .none:
                return
            }
        }
    }

    private func shutdownOnQueue() {
        persistFlushWorkItem?.cancel()
        persistFlushWorkItem = nil
        flushPendingRequests()
        tcpFlows.removeAll(keepingCapacity: false)
    }

    private func recordTCP(ipPacket: IPPacket, tcpPacket: TCPPacket, timestamp: Date) {
        // Keep the Network list signal-focused; ACK-only/empty payload packets stay in Connection analytics.
        guard !tcpPacket.payload.isEmpty else { return }

        let sourceIP = ipPacket.source.description
        let destinationIP = ipPacket.destination.description
        let sourcePort = tcpPacket.sourcePort
        let destinationPort = tcpPacket.destinationPort
        let payload = tcpPacket.payload
        let key = flowKey(
            transport: .tcp,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            destinationIP: destinationIP,
            destinationPort: destinationPort
        )

        var flowState = tcpFlows[key] ?? TCPFlowState(
            lastSeen: timestamp,
            recordedCount: 0,
            lastPersistedProtocol: nil,
            lastPersistedOutcome: nil,
            lastPersistedSummary: nil,
            probeBuffer: Data()
        )
        flowState.lastSeen = timestamp
        appendTCPProbe(payload, to: &flowState)

        let classification = classifyTCPPayload(
            payload: flowState.probeBuffer,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            destinationIP: destinationIP,
            destinationPort: destinationPort
        )

        if shouldPersistTCPRecord(state: flowState, classification: classification) {
            let request = TransportRequest(
                timestamp: timestamp,
                sourceIP: sourceIP,
                destinationIP: destinationIP,
                sourcePort: sourcePort,
                destinationPort: destinationPort,
                transport: .tcp,
                applicationProtocol: classification.applicationProtocol,
                parserOutcome: classification.parserOutcome,
                payload: storedPayload(from: payload),
                payloadBytes: payload.count,
                ipVersion: ipPacket.version,
                protocolNumber: ipPacket.protocolNumber,
                hopLimit: ipPacket.hopLimit,
                ipHeaderLength: ipPacket.headerLength,
                totalLength: ipPacket.totalLength,
                fragmentOffset: ipPacket.fragmentOffset,
                moreFragments: ipPacket.moreFragments,
                summary: classification.summary,
                flowKey: key
            )
            persist(request)

            flowState.recordedCount += 1
            flowState.lastPersistedProtocol = classification.applicationProtocol
            flowState.lastPersistedOutcome = classification.parserOutcome
            flowState.lastPersistedSummary = classification.summary
        }

        tcpFlows[key] = flowState
    }

    private func recordUDP(ipPacket: IPPacket, udpPacket: UDPPacket, timestamp: Date) {
        let sourceIP = ipPacket.source.description
        let destinationIP = ipPacket.destination.description
        let sourcePort = udpPacket.sourcePort
        let destinationPort = udpPacket.destinationPort
        let payload = udpPacket.payload

        let classification = UDPProtocolClassifier.classify(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload,
            sourceIP: sourceIP,
            destinationIP: destinationIP
        )

        let request = TransportRequest(
            timestamp: timestamp,
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            transport: .udp,
            applicationProtocol: classification.applicationProtocol,
            parserOutcome: classification.parserOutcome,
            payload: storedPayload(from: payload),
            payloadBytes: payload.count,
            ipVersion: ipPacket.version,
            protocolNumber: ipPacket.protocolNumber,
            hopLimit: ipPacket.hopLimit,
            ipHeaderLength: ipPacket.headerLength,
            totalLength: ipPacket.totalLength,
            fragmentOffset: ipPacket.fragmentOffset,
            moreFragments: ipPacket.moreFragments,
            summary: classification.summary,
            flowKey: flowKey(
                transport: .udp,
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destinationIP: destinationIP,
                destinationPort: destinationPort
            )
        )
        persist(request)
    }

    private func shouldPersistTCPRecord(
        state: TCPFlowState,
        classification: UDPProtocolClassifier.Classification
    ) -> Bool {
        guard state.recordedCount < maxTCPRecordsPerFlow else { return false }
        if state.recordedCount == 0 {
            return true
        }

        if state.lastPersistedProtocol != classification.applicationProtocol {
            return true
        }
        if state.lastPersistedOutcome != classification.parserOutcome {
            return true
        }
        if state.lastPersistedSummary != classification.summary {
            return true
        }

        return false
    }

    private func appendTCPProbe(_ payload: Data, to state: inout TCPFlowState) {
        guard !payload.isEmpty else { return }
        let remaining = max(0, maxTCPProbeBytes - state.probeBuffer.count)
        guard remaining > 0 else { return }
        state.probeBuffer.append(payload.prefix(remaining))
    }

    private func classifyTCPPayload(
        payload: Data,
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        destinationPort: UInt16
    ) -> UDPProtocolClassifier.Classification {
        // DNS over TCP prepends a 2-byte message length prefix.
        if sourcePort == 53 || destinationPort == 53 {
            if let dnsMessage = parseDNSOverTCP(
                payload: payload,
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destinationIP: destinationIP,
                destinationPort: destinationPort
            ) {
                let summary = "DNS/TCP \(dnsMessage.isResponse ? "response" : "query") \(dnsMessage.queryDomain ?? "-")"
                return UDPProtocolClassifier.Classification(
                    applicationProtocol: .dns,
                    parserOutcome: .parsed,
                    summary: summary
                )
            }

            return UDPProtocolClassifier.Classification(
                applicationProtocol: .unknown,
                parserOutcome: .fallbackSignatureOnly,
                summary: dnsTCPFallbackSummary(payload)
            )
        }

        if let summary = httpSummary(from: payload) {
            return UDPProtocolClassifier.Classification(
                applicationProtocol: .http,
                parserOutcome: .parsed,
                summary: summary
            )
        }

        if let summary = tlsSummary(
            from: payload,
            sourcePort: sourcePort,
            destinationPort: destinationPort
        ) {
            return UDPProtocolClassifier.Classification(
                applicationProtocol: .tls,
                parserOutcome: .parsed,
                summary: summary
            )
        }

        return UDPProtocolClassifier.Classification(
            applicationProtocol: .unknown,
            parserOutcome: .fallbackUnknown,
            summary: nil
        )
    }

    private func parseDNSOverTCP(
        payload: Data,
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        destinationPort: UInt16
    ) -> DNSMessage? {
        guard payload.count >= 2 else { return nil }

        let declaredLength = Int(UInt16(payload[0]) << 8 | UInt16(payload[1]))
        guard declaredLength > 0 else { return nil }
        guard payload.count >= declaredLength + 2 else { return nil }

        let dnsPayload = payload.subdata(in: 2 ..< 2 + declaredLength)
        return DNSParser.parseSafely(
            data: dnsPayload,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            destIP: destinationIP,
            destPort: destinationPort
        )
    }

    private func dnsTCPFallbackSummary(_ payload: Data) -> String {
        guard payload.count >= 2 else {
            return "tcp/53 awaiting_length_prefix"
        }

        let declaredLength = Int(UInt16(payload[0]) << 8 | UInt16(payload[1]))
        guard declaredLength > 0 else {
            return "tcp/53 invalid_length_prefix"
        }

        guard payload.count >= declaredLength + 2 else {
            return "tcp/53 awaiting_complete_message"
        }

        return "tcp/53 parse_failed"
    }

    private func httpSummary(from payload: Data) -> String? {
        guard payload.count >= 4 else { return nil }

        if let prefix = String(data: payload.prefix(16), encoding: .ascii) {
            if prefix.hasPrefix("HTTP/") {
                return "HTTP response"
            }

            let methods = ["GET", "POST", "PUT", "HEAD", "DELETE", "OPTIONS", "PATCH", "CONNECT", "TRACE"]
            if let method = methods.first(where: { prefix.hasPrefix("\($0) ") }) {
                return "HTTP request \(method)"
            }
        }

        return nil
    }

    private func tlsSummary(from payload: Data, sourcePort: UInt16, destinationPort: UInt16) -> String? {
        guard looksLikeTLSPayload(payload, sourcePort: sourcePort, destinationPort: destinationPort) else {
            return nil
        }

        let sni = TLSHandler.extractSNI(from: payload)
        let alpn = TLSHandler.extractALPN(from: payload)
        var parts: [String] = ["TLS"]

        if let sni, !sni.isEmpty {
            parts.append("sni=\(sni)")
        }

        if let alpn, !alpn.isEmpty {
            parts.append("alpn=\(alpn.joined(separator: ","))")
        }

        return parts.joined(separator: " ")
    }

    private func looksLikeTLSPayload(_ payload: Data, sourcePort: UInt16, destinationPort: UInt16) -> Bool {
        guard payload.count >= 5 else { return false }

        let contentType = payload[0]
        guard contentType == 0x14 || contentType == 0x15 || contentType == 0x16 || contentType == 0x17 else {
            return false
        }

        guard payload[1] == 0x03 else { return false }

        let recordLength = Int(UInt16(payload[3]) << 8 | UInt16(payload[4]))
        guard recordLength > 0 else { return false }

        // Heuristic guardrail: keep TLS detection scoped to common TLS ports when header-only data is available.
        if payload.count < 6 {
            return sourcePort == 443 || destinationPort == 443
        }

        return true
    }

    private func storedPayload(from payload: Data) -> BodyStorage {
        guard captureBody, maxBodySize > 0, !payload.isEmpty else { return .empty }
        return BodyStorage.from(
            data: payload,
            charset: nil,
            maxSize: maxBodySize,
            contentEncoding: nil,
            decodeCompressedContent: false
        )
    }

    private func flowKey(
        transport: FlowTransportProtocol,
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        destinationPort: UInt16
    ) -> String {
        let left = "\(sourceIP):\(sourcePort)"
        let right = "\(destinationIP):\(destinationPort)"
        if left <= right {
            return "\(transport.rawValue)|\(left)|\(right)"
        }
        return "\(transport.rawValue)|\(right)|\(left)"
    }

    private func persist(_ request: TransportRequest) {
        pendingPersistRequests.append(request)

        if pendingPersistRequests.count >= persistBatchLimit {
            flushPendingRequests()
            return
        }

        schedulePersistFlushIfNeeded()
    }

    private func schedulePersistFlushIfNeeded() {
        guard persistFlushWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistFlushWorkItem = nil
            self.flushPendingRequests()
        }
        persistFlushWorkItem = workItem
        queue.asyncAfter(deadline: .now() + persistFlushInterval, execute: workItem)
    }

    private func flushPendingRequests() {
        guard !pendingPersistRequests.isEmpty else { return }

        persistFlushWorkItem?.cancel()
        persistFlushWorkItem = nil

        let batch = pendingPersistRequests
        pendingPersistRequests.removeAll(keepingCapacity: true)

        do {
            try AppGroupStorage.shared.saveTransportRequests(batch)
        } catch {
            if logSampler.shouldLog(event: "vpn.transport_request_store", key: "write_failure", first: 3, every: 200) {
                VPNLog.tunnel.warning(
                    "event=vpn.transport_request_store outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }

            for request in batch {
                do {
                    try AppGroupStorage.shared.saveTransportRequest(request)
                } catch {
                    if logSampler.shouldLog(event: "vpn.transport_request_store", key: "write_failure_fallback", first: 3, every: 200) {
                        VPNLog.tunnel.warning(
                            "event=vpn.transport_request_store outcome=failure mode=single_fallback error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    private func cleanupTCPFlowStateIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastTCPFlowCleanup) >= tcpFlowCleanupInterval else { return }
        lastTCPFlowCleanup = now

        let cutoff = now.addingTimeInterval(-tcpFlowIdleTTL)
        tcpFlows = tcpFlows.filter { _, value in
            value.lastSeen >= cutoff
        }

        let overflow = tcpFlows.count - tcpFlowLimit
        guard overflow > 0 else { return }

        let keysToEvict = tcpFlows
            .sorted { $0.value.lastSeen < $1.value.lastSeen }
            .prefix(overflow)
            .map(\.key)

        for key in keysToEvict {
            tcpFlows.removeValue(forKey: key)
        }
    }

    private func refreshCaptureSettingsIfNeeded(force: Bool, now: Date) {
        guard force || now.timeIntervalSince(lastConfigRefresh) >= configRefreshInterval else { return }
        let config = AppGroupStorage.shared.loadConfiguration()
        captureBody = config.captureBody
        maxBodySize = max(0, config.maxBodySize)
        lastConfigRefresh = now
    }
}
