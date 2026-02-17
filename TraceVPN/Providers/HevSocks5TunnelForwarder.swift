//
//  HevSocks5TunnelForwarder.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/19.
//

import Darwin
import Foundation
import HevSocks5Tunnel
import NIOCore
import NIOTransportServices
import NetworkExtension
import OSLog
import TraceCore

enum Socks5UDPSupport: String {
    case unsupported
    case ipv4Only
    case ipv6
}

extension Socks5UDPSupport {
    func isUsable(forIPv6 ipv6Enabled: Bool) -> Bool {
        switch self {
        case .unsupported:
            false
        case .ipv4Only:
            !ipv6Enabled
        case .ipv6:
            true
        }
    }
}

final class HevSocks5TunnelForwarder: PacketForwardingEngine, @unchecked Sendable {
    private let packetFlow: NEPacketTunnelFlow
    private let tunnelQueue = DispatchQueue(label: "com.trace.vpn.socks5_tunnel", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.trace.vpn.socks5_tunnel.io", qos: .userInitiated)
    private let logSampler = LogSampler()
    private let mtu: Int
    private let socks5Host: String
    private let socks5Port: UInt16
    private let maxInputPending: Int
    private let ipv6Enabled: Bool
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private let udpAssociateProbeHandler: (@Sendable (Socks5UDPSupport) -> Void)?
    private var inputPending = 0
    private var isRunning = false
    private var tunFD: Int32 = -1
    private var bridgeFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(
        packetFlow: NEPacketTunnelFlow,
        socks5Host: String,
        socks5Port: UInt16,
        mtu: Int,
        ipv6Enabled: Bool,
        maxInputPending: Int = 8192,
        eventLogHandler: (@Sendable (String, String) -> Void)? = nil,
        udpAssociateProbeHandler: (@Sendable (Socks5UDPSupport) -> Void)? = nil
    ) {
        self.packetFlow = packetFlow
        self.socks5Host = socks5Host
        self.socks5Port = socks5Port
        self.mtu = max(576, mtu)
        self.ipv6Enabled = ipv6Enabled
        self.maxInputPending = max(1, maxInputPending)
        self.eventLogHandler = eventLogHandler
        self.udpAssociateProbeHandler = udpAssociateProbeHandler
    }

    func start() {
        var shouldStart = false
        var alreadyRunning = false
        var tunFD: Int32 = -1
        ioQueue.sync {
            guard !self.isRunning else {
                alreadyRunning = true
                return
            }
            guard self.setupTunnelSockets() else { return }
            self.isRunning = true
            tunFD = self.tunFD
            self.startReadLoop()
            shouldStart = true
        }

        guard !alreadyRunning else { return }
        guard shouldStart else {
            VPNLog.tunnel.error("event=vpn.socks5_tunnel_start outcome=failure reason=socketpair_failed")
            eventLogHandler?("socks5_tunnel_start", "outcome=failure reason=socketpair_failed")
            return
        }

        let hostHash = LogRedaction.hash(self.socks5Host)
        VPNLog.tunnel.info(
            "event=vpn.socks5_tunnel_config host_hash=\(hostHash) host_len=\(self.socks5Host.count) port=\(self.socks5Port) mtu=\(self.mtu)"
        )
        eventLogHandler?(
            "socks5_tunnel_config",
            "host_hash=\(hostHash) host_len=\(self.socks5Host.count) port=\(self.socks5Port) mtu=\(self.mtu) ipv6=\(self.ipv6Enabled)"
        )

        if let udpAssociateProbeHandler {
            probeSocks5UDPAssociate(completion: udpAssociateProbeHandler)
        }

        let config = buildConfig()
        let tunnelFD = tunFD
        tunnelQueue.async { [weak self] in
            guard let self else { return }
            let result = config.withUnsafeBytes { bytes -> Int32 in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return hev_socks5_tunnel_main_from_str(base, UInt32(bytes.count), Int32(tunnelFD))
            }
            if result == 0 {
                VPNLog.tunnel.info("event=vpn.socks5_tunnel_exit outcome=success")
                self.eventLogHandler?("socks5_tunnel_exit", "outcome=success")
            } else {
                VPNLog.tunnel.error("event=vpn.socks5_tunnel_exit outcome=failure code=\(result)")
                self.eventLogHandler?("socks5_tunnel_exit", "outcome=failure code=\(result)")
            }
        }

        VPNLog.tunnel.info("event=vpn.socks5_tunnel_start outcome=success")
        eventLogHandler?("socks5_tunnel_start", "outcome=success")
    }

    func stop() {
        var shouldStop = false
        ioQueue.sync {
            guard self.isRunning else { return }
            self.isRunning = false
            shouldStop = true
        }
        guard shouldStop else { return }

        tunnelQueue.async {
            hev_socks5_tunnel_quit()
        }

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.readSource?.cancel()
            self.readSource = nil
            self.closeFDs()
            self.inputPending = 0
        }

        VPNLog.tunnel.info("event=vpn.socks5_tunnel_stop outcome=success")
        eventLogHandler?("socks5_tunnel_stop", "outcome=success")
    }

