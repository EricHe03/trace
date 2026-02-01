//
//  DNSMessageTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class DNSMessageTests: XCTestCase {

    // MARK: - DNSMessage Initialization Tests

    func testDNSMessageInit() {
        let message = DNSMessage(
            transactionId: 0x1234,
            timestamp: Date(),
            isResponse: false,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: false,
            responseCode: .noError,
            questions: [],
            answers: [],
            authorities: [],
            additionals: [],
            sourceIP: "192.168.1.1",
            sourcePort: 12345,
            destIP: "8.8.8.8",
            destPort: 53,
            messageSize: 64
        )

        XCTAssertEqual(message.transactionId, 0x1234)
        XCTAssertFalse(message.isResponse)
        XCTAssertEqual(message.opcode, .query)
        XCTAssertEqual(message.sourceIP, "192.168.1.1")
        XCTAssertEqual(message.destPort, 53)
    }

    func testPrimaryQuestion() {
        let question = DNSQuestion(name: "example.com", type: .a, class: .in)
        let message = DNSMessage(
            transactionId: 1,
            isResponse: false,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: false,
            responseCode: .noError,
            questions: [question],
            answers: [],
            authorities: [],
            additionals: [],
            sourceIP: "192.168.1.1",
            sourcePort: 12345,
            destIP: "8.8.8.8",
            destPort: 53,
            messageSize: 64
        )

        XCTAssertEqual(message.primaryQuestion?.name, "example.com")
        XCTAssertEqual(message.queryDomain, "example.com")
        XCTAssertEqual(message.queryType, .a)
    }

    func testIsSuccessful() {
        let message = DNSMessage.sampleResponse

        XCTAssertTrue(message.isSuccessful)
        XCTAssertFalse(message.with(responseCode: .nameError).isSuccessful)
        XCTAssertFalse(message.with(isResponse: false).isSuccessful)
    }

    func testResolvedIPs() {
        let aRecord = DNSResourceRecord(
            name: "example.com",
            type: .a,
            ttl: 300,
            dataLength: 4,
            data: Data([192, 168, 1, 1])
        )
        let aaaaRecord = DNSResourceRecord(
            name: "example.com",
            type: .aaaa,
            ttl: 300,
            dataLength: 16,
            data: Data([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        )
        let cnameRecord = DNSResourceRecord(
            name: "alias.example.com",
            type: .cname,
            ttl: 300,
            dataLength: 13,
            data: Data("example.com".utf8)
        )

        let message = DNSMessage(
            transactionId: 1,
            isResponse: true,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: true,
            responseCode: .noError,
            questions: [],
            answers: [aRecord, aaaaRecord, cnameRecord],
            authorities: [],
            additionals: [],
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.1",
            destPort: 12345,
            messageSize: 128
        )

        let ips = message.resolvedIPs
        XCTAssertEqual(ips.count, 2)
        XCTAssertTrue(ips.contains("192.168.1.1"))
    }

    func testCnames() {
        let cnameData = Data([7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0])
        let cnameRecord = DNSResourceRecord(
            name: "alias.example.com",
            type: .cname,
            ttl: 300,
            dataLength: UInt16(cnameData.count),
            data: cnameData
        )

        let message = DNSMessage(
            transactionId: 1,
            isResponse: true,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: true,
            responseCode: .noError,
            questions: [],
            answers: [cnameRecord],
            authorities: [],
            additionals: [],
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.1",
            destPort: 12345,
            messageSize: 64
        )

        XCTAssertEqual(message.cnames.count, 1)
    }

    func testShortDescription() {
        let message = DNSMessage.sampleQuery

        let description = message.shortDescription
        XCTAssertTrue(description.contains("api.github.com"))
        XCTAssertTrue(description.contains("A"))
    }

    func testStatusIcon() {
        XCTAssertEqual(DNSMessage.sampleQuery.statusIcon, "arrow.up.circle")
        XCTAssertEqual(DNSMessage.sampleResponse.statusIcon, "checkmark.circle.fill")
        XCTAssertEqual(DNSMessage.sampleResponse.with(responseCode: .nameError).statusIcon, "xmark.circle.fill")
    }

    func testStatusColor() {
        XCTAssertEqual(DNSMessage.sampleQuery.statusColor, "blue")
        XCTAssertEqual(DNSMessage.sampleResponse.statusColor, "green")
        XCTAssertEqual(DNSMessage.sampleResponse.with(responseCode: .serverFailure).statusColor, "red")
    }

    // MARK: - DNSQuestion Tests

    func testDNSQuestionInit() {
        let question = DNSQuestion(name: "example.com", type: .a, class: .in)

        XCTAssertEqual(question.name, "example.com")
        XCTAssertEqual(question.type, .a)
        XCTAssertEqual(question.class, .in)
    }

    func testDNSQuestionDisplayString() {
        let question = DNSQuestion(name: "example.com", type: .a, class: .in)

        let display = question.displayString
        XCTAssertTrue(display.contains("example.com"))
        XCTAssertTrue(display.contains("A"))
        XCTAssertTrue(display.contains("IN"))
    }

    // MARK: - DNSResourceRecord Tests

    func testDNSResourceRecordInit() {
        let record = DNSResourceRecord(
            name: "example.com",
            type: .a,
            ttl: 300,
            dataLength: 4,
            data: Data([192, 168, 1, 1])
        )

        XCTAssertEqual(record.name, "example.com")
        XCTAssertEqual(record.type, .a)
        XCTAssertEqual(record.ttl, 300)
    }

    func testParseIPv4() {
        let record = DNSResourceRecord(
            name: "example.com",
            type: .a,
            ttl: 300,
            dataLength: 4,
            data: Data([192, 168, 1, 1])
        )

        XCTAssertEqual(record.dataString, "192.168.1.1")
    }

    func testParseIPv4Invalid() {
        let record = DNSResourceRecord(
            name: "example.com",
            type: .a,
            ttl: 300,
            dataLength: 3,
            data: Data([192, 168, 1])
        )

        XCTAssertEqual(record.dataString, "Invalid IPv4")
    }

    func testParseIPv6() {
        let ipv6Data = Data([
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
        ])
        let record = DNSResourceRecord(
            name: "example.com",
            type: .aaaa,
            ttl: 300,
            dataLength: 16,
            data: ipv6Data
        )

        let parsed = record.dataString
        XCTAssertTrue(parsed.contains(":"))
    }

    func testParseIPv6Invalid() {
        let record = DNSResourceRecord(
            name: "example.com",
            type: .aaaa,
            ttl: 300,
            dataLength: 8,
            data: Data([0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00])
        )

        XCTAssertEqual(record.dataString, "Invalid IPv6")
    }

    func testParseDomainName() {
        // Simple domain: "example.com"
        let domainData = Data([7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0])
        let record = DNSResourceRecord(
            name: "alias.example.com",
            type: .cname,
            ttl: 300,
            dataLength: UInt16(domainData.count),
            data: domainData
        )

        let parsed = record.dataString
        XCTAssertTrue(parsed.contains("example"))
    }

    func testParseDomainNameWithCompression() {
        // Domain with compression pointer (0xC0 0x0C)
        let domainData = Data([0xC0, 0x0C])
        let record = DNSResourceRecord(
            name: "example.com",
            type: .cname,
            ttl: 300,
            dataLength: 2,
            data: domainData
        )

        let parsed = record.dataString
        XCTAssertTrue(parsed.contains("compressed"))
    }

    func testParseMX() {
        // MX record: preference=10, exchange="mail.example.com"
        var mxData = Data([0x00, 0x0A]) // preference = 10
        mxData.append(contentsOf: [4, 109, 97, 105, 108, 7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0])

        let record = DNSResourceRecord(
            name: "example.com",
            type: .mx,
            ttl: 300,
            dataLength: UInt16(mxData.count),
            data: mxData
        )

        let parsed = record.dataString
        XCTAssertTrue(parsed.contains("10"))
    }

    func testParseTXT() {
        // TXT record: "v=spf1 include:_spf.example.com ~all"
        let txtData = Data([34, 118, 61, 115, 112, 102, 49, 32, 105, 110, 99, 108, 117, 100, 101, 58, 95, 115, 112, 102, 46, 101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109, 32, 126, 97, 108, 108])

        let record = DNSResourceRecord(
            name: "example.com",
            type: .txt,
            ttl: 300,
            dataLength: UInt16(txtData.count),
            data: txtData
        )

        let parsed = record.dataString
        XCTAssertFalse(parsed.isEmpty)
    }

    func testParseSRV() {
        // SRV record: priority=10, weight=20, port=80, target="server.example.com"
        var srvData = Data([0x00, 0x0A, 0x00, 0x14, 0x00, 0x50]) // priority, weight, port
        srvData.append(contentsOf: [6, 115, 101, 114, 118, 101, 114, 7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0])

        let record = DNSResourceRecord(
            name: "_http._tcp.example.com",
            type: .srv,
            ttl: 300,
            dataLength: UInt16(srvData.count),
            data: srvData
        )

        let parsed = record.dataString
        XCTAssertTrue(parsed.contains("10"))
        XCTAssertTrue(parsed.contains("20"))
        XCTAssertTrue(parsed.contains("80"))
    }

    func testParseUnknownType() {
        let record = DNSResourceRecord(
            name: "example.com",
            type: .soa,
            ttl: 300,
            dataLength: 4,
            data: Data([0x01, 0x02, 0x03, 0x04])
        )

        let parsed = record.dataString
        XCTAssertEqual(parsed, "01020304")
    }

    func testDisplayString() {
        let record = DNSResourceRecord(
            name: "example.com",
            type: .a,
            ttl: 300,
            dataLength: 4,
            data: Data([192, 168, 1, 1])
        )

        let display = record.displayString
        XCTAssertTrue(display.contains("example.com"))
        XCTAssertTrue(display.contains("300s"))
        XCTAssertTrue(display.contains("A"))
        XCTAssertTrue(display.contains("192.168.1.1"))
    }

    // MARK: - DNSRecordType Tests

    func testDNSRecordTypeDisplayName() {
        XCTAssertEqual(DNSRecordType.a.displayName, "A")
        XCTAssertEqual(DNSRecordType.aaaa.displayName, "AAAA")
        XCTAssertEqual(DNSRecordType.cname.displayName, "CNAME")
        XCTAssertEqual(DNSRecordType.mx.displayName, "MX")
    }

    func testDNSRecordTypeDescription() {
        XCTAssertEqual(DNSRecordType.a.description, "IPv4 host address")
        XCTAssertEqual(DNSRecordType.aaaa.description, "IPv6 host address")
    }

    func testDNSRecordTypeCommon() {
        let common = DNSRecordType.common
        XCTAssertTrue(common.contains(.a))
        XCTAssertTrue(common.contains(.aaaa))
        XCTAssertTrue(common.contains(.cname))
    }

    // MARK: - DNSClass Tests

    func testDNSClassDisplayName() {
        XCTAssertEqual(DNSClass.in.displayName, "IN")
        XCTAssertEqual(DNSClass.ch.displayName, "CH")
    }

    func testDNSClassDescription() {
        XCTAssertEqual(DNSClass.in.description, "Internet")
    }

    // MARK: - DNSResponseCode Tests

    func testDNSResponseCodeDisplayName() {
        XCTAssertEqual(DNSResponseCode.noError.displayName, "NOERROR")
        XCTAssertEqual(DNSResponseCode.nameError.displayName, "NXDOMAIN")
        XCTAssertEqual(DNSResponseCode.serverFailure.displayName, "SERVFAIL")
    }

    func testDNSResponseCodeDescription() {
        XCTAssertEqual(DNSResponseCode.noError.description, "No error")
        XCTAssertEqual(DNSResponseCode.nameError.description, "Name does not exist")
    }

    func testDNSResponseCodeIsSuccess() {
        XCTAssertTrue(DNSResponseCode.noError.isSuccess)
        XCTAssertFalse(DNSResponseCode.nameError.isSuccess)
        XCTAssertFalse(DNSResponseCode.serverFailure.isSuccess)
    }

    // MARK: - DNSOpcode Tests

    func testDNSOpcodeDisplayName() {
        XCTAssertEqual(DNSOpcode.query.displayName, "QUERY")
        XCTAssertEqual(DNSOpcode.notify.displayName, "NOTIFY")
        XCTAssertEqual(DNSOpcode.update.displayName, "UPDATE")
    }

    // MARK: - Codable Tests

    func testDNSMessageCodable() throws {
        let original = DNSMessage.sampleQuery

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DNSMessage.self, from: encoded)

        XCTAssertEqual(decoded.transactionId, original.transactionId)
        XCTAssertEqual(decoded.sourceIP, original.sourceIP)
        XCTAssertEqual(decoded.questions.count, original.questions.count)
    }

    func testDNSQuestionCodable() throws {
        let original = DNSQuestion(name: "example.com", type: .a, class: .in)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DNSQuestion.self, from: encoded)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.class, original.class)
    }

    func testDNSResourceRecordCodable() throws {
        let original = DNSResourceRecord(
            name: "example.com",
            type: .a,
            ttl: 300,
            dataLength: 4,
            data: Data([192, 168, 1, 1])
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DNSResourceRecord.self, from: encoded)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.ttl, original.ttl)
        XCTAssertEqual(decoded.data, original.data)
    }

    // MARK: - Sample Data Tests

    func testSampleQuery() {
        let query = DNSMessage.sampleQuery

        XCTAssertFalse(query.isResponse)
        XCTAssertEqual(query.opcode, .query)
        XCTAssertEqual(query.questions.count, 1)
        XCTAssertEqual(query.questions.first?.name, "api.github.com")
    }

    func testSampleResponse() {
        let response = DNSMessage.sampleResponse

        XCTAssertTrue(response.isResponse)
        XCTAssertEqual(response.answers.count, 1)
        XCTAssertNotNil(response.responseTime)
    }

    func testSamples() {
        let samples = DNSMessage.samples

        XCTAssertEqual(samples.count, 2)
        XCTAssertFalse(samples[0].isResponse)
        XCTAssertTrue(samples[1].isResponse)
    }

    // MARK: - Edge Cases

    func testEmptyQuestions() {
        let message = DNSMessage(
            transactionId: 1,
            isResponse: false,
            opcode: .query,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: false,
            responseCode: .noError,
            questions: [],
            answers: [],
            authorities: [],
            additionals: [],
            sourceIP: "192.168.1.1",
            sourcePort: 12345,
            destIP: "8.8.8.8",
            destPort: 53,
            messageSize: 12
        )

        XCTAssertNil(message.primaryQuestion)
        XCTAssertNil(message.queryDomain)
        XCTAssertNil(message.queryType)
    }

    func testRelatedMessages() {
        var query = DNSMessage.sampleQuery
        var response = DNSMessage.sampleResponse

        query.relatedResponseId = response.id
        response.relatedQueryId = query.id
        response.responseTime = 0.025

        XCTAssertEqual(query.relatedResponseId, response.id)
        XCTAssertEqual(response.relatedQueryId, query.id)
        XCTAssertEqual(response.responseTime, 0.025)
    }

    func testHexEncodedString() {
        let data = Data([0x01, 0x02, 0x0A, 0xFF])
        XCTAssertEqual(data.hexEncodedString(), "01020aff")
    }
}

private extension DNSMessage {
    func with(
        responseCode: DNSResponseCode? = nil,
        isResponse: Bool? = nil
    ) -> DNSMessage {
        DNSMessage(
            id: id,
            transactionId: transactionId,
            timestamp: timestamp,
            isResponse: isResponse ?? self.isResponse,
            opcode: opcode,
            isAuthoritative: isAuthoritative,
            isTruncated: isTruncated,
            recursionDesired: recursionDesired,
            recursionAvailable: recursionAvailable,
            responseCode: responseCode ?? self.responseCode,
            questions: questions,
            answers: answers,
            authorities: authorities,
            additionals: additionals,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            destIP: destIP,
            destPort: destPort,
            messageSize: messageSize,
            relatedQueryId: relatedQueryId,
            relatedResponseId: relatedResponseId,
            responseTime: responseTime
        )
    }
}
