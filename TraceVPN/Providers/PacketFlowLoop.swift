//
//  PacketFlowLoop.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/19.
//

import Darwin
import Foundation
import NetworkExtension
import OSLog
import TraceCore
import TracePacket
import TraceProxy

final class PacketCapturePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.trace.vpn.packet_capture", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let pendingLock = NSLock()
    private let maxPending: Int
    private let logSampler = LogSampler()
    private let reassembler = TCPReassembler()
    private let flowRecorder = PacketFlowRecorder()
    private let udpFlowManager = UDPFlowManager()
    private var pendingCount = 0
    private var isStopped = false

    private var enabled = false
    private var limit: UInt64 = 0
    private var bytes: UInt64 = 0
    private var writer: PCAPWriting?

    init(maxPending: Int) {
        self.maxPending = max(1, maxPending)
        queue.setSpecific(key: queueKey, value: ())
    }

    func configure(enabled: Bool, limit: UInt64, writer: PCAPWriting?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let stopped = self.isStopped
            self.pendingLock.unlock()
            guard !stopped else {
                writer?.close()
                return
            }

            if let current = self.writer, let next = writer {
                if current !== next {
                    current.close()
                }
            } else if writer == nil {
                self.writer?.close()
            }
            self.enabled = enabled
            self.limit = limit
            self.writer = writer
            self.bytes = writer?.currentFileSize() ?? 0
            if enabled, writer != nil {
                VPNLog.tunnel.info("event=vpn.packet_capture_config outcome=success enabled=true limit=\(limit)")
            } else {
                VPNLog.tunnel.info("event=vpn.packet_capture_config outcome=success enabled=false")
            }
        }
    }

    func updateLimit(_ limit: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let stopped = self.isStopped
            self.pendingLock.unlock()
            guard !stopped else { return }
            self.limit = limit
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
            return
        }

        pendingLock.lock()
        isStopped = true
        pendingLock.unlock()

        queue.sync { [weak self] in
            self?.stopOnQueue()
        }
    }

    func enqueue(packet: Data) -> Bool {
        enqueue(packets: [packet]) == 1
    }

    @discardableResult
    func enqueue(packets: [Data]) -> Int {
        guard !packets.isEmpty else { return 0 }

        let acceptedPackets: [Data]
        let droppedCount: Int
        pendingLock.lock()
        if isStopped {
            pendingLock.unlock()
            return 0
        }
        let available = max(0, maxPending - pendingCount)
        let acceptedCount = min(available, packets.count)
        if acceptedCount > 0 {
            pendingCount += acceptedCount
            acceptedPackets = Array(packets.prefix(acceptedCount))
        } else {
            acceptedPackets = []
        }
        droppedCount = packets.count - acceptedCount
        pendingLock.unlock()

        if droppedCount > 0 {
            if logSampler.shouldLog(event: "vpn.packet_capture_drop", key: "pending_full", first: 5, every: 200) {
                VPNLog.tunnel.warning("event=vpn.packet_capture_drop outcome=skipped reason=pending_full count=\(droppedCount)")
            }
        }

        guard !acceptedPackets.isEmpty else {
            return 0
        }

        queue.async { [weak self] in
            defer {
                self?.pendingLock.lock()
                self?.pendingCount = max(0, (self?.pendingCount ?? acceptedCount) - acceptedCount)
                self?.pendingLock.unlock()
            }

            guard let self else { return }
            if self.enabled, let writer = self.writer {
                let packetsToWrite: [Data]
                if self.limit > 0, !writer.supportsRolling {
                    var limitedPackets: [Data] = []
                    limitedPackets.reserveCapacity(acceptedPackets.count)
                    for packet in acceptedPackets {
                        let projected = self.bytes + UInt64(packet.count)
                        if projected > self.limit {
                            self.enabled = false
                            VPNLog.tunnel.warning("event=vpn.packet_capture_limit_reached outcome=disabled limit=\(self.limit) current=\(self.bytes)")
                            break
                        }
                        self.bytes = projected
                        limitedPackets.append(packet)
                    }
                    packetsToWrite = limitedPackets
                } else {
                    packetsToWrite = acceptedPackets
                }

                if !packetsToWrite.isEmpty {
                    writer.writePackets(packetsToWrite)
                }
            }

            for packet in acceptedPackets {
                self.processParsedPacket(packet: packet)
            }
        }

        return acceptedCount
    }

    private func processParsedPacket(packet: Data) {
        guard let ipPacket = IPPacketParser.parse(packet) else { return }
        flowRecorder.process(ipPacket: ipPacket)

        if ipPacket.transport == .udp, let udpPacket = UDPParser.parse(ipPacket.payload) {
            udpFlowManager.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        }

        guard ipPacket.transport == .tcp else { return }
        guard let tcpPacket = TCPParser.parse(ipPacket.payload) else { return }

        let outputs = reassembler.process(ipPacket: ipPacket, tcpPacket: tcpPacket)
        for output in outputs {
            flowRecorder.processReassembled(flow: output.flow, data: output.data, isFinal: output.isFinal)
            if !output.data.isEmpty,
               logSampler.shouldLog(event: "vpn.stream_reassembly", key: output.flow.description, first: 3, every: 200) {
                VPNLog.tunnel.debug(
                    "event=vpn.stream_reassembly outcome=success flow=\(output.flow.description, privacy: .private(mask: .hash)) bytes=\(output.data.count) final=\(output.isFinal)"
                )
            }
        }
    }

    private func stopOnQueue() {
        pendingLock.lock()
        isStopped = true
        pendingCount = 0
        pendingLock.unlock()

        enabled = false
        flowRecorder.shutdown()
        udpFlowManager.shutdown()
        writer?.close()
        writer = nil
    }
}

