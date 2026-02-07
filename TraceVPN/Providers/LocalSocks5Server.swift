//
//  LocalSocks5Server.swift
//  TraceVPN
//
//  Created by Justin on 2026/02/06.
//

import Darwin
import Foundation
import Network

/// Embedded SOCKS5 server used by full-tunnel mode when no external server is configured.
final class LocalSocks5Server: @unchecked Sendable {
    struct Endpoint: Sendable {
        let host: String
        let port: UInt16
    }

    private enum ServerError: LocalizedError {
        case listenerPortUnavailable
        case startupTimeout
        case startupFailed

        var errorDescription: String? {
            switch self {
            case .listenerPortUnavailable:
                "Local SOCKS5 listener did not report a port"
            case .startupTimeout:
                "Local SOCKS5 listener startup timed out"
            case .startupFailed:
                "Local SOCKS5 listener failed to start"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.trace.vpn.local_socks5", qos: .userInitiated)
    private let bindHost: String
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private var listener: NWListener?
    private var endpoint: Endpoint?
    private var sessions: [UUID: Socks5Session] = [:]

    init(bindHost: String = "127.0.0.1", eventLogHandler: (@Sendable (String, String) -> Void)? = nil) {
        self.bindHost = bindHost
        self.eventLogHandler = eventLogHandler
    }

    func start(preferredPort: UInt16) throws -> Endpoint {
        if let endpoint {
            return endpoint
        }

        do {
            let endpoint = try startListener(port: preferredPort > 0 ? preferredPort : nil)
            eventLogHandler?("local_socks5_server", "outcome=success host=\(endpoint.host) port=\(endpoint.port)")
            return endpoint
        } catch {
            if preferredPort > 0 {
                let endpoint = try startListener(port: nil)
                eventLogHandler?(
                    "local_socks5_server",
                    "outcome=success fallback=ephemeral requested_port=\(preferredPort) host=\(endpoint.host) port=\(endpoint.port)"
                )
                return endpoint
            }
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        endpoint = nil

        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()

        eventLogHandler?("local_socks5_server", "outcome=stopped")
    }

    private func startListener(port: UInt16?) throws -> Endpoint {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        if let loopback = IPv4Address(bindHost) {
            let listenerPort: NWEndpoint.Port = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: listenerPort)
        }

        let listener = try NWListener(using: parameters)

        let startup = StartupWaiter<Endpoint>()

        listener.stateUpdateHandler = { [bindHost] state in
            switch state {
            case .ready:
                guard let localPort = listener.port?.rawValue else {
                    startup.resolve(.failure(ServerError.listenerPortUnavailable))
                    return
                }
                startup.resolve(.success(Endpoint(host: bindHost, port: localPort)))
            case let .failed(error):
                startup.resolve(.failure(error))
            case .cancelled:
                startup.resolve(.failure(ServerError.startupFailed))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleClientConnection(connection)
        }

        listener.start(queue: queue)

        let waitResult = startup.semaphore.wait(timeout: .now() + 5)
        if waitResult == .timedOut {
            listener.cancel()
            throw ServerError.startupTimeout
        }

        if let startupError = startup.error {
            listener.cancel()
            throw startupError
        }

        guard let resolvedEndpoint = startup.value else {
            listener.cancel()
            throw ServerError.startupFailed
        }

        self.listener = listener
        self.endpoint = resolvedEndpoint
        return resolvedEndpoint
    }

    private func handleClientConnection(_ connection: NWConnection) {
        let session = Socks5Session(connection: connection, queue: queue, eventLogHandler: eventLogHandler)
        sessions[session.id] = session
        session.start { [weak self] id in
            guard let server = self else { return }
            server.queue.async {
                server.sessions.removeValue(forKey: id)
            }
        }
    }
}

private enum Socks5ServerConnectionError: LocalizedError {
    case closed
    case connectTimeout

    var errorDescription: String? {
        switch self {
        case .closed:
            "Connection closed"
        case .connectTimeout:
            "Connection timeout"
        }
    }
}

private final class StartupWaiter<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private(set) var value: T?
    private(set) var error: Error?
    let semaphore = DispatchSemaphore(value: 0)

    func resolve(_ result: Result<T, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        switch result {
        case let .success(value):
            self.value = value
        case let .failure(error):
            self.error = error
        }
        lock.unlock()
        semaphore.signal()
    }
}

private final class ContinuationResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func tryBeginResume() -> Bool {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return false
        }
        didResume = true
        lock.unlock()
        return true
    }
}

private final class ConnectionReader: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk = try await connection.receiveChunk(minimum: 1, maximum: max(4096, count))
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
        }

        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    func readSome(maximum: Int = 65_536) async throws -> Data {
        if !buffer.isEmpty {
            let data = buffer
            buffer.removeAll(keepingCapacity: true)
            return data
        }

        return try await connection.receiveChunk(minimum: 1, maximum: maximum)
    }
}

