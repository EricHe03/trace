//
//  LocalSocks5Protocol.swift
//  TraceVPN
//

import Foundation

enum Socks5ServerConnectionError: LocalizedError {
    case closed
    case commandNotSupported
    case addressTypeNotSupported
    case connectFailed

    var errorDescription: String? {
        switch self {
        case .closed:
            "Connection closed"
        case .commandNotSupported:
            "SOCKS5 command not supported"
        case .addressTypeNotSupported:
            "SOCKS5 address type not supported"
        case .connectFailed:
            "Failed to connect upstream target"
        }
    }
}

enum Socks5Command: UInt8 {
    case connect = 0x01
    case udpAssociate = 0x03
}

enum Socks5Reply: UInt8 {
    case succeeded = 0x00
    case generalFailure = 0x01
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08
}

enum Socks5AddressType: UInt8, Sendable {
    case ipv4 = 0x01
    case domain = 0x03
    case ipv6 = 0x04
}

struct Socks5Address: Hashable, Sendable {
    let type: Socks5AddressType
    let host: String
}

struct Socks5Request {
    let command: Socks5Command
    let address: Socks5Address
    let port: UInt16
}

enum ParseResult<T> {
    case needMoreData
    case invalid
    case value(T)
}

/// Result type for SOCKS5 request parsing that distinguishes the reason for rejection,
/// so the correct RFC 1928 §6 REP code can be returned to the client.
enum Socks5RequestParseResult {
    case needMoreData
    case commandNotSupported
    case addressTypeNotSupported
    case generalFailure
    case value(Socks5Request)
}
