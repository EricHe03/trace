//
//  UDPForwardingDecision.swift
//  TraceCore
//
//  Created by Justin on 2026/02/11.
//

import Foundation

public enum SocksEndpointSource: String, Sendable {
    case configured
    case embedded
}

@inlinable
public func selectSocksEndpointSource(host: String, port: UInt16) -> SocksEndpointSource {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    return (!trimmedHost.isEmpty && port > 0) ? .configured : .embedded
}

public enum UDPForwardDecision: Equatable, Sendable {
    case dropQUIC
    case forwardDirect
    case forwardTunnel
}

@inlinable
public func decideUDPForwarding(
    udpForwarderAvailable: Bool,
    mode: UDPForwardingMode,
    sourcePort: UInt16,
    destinationPort: UInt16,
    blockQUICEnabled: Bool,
    tunnelUDPSupported: Bool
) -> (decision: UDPForwardDecision, isQUIC: Bool) {
    let isQUIC = destinationPort == 443 || sourcePort == 443
    if blockQUICEnabled, isQUIC {
        return (.dropQUIC, true)
    }

    if udpForwarderAvailable {
        switch mode {
        case .direct:
            return (.forwardDirect, isQUIC)
        case .split:
            if isQUIC {
                return (tunnelUDPSupported ? .forwardTunnel : .forwardDirect, true)
            }
            return (.forwardDirect, false)
        case .hevOnly:
            return (tunnelUDPSupported ? .forwardTunnel : .forwardDirect, isQUIC)
        }
    }

    return (.forwardTunnel, isQUIC)
}
