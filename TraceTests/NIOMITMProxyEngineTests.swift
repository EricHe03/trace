//
//  NIOMITMProxyEngineTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/14.
//

import Darwin
import Foundation
import XCTest
@testable import TraceCore
@testable import TraceProxy

final class NIOMITMProxyEngineTests: XCTestCase {
    private enum TestError: Error {
        case socketCreateFailed(Int32)
        case socketBindFailed(Int32)
        case socketListenFailed(Int32)
        case socketAddressFailed
        case socketAcceptFailed(Int32)
        case socketConnectFailed(Int32)
        case socketWriteFailed(Int32)
        case socketReadFailed(Int32)
        case invalidHTTPMessage
        case invalidUTF8Data
    }

    private struct ParsedHTTPResponse {
        let statusLine: String
        let headers: [String: String]
        let body: Data
    }

    private actor StreamOnlyInterceptor: InterceptionProviding {
        func interceptRequest(
            flowId: UUID,
            url: String,
            method: String,
            headers: [String: String],
            body _: Data?
        ) async -> InterceptionResult {
            let uppercasedMethod = method.uppercased()
            let mappedMethod = HTTPMethod(rawValue: uppercasedMethod) ?? .get
            let methodRaw = HTTPMethod(rawValue: uppercasedMethod) == nil ? method : nil
            let requestHeaders = headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
            let request = NetworkRequest(
                id: flowId,
                url: url,
                method: mappedMethod,
                requestMethodRaw: methodRaw,
                duration: 0,
                requestHeaders: requestHeaders
            )
            return .modified(request)
        }

        func interceptResponse(
            request: NetworkRequest,
            statusCode _: Int,
            statusMessage _: String,
            headers _: [TraceHTTPHeader],
            body _: Data?
        ) async -> NetworkRequest {
            request
        }

        func responsePipeline(for _: String) async -> ResponsePipeline {
            .streamAndCapture
        }

        func requiresHTTP1Interception() async -> Bool {
            false
        }
    }

    private final class SingleConnectionTCPServer: @unchecked Sendable {
        let port: UInt16

        private let socketFD: Int32
        private let queue = DispatchQueue(label: "com.trace.tests.nio_mitm.server")
        private let completion = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var closed = false

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else {
                throw TestError.socketCreateFailed(errno)
            }
            socketFD = fd
            configureSocketTimeout(fd)

            var reuseAddress: Int32 = 1
            _ = withUnsafePointer(to: &reuseAddress) {
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
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

            guard Darwin.listen(fd, SOMAXCONN) == 0 else {
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

            port = UInt16(bigEndian: localAddress.sin_port)
        }

        deinit {
            closeSocket()
        }

        func start(handler: @escaping @Sendable (Int32) -> Void) {
            let listenerFD = socketFD
            queue.async { [weak self] in
                defer { self?.completion.signal() }

                var peerAddress = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let clientFD = withUnsafeMutablePointer(to: &peerAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.accept(listenerFD, sockaddrPointer, &peerLength)
                    }
                }
                guard clientFD >= 0 else {
                    return
                }
                defer { close(clientFD) }
                configureSocketTimeout(clientFD)
                handler(clientFD)
            }
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

        func waitForCompletion(timeout: TimeInterval = 5) {
            _ = completion.wait(timeout: .now() + timeout)
        }
    }

    override func tearDownWithError() throws {
        try NIORuntime.shared.shutdown(reason: .tests)
        try super.tearDownWithError()
    }

    func testStartAndStopBindsLoopbackEndpoint() throws {
        let engine = NIOMITMProxyEngine(port: 0, eventLog: nil)
        let endpoint = try engine.start()

        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertGreaterThan(endpoint.port, 0)
        XCTAssertEqual(engine.activeConnectionCount(), 0)

        engine.stop()
    }

    func testHTTPForwardingSupportsSequentialKeepAliveRequests() throws {
        let upstreamServer = try SingleConnectionTCPServer()
        upstreamServer.start(handler: Self.handleHTTPKeepAliveConnection)
        defer {
            upstreamServer.closeSocket()
            upstreamServer.waitForCompletion()
        }

        let engine = NIOMITMProxyEngine(port: 0, eventLog: nil)
        let endpoint = try engine.start()
        defer { engine.stop() }

        let clientFD = try Self.connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(clientFD) }

