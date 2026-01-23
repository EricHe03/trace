//
//  HevSocks5TunnelForwarder.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/19.
//

import Darwin
import Foundation
import HevSocks5Tunnel
import Network
import NetworkExtension
import OSLog
import TraceCore

final class HevSocks5TunnelForwarder: PacketForwardingEngine {
    private let packetFlow: NEPacketTunnelFlow
    private let tunnelQueue = DispatchQueue(label: "com.trace.vpn.socks5_tunnel", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.trace.vpn.socks5_tunnel.io", qos: .userInitiated)
    private let inputLock = NSLock()
    private let logSampler = LogSampler()
    private let mtu: Int
    private let socks5Host: String
    private let socks5Port: UInt16
    private let maxInputPending: Int
    private let udpAssociateProbeHandler: (@Sendable (Bool) -> Void)?
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
        maxInputPending: Int = 8192,
        udpAssociateProbeHandler: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.packetFlow = packetFlow
        self.socks5Host = socks5Host
        self.socks5Port = socks5Port
        self.mtu = max(576, mtu)
        self.maxInputPending = max(1, maxInputPending)
        self.udpAssociateProbeHandler = udpAssociateProbeHandler
    }

    func start() {
        guard !isRunning else { return }
        guard setupTunnelSockets() else {
            VPNLog.tunnel.error("event=vpn.socks5_tunnel_start outcome=failure reason=socketpair_failed")
            return
        }

        isRunning = true
        startReadLoop()

        VPNLog.tunnel.info(
            "event=vpn.socks5_tunnel_config host=\(self.socks5Host, privacy: .public) port=\(self.socks5Port) mtu=\(self.mtu)"
        )

        if let udpAssociateProbeHandler {
            probeSocks5UDPAssociate(completion: udpAssociateProbeHandler)
        }

        let config = buildConfig()
        let tunFD = self.tunFD
        tunnelQueue.async { [weak self] in
            guard let self else { return }
            let result = config.withUnsafeBytes { bytes -> Int32 in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return hev_socks5_tunnel_main_from_str(base, UInt32(bytes.count), Int32(tunFD))
            }
            if result == 0 {
                VPNLog.tunnel.info("event=vpn.socks5_tunnel_exit outcome=success")
            } else {
                VPNLog.tunnel.error("event=vpn.socks5_tunnel_exit outcome=failure code=\(result)")
            }
        }

        VPNLog.tunnel.info("event=vpn.socks5_tunnel_start outcome=success")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        tunnelQueue.async {
            hev_socks5_tunnel_quit()
        }

        readSource?.cancel()
        readSource = nil
        closeFDs()

        VPNLog.tunnel.info("event=vpn.socks5_tunnel_stop outcome=success")
    }

    func enqueue(packets: [Data], protocols: [NSNumber]) {
        guard isRunning else { return }

        for (index, packet) in packets.enumerated() {
            guard let proto = protocols[safe: index]?.int32Value else { continue }
            guard proto == AF_INET || proto == AF_INET6 else { continue }

            inputLock.lock()
            let hasCapacity = inputPending < maxInputPending
            if hasCapacity { inputPending += 1 }
            inputLock.unlock()

            guard hasCapacity else {
                if logSampler.shouldLog(event: "vpn.socks5_tunnel_input", key: "pending_full", first: 5, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.socks5_tunnel_input outcome=skipped reason=pending_full")
                }
                continue
            }

            ioQueue.async { [weak self] in
                guard let self else { return }
                self.writePacket(packet, proto: proto)
                self.inputLock.lock()
                self.inputPending = max(0, self.inputPending - 1)
                self.inputLock.unlock()
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
            self?.inputLock.lock()
            self?.inputPending = 0
            self?.inputLock.unlock()
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
        let config = """
        tunnel:
          name: tun0
          mtu: \(mtu)
          multi-queue: false
          ipv4: 198.18.0.1
          ipv6: 'fc00::1'

        socks5:
          address: '\(socks5Host)'
          port: \(socks5Port)
          udp: 'udp'

        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          udp-recv-buffer-size: 524288
          udp-copy-buffer-nums: 10
          max-session-count: 1200
          tcp-read-write-timeout: 300
          udp-read-write-timeout: 300
          connect-timeout: 30
        """
        return Data(config.utf8)
    }

    private func probeSocks5UDPAssociate(completion: @Sendable @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: socks5Port) else {
            completion(false)
            return
        }

        let host = NWEndpoint.Host(socks5Host)
        let parameters = NWParameters.tcp
        let connection = NWConnection(host: host, port: port, using: parameters)
        let queue = tunnelQueue
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        var completed = false
        let finish: @Sendable (Bool) -> Void = { supported in
            queue.async {
                guard !completed else { return }
                completed = true
                timeout.cancel()
                completion(supported)
                connection.cancel()
            }
        }
        timeout.schedule(deadline: .now() + 5)
        timeout.setEventHandler {
            finish(false)
        }
        timeout.resume()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let greeting = Data([0x05, 0x01, 0x00])
                connection.send(content: greeting, completion: .contentProcessed { error in
                    if error != nil {
                        finish(false)
                        return
                    }
                    connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, _ in
                        guard let data, data.count == 2, data[0] == 0x05, data[1] == 0x00 else {
                            finish(false)
                            return
                        }
                        let request = Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                        connection.send(content: request, completion: .contentProcessed { error in
                            if error != nil {
                                finish(false)
                                return
                            }
                            connection.receive(minimumIncompleteLength: 2, maximumLength: 32) { reply, _, _, _ in
                                guard let reply, reply.count >= 2 else {
                                    finish(false)
                                    return
                                }
                                finish(reply[0] == 0x05 && reply[1] == 0x00)
                            }
                        })
                    }
                })
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }

        connection.start(queue: queue)
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
