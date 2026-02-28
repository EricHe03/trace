//
//  DNSParser.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

/// Parses DNS packets per RFC 1035.
/// - Note: Enforces conservative size and label limits to avoid malformed or abusive packets.
public class DNSParser {
    // MARK: - Constants

    private static let dnsHeaderLength = 12
    private static let maxDomainNameLength = 255
    private static let maxLabelLength = 63
    private static let compressionPointerMask: UInt8 = 0xC0

    // MARK: - Errors

    enum DNSParsingError: Error, LocalizedError {
        case packetTooShort
        case invalidHeader
        case invalidDomainName
        case compressionPointerLoop
        case invalidRecordData
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .packetTooShort:
                "DNS packet is too short"
            case .invalidHeader:
                "Invalid DNS header"
            case .invalidDomainName:
                "Invalid domain name format"
            case .compressionPointerLoop:
                "Compression pointer loop detected"
            case .invalidRecordData:
                "Invalid DNS record data"
            case .unsupportedVersion:
                "Unsupported DNS version"
            }
        }
    }

    // MARK: - Parsing

    /// Parses a complete DNS message from packet data.
    ///
    /// - Parameters:
    ///   - data: Raw DNS packet bytes.
    ///   - sourceIP: Source IP address.
    ///   - sourcePort: Source UDP port.
    ///   - destIP: Destination IP address.
    ///   - destPort: Destination UDP port.
    /// - Returns: A decoded `DNSMessage`.
    /// - Throws: `DNSParsingError` when the packet is invalid.
    public static func parse(
        data: Data,
        sourceIP: String,
        sourcePort: UInt16,
        destIP: String,
        destPort: UInt16
    ) throws -> DNSMessage {
        guard data.count >= dnsHeaderLength else {
            throw DNSParsingError.packetTooShort
        }

        let header = try parseHeader(data: data)

        var offset = dnsHeaderLength
        var questions: [DNSQuestion] = []
        var answers: [DNSResourceRecord] = []
        var authorities: [DNSResourceRecord] = []
        var additionals: [DNSResourceRecord] = []

        for _ in 0 ..< header.questionCount {
            let (question, newOffset) = try parseQuestion(data: data, offset: offset)
            questions.append(question)
            offset = newOffset
        }

        for _ in 0 ..< header.answerCount {
            let (record, newOffset) = try parseResourceRecord(data: data, offset: offset)
            answers.append(record)
            offset = newOffset
        }

        for _ in 0 ..< header.authorityCount {
            let (record, newOffset) = try parseResourceRecord(data: data, offset: offset)
            authorities.append(record)
            offset = newOffset
        }

        for _ in 0 ..< header.additionalCount {
            let (record, newOffset) = try parseResourceRecord(data: data, offset: offset)
            additionals.append(record)
            offset = newOffset
        }

        return DNSMessage(
            transactionId: header.transactionId,
            timestamp: Date(),
            isResponse: header.isResponse,
            opcode: header.opcode,
            isAuthoritative: header.isAuthoritative,
            isTruncated: header.isTruncated,
            recursionDesired: header.recursionDesired,
            recursionAvailable: header.recursionAvailable,
            responseCode: header.responseCode,
            questions: questions,
            answers: answers,
            authorities: authorities,
            additionals: additionals,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            destIP: destIP,
            destPort: destPort,
            messageSize: data.count
        )
    }

    // MARK: - Header Parsing

    private struct DNSHeader {
        let transactionId: UInt16
        let isResponse: Bool
        let opcode: DNSOpcode
        let isAuthoritative: Bool
        let isTruncated: Bool
        let recursionDesired: Bool
        let recursionAvailable: Bool
        let responseCode: DNSResponseCode
        let questionCount: UInt16
        let answerCount: UInt16
        let authorityCount: UInt16
        let additionalCount: UInt16
    }

    private static func parseHeader(data: Data) throws -> DNSHeader {
        guard data.count >= dnsHeaderLength else {
            throw DNSParsingError.invalidHeader
        }

        let transactionId = UInt16(data[0]) << 8 | UInt16(data[1])

        let flags = UInt16(data[2]) << 8 | UInt16(data[3])

        let isResponse = (flags & 0x8000) != 0
        let opcodeValue = UInt8((flags >> 11) & 0x0F)
        let opcode = DNSOpcode(rawValue: opcodeValue) ?? .query
        let isAuthoritative = (flags & 0x0400) != 0
        let isTruncated = (flags & 0x0200) != 0
        let recursionDesired = (flags & 0x0100) != 0
        let recursionAvailable = (flags & 0x0080) != 0
        let responseCodeValue = UInt8(flags & 0x000F)
        let responseCode = DNSResponseCode(rawValue: responseCodeValue) ?? .noError

        let questionCount = UInt16(data[4]) << 8 | UInt16(data[5])
        let answerCount = UInt16(data[6]) << 8 | UInt16(data[7])
        let authorityCount = UInt16(data[8]) << 8 | UInt16(data[9])
        let additionalCount = UInt16(data[10]) << 8 | UInt16(data[11])

        return DNSHeader(
            transactionId: transactionId,
            isResponse: isResponse,
            opcode: opcode,
            isAuthoritative: isAuthoritative,
            isTruncated: isTruncated,
            recursionDesired: recursionDesired,
            recursionAvailable: recursionAvailable,
            responseCode: responseCode,
            questionCount: questionCount,
            answerCount: answerCount,
            authorityCount: authorityCount,
            additionalCount: additionalCount
        )
    }

    // MARK: - Question Parsing

    private static func parseQuestion(data: Data, offset: Int) throws -> (DNSQuestion, Int) {
        let (name, nameEndOffset) = try parseDomainName(data: data, offset: offset)

        guard nameEndOffset + 4 <= data.count else {
            throw DNSParsingError.packetTooShort
        }

        let typeValue = UInt16(data[nameEndOffset]) << 8 | UInt16(data[nameEndOffset + 1])
        let type = DNSRecordType(rawValue: typeValue) ?? .unknown

        let classValue = UInt16(data[nameEndOffset + 2]) << 8 | UInt16(data[nameEndOffset + 3])
        // Rule: Mask off the mDNS cache-flush bit if present while preserving the class.
        let normalizedClassValue = classValue & 0x7FFF
        let dnsClass = DNSClass(rawValue: normalizedClassValue) ?? .unknown

        let question = DNSQuestion(
            name: name,
            type: type,
            class: dnsClass,
            rawTypeValue: typeValue,
            rawClassValue: normalizedClassValue
        )

        return (question, nameEndOffset + 4)
    }

    // MARK: - Resource Record Parsing

    private static func parseResourceRecord(data: Data, offset: Int) throws -> (DNSResourceRecord, Int) {
        let (name, nameEndOffset) = try parseDomainName(data: data, offset: offset)

        guard nameEndOffset + 10 <= data.count else {
            throw DNSParsingError.packetTooShort
        }

        let typeValue = UInt16(data[nameEndOffset]) << 8 | UInt16(data[nameEndOffset + 1])
        let type = DNSRecordType(rawValue: typeValue) ?? .unknown

        let classValue = UInt16(data[nameEndOffset + 2]) << 8 | UInt16(data[nameEndOffset + 3])
        // Rule: Mask off the mDNS cache-flush bit if present while preserving the class.
        let normalizedClassValue = classValue & 0x7FFF
        let dnsClass = DNSClass(rawValue: normalizedClassValue) ?? .unknown

        let ttl = UInt32(data[nameEndOffset + 4]) << 24 |
            UInt32(data[nameEndOffset + 5]) << 16 |
            UInt32(data[nameEndOffset + 6]) << 8 |
            UInt32(data[nameEndOffset + 7])

        let dataLength = UInt16(data[nameEndOffset + 8]) << 8 | UInt16(data[nameEndOffset + 9])

        let dataOffset = nameEndOffset + 10
        guard dataOffset + Int(dataLength) <= data.count else {
            throw DNSParsingError.invalidRecordData
        }

        let recordData = data[dataOffset ..< (dataOffset + Int(dataLength))]
        let finalData = Data(recordData)

        let record = DNSResourceRecord(
            name: name,
            type: type,
            class: dnsClass,
            rawTypeValue: typeValue,
            rawClassValue: normalizedClassValue,
            ttl: ttl,
            dataLength: dataLength,
            data: finalData
        )

        return (record, dataOffset + Int(dataLength))
    }

    // MARK: - Domain Name Decompression

    private static func parseDomainName(data: Data, offset: Int) throws -> (String, Int) {
        var labels: [String] = []
        var currentOffset = offset
        var jumped = false
        // Store the original offset so the caller can resume after a compression jump.
        var jumpOffset = 0
        var visitedOffsets: Set<Int> = []

        while currentOffset < data.count {
            if visitedOffsets.contains(currentOffset) {
                throw DNSParsingError.compressionPointerLoop
            }
            visitedOffsets.insert(currentOffset)

            let length = data[currentOffset]

            if length == 0 {
                currentOffset += 1
                break
            }

            if (length & compressionPointerMask) == compressionPointerMask {
                guard currentOffset + 1 < data.count else {
                    throw DNSParsingError.invalidDomainName
                }

                let pointerOffset = Int((UInt16(length & 0x3F) << 8) | UInt16(data[currentOffset + 1]))
                guard pointerOffset < data.count else {
                    throw DNSParsingError.invalidDomainName
                }

                if !jumped {
                    jumpOffset = currentOffset + 2
                    jumped = true
                }

                currentOffset = pointerOffset
                continue
            }

            guard length <= maxLabelLength else {
                throw DNSParsingError.invalidDomainName
            }

            currentOffset += 1
            let labelEnd = currentOffset + Int(length)

            guard labelEnd <= data.count else {
                throw DNSParsingError.invalidDomainName
            }

            // Rule: Require UTF-8 labels to keep the decoded name printable and avoid lossy decoding.
            if let label = String(data: data[currentOffset ..< labelEnd], encoding: .utf8) {
                labels.append(label)
            } else {
                throw DNSParsingError.invalidDomainName
            }

            currentOffset = labelEnd
        }

        let domainName = labels.joined(separator: ".")

        guard domainName.count <= maxDomainNameLength else {
            throw DNSParsingError.invalidDomainName
        }

        let finalOffset = jumped ? jumpOffset : currentOffset

        return (domainName, finalOffset)
    }

    // MARK: - Validation

    /// Returns whether data resembles a DNS packet.
    /// - Note: This is a heuristic gate and should not be treated as full validation.
    public static func looksLikeDNS(data: Data) -> Bool {
        guard data.count >= dnsHeaderLength else {
            return false
        }

        let flags = UInt16(data[2]) << 8 | UInt16(data[3])
        let opcode = (flags >> 11) & 0x0F
        let rcode = flags & 0x000F

        guard opcode <= 6 else {
            return false
        }

        guard rcode <= 10 else {
            return false
        }

        let questionCount = UInt16(data[4]) << 8 | UInt16(data[5])
        let answerCount = UInt16(data[6]) << 8 | UInt16(data[7])
        let authorityCount = UInt16(data[8]) << 8 | UInt16(data[9])
        let additionalCount = UInt16(data[10]) << 8 | UInt16(data[11])

        let totalCount = questionCount + answerCount + authorityCount + additionalCount

        guard totalCount > 0 && totalCount < 100 else {
            return false
        }

        return true
    }
}

// MARK: - Extensions

public extension DNSParser {
    /// Parses a DNS message while logging failures.
    ///
    /// - Parameters:
    ///   - data: Raw DNS packet bytes.
    ///   - sourceIP: Source IP address.
    ///   - sourcePort: Source UDP port.
    ///   - destIP: Destination IP address.
    ///   - destPort: Destination UDP port.
    /// - Returns: A parsed `DNSMessage` or `nil` when parsing fails.
    static func parseSafely(
        data: Data,
        sourceIP: String,
        sourcePort: UInt16,
        destIP: String,
        destPort: UInt16
    ) -> DNSMessage? {
        do {
            return try parse(
                data: data,
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destIP: destIP,
                destPort: destPort
            )
        } catch {
            NetworkLog.dns.warning("event=dns.parse outcome=failure error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
