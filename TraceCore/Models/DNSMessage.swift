//
//  DNSMessage.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Represents a complete DNS message (query or response).
public struct DNSMessage: Codable, Identifiable {
    public let id: UUID
    public let transactionId: UInt16
    public let timestamp: Date

    // Header flags
    public let isResponse: Bool
    public let opcode: DNSOpcode
    public let isAuthoritative: Bool
    public let isTruncated: Bool
    public let recursionDesired: Bool
    public let recursionAvailable: Bool
    public let responseCode: DNSResponseCode

    // Sections
    public let questions: [DNSQuestion]
    public let answers: [DNSResourceRecord]
    public let authorities: [DNSResourceRecord]
    public let additionals: [DNSResourceRecord]

    // Network information
    public let sourceIP: String
    public let sourcePort: UInt16
    public let destIP: String
    public let destPort: UInt16

    /// Size
    public let messageSize: Int

    // Related messages
    public var relatedQueryId: UUID?
    public var relatedResponseId: UUID?
    public var responseTime: TimeInterval?

    public init(
        id: UUID = UUID(),
        transactionId: UInt16,
        timestamp: Date = Date(),
        isResponse: Bool,
        opcode: DNSOpcode,
        isAuthoritative: Bool,
        isTruncated: Bool,
        recursionDesired: Bool,
        recursionAvailable: Bool,
        responseCode: DNSResponseCode,
        questions: [DNSQuestion],
        answers: [DNSResourceRecord],
        authorities: [DNSResourceRecord],
        additionals: [DNSResourceRecord],
        sourceIP: String,
        sourcePort: UInt16,
        destIP: String,
        destPort: UInt16,
        messageSize: Int,
        relatedQueryId: UUID? = nil,
        relatedResponseId: UUID? = nil,
        responseTime: TimeInterval? = nil
    ) {
        self.id = id
        self.transactionId = transactionId
        self.timestamp = timestamp
        self.isResponse = isResponse
        self.opcode = opcode
        self.isAuthoritative = isAuthoritative
        self.isTruncated = isTruncated
        self.recursionDesired = recursionDesired
        self.recursionAvailable = recursionAvailable
        self.responseCode = responseCode
        self.questions = questions
        self.answers = answers
        self.authorities = authorities
        self.additionals = additionals
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destIP = destIP
        self.destPort = destPort
        self.messageSize = messageSize
        self.relatedQueryId = relatedQueryId
        self.relatedResponseId = relatedResponseId
        self.responseTime = responseTime
    }

    /// Primary question (first in questions array).
    public var primaryQuestion: DNSQuestion? {
        questions.first
    }

    /// Primary domain being queried.
    public var queryDomain: String? {
        primaryQuestion?.name
    }

    /// Primary query type.
    public var queryType: DNSRecordType? {
        primaryQuestion?.type
    }

    /// Indicates whether the message is a successful response.
    public var isSuccessful: Bool {
        isResponse && responseCode.isSuccess
    }

    /// Extracts all IP addresses from A and AAAA records.
    public var resolvedIPs: [String] {
        answers.compactMap { record in
            switch record.type {
            case .a, .aaaa:
                record.dataString
            default:
                nil
            }
        }
    }

    /// Extracts all CNAME records.
    public var cnames: [String] {
        answers.compactMap { record in
            record.type == .cname ? record.dataString : nil
        }
    }

    /// Short description for list views.
    public var shortDescription: String {
        if let domain = queryDomain, let type = queryType {
            return "\(domain) (\(type.displayName))"
        }
        return "DNS \(isResponse ? "Response" : "Query")"
    }

    /// Status icon system name.
    public var statusIcon: String {
        if !isResponse {
            return "arrow.up.circle"
        }
        return isSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    /// Status color name.
    public var statusColor: String {
        if !isResponse {
            return "blue"
        }
        return isSuccessful ? "green" : "red"
    }
}

/// Represents a DNS question.
public struct DNSQuestion: Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let type: DNSRecordType
    public let `class`: DNSClass
    public let rawTypeValue: UInt16
    public let rawClassValue: UInt16

    public init(
        id: UUID = UUID(),
        name: String,
        type: DNSRecordType,
        class: DNSClass = .in,
        rawTypeValue: UInt16? = nil,
        rawClassValue: UInt16? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.class = `class`
        self.rawTypeValue = rawTypeValue ?? type.rawValue
        self.rawClassValue = rawClassValue ?? `class`.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case `class`
        case rawTypeValue
        case rawClassValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)