private final class Socks5Session: @unchecked Sendable {
    enum Command: UInt8 {
        case connect = 0x01
        case udpAssociate = 0x03
    }

    enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    enum AddressType: UInt8 {
        case ipv4 = 0x01
        case domain = 0x03
        case ipv6 = 0x04
    }

    struct Address: Hashable, Sendable {
        let type: AddressType
        let host: String
    }

    let id = UUID()

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private var task: Task<Void, Never>?
    private var udpRelay: Socks5UDPRelay?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        eventLogHandler: (@Sendable (String, String) -> Void)?
    ) {
        self.connection = connection
        self.queue = queue
        self.eventLogHandler = eventLogHandler
    }

    func start(onClose: @escaping @Sendable (UUID) -> Void) {
        connection.start(queue: queue)
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
            onClose(self.id)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        udpRelay?.stop()
        udpRelay = nil
        connection.cancel()
    }

    private func run() async {
        defer {
            udpRelay?.stop()
            udpRelay = nil
            connection.cancel()
        }

        let reader = ConnectionReader(connection: connection)

        do {
            try await performHandshake(with: reader)
        } catch {
            eventLogHandler?(
                "local_socks5_session",
                "outcome=failure session=\(id.uuidString) error=\(error.localizedDescription)"
            )
        }
    }

    private func performHandshake(with reader: ConnectionReader) async throws {
        let greeting = try await reader.readExact(2)
        guard greeting[0] == 0x05 else {
            throw Socks5ServerConnectionError.closed
        }

        let methodCount = Int(greeting[1])
        let methods = try await reader.readExact(methodCount)
        let supportsNoAuth = methods.contains(0x00)
        let selectedMethod: UInt8 = supportsNoAuth ? 0x00 : 0xFF
        try await connection.sendData(Data([0x05, selectedMethod]))
        guard supportsNoAuth else {
            throw Socks5ServerConnectionError.closed
        }

        let requestHead = try await reader.readExact(4)
        guard requestHead[0] == 0x05 else {
            try await sendReply(.generalFailure)
            throw Socks5ServerConnectionError.closed
        }

        guard let command = Command(rawValue: requestHead[1]) else {
            try await sendReply(.commandNotSupported)
            throw Socks5ServerConnectionError.closed
        }

        let atyp = requestHead[3]
        guard let address = try await readAddress(typeRaw: atyp, reader: reader) else {
            try await sendReply(.addressTypeNotSupported)
            throw Socks5ServerConnectionError.closed
        }

        let portBytes = try await reader.readExact(2)
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])

        switch command {
        case .connect:
            try await handleConnect(address: address, port: port, reader: reader)
        case .udpAssociate:
            try await handleUDPAssociate(requestAddressType: address.type, reader: reader)
        }
    }

    private func handleConnect(address: Address, port: UInt16, reader: ConnectionReader) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            try await sendReply(.generalFailure)
            return
        }

        let remote = NWConnection(host: NWEndpoint.Host(address.host), port: endpointPort, using: .tcp)
        do {
            try await remote.startAndWait(on: queue, timeout: 10)
        } catch {
            try await sendReply(.generalFailure)
            throw error
        }

        try await sendReply(.succeeded)

        let remoteReader = ConnectionReader(connection: remote)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.pipe(source: reader, destination: remote)
            }
            group.addTask {
                await Self.pipe(source: remoteReader, destination: self.connection)
            }
            _ = await group.next()
            group.cancelAll()
        }

        remote.cancel()
    }

    private func handleUDPAssociate(requestAddressType: AddressType, reader: ConnectionReader) async throws {
        let preferredType: AddressType = requestAddressType == .ipv6 ? .ipv6 : .ipv4
        let relay: Socks5UDPRelay
        let relayEndpoint: Socks5UDPRelay.Endpoint

        do {
            let candidate = Socks5UDPRelay(
                queue: queue,
                bindAddressType: preferredType,
                eventLogHandler: eventLogHandler
            )
            relayEndpoint = try candidate.start()
            relay = candidate
        } catch {
            guard preferredType == .ipv6 else {
                throw error
            }

            let fallback = Socks5UDPRelay(
                queue: queue,
                bindAddressType: .ipv4,
                eventLogHandler: eventLogHandler
            )
            relayEndpoint = try fallback.start()
            relay = fallback
        }

        udpRelay = relay

        try await sendReply(
            .succeeded,
            bindAddress: Address(type: relayEndpoint.addressType, host: relayEndpoint.host),
            bindPort: relayEndpoint.port
        )

        while !Task.isCancelled {
            _ = try await reader.readSome(maximum: 1024)
        }
    }

    private func sendReply(_ reply: Reply, bindAddress: Address = Address(type: .ipv4, host: "0.0.0.0"), bindPort: UInt16 = 0) async throws {
        var response = Data([0x05, reply.rawValue, 0x00, bindAddress.type.rawValue])
        guard let encodedHost = encodeAddress(bindAddress) else {
            response = Data([0x05, Reply.generalFailure.rawValue, 0x00, AddressType.ipv4.rawValue, 0, 0, 0, 0, 0, 0])
            try await connection.sendData(response)
            return
        }
        response.append(encodedHost)
        response.append(UInt8((bindPort >> 8) & 0xFF))
        response.append(UInt8(bindPort & 0xFF))
        try await connection.sendData(response)
    }

    private func readAddress(typeRaw: UInt8, reader: ConnectionReader) async throws -> Address? {
        guard let type = AddressType(rawValue: typeRaw) else { return nil }

        switch type {
        case .ipv4:
            let raw = try await reader.readExact(4)
            let host = raw.map(String.init).joined(separator: ".")
            return Address(type: .ipv4, host: host)
        case .domain:
            let lengthRaw = try await reader.readExact(1)
            let length = Int(lengthRaw[0])
            let hostData = try await reader.readExact(length)
            guard let host = String(data: hostData, encoding: .utf8) else { return nil }
            return Address(type: .domain, host: host)
        case .ipv6:
            let raw = try await reader.readExact(16)
            guard let host = Self.ipv6String(from: raw) else { return nil }
            return Address(type: .ipv6, host: host)
        }
    }

    private func encodeAddress(_ address: Address) -> Data? {
        switch address.type {
        case .ipv4:
            guard let ipv4 = IPv4Address(address.host) else { return nil }
            return Data(ipv4.rawValue)
        case .domain:
            guard let data = address.host.data(using: .utf8), data.count <= 255 else { return nil }
            var encoded = Data([UInt8(data.count)])
            encoded.append(data)
            return encoded
        case .ipv6:
            guard let ipv6 = IPv6Address(address.host) else { return nil }
            return Data(ipv6.rawValue)
        }
    }

    fileprivate static func ipv6String(from data: Data) -> String? {
        guard data.count == 16 else { return nil }
        var addr = in6_addr()
        _ = withUnsafeMutableBytes(of: &addr) { buffer in
            data.copyBytes(to: buffer)
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &output, socklen_t(output.count)) != nil else {
            return nil
        }
        return String(cString: output)
    }

    private static func pipe(source: ConnectionReader, destination: NWConnection) async {
        while !Task.isCancelled {
            do {
                let chunk = try await source.readSome()
                if chunk.isEmpty {
                    continue
                }
                try await destination.sendData(chunk)
            } catch {
                destination.cancel()
                break
            }
        }
    }
}

