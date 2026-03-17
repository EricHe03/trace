//
//  LocalSocks5ServerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/14.
//

import Darwin
import Foundation
import XCTest
@testable import TraceCore
@testable import TraceVPNKit

final class LocalSocks5ServerTests: XCTestCase {
    private final class EventLogStore: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func append(_ message: String) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    private enum TestError: Error {
        case socketCreateFailed(Int32)
        case socketConnectFailed(Int32)
        case socketBindFailed(Int32)
        case socketListenFailed(Int32)
        case socketWriteFailed(Int32)
        case socketReadFailed(Int32)
        case socketAddressFailed
        case invalidSocksResponse
        case unsupportedAddressType(UInt8)
        case invalidUTF8Domain
    }

    private final class SingleShotUDPEchoServer: @unchecked Sendable {
        let port: UInt16

        private let socketFD: Int32
        private let queue = DispatchQueue(label: "com.trace.tests.local_socks5.udp_echo")
        private let completion = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var closed = false

        init() throws {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else {
                throw TestError.socketCreateFailed(errno)
            }
            socketFD = fd

            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) {
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }

            var bindAddress = sockaddr_in()
            bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            bindAddress.sin_family = sa_family_t(AF_INET)
            bindAddress.sin_port = in_port_t(0).bigEndian
            bindAddress.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &bindAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                close(fd)
                throw TestError.socketBindFailed(errno)
            }