        let decodedType = try? container.decode(DNSRecordType.self, forKey: .type)
        let decodedClass = try? container.decode(DNSClass.self, forKey: .class)
        rawTypeValue = try container.decodeIfPresent(UInt16.self, forKey: .rawTypeValue) ?? decodedType?.rawValue ?? DNSRecordType.unknown.rawValue
        rawClassValue = try container.decodeIfPresent(UInt16.self, forKey: .rawClassValue) ?? decodedClass?.rawValue ?? DNSClass.unknown.rawValue
        type = DNSRecordType(rawValue: rawTypeValue) ?? decodedType ?? .unknown
        `class` = DNSClass(rawValue: rawClassValue) ?? decodedClass ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(`class`, forKey: .class)
        try container.encode(rawTypeValue, forKey: .rawTypeValue)
        try container.encode(rawClassValue, forKey: .rawClassValue)
    }

    public var typeDisplayName: String {
        if type == .unknown {
            return "TYPE\(rawTypeValue)"
        }
        return type.displayName
    }

    public var classDisplayName: String {
        if `class` == .unknown {
            return "CLASS\(rawClassValue)"
        }
        return `class`.displayName
    }

    public var displayString: String {
        "\(name) \(typeDisplayName) \(classDisplayName)"
    }
}

/// Represents a DNS resource record (answer, authority, or additional).
public struct DNSResourceRecord: Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let type: DNSRecordType
    public let `class`: DNSClass
    public let rawTypeValue: UInt16
    public let rawClassValue: UInt16
    public let ttl: UInt32
    public let dataLength: UInt16
    public let data: Data

    public init(
        id: UUID = UUID(),
        name: String,
        type: DNSRecordType,
        class: DNSClass = .in,
        rawTypeValue: UInt16? = nil,
        rawClassValue: UInt16? = nil,
        ttl: UInt32,
        dataLength: UInt16,
        data: Data
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.class = `class`
        self.rawTypeValue = rawTypeValue ?? type.rawValue
        self.rawClassValue = rawClassValue ?? `class`.rawValue
        self.ttl = ttl
        self.dataLength = dataLength
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case `class`
        case rawTypeValue
        case rawClassValue
        case ttl
        case dataLength
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        let decodedType = try? container.decode(DNSRecordType.self, forKey: .type)
        let decodedClass = try? container.decode(DNSClass.self, forKey: .class)
        rawTypeValue = try container.decodeIfPresent(UInt16.self, forKey: .rawTypeValue) ?? decodedType?.rawValue ?? DNSRecordType.unknown.rawValue
        rawClassValue = try container.decodeIfPresent(UInt16.self, forKey: .rawClassValue) ?? decodedClass?.rawValue ?? DNSClass.unknown.rawValue
        type = DNSRecordType(rawValue: rawTypeValue) ?? decodedType ?? .unknown
        `class` = DNSClass(rawValue: rawClassValue) ?? decodedClass ?? .unknown
        ttl = try container.decode(UInt32.self, forKey: .ttl)
        dataLength = try container.decode(UInt16.self, forKey: .dataLength)
        data = try container.decode(Data.self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(`class`, forKey: .class)
        try container.encode(rawTypeValue, forKey: .rawTypeValue)
        try container.encode(rawClassValue, forKey: .rawClassValue)
        try container.encode(ttl, forKey: .ttl)
        try container.encode(dataLength, forKey: .dataLength)
        try container.encode(data, forKey: .data)
    }

    public var typeDisplayName: String {
        if type == .unknown {
            return "TYPE\(rawTypeValue)"
        }
        return type.displayName
    }

    public var classDisplayName: String {
        if `class` == .unknown {
            return "CLASS\(rawClassValue)"
        }
        return `class`.displayName
    }

    /// Parsed data as a string (for A, AAAA, CNAME, etc.).
    public var dataString: String {
        switch type {
        case .a:
            parseIPv4()
        case .aaaa:
            parseIPv6()
        case .cname, .ns, .ptr, .dname:
            parseDomainName()
        case .mx:
            parseMX()
        case .txt:
            parseTXT()
        case .srv:
            parseSRV()
        default:
            data.hexEncodedString()
        }
    }

    /// Parses an IPv4 address from an A record.
    private func parseIPv4() -> String {
        guard data.count == 4 else { return "Invalid IPv4" }
        return data.map { String($0) }.joined(separator: ".")
    }

    /// Parses an IPv6 address from an AAAA record.
    private func parseIPv6() -> String {
        guard data.count == 16 else { return "Invalid IPv6" }
        var parts: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let value = UInt16(data[i]) << 8 | UInt16(data[i + 1])
            parts.append(String(format: "%x", value))
        }
        return parts.joined(separator: ":")
    }

    /// Parses a domain name (for CNAME, NS, PTR, etc.).
    private func parseDomainName() -> String {
        // Simplified: does not resolve compression without full packet context.
        var result = ""
        var offset = 0

        while offset < data.count {
            let length = Int(data[offset])
            offset += 1

            if length == 0 {
                break
            }

            // Check for compression pointer
            if length >= 192 {
                result += "<compressed>"
                break
            }

            if !result.isEmpty {
                result += "."
            }

            let end = min(offset + length, data.count)
            if let label = String(data: data[offset ..< end], encoding: .utf8) {
                result += label
            }
            offset += length
        }

        return result.isEmpty ? "<invalid>" : result
    }

    /// Parses an MX record.
    private func parseMX() -> String {
        guard data.count >= 2 else { return "Invalid MX" }
        let preference = UInt16(data[0]) << 8 | UInt16(data[1])
        let exchange = parseDomainNameFrom(offset: 2)
        return "\(preference) \(exchange)"
    }

    /// Parses a TXT record.
    private func parseTXT() -> String {
        var result = ""
        var offset = 0

        while offset < data.count {
            let length = Int(data[offset])
            offset += 1

            if length == 0 || offset + length > data.count {
                break
            }

            if let text = String(data: data[offset ..< (offset + length)], encoding: .utf8) {
                if !result.isEmpty {
                    result += " "
                }
                result += text
            }
            offset += length
        }

        return result.isEmpty ? "<empty>" : result
    }

    /// Parses an SRV record.
    private func parseSRV() -> String {
        guard data.count >= 6 else { return "Invalid SRV" }
        let priority = UInt16(data[0]) << 8 | UInt16(data[1])
        let weight = UInt16(data[2]) << 8 | UInt16(data[3])
        let port = UInt16(data[4]) << 8 | UInt16(data[5])
        let target = parseDomainNameFrom(offset: 6)
        return "\(priority) \(weight) \(port) \(target)"
    }

    /// Parses a domain name starting from a specific offset.
    private func parseDomainNameFrom(offset: Int) -> String {
        var result = ""
        var pos = offset

        while pos < data.count {
            let length = Int(data[pos])
            pos += 1

            if length == 0 {
                break
            }

            if length >= 192 {
                result += "<compressed>"
                break
            }

            if !result.isEmpty {
                result += "."
            }

            let end = min(pos + length, data.count)
            if let label = String(data: data[pos ..< end], encoding: .utf8) {
                result += label
            }
            pos += length
        }

        return result.isEmpty ? "<invalid>" : result
    }

    public var displayString: String {
        "\(name) \(ttl)s \(classDisplayName) \(typeDisplayName) \(dataString)"
    }
}