    func enqueue(packets: [Data], protocols: [NSNumber]) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }

            for (index, packet) in packets.enumerated() {
                guard let proto = protocols[safe: index]?.int32Value else { continue }
                guard proto == AF_INET || proto == AF_INET6 else { continue }

                let hasCapacity = self.inputPending < self.maxInputPending
                if hasCapacity {
                    self.inputPending += 1
                }

                guard hasCapacity else {
                    if self.logSampler.shouldLog(event: "vpn.socks5_tunnel_input", key: "pending_full", first: 5, every: 200) {
                        VPNLog.tunnel.warning("event=vpn.socks5_tunnel_input outcome=skipped reason=pending_full")
                    }
                    continue
                }

                self.writePacket(packet, proto: proto)
                self.inputPending = max(0, self.inputPending - 1)
            }
        }
    }

    private func setupTunnelSockets() -> Bool {
        if tunFD >= 0 || bridgeFD >= 0 {
            closeFDs()
        }

        var fds = [Int32](repeating: -1, count: 2)
        let result = socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds)
        guard result == 0 else { return false }

        tunFD = fds[0]
        bridgeFD = fds[1]
        tuneSocketBuffer(fd: tunFD)
        tuneSocketBuffer(fd: bridgeFD)
        _ = setNonBlocking(fd: bridgeFD)
        return true
    }

    private func closeFDs() {
        if bridgeFD >= 0 {
            _ = close(bridgeFD)
            bridgeFD = -1
        }
        if tunFD >= 0 {
            _ = close(tunFD)
            tunFD = -1
        }
    }

    private func startReadLoop() {
        guard bridgeFD >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: bridgeFD, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.drainOutput()
        }
        source.setCancelHandler { [weak self] in
            self?.inputPending = 0
        }
        readSource = source
        source.resume()
    }

    private func drainOutput() {
        let bufferSize = mtu + 4
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingPackets: [Data] = []
        var pendingProtocols: [NSNumber] = []
        while true {
            let readBytes = read(bridgeFD, &buffer, buffer.count)
            if readBytes > 4 {
                let typeValue = buffer.withUnsafeBytes { rawPtr -> UInt32 in
                    rawPtr.load(as: UInt32.self).bigEndian
                }
                let proto = Int32(bitPattern: typeValue)
                let payload = Data(buffer[4 ..< readBytes])
                pendingPackets.append(payload)
                pendingProtocols.append(NSNumber(value: proto))
                continue
            }
            if readBytes == 0 {
                break
            }
            if readBytes < 0 && errno == EAGAIN {
                break
            }
            if readBytes < 0, logSampler.shouldLog(event: "vpn.socks5_tunnel_output", key: "read_error", first: 3, every: 200) {
                VPNLog.tunnel.warning("event=vpn.socks5_tunnel_output outcome=failure errno=\(errno)")
            }
            break
        }
        if !pendingPackets.isEmpty {
            packetFlow.writePackets(pendingPackets, withProtocols: pendingProtocols)
        }
    }

    private func writePacket(_ packet: Data, proto: Int32) {
        guard bridgeFD >= 0 else { return }
        var header = UInt32(bitPattern: proto).bigEndian
        let result = packet.withUnsafeBytes { bytes -> ssize_t in
            guard let base = bytes.baseAddress else { return -1 }
            var iov = [
                iovec(iov_base: &header, iov_len: MemoryLayout<UInt32>.size),
                iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: bytes.count)
            ]
            return writev(bridgeFD, &iov, 2)
        }

        if result <= 0, logSampler.shouldLog(event: "vpn.socks5_tunnel_input", key: "write_error", first: 3, every: 200) {
            VPNLog.tunnel.warning("event=vpn.socks5_tunnel_input outcome=failure errno=\(errno)")
        }
    }

    private func buildConfig() -> Data {
        let ipv6Line = ipv6Enabled ? "ipv6: 'fc00::1'\n" : ""
        let config = """
        tunnel:
          name: tun0
          mtu: \(mtu)
          multi-queue: false
          ipv4: 198.18.0.1
          \(ipv6Line)
        socks5:
          address: '\(socks5Host)'
          port: \(socks5Port)
          udp: 'udp'

        misc:
          task-stack-size: 36864
          tcp-buffer-size: 16384
          udp-recv-buffer-size: 524288
          udp-copy-buffer-nums: 20
          max-session-count: 1200
          tcp-read-write-timeout: 300
          udp-read-write-timeout: 300
          connect-timeout: 30
        """
        return Data(config.utf8)
    }

    private enum Socks5AddressType: UInt8 {
        case ipv4 = 0x01
        case domain = 0x03
        case ipv6 = 0x04
    }

    private enum Socks5ProbeError: Error {
        case timeout
        case eventLoopUnavailable
    }

    private final class ProbeCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func markCompleted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    private func probeSocks5UDPAssociate(completion: @Sendable @escaping (Socks5UDPSupport) -> Void) {
        guard socks5Port > 0 else {
            eventLogHandler?("socks5_udp_probe", "outcome=failure reason=invalid_port")
            completion(.unsupported)
            return
        }

        let hostHash = LogRedaction.hash(self.socks5Host)
        VPNLog.tunnel.info(
            "event=vpn.socks5_udp_probe_begin host_hash=\(hostHash) host_len=\(self.socks5Host.count) port=\(self.socks5Port) ipv6_enabled=\(self.ipv6Enabled)"
        )
        eventLogHandler?(
            "socks5_udp_probe",
            "outcome=begin host_hash=\(hostHash) host_len=\(self.socks5Host.count) port=\(self.socks5Port) ipv6_enabled=\(self.ipv6Enabled)"
        )

        let completionGate = ProbeCompletionGate()
        let queue = DispatchQueue(label: "com.trace.vpn.socks5_udp_probe", qos: .utility)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { [weak self] in
            guard completionGate.markCompleted() else { return }
            VPNLog.tunnel.warning("event=vpn.socks5_udp_probe_guard outcome=triggered fallback=unsupported")
            self?.eventLogHandler?("socks5_udp_probe", "outcome=failure reason=probe_guard_timeout")
            completion(.unsupported)
        }
        queue.async { [weak self] in
            guard let self else { return }
            let support = self.runSocks5UDPAssociateProbe()
            guard completionGate.markCompleted() else { return }
            VPNLog.tunnel.info("event=vpn.socks5_udp_probe_done support=\(support.rawValue, privacy: .public)")
            self.eventLogHandler?("socks5_udp_probe", "outcome=done support=\(support.rawValue)")
            completion(support)
        }
    }

    private func runSocks5UDPAssociateProbe() -> Socks5UDPSupport {
        let resources = NIORuntime.shared.acquire(for: .networkExtension)
        defer { try? NIORuntime.shared.release(for: .networkExtension) }

        guard let group = resources.eventLoopGroup as? NIOTSEventLoopGroup else {
            eventLogHandler?("socks5_udp_probe", "outcome=failure reason=event_loop_unavailable")
            return .unsupported
        }

        let ioHandler = Socks5ProbeIOHandler()
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                channel.pipeline.addHandler(ioHandler)
            }

        do {
            let channel = try waitFor(bootstrap.connect(host: socks5Host, port: Int(socks5Port)), timeout: 5)
            defer { _ = try? waitFor(channel.close(), timeout: 1) }

            ioHandler.bindFallbackEventLoop(channel.eventLoop)
            try waitFor(ioHandler.waitUntilReady(on: channel.eventLoop), timeout: 1)

            try waitFor(ioHandler.send([0x05, 0x01, 0x00]), timeout: 5)
            let greetingReply = try waitFor(ioHandler.readExact(2), timeout: 5)
            guard greetingReply == [0x05, 0x00] else {
                eventLogHandler?("socks5_udp_probe", "outcome=failure reason=greeting_reply_invalid")
                return .unsupported
            }
            eventLogHandler?("socks5_udp_probe", "greeting_reply_ok")

            if ipv6Enabled {
                let ipv6Support = try sendAssociateProbe(addressType: .ipv6, ioHandler: ioHandler)
                if ipv6Support != .unsupported {
                    eventLogHandler?("socks5_udp_probe", "outcome=success support=\(ipv6Support.rawValue)")
                    return ipv6Support
                }
                eventLogHandler?("socks5_udp_probe", "outcome=partial reason=ipv6_unavailable")
            }

            let ipv4Support = try sendAssociateProbe(addressType: .ipv4, ioHandler: ioHandler)
            if ipv4Support == .unsupported {
                eventLogHandler?("socks5_udp_probe", "outcome=failure reason=associate_reply_invalid")
            } else {
                eventLogHandler?("socks5_udp_probe", "outcome=success support=\(ipv4Support.rawValue)")
            }
            return ipv4Support
        } catch Socks5ProbeError.timeout {
            eventLogHandler?("socks5_udp_probe", "outcome=failure reason=timeout")
            return .unsupported
        } catch {
            eventLogHandler?("socks5_udp_probe", "outcome=failure reason=connection_failed")
            return .unsupported
        }
    }

    private func sendAssociateProbe(
        addressType: Socks5AddressType,
        ioHandler: Socks5ProbeIOHandler
    ) throws -> Socks5UDPSupport {
        var request: [UInt8] = [0x05, 0x03, 0x00, addressType.rawValue]
        eventLogHandler?("socks5_udp_probe", "associate_send addr_type=\(addressType.rawValue)")
        switch addressType {
        case .ipv4:
            request += [0, 0, 0, 0]
        case .ipv6:
            request += Array(repeating: 0, count: 16)
        case .domain:
            request += [0]
        }
        request += [0, 0]

        try waitFor(ioHandler.send(request), timeout: 5)
        let header = try waitFor(ioHandler.readExact(4), timeout: 5)
        guard header.count == 4, header[0] == 0x05, header[1] == 0x00 else {
            return .unsupported
        }

        let replyTypeRaw = header[3]
        switch replyTypeRaw {
        case Socks5AddressType.ipv4.rawValue:
            _ = try waitFor(ioHandler.readExact(4 + 2), timeout: 5)
            return .ipv4Only
        case Socks5AddressType.ipv6.rawValue:
            _ = try waitFor(ioHandler.readExact(16 + 2), timeout: 5)
            return .ipv6
        case Socks5AddressType.domain.rawValue:
            let lengthBytes = try waitFor(ioHandler.readExact(1), timeout: 5)
            guard let length = lengthBytes.first else { return .unsupported }
            _ = try waitFor(ioHandler.readExact(Int(length) + 2), timeout: 5)
            return .ipv4Only
        default:
            return .unsupported
        }
    }

    private func waitFor<T>(_ future: EventLoopFuture<T>, timeout: TimeInterval) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<T, Error>?

        future.whenComplete { completion in
            lock.lock()
            result = completion
            lock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) != .timedOut else {
            throw Socks5ProbeError.timeout
        }

        lock.lock()
        defer { lock.unlock() }
        guard let resolved = result else {
            throw Socks5ProbeError.timeout
        }
        return try resolved.get()
    }

    private func setNonBlocking(fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
    }

    private func tuneSocketBuffer(fd: Int32) {
        var size = 4 * 1024 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int>.size))
    }
}

