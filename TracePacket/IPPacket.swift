//
//  IPPacket.swift
//  TracePacket
//
//  Created by Justin on 2026/01/19.
//

import Foundation

public enum TransportProtocol: UInt8, Sendable {
    case tcp = 6
    case udp = 17
}

public struct IPPacket: Sendable {
    public let version: UInt8
    public let headerLength: Int
    public let totalLength: Int
    public let protocolNumber: UInt8
    public let source: IPAddress
    public let destination: IPAddress
    public let payload: Data

    public var transport: TransportProtocol? {
        TransportProtocol(rawValue: protocolNumber)
    }
}
