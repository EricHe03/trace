//
//  UDPForwarder.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/21.
//

import Darwin
import Foundation
import NetworkExtension
import NIOCore
import NIOTransportServices
import os
import TraceCore
import TracePacket

final class UDPForwarder: @unchecked Sendable {
    fileprivate struct FlowKey: Hashable {
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
        let remoteAddress: SocketAddress
        var channel: Channel?
        var lastActivity: Date
        var isReady = false
        var pendingPayloads: [Data] = []
        var pendingPayloadBytes = 0

        init(key: FlowKey, remoteAddress: SocketAddress, lastActivity: Date) {
            self.key = key
            self.remoteAddress = remoteAddress
            self.lastActivity = lastActivity
        }
    }

    private let packetFlow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "com.trace.vpn.udp_forwarder", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let cleanupInterval: TimeInterval
    private let idleTimeout: TimeInterval
    private let maxPendingPayloadPackets: Int
    private let maxPendingPayloadBytes: Int
    private let inboundPacketObserver: (@Sendable (Data) -> Void)?
    private let inboundPacketInterceptor: (@Sendable (Data) -> Bool)?
    private let logSampler = LogSampler()
    private let runtimeLock = NSLock()

    private var group: NIOTSEventLoopGroup?
    private var runtimeAcquired = false
    private var connections: [FlowKey: UDPForwardConnection] = [:]
    private var cleanupTimer: DispatchSourceTimer?
    private var packetIdentifier: UInt16 = 0
    private var metrics = Metrics()

    init(
        packetFlow: NEPacketTunnelFlow,
        idleTimeout: TimeInterval = 120,
        cleanupInterval: TimeInterval = 30,
        maxPendingPayloadPackets: Int = 128,
        maxPendingPayloadBytes: Int = 1_048_576,
        inboundPacketObserver: (@Sendable (Data) -> Void)? = nil,
        inboundPacketInterceptor: (@Sendable (Data) -> Bool)? = nil
    ) {
        self.packetFlow = packetFlow
        self.idleTimeout = idleTimeout
        self.cleanupInterval = cleanupInterval
        self.maxPendingPayloadPackets = max(1, maxPendingPayloadPackets)
        self.maxPendingPayloadBytes = max(1024, maxPendingPayloadBytes)
        self.inboundPacketObserver = inboundPacketObserver
        self.inboundPacketInterceptor = inboundPacketInterceptor
        queue.setSpecific(key: queueKey, value: ())

        let resources = NIORuntime.shared.acquire(for: .networkExtension)
        if let eventLoopGroup = resources.eventLoopGroup as? NIOTSEventLoopGroup {
            group = eventLoopGroup
            setRuntimeAcquired(true)
        } else {
            try? NIORuntime.shared.release(for: .networkExtension)
            group = nil
            setRuntimeAcquired(false)
            VPNLog.tunnel.error("event=vpn.udp_forward_runtime outcome=failure reason=event_loop_group_unavailable")
        }

        start()
    }

    deinit {
        stopSync()
    }

    func start() {
        queue.async { [weak self] in
            self?.startCleanupTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    func isAvailable() -> Bool {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return runtimeAcquired
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

            self.send(payload: payload, on: connection)
        }
    }

    private func connection(for key: FlowKey, port: UInt16) -> UDPForwardConnection? {
        if let existing = connections[key] {
            return existing
        }

        guard let group else {
            if logSampler.shouldLog(event: "vpn.udp_forward_connect", key: "missing_runtime", first: 3, every: 200) {
                VPNLog.tunnel.warning("event=vpn.udp_forward_connect outcome=failure reason=missing_runtime")
            }
            return nil
        }

        let host = key.destinationIP.description
        let remoteAddress = (try? SocketAddress(ipAddress: host, port: Int(port))) ??
            (try? SocketAddress.makeAddressResolvingHost(host, port: Int(port)))

        guard let remoteAddress else { return nil }

        let connection = UDPForwardConnection(key: key, remoteAddress: remoteAddress, lastActivity: Date())
        connections[key] = connection

        metrics.flowsCreated &+= 1
        metrics.flowsActive &+= 1

        let bootstrap = NIOTSDatagramConnectionBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return channel.pipeline.addHandler(UDPForwardInboundHandler(owner: self, key: key))
            }

        bootstrap.connect(to: remoteAddress).whenComplete { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case let .success(channel):
                    guard let current = self.connections[key] else {
                        channel.close(promise: nil)
                        return
                    }
                    current.channel = channel
                    current.isReady = true

                    channel.closeFuture.whenComplete { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            self.removeConnection(for: key, closeChannel: false)
                        }
                    }

                    if !current.pendingPayloads.isEmpty {
                        let pending = current.pendingPayloads
                        current.pendingPayloads.removeAll(keepingCapacity: true)
                        current.pendingPayloadBytes = 0
                        for payload in pending {
                            self.send(payload: payload, on: current)
                        }
                    }
                case let .failure(error):
                    self.removeConnection(for: key, closeChannel: false)
                    if self.logSampler.shouldLog(event: "vpn.udp_forward_connect", key: "error", first: 3, every: 200) {
                        VPNLog.tunnel.warning("event=vpn.udp_forward_connect outcome=failure error=\(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        return connection
    }

    private func send(payload: Data, on connection: UDPForwardConnection) {
        guard connection.isReady, let channel = connection.channel, channel.isActive else {
            enqueuePendingPayload(payload, on: connection)
            return
        }

        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if self.logSampler.shouldLog(event: "vpn.udp_forward_send", key: "error", first: 3, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.udp_forward_send outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        channel.writeAndFlush(buffer, promise: promise)
    }

    fileprivate func handleInbound(payload: Data, for key: FlowKey) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.connections[key] else { return }

            connection.lastActivity = Date()
            self.metrics.udpInPackets &+= 1
            if key.destinationPort == 443 {
                self.metrics.udpIn443 &+= 1
            }
            self.handleInboundPayload(payload, for: key)
        }
    }

    fileprivate func handleChannelInactive(for key: FlowKey) {
        queue.async { [weak self] in
            self?.removeConnection(for: key, closeChannel: false)
        }
    }

    private func handleInboundPayload(_ payload: Data, for key: FlowKey) {
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
            emitInboundPacket(packet, protocolNumber: NSNumber(value: AF_INET))

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
            emitInboundPacket(packet, protocolNumber: NSNumber(value: AF_INET6))

        default:
            return
        }
    }