protocol PacketForwardingEngine: AnyObject {
    func start()
    func stop()
    func enqueue(packets: [Data], protocols: [NSNumber])
}

final class PacketFlowLoop {
    typealias UDPForwardDecision = TraceCore.UDPForwardDecision

    private struct QUICBlockFlowKey: Hashable {
        let sourceIP: TracePacket.IPAddress
        let sourcePort: UInt16
        let destinationIP: TracePacket.IPAddress
        let destinationPort: UInt16
    }

    private static let quicICMPRateLimitNanos: UInt64 = 1_000_000_000
    private static let quicICMPStateCleanupIntervalNanos: UInt64 = 30_000_000_000
    private static let quicICMPStateExpireNanos: UInt64 = 120_000_000_000
    private static let quicICMPStateMaxEntries: Int = 2048

    static func decideUDPForwarding(
        udpForwarderAvailable: Bool,
        mode: UDPForwardingMode,
        sourcePort: UInt16,
        destinationPort: UInt16,
        blockQUICEnabled: Bool,
        tunnelUDPSupported: Bool
    ) -> (decision: UDPForwardDecision, isQUIC: Bool) {
        TraceCore.decideUDPForwarding(
            udpForwarderAvailable: udpForwarderAvailable,
            mode: mode,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            blockQUICEnabled: blockQUICEnabled,
            tunnelUDPSupported: tunnelUDPSupported
        )
    }

    private let packetFlow: NEPacketTunnelFlow
    private let capturePipeline: PacketCapturePipeline
    private weak var forwarder: PacketForwardingEngine?
    private weak var udpForwarder: UDPForwarder?
    private let udpForwardingMode: UDPForwardingMode
    private var blockQUICEnabled: Bool
    private var tunnelUDPSupported = true
    private let queue = DispatchQueue(label: "com.trace.vpn.packet_flow_loop", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var isRunning = false
    private var isStopping = false
    private var hasPendingRead = false
    private let logSampler = LogSampler()
    private var udpForwardedPackets: UInt64 = 0
    private var udpForwardedPackets443: UInt64 = 0
    private var quicBlockedPackets: UInt64 = 0
    private var quicBlockedICMPSent: UInt64 = 0
    private var quicBlockedICMPRateLimited: UInt64 = 0
    private var quicBlockFlowLastICMPSent: [QUICBlockFlowKey: UInt64] = [:]
    private var quicBlockLastCleanup: UInt64 = 0
    private var icmpPacketIdentifier: UInt16 = 0

    init(
        packetFlow: NEPacketTunnelFlow,
        capturePipeline: PacketCapturePipeline,
        forwarder: PacketForwardingEngine?,
        udpForwarder: UDPForwarder?,
        udpForwardingMode: UDPForwardingMode,
        blockQUICEnabled: Bool
    ) {
        self.packetFlow = packetFlow
        self.capturePipeline = capturePipeline
        self.forwarder = forwarder
        self.udpForwarder = udpForwarder
        self.udpForwardingMode = udpForwardingMode
        self.blockQUICEnabled = blockQUICEnabled
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            self.isStopping = false
            VPNLog.tunnel.info("event=vpn.packet_loop_start outcome=success")
            self.scheduleRead()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            isStopping = true
            logUDPForwardSummary(reason: "stop")
            return
        }

        queue.sync { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.logUDPForwardSummary(reason: "stop")
        }
    }

