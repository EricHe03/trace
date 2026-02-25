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

final class TransportRequestRecorder {
    private let queue = DispatchQueue(label: "com.trace.vpn.transport_request_recorder", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let logSampler = LogSampler()
    private let configRefreshInterval: TimeInterval = 1
    private var lastConfigRefresh: Date = .distantPast
    private var captureBody = true
    private var maxBodySize = 10 * 1024 * 1024

    init() {
        queue.setSpecific(key: queueKey, value: ())
        refreshCaptureSettingsIfNeeded(force: true, now: Date())
    }

    func shutdown() {
        // No buffered state currently; kept for lifecycle parity with other recorders.
    }

    func process(ipPacket: IPPacket) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            self.refreshCaptureSettingsIfNeeded(force: false, now: now)

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

    private func recordTCP(ipPacket: IPPacket, tcpPacket: TCPPacket, timestamp: Date) {
        // Keep the Network list signal-focused; ACK-only/empty payload packets stay in Connection analytics.
        guard !tcpPacket.payload.isEmpty else { return }

        let sourceIP = ipPacket.source.description
        let destinationIP = ipPacket.destination.description
        let sourcePort = tcpPacket.sourcePort
        let destinationPort = tcpPacket.destinationPort
        let payload = tcpPacket.payload

        let classification = classifyTCPPayload(
            payload: payload,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            destinationIP: destinationIP,
            destinationPort: destinationPort
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
            ipVersion: ipPacket.version,
            protocolNumber: ipPacket.protocolNumber,
            hopLimit: ipPacket.hopLimit,
            ipHeaderLength: ipPacket.headerLength,
            totalLength: ipPacket.totalLength,
            fragmentOffset: ipPacket.fragmentOffset,
            moreFragments: ipPacket.moreFragments,
            summary: classification.summary,
            flowKey: flowKey(
                transport: .tcp,
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destinationIP: destinationIP,
                destinationPort: destinationPort
            )
        )
        persist(request)
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

    private func classifyTCPPayload(
        payload: Data,
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        destinationPort: UInt16
    ) -> UDPProtocolClassifier.Classification {
        // DNS over TCP prepends a 2-byte length prefix to the DNS message.
        if sourcePort == 53 || destinationPort == 53 {
            if payload.count > 2 {
                let declaredLength = Int(UInt16(payload[0]) << 8 | UInt16(payload[1]))
                if declaredLength > 0, payload.count >= declaredLength + 2 {
                    let dnsPayload = payload.subdata(in: 2 ..< 2 + declaredLength)
                    if let dnsMessage = DNSParser.parseSafely(
                        data: dnsPayload,
                        sourceIP: sourceIP,
                        sourcePort: sourcePort,
                        destIP: destinationIP,
                        destPort: destinationPort
                    ) {
                        let summary = "DNS/TCP \(dnsMessage.isResponse ? "response" : "query") \(dnsMessage.queryDomain ?? "-")"
                        return UDPProtocolClassifier.Classification(
                            applicationProtocol: .dns,
                            parserOutcome: .parsed,
                            summary: summary
                        )
                    }
                }
            }
            return UDPProtocolClassifier.Classification(
                applicationProtocol: .unknown,
                parserOutcome: .fallbackSignatureOnly,
                summary: "tcp/53 parse_failed"
            )
        }

        return UDPProtocolClassifier.Classification(
            applicationProtocol: .unknown,
            parserOutcome: .fallbackUnknown,
            summary: nil
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
        do {
            try AppGroupStorage.shared.saveTransportRequest(request)
        } catch {
            if logSampler.shouldLog(event: "vpn.transport_request_store", key: "write_failure", first: 3, every: 200) {
                VPNLog.tunnel.warning(
                    "event=vpn.transport_request_store outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
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
