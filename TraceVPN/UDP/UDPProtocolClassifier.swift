//
//  UDPProtocolClassifier.swift
//  TraceVPN
//
//  Created by Justin on 2026/02/24.
//

import Foundation
import TraceCore
import TraceNetworking

enum UDPProtocolClassifier {
    struct Classification {
        let applicationProtocol: TransportApplicationProtocol
        let parserOutcome: TransportParserOutcome
        let summary: String?
    }

    static func classify(
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data,
        sourceIP: String,
        destinationIP: String
    ) -> Classification {
        if sourcePort == 53 || destinationPort == 53 {
            if let message = parseDNS(
                payload: payload,
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destinationIP: destinationIP,
                destinationPort: destinationPort
            ) {
                return Classification(
                    applicationProtocol: .dns,
                    parserOutcome: .parsed,
                    summary: messageSummary(for: message)
                )
            }
            return Classification(
                applicationProtocol: .unknown,
                parserOutcome: .fallbackSignatureOnly,
                summary: "udp/53 parse_failed"
            )
        }

        if sourcePort == 5353 || destinationPort == 5353 {
            if let message = parseDNS(
                payload: payload,
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destinationIP: destinationIP,
                destinationPort: destinationPort
            ) {
                return Classification(
                    applicationProtocol: .mdns,
                    parserOutcome: .parsed,
                    summary: messageSummary(for: message)
                )
            }
            return Classification(
                applicationProtocol: .unknown,
                parserOutcome: .fallbackSignatureOnly,
                summary: "udp/5353 parse_failed"
            )
        }

        if sourcePort == 123 || destinationPort == 123 {
            if looksLikeNTP(payload) {
                return Classification(
                    applicationProtocol: .ntp,
                    parserOutcome: .parsed,
                    summary: "NTP v\(ntpVersion(payload)) mode=\(ntpMode(payload))"
                )
            }
            return Classification(
                applicationProtocol: .unknown,
                parserOutcome: .fallbackSignatureOnly,
                summary: "udp/123 parse_failed"
            )
        }

        if sourcePort == 67 || sourcePort == 68 || destinationPort == 67 || destinationPort == 68 {
            if looksLikeDHCPv4(payload) {
                return Classification(
                    applicationProtocol: .dhcpv4,
                    parserOutcome: .parsed,
                    summary: "DHCPv4"
                )
            }
            return Classification(
                applicationProtocol: .unknown,
                parserOutcome: .fallbackSignatureOnly,
                summary: "udp/67-68 parse_failed"
            )
        }

        if sourcePort == 546 || sourcePort == 547 || destinationPort == 546 || destinationPort == 547 {
            if looksLikeDHCPv6(payload) {
                return Classification(
                    applicationProtocol: .dhcpv6,
                    parserOutcome: .parsed,
                    summary: "DHCPv6 type=\(payload.first ?? 0)"
                )
            }
            return Classification(
                applicationProtocol: .unknown,
                parserOutcome: .fallbackSignatureOnly,
                summary: "udp/546-547 parse_failed"
            )
        }

        if sourcePort == 161 || sourcePort == 162 || destinationPort == 161 || destinationPort == 162 {
            if looksLikeSNMP(payload) {
                return Classification(
                    applicationProtocol: .snmp,
                    parserOutcome: .parsed,
                    summary: "SNMP"
                )
            }
            return Classification(
                applicationProtocol: .unknown,
                parserOutcome: .fallbackSignatureOnly,
                summary: "udp/161-162 parse_failed"
            )
        }

        if sourcePort == 443 || destinationPort == 443 {
            if looksLikeQUIC(payload) {
                return Classification(
                    applicationProtocol: .quic,
                    parserOutcome: .parsed,
                    summary: "QUIC"
                )
            }
        }

        // QUIC on non-standard ports: require the stricter long-header + known version check
        // to avoid false positives that the loose bit-only check would produce on arbitrary ports.
        if looksLikeQUICStrict(payload) {
            return Classification(
                applicationProtocol: .quic,
                parserOutcome: .parsed,
                summary: "QUIC (non-443)"
            )
        }

        return Classification(
            applicationProtocol: .unknown,
            parserOutcome: .fallbackUnknown,
            summary: nil
        )
    }

    private static func parseDNS(
        payload: Data,
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        destinationPort: UInt16
    ) -> DNSMessage? {
        DNSParser.parseSafely(
            data: payload,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            destIP: destinationIP,
            destPort: destinationPort
        )
    }

    private static func messageSummary(for message: DNSMessage) -> String {
        let kind = message.isResponse ? "response" : "query"
        let domain = message.queryDomain ?? "-"
        let type = message.queryType?.displayName ?? "UNK"
        return "DNS \(kind) \(domain) \(type)"
    }

