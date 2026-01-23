//
//  ProxyConnection+TLS.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import Network
import OSLog
import TraceCore
import TraceSecurity

/// Adds TLS support to `ProxyConnection`.
public extension ProxyConnection {
    /// Creates a TLS connection to the upstream server.
    func createTLSServerConnection(to host: String, port: UInt16) -> NWConnection? {
        let tlsOptions = TLSHandler.createClientTLSOptions(for: host)

        let parameters = NWParameters(tls: tlsOptions, tcp: .init())

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            ProxyLog.mitm.error("event=proxy.tls_invalid_port outcome=failure port=\(port)")
            return nil
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let connection = NWConnection(to: endpoint, using: parameters)

        ProxyLog.mitm.debug("event=proxy.tls_connect_create outcome=pending host=\(host, privacy: .private(mask: .hash)) port=\(port)")

        return connection
    }
}