        let request1 = """
        GET http://127.0.0.1:\(upstreamServer.port)/first HTTP/1.1\r
        Host: 127.0.0.1:\(upstreamServer.port)\r
        Connection: keep-alive\r
        \r
        """
        try Self.writeAll(Data(request1.utf8), to: clientFD)

        var pendingBytes = Data()
        let response1 = try Self.readHTTPResponse(from: clientFD, pendingBytes: &pendingBytes)
        XCTAssertTrue(response1.statusLine.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(response1.headers["connection"]?.lowercased(), "keep-alive")
        XCTAssertEqual(String(data: response1.body, encoding: .utf8), "one")

        let request2 = """
        GET http://127.0.0.1:\(upstreamServer.port)/second HTTP/1.1\r
        Host: 127.0.0.1:\(upstreamServer.port)\r
        Connection: close\r
        \r
        """
        try Self.writeAll(Data(request2.utf8), to: clientFD)

        let response2 = try Self.readHTTPResponse(from: clientFD, pendingBytes: &pendingBytes)
        XCTAssertTrue(response2.statusLine.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(response2.headers["connection"]?.lowercased(), "close")
        XCTAssertEqual(String(data: response2.body, encoding: .utf8), "two")
    }

    func testHTTPCaptureDurationReflectsElapsedTime() throws {
        let upstreamServer = try SingleConnectionTCPServer()
        upstreamServer.start(handler: Self.handleHTTPDelayedResponseConnection)
        defer {
            upstreamServer.closeSocket()
            upstreamServer.waitForCompletion()
        }

        let capturedExpectation = expectation(description: "captured delayed request")
        capturedExpectation.assertForOverFulfill = false

        let capturedLock = NSLock()
        var capturedRequest: NetworkRequest?

        let engine = NIOMITMProxyEngine(
            port: 0,
            eventLog: nil,
            onRequestCaptured: { request in
                guard request.url.contains("/delayed") else { return }
                capturedLock.lock()
                capturedRequest = request
                capturedLock.unlock()
                capturedExpectation.fulfill()
            }
        )
        let endpoint = try engine.start()
        defer { engine.stop() }

        let clientFD = try Self.connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(upstreamServer.port)/delayed HTTP/1.1\r
        Host: 127.0.0.1:\(upstreamServer.port)\r
        Connection: close\r
        \r
        """
        try Self.writeAll(Data(request.utf8), to: clientFD)

        var pendingBytes = Data()
        let response = try Self.readHTTPResponse(from: clientFD, pendingBytes: &pendingBytes)
        XCTAssertTrue(response.statusLine.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "delayed")

        wait(for: [capturedExpectation], timeout: 3.0)

        capturedLock.lock()
        let captured = capturedRequest
        capturedLock.unlock()

        XCTAssertNotNil(captured)
        XCTAssertGreaterThanOrEqual(captured?.duration ?? 0, 0.03)
    }

    func testStreamAndCaptureFlushesResponseHeadBeforeBodyCompletes() throws {
        let upstreamServer = try SingleConnectionTCPServer()
        upstreamServer.start(handler: Self.handleHTTPDelayedBodyAfterHeadersConnection)
        defer {
            upstreamServer.closeSocket()
            upstreamServer.waitForCompletion()
        }

        let engine = NIOMITMProxyEngine(
            port: 0,
            eventLog: nil,
            interceptor: StreamOnlyInterceptor()
        )
        let endpoint = try engine.start()
        defer { engine.stop() }

        let clientFD = try Self.connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(upstreamServer.port)/download HTTP/1.1\r
        Host: 127.0.0.1:\(upstreamServer.port)\r
        Connection: close\r
        \r
        """
        try Self.writeAll(Data(request.utf8), to: clientFD)

        let readableBeforeBody = try Self.waitForReadable(clientFD, timeout: 0.25)
        XCTAssertTrue(readableBeforeBody, "Expected response head to be forwarded before delayed body completes.")

        var pendingBytes = Data()
        let response = try Self.readHTTPResponse(from: clientFD, pendingBytes: &pendingBytes)
        XCTAssertTrue(response.statusLine.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(
            response.headers["content-disposition"]?.lowercased(),
            "attachment; filename=\"download.bin\""
        )
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "stream-body")
    }

    func testCONNECTTunnelRelaysBidirectionalBytes() throws {
        let echoServer = try SingleConnectionTCPServer()
        echoServer.start(handler: Self.handleEchoConnection)
        defer {
            echoServer.closeSocket()
            echoServer.waitForCompletion()
        }

        let engine = NIOMITMProxyEngine(port: 0, eventLog: nil)
        let endpoint = try engine.start()
        defer { engine.stop() }

        let clientFD = try Self.connectTCP(host: endpoint.host, port: endpoint.port)
        defer { close(clientFD) }

        let connectRequest = """
        CONNECT 127.0.0.1:\(echoServer.port) HTTP/1.1\r
        Host: 127.0.0.1:\(echoServer.port)\r
        \r
        """
        try Self.writeAll(Data(connectRequest.utf8), to: clientFD)

        var pendingBytes = Data()
        let connectResponse = try Self.readHTTPResponse(from: clientFD, pendingBytes: &pendingBytes)
        XCTAssertTrue(connectResponse.statusLine.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(connectResponse.body.count, 0)

        let payload = Data("trace-nio-connect-relay".utf8)
        try Self.writeAll(payload, to: clientFD)
        let echoedPayload = try Self.readExactByteCount(payload.count, from: clientFD, pendingBytes: &pendingBytes)
        XCTAssertEqual(echoedPayload, payload)
    }
}

private extension NIOMITMProxyEngineTests {
    static func configureSocketTimeout(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    static func connectTCP(host: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw TestError.socketCreateFailed(errno)
        }
        configureSocketTimeout(fd)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let presentationResult = host.withCString { cString in
            inet_pton(AF_INET, cString, &address.sin_addr)
        }
        guard presentationResult == 1 else {
            close(fd)
            throw TestError.socketAddressFailed
        }

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

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var baseAddress = rawBuffer.baseAddress else {
                return
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, baseAddress, remaining)
                guard written > 0 else {
                    throw TestError.socketWriteFailed(errno)
                }
                remaining -= written
                baseAddress = baseAddress.advanced(by: written)
            }
        }
    }