    private static func looksLikeQUIC(_ payload: Data) -> Bool {
        guard let first = payload.first else { return false }
        // Long header sets bit 0x80; short header keeps fixed bit 0x40 set.
        return (first & 0x80) == 0x80 || (first & 0x40) == 0x40
    }

    /// Strict QUIC detection: requires both the long-header fixed bits (0xC0) AND a known QUIC
    /// version number in bytes 1–4. Safe to apply on any port without false positives from
    /// the looser bit-only check used on port 443.
    ///
    /// Recognised versions (RFC 9000 §15):
    ///   - 0x00000001  QUIC v1
    ///   - 0x6b3343cf  QUIC v2 (RFC 9369)
    ///   - 0x00000000  Version Negotiation
    private static func looksLikeQUICStrict(_ payload: Data) -> Bool {
        guard payload.count >= 5, let first = payload.first else { return false }
        guard (first & 0xC0) == 0xC0 else { return false }
        let version = UInt32(payload[1]) << 24
            | UInt32(payload[2]) << 16
            | UInt32(payload[3]) << 8
            | UInt32(payload[4])
        return version == 0x0000_0001 || version == 0x6B33_43CF || version == 0x0000_0000
    }

    private static func ntpVersion(_ payload: Data) -> UInt8 {
        guard let first = payload.first else { return 0 }
        return (first >> 3) & 0x07
    }

    private static func ntpMode(_ payload: Data) -> UInt8 {
        guard let first = payload.first else { return 0 }
        return first & 0x07
    }

    private static func looksLikeNTP(_ payload: Data) -> Bool {
        guard payload.count >= 48 else { return false }
        let version = ntpVersion(payload)
        let mode = ntpMode(payload)
        let stratum = payload[1]
        guard (1 ... 4).contains(version) else { return false }
        guard (1 ... 7).contains(mode) else { return false }
        guard stratum <= 16 else { return false }
        return true
    }

    private static func looksLikeDHCPv4(_ payload: Data) -> Bool {
        guard payload.count >= 240 else { return false }
        let op = payload[0]
        let hlen = payload[2]
        guard op == 1 || op == 2 else { return false }
        guard hlen > 0, hlen <= 16 else { return false }

        let cookieOffset = 236
        let cookie = UInt32(payload[cookieOffset]) << 24 |
            UInt32(payload[cookieOffset + 1]) << 16 |
            UInt32(payload[cookieOffset + 2]) << 8 |
            UInt32(payload[cookieOffset + 3])
        guard cookie == 0x6382_5363 else { return false }
        return true
    }

    private static func looksLikeDHCPv6(_ payload: Data) -> Bool {
        guard payload.count >= 4 else { return false }
        let type = payload[0]
        // RFC 8415 defines core message types 1...13, but newer specs/registries
        // can allocate additional non-zero values. Accept non-zero type codes
        // with structural checks to stay forward-compatible.
        guard type != 0 else { return false }
        if type == 12 || type == 13 {
            // Relay-forward / relay-reply include hop-count + link-address + peer-address.
            return payload.count >= 34
        }
        return payload.count >= 4
    }

    private static func looksLikeSNMP(_ payload: Data) -> Bool {
        guard payload.count >= 6 else { return false }
        guard payload[0] == 0x30 else { return false } // SEQUENCE
        guard let (sequenceLength, sequenceLengthBytes) = parseBERLength(payload, at: 1) else { return false }
        let sequenceEnd = 1 + sequenceLengthBytes + sequenceLength
        guard sequenceEnd <= payload.count else { return false }

        let versionTagOffset = 1 + sequenceLengthBytes
        guard versionTagOffset + 2 <= payload.count else { return false }
        guard payload[versionTagOffset] == 0x02 else { return false } // INTEGER
        guard let (versionLength, versionLengthBytes) = parseBERLength(payload, at: versionTagOffset + 1) else { return false }
        let versionValueOffset = versionTagOffset + 1 + versionLengthBytes
        guard versionValueOffset + versionLength <= payload.count else { return false }
        guard versionLength > 0, versionLength <= 4 else { return false }

        var version = 0
        for index in 0 ..< versionLength {
            version = (version << 8) | Int(payload[versionValueOffset + index])
        }

        // v1=0, v2c=1, v3=3 (allow v2u=2 for compatibility).
        return (0 ... 3).contains(version)
    }

    private static func parseBERLength(_ data: Data, at offset: Int) -> (length: Int, bytesUsed: Int)? {
        guard offset < data.count else { return nil }
        let first = data[offset]
        if first & 0x80 == 0 {
            return (Int(first), 1)
        }

        let count = Int(first & 0x7F)
        guard count > 0, count <= 4 else { return nil }
        guard offset + 1 + count <= data.count else { return nil }

        var length = 0
        for index in 0 ..< count {
            length = (length << 8) | Int(data[offset + 1 + index])
        }
        return (length, 1 + count)
    }
}