// MARK: - Helpers

public extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Sample Data

public extension DNSMessage {
    static var sampleQuery: DNSMessage {
        DNSMessage(
            transactionId: 0x1234,
            timestamp: Date(),
            isResponse: false,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: false,
            responseCode: .noError,
            questions: [
                DNSQuestion(name: "api.github.com", type: .a, class: .in)
            ],
            answers: [],
            authorities: [],
            additionals: [],
            sourceIP: "192.168.1.100",
            sourcePort: 54321,
            destIP: "8.8.8.8",
            destPort: 53,
            messageSize: 32
        )
    }

    static var sampleResponse: DNSMessage {
        DNSMessage(
            transactionId: 0x1234,
            timestamp: Date(),
            isResponse: true,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: true,
            responseCode: .noError,
            questions: [
                DNSQuestion(name: "api.github.com", type: .a, class: .in)
            ],
            answers: [
                DNSResourceRecord(
                    name: "api.github.com",
                    type: .a,
                    class: .in,
                    ttl: 60,
                    dataLength: 4,
                    data: Data([140, 82, 121, 4])
                )
            ],
            authorities: [],
            additionals: [],
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.100",
            destPort: 54321,
            messageSize: 48,
            responseTime: 0.025
        )
    }

    static var samples: [DNSMessage] {
        [sampleQuery, sampleResponse]
    }
}