    static func readChunk(from fd: Int32, maxBytes: Int = 4096) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count >= 0 else {
            throw TestError.socketReadFailed(errno)
        }
        guard count > 0 else {
            return Data()
        }
        return Data(buffer.prefix(Int(count)))
    }

    private static func readHTTPResponse(from fd: Int32, pendingBytes: inout Data) throws -> ParsedHTTPResponse {
        let delimiter = Data("\r\n\r\n".utf8)
        while pendingBytes.range(of: delimiter) == nil {
            let chunk = try readChunk(from: fd)
            guard !chunk.isEmpty else {
                throw TestError.invalidHTTPMessage
            }
            pendingBytes.append(chunk)
        }

        guard let delimiterRange = pendingBytes.range(of: delimiter) else {
            throw TestError.invalidHTTPMessage
        }

        let headerData = pendingBytes.prefix(upTo: delimiterRange.upperBound)
        pendingBytes.removeSubrange(pendingBytes.startIndex ..< delimiterRange.upperBound)

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw TestError.invalidUTF8Data
        }

        let rawHeaderLines = headerText.split(separator: "\r\n")
        guard let statusLineSubstring = rawHeaderLines.first else {
            throw TestError.invalidHTTPMessage
        }

        var headers: [String: String] = [:]
        for line in rawHeaderLines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = line.index(after: separatorIndex)
            let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let expectedBodyBytes = Int(headers["content-length"] ?? "0") ?? 0
        while pendingBytes.count < expectedBodyBytes {
            let chunk = try readChunk(from: fd)
            guard !chunk.isEmpty else {
                throw TestError.invalidHTTPMessage
            }
            pendingBytes.append(chunk)
        }

        let body = Data(pendingBytes.prefix(expectedBodyBytes))
        pendingBytes.removeSubrange(0 ..< expectedBodyBytes)