private enum Socks5ProbeIOError: Error {
    case contextUnavailable
    case channelClosed
}

private final class Socks5ProbeIOHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private static let fallbackEventLoopGroup = NIOTSEventLoopGroup()

    private struct PendingRead {
        let count: Int
        let promise: EventLoopPromise<[UInt8]>
    }

    private let stateLock = NSLock()
    private var context: ChannelHandlerContext?
    private var fallbackEventLoop: EventLoop?
    private var pendingReadyPromises: [EventLoopPromise<Void>] = []
    private var readBuffer = ByteBuffer()
    private var pendingReads: [PendingRead] = []

    func bindFallbackEventLoop(_ eventLoop: EventLoop) {
        stateLock.lock()
        fallbackEventLoop = eventLoop
        stateLock.unlock()
    }

    func waitUntilReady(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        stateLock.lock()
        if context != nil {
            stateLock.unlock()
            return eventLoop.makeSucceededFuture(())
        }
        let promise = eventLoop.makePromise(of: Void.self)
        pendingReadyPromises.append(promise)
        stateLock.unlock()
        return promise.futureResult
    }

    func handlerAdded(context: ChannelHandlerContext) {
        stateLock.lock()
        self.context = context
        fallbackEventLoop = context.eventLoop
        let readyPromises = pendingReadyPromises
        pendingReadyPromises.removeAll(keepingCapacity: false)
        stateLock.unlock()

        for promise in readyPromises {
            promise.succeed(())
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        readBuffer.writeBuffer(&inbound)
        fulfillPendingReads()
    }

    func channelInactive(context: ChannelHandlerContext) {
        failPendingReads(error: Socks5ProbeIOError.channelClosed)
        failPendingReadyPromises(error: Socks5ProbeIOError.channelClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failPendingReads(error: error)
        failPendingReadyPromises(error: error)
        context.close(promise: nil)
    }

    func send(_ bytes: [UInt8]) -> EventLoopFuture<Void> {
        guard let context = currentContext() else {
            return makeContextUnavailableFuture()
        }

        let promise = context.eventLoop.makePromise(of: Void.self)
        let writeBlock = { [weak context] in
            guard let context else {
                promise.fail(Socks5ProbeIOError.contextUnavailable)
                return
            }
            var buffer = context.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            context.writeAndFlush(NIOAny(buffer), promise: promise)
        }

        if context.eventLoop.inEventLoop {
            writeBlock()
        } else {
            context.eventLoop.execute(writeBlock)
        }
        return promise.futureResult
    }

    func readExact(_ count: Int) -> EventLoopFuture<[UInt8]> {
        guard let context = currentContext() else {
            return makeContextUnavailableFuture()
        }

        let promise = context.eventLoop.makePromise(of: [UInt8].self)
        let scheduleRead = {
            if self.readBuffer.readableBytes >= count, let bytes = self.readBuffer.readBytes(length: count) {
                promise.succeed(bytes)
            } else {
                self.pendingReads.append(PendingRead(count: count, promise: promise))
            }
        }

        if context.eventLoop.inEventLoop {
            scheduleRead()
        } else {
            context.eventLoop.execute(scheduleRead)
        }
        return promise.futureResult
    }

    private func currentContext() -> ChannelHandlerContext? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context
    }

    private func makeContextUnavailableFuture<T>() -> EventLoopFuture<T> {
        stateLock.lock()
        let eventLoop = context?.eventLoop ?? fallbackEventLoop
        stateLock.unlock()

        if let eventLoop {
            return eventLoop.makeFailedFuture(Socks5ProbeIOError.contextUnavailable)
        }

        if let eventLoop = NIORuntime.shared.currentResources()?.eventLoopGroup.next() {
            return eventLoop.makeFailedFuture(Socks5ProbeIOError.contextUnavailable)
        }

        return Self.fallbackEventLoopGroup.next().makeFailedFuture(Socks5ProbeIOError.contextUnavailable)
    }

    private func fulfillPendingReads() {
        while let next = pendingReads.first {
            guard readBuffer.readableBytes >= next.count else { break }
            guard let bytes = readBuffer.readBytes(length: next.count) else { break }
            pendingReads.removeFirst()
            next.promise.succeed(bytes)
        }
    }

    private func failPendingReads(error: Error) {
        let pending = pendingReads
        pendingReads.removeAll(keepingCapacity: false)
        for pendingRead in pending {
            pendingRead.promise.fail(error)
        }
    }

    private func failPendingReadyPromises(error: Error) {
        stateLock.lock()
        let promises = pendingReadyPromises
        pendingReadyPromises.removeAll(keepingCapacity: false)
        stateLock.unlock()

        for promise in promises {
            promise.fail(error)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