            var localAddress = sockaddr_in()
            var localAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &localAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &localAddressLength)
                }
            }
            guard nameResult == 0 else {
                close(fd)
                throw TestError.socketAddressFailed
            }

            self.port = UInt16(bigEndian: localAddress.sin_port)
        }

        deinit {
            closeSocket()
        }

        func start() {
            let fd = socketFD
            queue.async { [weak self] in
                defer { self?.completion.signal() }

                var buffer = [UInt8](repeating: 0, count: 65535)
                var peer = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

                let received = withUnsafeMutablePointer(to: &peer) { peerPointer in
                    peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        buffer.withUnsafeMutableBytes { rawBuffer in
                            recvfrom(fd, rawBuffer.baseAddress, rawBuffer.count, 0, sockaddrPointer, &peerLength)
                        }
                    }
                }

                guard received > 0 else {
                    return
                }

                let byteCount = Int(received)
                _ = withUnsafePointer(to: &peer) { peerPointer in
                    peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        buffer.withUnsafeBytes { rawBuffer in
                            sendto(fd, rawBuffer.baseAddress, byteCount, 0, sockaddrPointer, peerLength)
                        }
                    }
                }
            }
        }

        func waitForCompletion(timeout: TimeInterval = 5) {
            _ = completion.wait(timeout: .now() + timeout)
        }

        func closeSocket() {
            lock.lock()
            let shouldClose = !closed
            closed = true
            lock.unlock()
            guard shouldClose else {
                return
            }
            close(socketFD)
        }
    }

    private final class SingleShotTCPAcceptServer: @unchecked Sendable {
        let port: UInt16

        private let socketFD: Int32
        private let queue = DispatchQueue(label: "com.trace.tests.local_socks5.tcp_accept")
        private let acceptedSemaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var closed = false

        init(port: UInt16? = nil) throws {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else {
                throw TestError.socketCreateFailed(errno)
            }
            socketFD = fd

            var reuseAddr: Int32 = 1
            _ = withUnsafePointer(to: &reuseAddr) {
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
            }

            var bindAddress = sockaddr_in()
            bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            bindAddress.sin_family = sa_family_t(AF_INET)
            bindAddress.sin_port = in_port_t(port ?? 0).bigEndian
            bindAddress.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &bindAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                close(fd)
                throw TestError.socketBindFailed(errno)
            }

            guard listen(fd, 5) == 0 else {
                close(fd)
                throw TestError.socketListenFailed(errno)
            }

            var localAddress = sockaddr_in()
            var localAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &localAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &localAddressLength)
                }
            }
            guard nameResult == 0 else {
                close(fd)
                throw TestError.socketAddressFailed
            }

            self.port = UInt16(bigEndian: localAddress.sin_port)
        }

        deinit {
            closeSocket()
        }

        func start() {
            let fd = socketFD
            queue.async { [weak self] in
                guard let self else { return }
                var peer = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let acceptedFD = withUnsafeMutablePointer(to: &peer) { peerPointer in
                    peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.accept(fd, sockaddrPointer, &peerLength)
                    }
                }
                if acceptedFD >= 0 {
                    close(acceptedFD)
                    self.acceptedSemaphore.signal()
                }
            }
        }

        func waitForAccept(timeout: TimeInterval = 5) -> Bool {
            acceptedSemaphore.wait(timeout: .now() + timeout) == .success
        }

        func closeSocket() {
            lock.lock()
            let shouldClose = !closed
            closed = true
            lock.unlock()
            guard shouldClose else {
                return
            }
            close(socketFD)
        }
    }

    private var server: LocalSocks5Server?

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testUDPAssociateHandshake_ReturnsRelayEndpoint() throws {
        let endpoint = try startServer()
        let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(tcpFD) }

        let relay = try performSocks5UDPAssociate(on: tcpFD)

        XCTAssertEqual(relay.reply, 0x00)
        XCTAssertFalse(relay.host.isEmpty)
        XCTAssertGreaterThan(relay.port, 0)
    }

    func testUDPAssociateRelay_RoundTripsDatagram() throws {
        let endpoint = try startServer()
        let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(tcpFD) }

        let relay = try performSocks5UDPAssociate(on: tcpFD)
        XCTAssertEqual(relay.reply, 0x00)

        let echoServer = try SingleShotUDPEchoServer()
        echoServer.start()
        defer {
            echoServer.closeSocket()
            echoServer.waitForCompletion()
        }

        let udpClientFD = try createUDPClientSocket()
        defer { close(udpClientFD) }

        let payload = Data("trace-local-socks-udp".utf8)
        let requestDatagram = makeSocks5UDPDatagram(
            destinationIPv4: "127.0.0.1",
            destinationPort: echoServer.port,
            payload: payload
        )

        try sendUDP(
            requestDatagram,
            from: udpClientFD,
            toHost: relay.host,
            toPort: relay.port
        )
        let responseDatagram = try receiveUDP(from: udpClientFD)
        let response = try parseSocks5UDPDatagram(responseDatagram)

        XCTAssertEqual(response.payload, payload)
        XCTAssertEqual(response.port, echoServer.port)
        XCTAssertEqual(response.addressType, 0x01)
        XCTAssertEqual(response.host, "127.0.0.1")
    }

    func testConcurrentStartReturnsSameEndpoint() {
        let localServer = LocalSocks5Server(bindHost: "127.0.0.1")
        server = localServer

        let group = DispatchGroup()
        let lock = NSLock()
        var endpoints: [LocalSocks5Server.Endpoint] = []
        var errors: [Error] = []

        for _ in 0..<6 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    let endpoint = try localServer.start(preferredPort: 0)
                    lock.lock()
                    endpoints.append(endpoint)
                    lock.unlock()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(endpoints.count, 6)

        guard let first = endpoints.first else {
            XCTFail("Expected at least one endpoint")
            return
        }

        for endpoint in endpoints {
            XCTAssertEqual(endpoint.host, first.host)
            XCTAssertEqual(endpoint.port, first.port)
        }
    }

    func testTCPConnectRoutingPolicyRoutesHTTPSWhenEnabled() {
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true
        )

        XCTAssertTrue(policy.shouldRouteToMITM(destinationHost: "example.com", destinationPort: 443))
        XCTAssertFalse(policy.shouldRouteToMITM(destinationHost: "example.com", destinationPort: 80))
    }

    func testTCPConnectRoutingPolicyRoutesHTTPAndHTTPSWhenConfigured() {
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [80, 443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true
        )

        XCTAssertTrue(policy.shouldRouteToMITM(destinationHost: "example.com", destinationPort: 80))
        XCTAssertTrue(policy.shouldRouteToMITM(destinationHost: "example.com", destinationPort: 443))
        XCTAssertEqual(
            policy.routeDecision(destinationHost: "example.com", destinationPort: 8080),
            .direct(reason: "port_not_intercepted")
        )
    }

    func testTCPConnectRoutingPolicyAvoidsProxyLoop() {
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true
        )

        XCTAssertFalse(policy.shouldRouteToMITM(destinationHost: "127.0.0.1", destinationPort: 8888))
    }

    func testTCPConnectRoutingPolicyDisabledSkipsRouting() {
        XCTAssertFalse(
            LocalSocks5Server.TCPConnectRoutingPolicy.disabled
                .shouldRouteToMITM(destinationHost: "example.com", destinationPort: 443)
        )
    }

    func testTCPConnectRoutingPolicyBypassedHostRoutesDirect() {
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true,
            shouldBypassHost: { host in host == "example.com" },
            bypassReasonForHost: { _ in "Upstream trust failure" }
        )

        XCTAssertFalse(policy.shouldRouteToMITM(destinationHost: "example.com", destinationPort: 443))
        XCTAssertEqual(
            policy.routeDecision(destinationHost: "example.com", destinationPort: 443),
            .direct(reason: "auto_bypass_upstream_trust_failure")
        )
    }

    func testTCPConnectRoutingPolicyBypassedBracketedIPv6RoutesDirect() {
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true,
            shouldBypassHost: { host in host == "2001:db8::1" },
            bypassReasonForHost: { _ in "Pinning requirements" }
        )

        XCTAssertFalse(policy.shouldRouteToMITM(destinationHost: "[2001:db8::1]", destinationPort: 443))
        XCTAssertEqual(
            policy.routeDecision(destinationHost: "[2001:db8::1]", destinationPort: 443),
            .direct(reason: "auto_bypass_pinning_requirements")
        )
    }

    func testTCPConnectRoutingPolicyIgnoresQUICBypassReasons() {
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true,
            shouldBypassHost: { host in host == "example.com" },
            bypassReasonForHost: { _ in "quic no progress fail open" }
        )

        XCTAssertTrue(policy.shouldRouteToMITM(destinationHost: "example.com", destinationPort: 443))
        XCTAssertEqual(
            policy.routeDecision(destinationHost: "example.com", destinationPort: 443),
            .mitm
        )
    }

    func testTCPConnectRoutingPolicyUsesCircuitBreakerForPort443() {
        DualMITMCircuitBreaker.shared.resetForTesting()
        defer {
            DualMITMCircuitBreaker.shared.configure(enabled: false)
            DualMITMCircuitBreaker.shared.resetForTesting()
        }

        DualMITMCircuitBreaker.shared.configure(
            enabled: true,
            cooldownSeconds: 300,
            tcpWindowSize: 100
        )
        for _ in 0..<40 {
            DualMITMCircuitBreaker.shared.recordTCPClientHandshake(success: false)
        }
        for _ in 0..<60 {
            DualMITMCircuitBreaker.shared.recordTCPClientHandshake(success: true)
        }

        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true,
            dualMITMPolicy: .adaptiveFailOpen
        )

        XCTAssertEqual(
            policy.routeDecision(destinationHost: "example.com", destinationPort: 443),
            .direct(reason: "dual_mitm_circuit_breaker")
        )
    }

    func testTCPConnectRoutingPolicyShadowModeKeepsLegacyDecision() {
        let policyEngine = DualMITMPolicyEngine(
            snapshot: DualMITMPolicySnapshot(
                tcpTransparentMITMEnabled: false,
                tcpInterceptPorts: [443],
                mitmProxyHost: "127.0.0.1",
                mitmProxyPort: 8888,
                policyMode: .adaptiveFailOpen,
                circuitBreakerEnabled: true,
                featureFlags: DualMITMPolicyFeatureFlags(
                    shadowEnabled: true,
                    enforceTCPRouting: false
                )
            )
        )
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true,
            dualMITMPolicy: .adaptiveFailOpen,
            policyEngine: policyEngine
        )

        let evaluation = policy.evaluateRouteDecision(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(evaluation.legacyDecision, .mitm)
        XCTAssertEqual(evaluation.policyDecision, .direct(reason: "policy_disabled"))
        XCTAssertEqual(evaluation.effectiveDecision, .mitm)
        XCTAssertTrue(evaluation.shadowEnabled)
        XCTAssertFalse(evaluation.policyEnforced)
        XCTAssertTrue(evaluation.hasShadowMismatch)
    }

    func testTCPConnectRoutingPolicyEnforcedModeUsesPolicyDecision() {
        let policyEngine = DualMITMPolicyEngine(
            snapshot: DualMITMPolicySnapshot(
                tcpTransparentMITMEnabled: false,
                tcpInterceptPorts: [443],
                mitmProxyHost: "127.0.0.1",
                mitmProxyPort: 8888,
                policyMode: .adaptiveFailOpen,
                circuitBreakerEnabled: true,
                featureFlags: DualMITMPolicyFeatureFlags(
                    shadowEnabled: true,
                    enforceTCPRouting: true
                )
            )
        )
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true,
            dualMITMPolicy: .adaptiveFailOpen,
            policyEngine: policyEngine
        )

        let evaluation = policy.evaluateRouteDecision(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(evaluation.legacyDecision, .mitm)
        XCTAssertEqual(evaluation.policyDecision, .direct(reason: "policy_disabled"))
        XCTAssertEqual(evaluation.effectiveDecision, .direct(reason: "policy_disabled"))
        XCTAssertTrue(evaluation.shadowEnabled)
        XCTAssertTrue(evaluation.policyEnforced)
        XCTAssertTrue(evaluation.hasShadowMismatch)
    }

    func testTCPConnectRoutesPort443ToMITMEndpoint() throws {
        let mitmServer = try SingleShotTCPAcceptServer()
        mitmServer.start()
        defer { mitmServer.closeSocket() }

        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: mitmServer.port,
            failOpen: true
        )
        let endpoint = try startServer(tcpConnectRoutingPolicy: policy)
        let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(tcpFD) }

        let reply = try performSocks5Connect(on: tcpFD, host: "127.0.0.1", port: 443)

        XCTAssertEqual(reply, 0x00)
        XCTAssertTrue(mitmServer.waitForAccept(timeout: 3))
    }

    func testTCPConnectFallsBackToDirectWhenMITMEndpointUnavailable() throws {
        let destinationServer = try SingleShotTCPAcceptServer()
        destinationServer.start()
        defer { destinationServer.closeSocket() }

        let unavailablePort = try unusedLocalTCPPort()
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [destinationServer.port],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: unavailablePort,
            failOpen: true
        )
        let endpoint = try startServer(tcpConnectRoutingPolicy: policy)
        let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(tcpFD) }

        let reply = try performSocks5Connect(on: tcpFD, host: "127.0.0.1", port: destinationServer.port)

        XCTAssertEqual(reply, 0x00)
        XCTAssertTrue(destinationServer.waitForAccept(timeout: 3))
    }

    func testTCPConnectDoesNotFallbackToDirectWhenFailOpenDisabled() throws {
        let destinationServer = try SingleShotTCPAcceptServer()
        destinationServer.start()
        defer { destinationServer.closeSocket() }

        let unavailablePort = try unusedLocalTCPPort()
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [destinationServer.port],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: unavailablePort,
            failOpen: false,
            dualMITMPolicy: .strictMITM
        )
        let endpoint = try startServer(tcpConnectRoutingPolicy: policy)
        let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(tcpFD) }

        let reply = try performSocks5Connect(on: tcpFD, host: "127.0.0.1", port: destinationServer.port)

        XCTAssertEqual(reply, 0x01)
        XCTAssertFalse(destinationServer.waitForAccept(timeout: 1))
    }

    func testTCPConnectBypassesMITMForNonInterceptPort() throws {
        let destinationServer = try SingleShotTCPAcceptServer()
        destinationServer.start()
        defer { destinationServer.closeSocket() }

        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 9,
            failOpen: true
        )
        let endpoint = try startServer(tcpConnectRoutingPolicy: policy)
        let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(tcpFD) }

        let reply = try performSocks5Connect(on: tcpFD, host: "127.0.0.1", port: destinationServer.port)

        XCTAssertEqual(reply, 0x00)
        XCTAssertTrue(destinationServer.waitForAccept(timeout: 3))
    }

    func testTCPConnectDirectRouteRecoversWhenDestinationAppearsShortlyAfterFirstFailure() throws {
        let endpoint = try startServer(tcpConnectRoutingPolicy: .disabled)
        let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(tcpFD) }

        let delayedPort = try unusedLocalTCPPort()
        let delayedServerReady = expectation(description: "delayed server ready")
        let stateQueue = DispatchQueue(label: "com.trace.tests.local_socks5.delayed_server")
        var delayedServer: SingleShotTCPAcceptServer?
        var delayedServerError: Error?

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            do {
                let server = try SingleShotTCPAcceptServer(port: delayedPort)
                stateQueue.sync {
                    delayedServer = server
                }
                server.start()
            } catch {
                stateQueue.sync {
                    delayedServerError = error
                }
            }
            delayedServerReady.fulfill()
        }

        let reply = try performSocks5Connect(on: tcpFD, host: "127.0.0.1", port: delayedPort)
        wait(for: [delayedServerReady], timeout: 2)

        if let delayedServerError = stateQueue.sync(execute: { delayedServerError }) {
            XCTFail("Failed to start delayed destination server: \(delayedServerError)")
            return
        }
        let server = stateQueue.sync { delayedServer }
        defer {
            server?.closeSocket()
        }

        XCTAssertEqual(reply, 0x00)
        XCTAssertTrue(server?.waitForAccept(timeout: 3) ?? false)
    }

    func testTCPConnectDirectRouteAppliesBackoffAfterRepeated443Failure() throws {
        let eventStore = EventLogStore()
        let policy = LocalSocks5Server.TCPConnectRoutingPolicy(
            enabled: true,
            interceptPorts: [443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888,
            failOpen: true,
            shouldBypassHost: { _ in true },
            bypassReasonForHost: { _ in "connection_closed_early" }
        )
        let endpoint = try startServer(
            tcpConnectRoutingPolicy: policy,
            eventLogHandler: { type, message in
                guard type == "local_socks5_connect_route" else { return }
                eventStore.append(message)
            }
        )

        func runConnect() throws -> UInt8 {
            let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
            defer { close(tcpFD) }
            return try performSocks5Connect(on: tcpFD, host: "127.0.0.1", port: 443)
        }

        let firstReply = try runConnect()
        if firstReply == 0x00 {
            throw XCTSkip("Local destination 127.0.0.1:443 accepted the test connect; cannot validate failure backoff.")
        }
        XCTAssertEqual(firstReply, 0x01)

        let secondReply = try runConnect()
        XCTAssertEqual(secondReply, 0x01)

        let connectRouteEvents = eventStore.snapshot()
        let backoffSetLogged = connectRouteEvents.contains { $0.contains("reason=direct_endpoint_backoff") }
        let backoffSkipLogged = connectRouteEvents.contains { $0.contains("reason=direct_backoff_active") }
        XCTAssertTrue(backoffSetLogged)
        XCTAssertTrue(backoffSkipLogged)
    }

    func testSessionFailureLogIsEmittedAtMostOncePerSession() throws {
        let eventStore = EventLogStore()
        let endpoint = try startServer(
            tcpConnectRoutingPolicy: .disabled,
            eventLogHandler: { type, message in
                guard type == "local_socks5_session" else { return }
                eventStore.append(message)
            }
        )

        let tcpFD = try connectTCP(host: endpoint.host, port: endpoint.port)
        try writeAll([0x05, 0x01, 0x00], to: tcpFD)
        setResetOnClose(for: tcpFD)
        close(tcpFD)

        Thread.sleep(forTimeInterval: 0.3)

        let failureEvents = eventStore.snapshot().filter { $0.contains("outcome=failure") }
        if failureEvents.isEmpty {
            throw XCTSkip("No failure event observed in reset-close scenario; cannot validate duplicate suppression.")
        }

        var countsBySession: [String: Int] = [:]
        for event in failureEvents {
            guard let session = Self.extractValue(for: "session", from: event) else { continue }
            countsBySession[session, default: 0] += 1
        }

        XCTAssertFalse(countsBySession.isEmpty)
        for count in countsBySession.values {
            XCTAssertLessThanOrEqual(count, 1, "Failure log should be emitted only once per session.")
        }
    }
}