    func updateBlockQUICEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.blockQUICEnabled = enabled
        }
    }

    func updateUDPTunnelSupported(_ supported: Bool) {
        queue.async { [weak self] in
            self?.tunnelUDPSupported = supported
        }
    }

    private func scheduleRead() {
        queue.async { [weak self] in
            self?.readOnce()
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func readOnce() {
        guard !isStopping else {
            isRunning = false
            VPNLog.tunnel.info("event=vpn.packet_loop_stop outcome=success")
            return
        }

        guard !hasPendingRead else { return }
        hasPendingRead = true
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                self.hasPendingRead = false
                guard !self.isStopping else {
                    self.isRunning = false
                    return
                }

                if packets.isEmpty {
                    self.scheduleRead()
                    return
                }

                _ = self.capturePipeline.enqueue(packets: packets)

                if let udpForwarder = self.udpForwarder {
                    let udpForwarderAvailable = udpForwarder.isAvailable()
                    var forwardPackets: [Data] = []
                    var forwardProtocols: [NSNumber] = []

                    for (index, packet) in packets.enumerated() {
                        if let ipPacket = IPPacketParser.parse(packet), ipPacket.transport == .udp,
                           let udpPacket = UDPParser.parse(ipPacket.payload) {
                            let decision = Self.decideUDPForwarding(
                                udpForwarderAvailable: udpForwarderAvailable,
                                mode: self.udpForwardingMode,
                                sourcePort: udpPacket.sourcePort,
                                destinationPort: udpPacket.destinationPort,
                                blockQUICEnabled: self.blockQUICEnabled,
                                tunnelUDPSupported: self.tunnelUDPSupported
                            )

                            if decision.decision == .dropQUIC {
                                if self.logSampler.shouldLog(event: "vpn.packet_forward", key: "quic_blocked", first: 3, every: 200) {
                                    VPNLog.tunnel.info("event=vpn.packet_forward outcome=skipped reason=quic_blocked")
                                }
                                self.quicBlockedPackets &+= 1
                                let proto = protocols.indices.contains(index) ? protocols[index] : nil
                                self.maybeInjectQUICBlockedICMP(
                                    originalPacket: packet,
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    proto: proto
                                )
                                continue
                            }

                            switch decision.decision {
                            case .forwardDirect:
                                if !self.tunnelUDPSupported,
                                   self.udpForwardingMode == .hevOnly || (self.udpForwardingMode == .split && decision.isQUIC),
                                   self.logSampler.shouldLog(event: "vpn.udp_forward_fallback", key: "direct", first: 3, every: 200) {
                                    VPNLog.tunnel.warning(
                                        "event=vpn.udp_forward_fallback outcome=success mode=\(self.udpForwardingMode.rawValue, privacy: .public) action=direct reason=tunnel_udp_unsupported"
                                    )
                                }
                                udpForwarder.enqueue(packet: packet, ipPacket: ipPacket)
                            case .forwardTunnel:
                                forwardPackets.append(packet)
                                if protocols.indices.contains(index) {
                                    forwardProtocols.append(protocols[index])
                                }
                                self.udpForwardedPackets &+= 1
                                if decision.isQUIC {
                                    self.udpForwardedPackets443 &+= 1
                                }
                            case .dropQUIC:
                                break
                            }
                        } else {
                            forwardPackets.append(packet)
                            if protocols.indices.contains(index) {
                                forwardProtocols.append(protocols[index])
                            }
                        }
                    }

                    if let forwarder = self.forwarder, !forwardPackets.isEmpty {
                        forwarder.enqueue(packets: forwardPackets, protocols: forwardProtocols)
                    } else if self.forwarder == nil,
                              self.logSampler.shouldLog(event: "vpn.packet_forward", key: "disabled", first: 3, every: 200) {
                        VPNLog.tunnel.debug("event=vpn.packet_forward outcome=skipped reason=forwarder_disabled")
                    }
                } else if let forwarder = self.forwarder {
                    var forwardPackets: [Data] = []
                    var forwardProtocols: [NSNumber] = []
                    for (index, packet) in packets.enumerated() {
                        if let ipPacket = IPPacketParser.parse(packet), ipPacket.transport == .udp,
                           let udpPacket = UDPParser.parse(ipPacket.payload) {
                            let decision = Self.decideUDPForwarding(
                                udpForwarderAvailable: false,
                                mode: self.udpForwardingMode,
                                sourcePort: udpPacket.sourcePort,
                                destinationPort: udpPacket.destinationPort,
                                blockQUICEnabled: self.blockQUICEnabled,
                                tunnelUDPSupported: self.tunnelUDPSupported
                            )
                            if decision.decision == .dropQUIC {
                                if self.logSampler.shouldLog(event: "vpn.packet_forward", key: "quic_blocked", first: 3, every: 200) {
                                    VPNLog.tunnel.info("event=vpn.packet_forward outcome=skipped reason=quic_blocked")
                                }
                                self.quicBlockedPackets &+= 1
                                let proto = protocols.indices.contains(index) ? protocols[index] : nil
                                self.maybeInjectQUICBlockedICMP(
                                    originalPacket: packet,
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    proto: proto
                                )
                                continue
                            }
                            self.udpForwardedPackets &+= 1
                            if decision.isQUIC {
                                self.udpForwardedPackets443 &+= 1
                            }
                        }
                        forwardPackets.append(packet)
                        if protocols.indices.contains(index) {
                            forwardProtocols.append(protocols[index])
                        }
                    }
                    if !forwardPackets.isEmpty {
                        forwarder.enqueue(packets: forwardPackets, protocols: forwardProtocols)
                    }
                } else if self.logSampler.shouldLog(event: "vpn.packet_forward", key: "disabled", first: 3, every: 200) {
                    VPNLog.tunnel.debug("event=vpn.packet_forward outcome=skipped reason=forwarder_disabled")
                }

                self.scheduleRead()
            }
        }
    }

    private func logUDPForwardSummary(reason: String) {
        guard self.udpForwardedPackets > 0 || self.udpForwardedPackets443 > 0 || self.quicBlockedPackets > 0 || self.quicBlockedICMPSent > 0 else { return }
        VPNLog.tunnel.info(
            "event=vpn.udp_forward_summary reason=\(reason, privacy: .public) udp_out_packets=\(self.udpForwardedPackets) udp_out_443=\(self.udpForwardedPackets443) quic_blocked=\(self.quicBlockedPackets) quic_icmp=\(self.quicBlockedICMPSent) quic_icmp_rl=\(self.quicBlockedICMPRateLimited)"
        )
    }

    private func maybeInjectQUICBlockedICMP(
        originalPacket: Data,
        ipPacket: IPPacket,
        udpPacket: UDPPacket,
        proto: NSNumber?
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        cleanupQUICBlockStateIfNeeded(now: now)

        let flowKey = QUICBlockFlowKey(
            sourceIP: ipPacket.source,
            sourcePort: udpPacket.sourcePort,
            destinationIP: ipPacket.destination,
            destinationPort: udpPacket.destinationPort
        )

        if let last = quicBlockFlowLastICMPSent[flowKey], now &- last < Self.quicICMPRateLimitNanos {
            quicBlockedICMPRateLimited &+= 1
            return
        }
        quicBlockFlowLastICMPSent[flowKey] = now

        guard let icmpPacket = buildICMPPortUnreachable(ipPacket: ipPacket, originalPacket: originalPacket) else { return }
        let protocolNumber = proto ?? NSNumber(value: ipPacket.version == 4 ? AF_INET : AF_INET6)
        packetFlow.writePackets([icmpPacket], withProtocols: [protocolNumber])
        quicBlockedICMPSent &+= 1

        if logSampler.shouldLog(event: "vpn.quic_block_icmp", key: "\(flowKey.hashValue)", first: 3, every: 200) {
            let srcHash = LogRedaction.hash("\(ipPacket.source):\(udpPacket.sourcePort)")
            let dstHash = LogRedaction.hash("\(ipPacket.destination):\(udpPacket.destinationPort)")
            VPNLog.tunnel.info(
                "event=vpn.quic_block_icmp outcome=sent ip_version=\(ipPacket.version) src=\(srcHash, privacy: .public) dst=\(dstHash, privacy: .public)"
            )
        }
    }

    private func cleanupQUICBlockStateIfNeeded(now: UInt64) {
        let shouldCleanupByTime = now &- quicBlockLastCleanup >= Self.quicICMPStateCleanupIntervalNanos
        let shouldCleanupBySize = quicBlockFlowLastICMPSent.count >= Self.quicICMPStateMaxEntries
        guard shouldCleanupByTime || shouldCleanupBySize else { return }
        quicBlockLastCleanup = now

        let cutoff = now > Self.quicICMPStateExpireNanos ? (now - Self.quicICMPStateExpireNanos) : 0
        quicBlockFlowLastICMPSent = quicBlockFlowLastICMPSent.filter { $0.value >= cutoff }
        if quicBlockFlowLastICMPSent.count > Self.quicICMPStateMaxEntries {
            quicBlockFlowLastICMPSent = Dictionary(
                uniqueKeysWithValues: quicBlockFlowLastICMPSent
                    .prefix(Self.quicICMPStateMaxEntries)
                    .map { ($0.key, $0.value) }
            )
        }
    }

    private func buildICMPPortUnreachable(ipPacket: IPPacket, originalPacket: Data) -> Data? {
        let quoteLength = min(originalPacket.count, ipPacket.totalLength, ipPacket.headerLength + 8)
        guard quoteLength > 0 else { return nil }
        let quoted = originalPacket.prefix(quoteLength)

        switch (ipPacket.source, ipPacket.destination) {
        case let (.v4(sourceIP), .v4(destinationIP)):
            return buildIPv4ICMPPortUnreachable(
                sourceIP: destinationIP,
                destinationIP: sourceIP,
                quotedPacket: quoted
            )
        case let (.v6(sourceIP), .v6(destinationIP)):
            return buildIPv6ICMPPortUnreachable(
                sourceIP: destinationIP,
                destinationIP: sourceIP,
                quotedPacket: quoted
            )
        default:
            return nil
        }
    }

    private func buildIPv4ICMPPortUnreachable(sourceIP: UInt32, destinationIP: UInt32, quotedPacket: Data) -> Data {
        var icmpBytes = [UInt8](repeating: 0, count: 8 + quotedPacket.count)
        icmpBytes[0] = 3 // Destination Unreachable
        icmpBytes[1] = 3 // Port Unreachable
        if !quotedPacket.isEmpty {
            icmpBytes.replaceSubrange(8 ..< 8 + quotedPacket.count, with: quotedPacket)
        }
        let icmpChecksum = internetChecksum(icmpBytes)
        icmpBytes[2] = UInt8((icmpChecksum >> 8) & 0xFF)
        icmpBytes[3] = UInt8(icmpChecksum & 0xFF)

        let totalLength = 20 + icmpBytes.count
        icmpPacketIdentifier &+= 1

        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        header[1] = 0x00
        header[2] = UInt8((totalLength >> 8) & 0xFF)
        header[3] = UInt8(totalLength & 0xFF)
        header[4] = UInt8((icmpPacketIdentifier >> 8) & 0xFF)
        header[5] = UInt8(icmpPacketIdentifier & 0xFF)
        header[6] = 0x00
        header[7] = 0x00
        header[8] = 64
        header[9] = 1 // ICMP
        header[10] = 0x00
        header[11] = 0x00
        header[12] = UInt8((sourceIP >> 24) & 0xFF)
        header[13] = UInt8((sourceIP >> 16) & 0xFF)
        header[14] = UInt8((sourceIP >> 8) & 0xFF)
        header[15] = UInt8(sourceIP & 0xFF)
        header[16] = UInt8((destinationIP >> 24) & 0xFF)
        header[17] = UInt8((destinationIP >> 16) & 0xFF)
        header[18] = UInt8((destinationIP >> 8) & 0xFF)
        header[19] = UInt8(destinationIP & 0xFF)

        let checksum = internetChecksum(header)
        header[10] = UInt8((checksum >> 8) & 0xFF)
        header[11] = UInt8(checksum & 0xFF)

        var packet = Data(header)
        packet.append(contentsOf: icmpBytes)
        return packet
    }

    private func buildIPv6ICMPPortUnreachable(
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64),
        quotedPacket: Data
    ) -> Data {
        var icmpBytes = [UInt8](repeating: 0, count: 8 + quotedPacket.count)
        icmpBytes[0] = 1 // Destination Unreachable
        icmpBytes[1] = 4 // Port Unreachable
        if !quotedPacket.isEmpty {
            icmpBytes.replaceSubrange(8 ..< 8 + quotedPacket.count, with: quotedPacket)
        }

        let checksum = icmpv6Checksum(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            message: icmpBytes
        )
        icmpBytes[2] = UInt8((checksum >> 8) & 0xFF)
        icmpBytes[3] = UInt8(checksum & 0xFF)

        var header = [UInt8](repeating: 0, count: 40)
        header[0] = 0x60
        let payloadLength = icmpBytes.count
        header[4] = UInt8((payloadLength >> 8) & 0xFF)
        header[5] = UInt8(payloadLength & 0xFF)
        header[6] = 58 // ICMPv6
        header[7] = 64

        writeIPv6Address(sourceIP, into: &header, offset: 8)
        writeIPv6Address(destinationIP, into: &header, offset: 24)

        var packet = Data(header)
        packet.append(contentsOf: icmpBytes)
        return packet
    }

    private func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            let word = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            sum += UInt32(word)
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(UInt16(bytes[index]) << 8)
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func icmpv6Checksum(
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64),
        message: [UInt8]
    ) -> UInt16 {
        var sum: UInt32 = 0
        sum += checksumWord(from: sourceIP.0)
        sum += checksumWord(from: sourceIP.1)
        sum += checksumWord(from: destinationIP.0)
        sum += checksumWord(from: destinationIP.1)

        let length = UInt32(message.count)
        sum += UInt32((length >> 16) & 0xFFFF)
        sum += UInt32(length & 0xFFFF)
        sum += UInt32(58)

        var bytes = message
        if bytes.count % 2 != 0 {
            bytes.append(0)
        }
        var index = 0
        while index < bytes.count {
            let word = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            sum += UInt32(word)
            index += 2
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func checksumWord(from value: UInt64) -> UInt32 {
        var sum: UInt32 = 0
        sum += UInt32((value >> 48) & 0xFFFF)
        sum += UInt32((value >> 32) & 0xFFFF)
        sum += UInt32((value >> 16) & 0xFFFF)
        sum += UInt32(value & 0xFFFF)
        return sum
    }

    private func writeIPv6Address(_ address: (UInt64, UInt64), into buffer: inout [UInt8], offset: Int) {
        let hi = address.0
        let lo = address.1
        buffer[offset + 0] = UInt8((hi >> 56) & 0xFF)
        buffer[offset + 1] = UInt8((hi >> 48) & 0xFF)
        buffer[offset + 2] = UInt8((hi >> 40) & 0xFF)
        buffer[offset + 3] = UInt8((hi >> 32) & 0xFF)
        buffer[offset + 4] = UInt8((hi >> 24) & 0xFF)
        buffer[offset + 5] = UInt8((hi >> 16) & 0xFF)
        buffer[offset + 6] = UInt8((hi >> 8) & 0xFF)
        buffer[offset + 7] = UInt8(hi & 0xFF)
        buffer[offset + 8] = UInt8((lo >> 56) & 0xFF)
        buffer[offset + 9] = UInt8((lo >> 48) & 0xFF)
        buffer[offset + 10] = UInt8((lo >> 40) & 0xFF)
        buffer[offset + 11] = UInt8((lo >> 32) & 0xFF)
        buffer[offset + 12] = UInt8((lo >> 24) & 0xFF)
        buffer[offset + 13] = UInt8((lo >> 16) & 0xFF)
        buffer[offset + 14] = UInt8((lo >> 8) & 0xFF)
        buffer[offset + 15] = UInt8(lo & 0xFF)
    }
}