        return ParsedHTTPResponse(
            statusLine: String(statusLineSubstring),
            headers: headers,
            body: body
        )
    }

    static func readExactByteCount(_ count: Int, from fd: Int32, pendingBytes: inout Data) throws -> Data {
        while pendingBytes.count < count {
            let chunk = try readChunk(from: fd)
            guard !chunk.isEmpty else {
                throw TestError.invalidHTTPMessage
            }
            pendingBytes.append(chunk)
        }

        let payload = Data(pendingBytes.prefix(count))
        pendingBytes.removeSubrange(0 ..< count)
        return payload
    }

    static func waitForReadable(_ fd: Int32, timeout: TimeInterval) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMilliseconds = Int32(max(0, timeout * 1_000))
        let pollResult = withUnsafeMutablePointer(to: &descriptor) {
            Darwin.poll($0, 1, timeoutMilliseconds)
        }
        guard pollResult >= 0 else {
            throw TestError.socketReadFailed(errno)
        }
        guard pollResult > 0 else {
            return false
        }
        return (descriptor.revents & Int16(POLLIN)) != 0
    }

    static func readHTTPRequestHead(from fd: Int32, pendingBytes: inout Data) throws -> String {
        let delimiter = Data("\r\n\r\n".utf8)
        while pendingBytes.range(of: delimiter) == nil {
            let chunk = try readChunk(from: fd)
            guard !chunk.isEmpty else {
                throw TestError.invalidHTTPMessage
            }
            pendingBytes.append(chunk)
        }

        guard let delimiterRange = pendingBytes.range(of: delimiter) else {
            throw TestError.invalidHTTPMessage
        }

        let headerData = Data(pendingBytes[pendingBytes.startIndex ..< delimiterRange.upperBound])
        pendingBytes.removeSubrange(pendingBytes.startIndex ..< delimiterRange.upperBound)

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw TestError.invalidUTF8Data
        }
        return headerText
    }

    static func handleHTTPKeepAliveConnection(_ clientFD: Int32) {
        do {
            var pendingBytes = Data()
            let firstRequest = try readHTTPRequestHead(from: clientFD, pendingBytes: &pendingBytes)
            let firstBody = firstRequest.contains("/first") ? "one" : "unexpected"
            let firstResponse = """
            HTTP/1.1 200 OK\r
            Content-Length: \(firstBody.utf8.count)\r
            Connection: keep-alive\r
            \r
            \(firstBody)
            """
            try writeAll(Data(firstResponse.utf8), to: clientFD)

            let secondRequest = try readHTTPRequestHead(from: clientFD, pendingBytes: &pendingBytes)
            let secondBody = secondRequest.contains("/second") ? "two" : "unexpected"
            let secondResponse = """
            HTTP/1.1 200 OK\r
            Content-Length: \(secondBody.utf8.count)\r
            Connection: close\r
            \r
            \(secondBody)
            """
            try writeAll(Data(secondResponse.utf8), to: clientFD)
        } catch {
            return
        }
    }

    static func handleHTTPDelayedResponseConnection(_ clientFD: Int32) {
        do {
            var pendingBytes = Data()
            _ = try readHTTPRequestHead(from: clientFD, pendingBytes: &pendingBytes)
            usleep(50_000)
            let body = "delayed"
            let response = """
            HTTP/1.1 200 OK\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            try writeAll(Data(response.utf8), to: clientFD)
        } catch {
            return
        }
    }

    static func handleHTTPDelayedBodyAfterHeadersConnection(_ clientFD: Int32) {
        do {
            var pendingBytes = Data()
            _ = try readHTTPRequestHead(from: clientFD, pendingBytes: &pendingBytes)
            let body = "stream-body"
            let responseHead = """
            HTTP/1.1 200 OK\r
            Content-Length: \(body.utf8.count)\r
            Content-Disposition: attachment; filename="download.bin"\r
            Connection: close\r
            \r
            """
            try writeAll(Data(responseHead.utf8), to: clientFD)
            usleep(700_000)
            try writeAll(Data(body.utf8), to: clientFD)
        } catch {
            return
        }
    }

    static func handleEchoConnection(_ clientFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = recv(clientFD, &buffer, buffer.count, 0)
            guard received > 0 else {
                return
            }

            var totalSent = 0
            while totalSent < received {
                let sent = buffer.withUnsafeBytes { rawBuffer in
                    Darwin.write(
                        clientFD,
                        rawBuffer.baseAddress?.advanced(by: totalSent),
                        Int(received - totalSent)
                    )
                }
                guard sent > 0 else {
                    return
                }
                totalSent += sent
            }
        }
    }
}