    private func emitInboundPacket(_ packet: Data, protocolNumber: NSNumber) {
        inboundPacketObserver?(packet)
        if inboundPacketInterceptor?(packet) == true {
            return
        }
        packetFlow.writePackets([packet], withProtocols: [protocolNumber])
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

        for (key, _) in expired {
            removeConnection(for: key, closeChannel: true)
        }

        if logSampler.shouldLog(event: "vpn.udp_forward_metrics", key: "periodic", first: 2, every: 120) {
            logSummary(reason: "periodic")
        }
    }

    private func removeConnection(for key: FlowKey, closeChannel: Bool) {
        guard let connection = connections.removeValue(forKey: key) else {
            return
        }

        if closeChannel, let channel = connection.channel {
            channel.close(promise: nil)
        }

        if metrics.flowsActive > 0 {
            metrics.flowsActive &-= 1
        }

        connection.pendingPayloads.removeAll()
        connection.pendingPayloadBytes = 0
    }

    private func logSummary(reason: String) {
        VPNLog.tunnel.info(
            "event=vpn.udp_forward_metrics reason=\(reason) udp_flows_created=\(self.metrics.flowsCreated) udp_flows_active=\(self.metrics.flowsActive) udp_out_packets=\(self.metrics.udpOutPackets) udp_in_packets=\(self.metrics.udpInPackets) udp_out_443=\(self.metrics.udpOut443) udp_in_443=\(self.metrics.udpIn443)"
        )
    }

    private func setRuntimeAcquired(_ value: Bool) {
        runtimeLock.lock()
        runtimeAcquired = value
        runtimeLock.unlock()
    }

    private func stopSync() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
            return
        }
        queue.sync { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        logSummary(reason: "stop")

        cleanupTimer?.cancel()
        cleanupTimer = nil

        for connection in connections.values {
            if let channel = connection.channel {
                channel.close(promise: nil)
            }
        }
        connections.removeAll()

        if isAvailable() {
            setRuntimeAcquired(false)
            group = nil
            try? NIORuntime.shared.release(for: .networkExtension)
        }
    }

    private func enqueuePendingPayload(_ payload: Data, on connection: UDPForwardConnection) {
        let projectedBytes = connection.pendingPayloadBytes + payload.count
        let overPacketLimit = connection.pendingPayloads.count >= maxPendingPayloadPackets
        let overByteLimit = projectedBytes > maxPendingPayloadBytes
        guard !overPacketLimit, !overByteLimit else {
            if logSampler.shouldLog(event: "vpn.udp_forward_pending", key: "overflow", first: 5, every: 200) {
                VPNLog.tunnel.warning(
                    "event=vpn.udp_forward_pending outcome=skipped reason=overflow packets=\(connection.pendingPayloads.count) bytes=\(connection.pendingPayloadBytes)"
                )
            }
            return
        }

        connection.pendingPayloads.append(payload)
        connection.pendingPayloadBytes = projectedBytes
    }
}

private final class UDPForwardInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var owner: UDPForwarder?
    private let key: UDPForwarder.FlowKey

    init(owner: UDPForwarder, key: UDPForwarder.FlowKey) {
        self.owner = owner
        self.key = key
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let payload = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        guard !payload.isEmpty else { return }
        owner?.handleInbound(payload: payload, for: key)
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.handleChannelInactive(for: key)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner?.handleChannelInactive(for: key)
        context.close(promise: nil)
    }
}
