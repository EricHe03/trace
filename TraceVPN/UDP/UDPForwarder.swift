//
//  UDPForwarder.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/21.
//

import Darwin
import Foundation
import Network
import NetworkExtension
import os
import TraceCore
import TracePacket

final class UDPForwarder: @unchecked Sendable {
    private struct FlowKey: Hashable {
        let sourceIP: TracePacket.IPAddress
        let sourcePort: UInt16
        let destinationIP: TracePacket.IPAddress
        let destinationPort: UInt16
    }

    private struct Metrics {
        var flowsCreated: UInt64 = 0
        var flowsActive: UInt64 = 0
        var udpOutPackets: UInt64 = 0
        var udpInPackets: UInt64 = 0
        var udpOut443: UInt64 = 0
        var udpIn443: UInt64 = 0
    }

    private final class UDPForwardConnection: @unchecked Sendable {
        let key: FlowKey
        let connection: NWConnection
        var lastActivity: Date
        var isReady = false

        init(key: FlowKey, connection: NWConnection, lastActivity: Date) {
            self.key = key
            self.connection = connection
            self.lastActivity = lastActivity
        }
    }

    private let packetFlow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "com.trace.vpn.udp_forwarder", qos: .userInitiated)
    private let cleanupInterval: TimeInterval
    private let idleTimeout: TimeInterval
    private var connections: [FlowKey: UDPForwardConnection] = [:]
    private var cleanupTimer: DispatchSourceTimer?
    private let logSampler = LogSampler()
    private var packetIdentifier: UInt16 = 0
    private var metrics = Metrics()

    init(packetFlow: NEPacketTunnelFlow, idleTimeout: TimeInterval = 120, cleanupInterval: TimeInterval = 30) {
        self.packetFlow = packetFlow
        self.idleTimeout = idleTimeout
        self.cleanupInterval = cleanupInterval
        start()
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            self?.startCleanupTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.logSummary(reason: "stop")
            self.cleanupTimer?.cancel()
            self.cleanupTimer = nil
            for connection in self.connections.values {
                connection.connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    func enqueue(packet: Data, ipPacket: IPPacket) {
        guard let udpPacket = UDPParser.parse(ipPacket.payload) else { return }

        let key = FlowKey(
            sourceIP: ipPacket.source,
            sourcePort: udpPacket.sourcePort,
            destinationIP: ipPacket.destination,
            destinationPort: udpPacket.destinationPort
        )

        queue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.connection(for: key, port: udpPacket.destinationPort) else { return }
            connection.lastActivity = Date()

            let payload = udpPacket.payload
            guard !payload.isEmpty else { return }

            self.metrics.udpOutPackets &+= 1
            if udpPacket.destinationPort == 443 {
                self.metrics.udpOut443 &+= 1
            }

            connection.connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error, self.logSampler.shouldLog(event: "vpn.udp_forward_send", key: "error", first: 3, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.udp_forward_send outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    private func connection(for key: FlowKey, port: UInt16) -> UDPForwardConnection? {
        if let existing = connections[key] {
            return existing
        }

        let host = NWEndpoint.Host(key.destinationIP.description)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.prohibitedInterfaceTypes = [.loopback, .other]

        let connection = NWConnection(host: host, port: endpointPort, using: parameters)
        let newConnection = UDPForwardConnection(key: key, connection: connection, lastActivity: Date())
        connections[key] = newConnection
        metrics.flowsCreated &+= 1
        metrics.flowsActive &+= 1

        connection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                newConnection.isReady = true
                self.receiveLoop(for: newConnection)
            case .failed, .cancelled:
                self.removeConnection(for: key)
            default:
                break
            }
        }

        connection.start(queue: queue)
        return newConnection
    }

    private func receiveLoop(for connection: UDPForwardConnection) {
        connection.connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.handleInbound(payload: data, for: connection.key)
                connection.lastActivity = Date()
                self.metrics.udpInPackets &+= 1
                if connection.key.destinationPort == 443 {
                    self.metrics.udpIn443 &+= 1
                }
            }

            if let error {
                if self.logSampler.shouldLog(event: "vpn.udp_forward_receive", key: "error", first: 3, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.udp_forward_receive outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
                self.removeConnection(for: connection.key)
                return
            }

            self.receiveLoop(for: connection)
        }
    }

    private func handleInbound(payload: Data, for key: FlowKey) {
        switch (key.destinationIP, key.sourceIP) {
        case let (.v4(srcIP), .v4(dstIP)):
            let udpPacket = buildUDPDatagramV4(
                sourcePort: key.destinationPort,
                destinationPort: key.sourcePort,
                payload: payload,
                sourceIP: srcIP,
                destinationIP: dstIP
            )

            let packet = buildIPv4Packet(
                sourceIP: srcIP,
                destinationIP: dstIP,
                payload: udpPacket
            )

            packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        case let (.v6(srcIP), .v6(dstIP)):
            let udpPacket = buildUDPDatagramV6(
                sourcePort: key.destinationPort,
                destinationPort: key.sourcePort,
                payload: payload,
                sourceIP: srcIP,
                destinationIP: dstIP
            )

            let packet = buildIPv6Packet(
                sourceIP: srcIP,
                destinationIP: dstIP,
                payload: udpPacket
            )

            packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET6)])
        default:
            return
        }
    }

    private func buildUDPDatagramV4(
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data,
        sourceIP: UInt32,
        destinationIP: UInt32
    ) -> Data {
        let length = UInt16(8 + payload.count)
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = UInt8(sourcePort >> 8)
        header[1] = UInt8(sourcePort & 0xFF)
        header[2] = UInt8(destinationPort >> 8)
        header[3] = UInt8(destinationPort & 0xFF)
        header[4] = UInt8(length >> 8)
        header[5] = UInt8(length & 0xFF)

        var checksum = udpChecksumV4(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            udpHeader: header,
            payload: payload
        )
        if checksum == 0 {
            checksum = 0xFFFF
        }
        header[6] = UInt8(checksum >> 8)
        header[7] = UInt8(checksum & 0xFF)

        var data = Data(header)
        data.append(payload)
        return data
    }

    private func buildUDPDatagramV6(
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data,
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64)
    ) -> Data {
        let length = UInt16(8 + payload.count)
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = UInt8(sourcePort >> 8)
        header[1] = UInt8(sourcePort & 0xFF)
        header[2] = UInt8(destinationPort >> 8)
        header[3] = UInt8(destinationPort & 0xFF)
        header[4] = UInt8(length >> 8)
        header[5] = UInt8(length & 0xFF)

        let checksum = udpChecksumV6(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            udpHeader: header,
            payload: payload
        )
        header[6] = UInt8(checksum >> 8)
        header[7] = UInt8(checksum & 0xFF)

        var data = Data(header)
        data.append(payload)
        return data
    }

    private func buildIPv4Packet(sourceIP: UInt32, destinationIP: UInt32, payload: Data) -> Data {
        let totalLength = 20 + payload.count
        packetIdentifier &+= 1

        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        header[1] = 0x00
        header[2] = UInt8((totalLength >> 8) & 0xFF)
        header[3] = UInt8(totalLength & 0xFF)
        header[4] = UInt8(packetIdentifier >> 8)
        header[5] = UInt8(packetIdentifier & 0xFF)
        header[6] = 0x00
        header[7] = 0x00
        header[8] = 64
        header[9] = 17
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

        let checksum = ipChecksum(header)
        header[10] = UInt8(checksum >> 8)
        header[11] = UInt8(checksum & 0xFF)

        var data = Data(header)
        data.append(payload)
        return data
    }

    private func buildIPv6Packet(
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64),
        payload: Data
    ) -> Data {
        let payloadLength = payload.count
        var header = [UInt8](repeating: 0, count: 40)
        header[0] = 0x60
        header[4] = UInt8((payloadLength >> 8) & 0xFF)
        header[5] = UInt8(payloadLength & 0xFF)
        header[6] = 17
        header[7] = 64

        writeIPv6Address(sourceIP, into: &header, offset: 8)
        writeIPv6Address(destinationIP, into: &header, offset: 24)

        var data = Data(header)
        data.append(payload)
        return data
    }

    private func ipChecksum(_ header: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index < header.count {
            let word = UInt16(header[index]) << 8 | UInt16(header[index + 1])
            sum += UInt32(word)
            index += 2
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func udpChecksumV4(
        sourceIP: UInt32,
        destinationIP: UInt32,
        udpHeader: [UInt8],
        payload: Data
    ) -> UInt16 {
        var sum: UInt32 = 0

        sum += UInt32((sourceIP >> 16) & 0xFFFF)
        sum += UInt32(sourceIP & 0xFFFF)
        sum += UInt32((destinationIP >> 16) & 0xFFFF)
        sum += UInt32(destinationIP & 0xFFFF)
        sum += UInt32(17)
        let udpLength = UInt16(udpHeader.count + payload.count)
        sum += UInt32(udpLength)

        var index = 0
        while index < udpHeader.count {
            let word = UInt16(udpHeader[index]) << 8 | UInt16(udpHeader[index + 1])
            sum += UInt32(word)
            index += 2
        }

        var payloadBytes = [UInt8](payload)
        if payloadBytes.count % 2 != 0 {
            payloadBytes.append(0)
        }
        index = 0
        while index < payloadBytes.count {
            let word = UInt16(payloadBytes[index]) << 8 | UInt16(payloadBytes[index + 1])
            sum += UInt32(word)
            index += 2
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func udpChecksumV6(
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64),
        udpHeader: [UInt8],
        payload: Data
    ) -> UInt16 {
        var sum: UInt32 = 0

        sum += checksumWord(from: sourceIP.0)
        sum += checksumWord(from: sourceIP.1)
        sum += checksumWord(from: destinationIP.0)
        sum += checksumWord(from: destinationIP.1)

        let udpLength = UInt32(udpHeader.count + payload.count)
        sum += UInt32((udpLength >> 16) & 0xFFFF)
        sum += UInt32(udpLength & 0xFFFF)
        sum += UInt32(17)

        var index = 0
        while index < udpHeader.count {
            let word = UInt16(udpHeader[index]) << 8 | UInt16(udpHeader[index + 1])
            sum += UInt32(word)
            index += 2
        }

        var payloadBytes = [UInt8](payload)
        if payloadBytes.count % 2 != 0 {
            payloadBytes.append(0)
        }
        index = 0
        while index < payloadBytes.count {
            let word = UInt16(payloadBytes[index]) << 8 | UInt16(payloadBytes[index + 1])
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

    private func startCleanupTimer() {
        if cleanupTimer != nil {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + cleanupInterval, repeating: cleanupInterval)
        timer.setEventHandler { [weak self] in
            self?.cleanupExpiredConnections()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func cleanupExpiredConnections() {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        let expired = connections.filter { $0.value.lastActivity < cutoff }
        guard !expired.isEmpty else { return }

        for (key, connection) in expired {
            connection.connection.cancel()
            removeConnection(for: key)
        }

        if logSampler.shouldLog(event: "vpn.udp_forward_metrics", key: "periodic", first: 2, every: 120) {
            logSummary(reason: "periodic")
        }
    }

    private func removeConnection(for key: FlowKey) {
        if connections.removeValue(forKey: key) != nil, self.metrics.flowsActive > 0 {
            self.metrics.flowsActive &-= 1
        }
    }

    private func logSummary(reason: String) {
        VPNLog.tunnel.info(
            "event=vpn.udp_forward_metrics reason=\(reason) udp_flows_created=\(self.metrics.flowsCreated) udp_flows_active=\(self.metrics.flowsActive) udp_out_packets=\(self.metrics.udpOutPackets) udp_in_packets=\(self.metrics.udpInPackets) udp_out_443=\(self.metrics.udpOut443) udp_in_443=\(self.metrics.udpIn443)"
        )
    }
}
