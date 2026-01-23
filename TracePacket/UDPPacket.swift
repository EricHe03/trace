//
//  UDPPacket.swift
//  TracePacket
//
//  Created by Justin on 2026/01/20.
//

import Foundation

public struct UDPPacket: Sendable {
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let length: UInt16
    public let payload: Data
}