private final class Socks5UDPRelay: @unchecked Sendable {
    struct Endpoint: Sendable {
        let host: String
        let port: UInt16
        let addressType: Socks5Session.AddressType
    }

    private struct RemoteKey: Hashable {
        let address: Socks5Session.Address
        let port: UInt16
    }

    private struct Datagram {
        let address: Socks5Session.Address
        let port: UInt16
        let payload: Data
    }

    private enum RelayError: LocalizedError {
        case listenerPortUnavailable
        case startupTimeout
        case startupFailed
    }

    private let queue: DispatchQueue
    private let bindAddressType: Socks5Session.AddressType
    private let bindHost: String
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private var listener: NWListener?
    private var clientConnection: NWConnection?
    private var clientKey: String?
    private var remoteConnections: [RemoteKey: NWConnection] = [:]

    init(
        queue: DispatchQueue,
        bindAddressType: Socks5Session.AddressType,
        eventLogHandler: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.queue = queue
        self.bindAddressType = bindAddressType
        self.bindHost = bindAddressType == .ipv6 ? "::1" : "127.0.0.1"
        self.eventLogHandler = eventLogHandler
    }

    func start() throws -> Endpoint {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        switch bindAddressType {
        case .ipv6:
            if let loopback = IPv6Address(bindHost) {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv6(loopback), port: .any)
            }
        case .ipv4, .domain:
            if let loopback = IPv4Address(bindHost) {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: .any)
            }
        }

        let listener = try NWListener(using: parameters)

        let startup = StartupWaiter<Endpoint>()

        listener.stateUpdateHandler = { [bindHost, bindAddressType] state in
            switch state {
            case .ready:
                guard let relayPort = listener.port?.rawValue else {
                    startup.resolve(.failure(RelayError.listenerPortUnavailable))
                    return
                }
                startup.resolve(.success(Endpoint(host: bindHost, port: relayPort, addressType: bindAddressType)))
            case let .failed(error):
                startup.resolve(.failure(error))
            case .cancelled:
                startup.resolve(.failure(RelayError.startupFailed))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleClientConnection(connection)
        }
        listener.start(queue: queue)

        if startup.semaphore.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw RelayError.startupTimeout
        }

        if let startupError = startup.error {
            listener.cancel()
            throw startupError
        }

        guard let resolvedEndpoint = startup.value else {
            listener.cancel()
            throw RelayError.startupFailed
        }

        self.listener = listener
        eventLogHandler?("local_socks5_udp_relay", "outcome=ready port=\(resolvedEndpoint.port)")
        return resolvedEndpoint
    }

    func stop() {
        listener?.cancel()
        listener = nil

        clientConnection?.cancel()
        clientConnection = nil
        clientKey = nil

        for connection in remoteConnections.values {
            connection.cancel()
        }
        remoteConnections.removeAll()
    }

    private func handleClientConnection(_ connection: NWConnection) {
        let key = endpointKey(connection.endpoint)
        if let clientKey, clientKey != key {
            connection.cancel()
            return
        }

        clientKey = key
        clientConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveClientDatagrams(from: connection)
            case .failed, .cancelled:
                self.clientConnection = nil
                self.clientKey = nil
                self.stopRemoteConnections()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveClientDatagrams(from connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                self.handleClientDatagram(data)
            }

            if error == nil {
                self.receiveClientDatagrams(from: connection)
            }
        }
    }

    private func handleClientDatagram(_ data: Data) {
        guard let datagram = parseUDPRequest(data) else { return }
        let key = RemoteKey(address: datagram.address, port: datagram.port)

        guard let remote = remoteConnection(for: key) else { return }
        remote.send(content: datagram.payload, completion: .contentProcessed { _ in })
    }

    private func remoteConnection(for key: RemoteKey) -> NWConnection? {
        if let existing = remoteConnections[key] {
            return existing
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: key.port) else { return nil }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: NWEndpoint.Host(key.address.host), port: endpointPort, using: parameters)
        remoteConnections[key] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveRemoteDatagrams(from: connection, key: key)
            case .failed, .cancelled:
                self.remoteConnections.removeValue(forKey: key)
            default:
                break
            }
        }
        connection.start(queue: queue)

        return connection
    }

    private func receiveRemoteDatagrams(from connection: NWConnection, key: RemoteKey) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                self.sendResponseToClient(payload: data, from: key)
            }

            if error == nil {
                self.receiveRemoteDatagrams(from: connection, key: key)
            } else {
                self.remoteConnections.removeValue(forKey: key)
            }
        }
    }

    private func sendResponseToClient(payload: Data, from key: RemoteKey) {
        guard let clientConnection else { return }
        guard let frame = buildUDPResponse(address: key.address, port: key.port, payload: payload) else { return }
        clientConnection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func parseUDPRequest(_ data: Data) -> Datagram? {
        guard data.count >= 4 else { return nil }
        guard data[0] == 0, data[1] == 0 else { return nil }
        guard data[2] == 0 else { return nil } // Fragmentation is not supported.

        var offset = 3
        guard let atyp = Socks5Session.AddressType(rawValue: data[offset]) else { return nil }
        offset += 1

        let host: String
        switch atyp {
        case .ipv4:
            guard data.count >= offset + 4 else { return nil }
            host = data[offset ..< offset + 4].map(String.init).joined(separator: ".")
            offset += 4
        case .domain:
            guard data.count > offset else { return nil }
            let length = Int(data[offset])
            offset += 1
            guard data.count >= offset + length else { return nil }
            guard let decoded = String(data: Data(data[offset ..< offset + length]), encoding: .utf8) else { return nil }
            host = decoded
            offset += length
        case .ipv6:
            guard data.count >= offset + 16 else { return nil }
            let raw = Data(data[offset ..< offset + 16])
            guard let decoded = Socks5Session.ipv6String(from: raw) else { return nil }
            host = decoded
            offset += 16
        }

        guard data.count >= offset + 2 else { return nil }
        let port = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2

        let payload = Data(data[offset...])
        let address = Socks5Session.Address(type: atyp, host: host)
        return Datagram(address: address, port: port, payload: payload)
    }

    private func buildUDPResponse(address: Socks5Session.Address, port: UInt16, payload: Data) -> Data? {
        guard let encodedAddress = encodeAddress(address) else { return nil }
        var frame = Data([0x00, 0x00, 0x00, address.type.rawValue])
        frame.append(encodedAddress)
        frame.append(UInt8((port >> 8) & 0xFF))
        frame.append(UInt8(port & 0xFF))
        frame.append(payload)
        return frame
    }

    private func encodeAddress(_ address: Socks5Session.Address) -> Data? {
        switch address.type {
        case .ipv4:
            guard let ipv4 = IPv4Address(address.host) else { return nil }
            return Data(ipv4.rawValue)
        case .domain:
            guard let data = address.host.data(using: .utf8), data.count <= 255 else { return nil }
            var encoded = Data([UInt8(data.count)])
            encoded.append(data)
            return encoded
        case .ipv6:
            guard let ipv6 = IPv6Address(address.host) else { return nil }
            return Data(ipv6.rawValue)
        }
    }

    private func endpointKey(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, port):
            return "\(host):\(port.rawValue)"
        default:
            return "\(endpoint)"
        }
    }

    private func stopRemoteConnections() {
        for connection in remoteConnections.values {
            connection.cancel()
        }
        remoteConnections.removeAll()
    }
}

private extension NWConnection {
    func startAndWait(on queue: DispatchQueue, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeGuard = ContinuationResumeGuard()

            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                guard resumeGuard.tryBeginResume() else {
                    return
                }

                switch result {
                case .success:
                    continuation.resume(returning: ())
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                finish(.failure(Socks5ServerConnectionError.connectTimeout))
            }
            timer.resume()

            stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timer.cancel()
                    finish(.success(()))
                case let .failed(error):
                    timer.cancel()
                    finish(.failure(error))
                case .cancelled:
                    timer.cancel()
                    finish(.failure(Socks5ServerConnectionError.closed))
                default:
                    break
                }
            }

            start(queue: queue)
        }
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receiveChunk(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }

                if isComplete {
                    continuation.resume(throwing: Socks5ServerConnectionError.closed)
                    return
                }

                continuation.resume(returning: Data())
            }
        }
    }
}
