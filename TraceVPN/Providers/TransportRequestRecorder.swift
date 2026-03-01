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
        var stickyApplicationProtocol: TransportApplicationProtocol?
        var stickySummary: String?
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

    func process(ipPacket: IPPacket, rawPacket: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            self.refreshCaptureSettingsIfNeeded(force: false, now: now)
            self.cleanupTCPFlowStateIfNeeded(now: now)

            switch ipPacket.transport {
            case .tcp:
                guard let tcpPacket = TCPParser.parse(ipPacket.payload) else { return }
                self.recordTCP(ipPacket: ipPacket, tcpPacket: tcpPacket, rawPacket: rawPacket, timestamp: now)
            case .udp:
                guard let udpPacket = UDPParser.parse(ipPacket.payload) else { return }
                self.recordUDP(ipPacket: ipPacket, udpPacket: udpPacket, rawPacket: rawPacket, timestamp: now)
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

    private func recordTCP(ipPacket: IPPacket, tcpPacket: TCPPacket, rawPacket: Data, timestamp: Date) {
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
            stickyApplicationProtocol: nil,
            stickySummary: nil,
            probeBuffer: Data()
        )
        flowState.lastSeen = timestamp
        appendTCPProbe(payload, to: &flowState)

        let probeClassification = classifyTCPPayload(
            payload: flowState.probeBuffer,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            destinationIP: destinationIP,
            destinationPort: destinationPort
        )

        let classification = applyTCPFallbackHeuristics(
            classification: probeClassification,
            flowState: flowState,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            hasPayload: !payload.isEmpty
        )

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
            packet: storedPacket(from: rawPacket),
            packetBytes: rawPacket.count,
            ipVersion: ipPacket.version,
            protocolNumber: ipPacket.protocolNumber,
            hopLimit: ipPacket.hopLimit,
            ipHeaderLength: ipPacket.headerLength,
            totalLength: ipPacket.totalLength,
            fragmentOffset: ipPacket.fragmentOffset,
            moreFragments: ipPacket.moreFragments,
            tcpSequenceNumber: tcpPacket.sequenceNumber,
            tcpAcknowledgmentNumber: tcpPacket.acknowledgmentNumber,
            tcpFlags: tcpPacket.flags.rawValue,
            tcpWindowSize: tcpPacket.windowSize,
            tcpDataOffset: tcpPacket.dataOffset,
            tcpOptions: tcpOptionsMetadata(from: tcpPacket.options),
            summary: classification.summary,
            flowKey: key
        )
        persist(request)

        if classification.applicationProtocol != .unknown {
            flowState.stickyApplicationProtocol = classification.applicationProtocol
            if let summary = classification.summary, !summary.isEmpty {
                flowState.stickySummary = summary
            }
        }

        tcpFlows[key] = flowState
    }

    private func recordUDP(ipPacket: IPPacket, udpPacket: UDPPacket, rawPacket: Data, timestamp: Date) {
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
            packet: storedPacket(from: rawPacket),
            packetBytes: rawPacket.count,
            ipVersion: ipPacket.version,
            protocolNumber: ipPacket.protocolNumber,
            hopLimit: ipPacket.hopLimit,
            ipHeaderLength: ipPacket.headerLength,
            totalLength: ipPacket.totalLength,
            fragmentOffset: ipPacket.fragmentOffset,
            moreFragments: ipPacket.moreFragments,
            udpDatagramLength: udpPacket.length,
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

    private func applyTCPFallbackHeuristics(
        classification: UDPProtocolClassifier.Classification,
        flowState: TCPFlowState,
        sourcePort: UInt16,
        destinationPort: UInt16,
        hasPayload: Bool
    ) -> UDPProtocolClassifier.Classification {
        guard classification.applicationProtocol == .unknown else {
            return classification
        }

        if let stickyProtocol = flowState.stickyApplicationProtocol {
            let stickySummary = flowState.stickySummary.map { "sticky:\($0)" }
            return UDPProtocolClassifier.Classification(
                applicationProtocol: stickyProtocol,
                parserOutcome: .fallbackSignatureOnly,
                summary: stickySummary
            )
        }

        if sourcePort == 53 || destinationPort == 53 {
            return UDPProtocolClassifier.Classification(
                applicationProtocol: .dns,
                parserOutcome: .fallbackSignatureOnly,
                summary: "tcp/53 signature_fallback"
            )
        }

        if isLikelyTLSPort(sourcePort) || isLikelyTLSPort(destinationPort) {
            return UDPProtocolClassifier.Classification(
                applicationProtocol: .tls,
                parserOutcome: .fallbackSignatureOnly,
                summary: "tcp/\(signaturePortHint(sourcePort: sourcePort, destinationPort: destinationPort)) signature_tls"
            )
        }

        if isLikelyHTTPPort(sourcePort) || isLikelyHTTPPort(destinationPort) {
            return UDPProtocolClassifier.Classification(
                applicationProtocol: .http,
                parserOutcome: .fallbackSignatureOnly,
                summary: "tcp/\(signaturePortHint(sourcePort: sourcePort, destinationPort: destinationPort)) signature_http"
            )
        }

        if !hasPayload, sourcePort == 443 || destinationPort == 443 {
            return UDPProtocolClassifier.Classification(
                applicationProtocol: .tls,
                parserOutcome: .fallbackSignatureOnly,
                summary: "tcp/443 ack_or_control"
            )
        }

        return classification
    }

    private func isLikelyTLSPort(_ port: UInt16) -> Bool {
        switch port {
        case 443, 465, 853, 993, 995, 8443, 9443:
            true
        default:
            false
        }
    }

    private func isLikelyHTTPPort(_ port: UInt16) -> Bool {
        switch port {
        case 80, 81, 3000, 3128, 8000, 8080, 8081, 8888:
            true
        default:
            false
        }
    }

    private func signaturePortHint(sourcePort: UInt16, destinationPort: UInt16) -> UInt16 {
        if sourcePort <= 1024 {
            return sourcePort
        }
        if destinationPort <= 1024 {
            return destinationPort
        }
        return destinationPort
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
        var parts = ["TLS"]

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

    private func tcpOptionsMetadata(from options: TCPPacket.Options) -> TransportTCPPacketOptions? {
        let sackPermitted: Bool? = options.sackPermitted ? true : nil
        let timestamp = options.timestamps.map {
            TransportTCPPacketTimestamp(value: $0.value, echoReply: $0.echo)
        }
        guard options.mss != nil || options.windowScale != nil || sackPermitted != nil || timestamp != nil else {
            return nil
        }
        return TransportTCPPacketOptions(
            maximumSegmentSize: options.mss,
            windowScale: options.windowScale,
            sackPermitted: sackPermitted,
            timestamps: timestamp
        )
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

    private func storedPacket(from packet: Data) -> BodyStorage? {
        guard captureBody, maxBodySize > 0, !packet.isEmpty else { return nil }
        return BodyStorage.from(
            data: packet,
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