private extension LocalSocks5ServerTests {
    struct UDPAssociateResponse {
        let reply: UInt8
        let addressType: UInt8
        let host: String
        let port: UInt16
    }

    struct UDPDatagram {
        let addressType: UInt8
        let host: String
        let port: UInt16
        let payload: Data
    }

    func startServer(
        tcpConnectRoutingPolicy: LocalSocks5Server.TCPConnectRoutingPolicy = .disabled,
        eventLogHandler: (@Sendable (String, String) -> Void)? = nil
    ) throws -> LocalSocks5Server.Endpoint {
        let localServer = LocalSocks5Server(
            bindHost: "127.0.0.1",
            tcpConnectRoutingPolicy: tcpConnectRoutingPolicy,
            eventLogHandler: eventLogHandler
        )
        let endpoint = try localServer.start(preferredPort: 0)
        server = localServer
        return endpoint
    }

    func connectTCP(host: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw TestError.socketCreateFailed(errno)
        }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = try makeIPv4Address(host: host, port: port)
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            let socketError = errno
            close(fd)
            throw TestError.socketConnectFailed(socketError)
        }

        return fd
    }

    func setResetOnClose(for fd: Int32) {
        var lingerOption = linger(l_onoff: 1, l_linger: 0)
        _ = withUnsafePointer(to: &lingerOption) {
            setsockopt(fd, SOL_SOCKET, SO_LINGER, $0, socklen_t(MemoryLayout<linger>.size))
        }
    }

    func createUDPClientSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw TestError.socketCreateFailed(errno)
        }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = in_port_t(0).bigEndian
        bindAddress.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let socketError = errno
            close(fd)
            throw TestError.socketBindFailed(socketError)
        }

        return fd
    }

    func performSocks5UDPAssociate(on tcpFD: Int32) throws -> UDPAssociateResponse {
        try writeAll([0x05, 0x01, 0x00], to: tcpFD)
        let greetingResponse = try readExact(count: 2, from: tcpFD)
        XCTAssertEqual(greetingResponse, [0x05, 0x00])

        let udpAssociateRequest: [UInt8] = [0x05, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        try writeAll(udpAssociateRequest, to: tcpFD)

        let head = try readExact(count: 4, from: tcpFD)
        guard head.count == 4, head[0] == 0x05 else {
            throw TestError.invalidSocksResponse
        }
        let reply = head[1]
        let atyp = head[3]

        let host: String
        switch atyp {
        case 0x01:
            let bytes = try readExact(count: 4, from: tcpFD)
            host = bytes.map(String.init).joined(separator: ".")
        case 0x03:
            let length = Int(try readExact(count: 1, from: tcpFD)[0])
            let bytes = try readExact(count: length, from: tcpFD)
            guard let domain = String(bytes: bytes, encoding: .utf8) else {
                throw TestError.invalidUTF8Domain
            }
            host = domain
        case 0x04:
            let bytes = try readExact(count: 16, from: tcpFD)
            host = try ipv6String(bytes: bytes)
        default:
            throw TestError.unsupportedAddressType(atyp)
        }

        let portBytes = try readExact(count: 2, from: tcpFD)
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])

        return UDPAssociateResponse(reply: reply, addressType: atyp, host: host, port: port)
    }

    func performSocks5Connect(on tcpFD: Int32, host: String, port: UInt16) throws -> UInt8 {
        try writeAll([0x05, 0x01, 0x00], to: tcpFD)
        let greetingResponse = try readExact(count: 2, from: tcpFD)
        XCTAssertEqual(greetingResponse, [0x05, 0x00])

        let hostBytes = Array(host.utf8)
        guard hostBytes.count <= 255 else {
            throw TestError.invalidSocksResponse
        }

        var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
        request.append(contentsOf: hostBytes)
        request.append(UInt8((port >> 8) & 0xFF))
        request.append(UInt8(port & 0xFF))
        try writeAll(request, to: tcpFD)

        let responseHead = try readExact(count: 4, from: tcpFD)
        guard responseHead.count == 4, responseHead[0] == 0x05 else {
            throw TestError.invalidSocksResponse
        }
        let reply = responseHead[1]
        let atyp = responseHead[3]

        switch atyp {
        case 0x01:
            _ = try readExact(count: 4, from: tcpFD)
        case 0x03:
            let length = Int(try readExact(count: 1, from: tcpFD)[0])
            _ = try readExact(count: length, from: tcpFD)
        case 0x04:
            _ = try readExact(count: 16, from: tcpFD)
        default:
            throw TestError.unsupportedAddressType(atyp)
        }
        _ = try readExact(count: 2, from: tcpFD)
        return reply
    }

    func makeSocks5UDPDatagram(destinationIPv4: String, destinationPort: UInt16, payload: Data) -> Data {
        let octets = destinationIPv4.split(separator: ".").compactMap { UInt8($0) }
        precondition(octets.count == 4)

        var datagram = Data([0x00, 0x00, 0x00, 0x01])
        datagram.append(contentsOf: octets)
        datagram.append(UInt8((destinationPort >> 8) & 0xFF))
        datagram.append(UInt8(destinationPort & 0xFF))
        datagram.append(payload)
        return datagram
    }

    func parseSocks5UDPDatagram(_ datagram: Data) throws -> UDPDatagram {
        guard datagram.count >= 10 else {
            throw TestError.invalidSocksResponse
        }
        guard datagram[0] == 0x00, datagram[1] == 0x00, datagram[2] == 0x00 else {
            throw TestError.invalidSocksResponse
        }

        var offset = 3
        let atyp = datagram[offset]
        offset += 1

        let host: String
        switch atyp {
        case 0x01:
            guard datagram.count >= offset + 4 else { throw TestError.invalidSocksResponse }
            host = datagram[offset ..< offset + 4].map(String.init).joined(separator: ".")
            offset += 4
        case 0x03:
            guard datagram.count > offset else { throw TestError.invalidSocksResponse }
            let length = Int(datagram[offset])
            offset += 1
            guard datagram.count >= offset + length else { throw TestError.invalidSocksResponse }
            let bytes = [UInt8](datagram[offset ..< offset + length])
            guard let domain = String(bytes: bytes, encoding: .utf8) else {
                throw TestError.invalidUTF8Domain
            }
            host = domain
            offset += length
        case 0x04:
            guard datagram.count >= offset + 16 else { throw TestError.invalidSocksResponse }
            host = try ipv6String(bytes: [UInt8](datagram[offset ..< offset + 16]))
            offset += 16
        default:
            throw TestError.unsupportedAddressType(atyp)
        }

        guard datagram.count >= offset + 2 else {
            throw TestError.invalidSocksResponse
        }
        let port = UInt16(datagram[offset]) << 8 | UInt16(datagram[offset + 1])
        offset += 2

        return UDPDatagram(
            addressType: atyp,
            host: host,
            port: port,
            payload: Data(datagram[offset...])
        )
    }

    func sendUDP(_ payload: Data, from fd: Int32, toHost host: String, toPort port: UInt16) throws {
        var address = try makeIPv4Address(host: host, port: port)
        let sent = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                payload.withUnsafeBytes { bytes in
                    sendto(fd, bytes.baseAddress, payload.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else {
            throw TestError.socketWriteFailed(errno)
        }
    }

    func receiveUDP(from fd: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 65535)
        let read = bytes.withUnsafeMutableBytes {
            recv(fd, $0.baseAddress, $0.count, 0)
        }
        guard read > 0 else {
            throw TestError.socketReadFailed(errno)
        }
        return Data(bytes.prefix(Int(read)))
    }

    func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { rawBytes in
                Darwin.send(fd, rawBytes.baseAddress?.advanced(by: sent), bytes.count - sent, 0)
            }
            guard wrote > 0 else {
                throw TestError.socketWriteFailed(errno)
            }
            sent += wrote
        }
    }

    func readExact(count: Int, from fd: Int32) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: count)
        var readBytes = 0
        while readBytes < count {
            let amount = output.withUnsafeMutableBytes { rawBytes in
                Darwin.recv(fd, rawBytes.baseAddress?.advanced(by: readBytes), count - readBytes, 0)
            }
            guard amount > 0 else {
                throw TestError.socketReadFailed(errno)
            }
            readBytes += amount
        }
        return output
    }

    func makeIPv4Address(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        let parseResult = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard parseResult == 1 else {
            throw TestError.socketAddressFailed
        }
        return address
    }

    func ipv6String(bytes: [UInt8]) throws -> String {
        guard bytes.count == 16 else {
            throw TestError.invalidSocksResponse
        }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address.__u6_addr.__u6_addr8) { destination in
            destination.copyBytes(from: bytes)
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &output, socklen_t(output.count)) != nil else {
            throw TestError.invalidSocksResponse
        }
        return String(cString: output)
    }

    func unusedLocalTCPPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw TestError.socketCreateFailed(errno)
        }
        defer { close(fd) }

        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = in_port_t(0).bigEndian
        bindAddress.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw TestError.socketBindFailed(errno)
        }

        var localAddress = sockaddr_in()
        var localAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &localAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &localAddressLength)
            }
        }
        guard nameResult == 0 else {
            throw TestError.socketAddressFailed
        }
        return UInt16(bigEndian: localAddress.sin_port)
    }

    static func extractValue(for key: String, from message: String) -> String? {
        let token = "\(key)="
        guard let tokenRange = message.range(of: token) else { return nil }
        let valueStart = tokenRange.upperBound
        let suffix = message[valueStart...]
        if let end = suffix.firstIndex(of: " ") {
            return String(suffix[..<end])
        }
        return String(suffix)
    }
}
