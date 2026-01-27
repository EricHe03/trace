//
//  PacketFlowLoop.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/19.
//

import Foundation
import NetworkExtension
import OSLog
import TraceCore
import TracePacket
import TraceProxy

final class PacketCapturePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.trace.vpn.packet_capture", qos: .utility)
    private let pendingLock = NSLock()
    private let maxPending: Int
    private let logSampler = LogSampler()
    private let reassembler = TCPReassembler()
    private let flowRecorder = PacketFlowRecorder()
    private let udpFlowManager = UDPFlowManager()
    private var pendingCount = 0

    private var enabled = false
    private var limit: UInt64 = 0
    private var bytes: UInt64 = 0
    private var writer: PCAPWriting?

    init(maxPending: Int) {
        self.maxPending = max(1, maxPending)
    }

    func configure(enabled: Bool, limit: UInt64, writer: PCAPWriting?) {
        queue.async { [weak self] in
            guard let self else { return }
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
            self?.limit = limit
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.enabled = false
            self.writer?.close()
            self.writer = nil
        }
    }

    func enqueue(packet: Data) -> Bool {
        pendingLock.lock()
        let hasCapacity = pendingCount < maxPending
        if hasCapacity {
            pendingCount += 1
        }
        pendingLock.unlock()

        guard hasCapacity else {
            if logSampler.shouldLog(event: "vpn.packet_capture_drop", key: "pending_full", first: 5, every: 200) {
                VPNLog.tunnel.warning("event=vpn.packet_capture_drop outcome=skipped reason=pending_full")
            }
            return false
        }

        queue.async { [weak self] in
            defer {
                self?.pendingLock.lock()
                self?.pendingCount = max(0, (self?.pendingCount ?? 1) - 1)
                self?.pendingLock.unlock()
            }

            guard let self else { return }
            if self.enabled, let writer = self.writer {
                if self.limit > 0, !writer.supportsRolling {
                    let projected = self.bytes + UInt64(packet.count)
                    if projected > self.limit {
                        self.enabled = false
                        VPNLog.tunnel.warning("event=vpn.packet_capture_limit_reached outcome=disabled limit=\(self.limit) current=\(self.bytes)")
                        return
                    }
                    self.bytes = projected
                }

                writer.writePacket(packet)
            }

            self.processParsedPacket(packet: packet)
        }

        return true
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
        for output in outputs where !output.data.isEmpty {
            flowRecorder.processReassembled(flow: output.flow, data: output.data, isFinal: output.isFinal)
            if logSampler.shouldLog(event: "vpn.stream_reassembly", key: output.flow.description, first: 3, every: 200) {
                VPNLog.tunnel.debug(
                    "event=vpn.stream_reassembly outcome=success flow=\(output.flow.description, privacy: .private(mask: .hash)) bytes=\(output.data.count) final=\(output.isFinal)"
                )
            }
        }
    }
}

protocol PacketForwardingEngine: AnyObject {
    func start()
    func stop()
    func enqueue(packets: [Data], protocols: [NSNumber])
}

final class PacketFlowLoop {
    private let packetFlow: NEPacketTunnelFlow
    private let capturePipeline: PacketCapturePipeline
    private weak var forwarder: PacketForwardingEngine?
    private weak var udpForwarder: UDPForwarder?
    private let udpForwardingMode: UDPForwardingMode
    private var blockQUICEnabled: Bool
    private let queue = DispatchQueue(label: "com.trace.vpn.packet_flow_loop", qos: .userInitiated)
    private var isRunning = false
    private var isStopping = false
    private var hasPendingRead = false
    private let logSampler = LogSampler()
    private var udpForwardedPackets: UInt64 = 0
    private var udpForwardedPackets443: UInt64 = 0
    private var quicBlockedPackets: UInt64 = 0

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
        queue.async { [weak self] in
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

    private func scheduleRead() {
        queue.async { [weak self] in
            self?.readOnce()
        }
    }

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

                for packet in packets {
                    _ = self.capturePipeline.enqueue(packet: packet)
                }

                if let udpForwarder = self.udpForwarder {
                    var forwardPackets: [Data] = []
                    var forwardProtocols: [NSNumber] = []

                    for (index, packet) in packets.enumerated() {
                        if let ipPacket = IPPacketParser.parse(packet), ipPacket.transport == .udp,
                           let udpPacket = UDPParser.parse(ipPacket.payload) {
                            let isQUIC = udpPacket.destinationPort == 443 || udpPacket.sourcePort == 443
                            if self.blockQUICEnabled, isQUIC {
                                if self.logSampler.shouldLog(event: "vpn.packet_forward", key: "quic_blocked", first: 3, every: 200) {
                                    VPNLog.tunnel.info("event=vpn.packet_forward outcome=skipped reason=quic_blocked")
                                }
                                self.quicBlockedPackets &+= 1
                                continue
                            }

                            switch self.udpForwardingMode {
                            case .direct:
                                udpForwarder.enqueue(packet: packet, ipPacket: ipPacket)
                            case .split where isQUIC:
                                forwardPackets.append(packet)
                                if protocols.indices.contains(index) {
                                    forwardProtocols.append(protocols[index])
                                }
                                self.udpForwardedPackets &+= 1
                                if isQUIC {
                                    self.udpForwardedPackets443 &+= 1
                                }
                            case .split, .hevOnly:
                                udpForwarder.enqueue(packet: packet, ipPacket: ipPacket)
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
                            let isQUIC = udpPacket.destinationPort == 443 || udpPacket.sourcePort == 443
                            if self.blockQUICEnabled, isQUIC {
                                if self.logSampler.shouldLog(event: "vpn.packet_forward", key: "quic_blocked", first: 3, every: 200) {
                                    VPNLog.tunnel.info("event=vpn.packet_forward outcome=skipped reason=quic_blocked")
                                }
                                self.quicBlockedPackets &+= 1
                                continue
                            }
                            self.udpForwardedPackets &+= 1
                            if isQUIC {
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
        guard self.udpForwardedPackets > 0 || self.udpForwardedPackets443 > 0 || self.quicBlockedPackets > 0 else { return }
        VPNLog.tunnel.info(
            "event=vpn.udp_forward_summary reason=\(reason) udp_out_packets=\(self.udpForwardedPackets) udp_out_443=\(self.udpForwardedPackets443) quic_blocked=\(self.quicBlockedPackets)"
        )
    }
}
