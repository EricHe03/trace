//
//  DNSParserTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceNetworking

final class DNSParserTests: XCTestCase {
    
    // MARK: - Header Parsing Tests
    
    func testParseBasicDNSQuery() throws {
        // DNS query for "example.com" A record
        // Transaction ID: 0x1234
        // Flags: Standard query, recursion desired
        // 1 question, 0 answers, 0 authorities, 0 additionals
        var data = Data()
        
        // Header (12 bytes)
        data.append(contentsOf: [0x12, 0x34]) // Transaction ID
        data.append(contentsOf: [0x01, 0x00]) // Flags: Standard query, RD=1
        data.append(contentsOf: [0x00, 0x01]) // Questions: 1
        data.append(contentsOf: [0x00, 0x00]) // Answers: 0
        data.append(contentsOf: [0x00, 0x00]) // Authority: 0
        data.append(contentsOf: [0x00, 0x00]) // Additional: 0
        
        // Question: example.com A IN
        data.append(contentsOf: [0x07]) // Length of "example"
        data.append("example".data(using: .utf8)!)
        data.append(contentsOf: [0x03]) // Length of "com"
        data.append("com".data(using: .utf8)!)
        data.append(contentsOf: [0x00]) // End of name
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        
        let message = try DNSParser.parse(
            data: data,
            sourceIP: "192.168.1.100",
            sourcePort: 54321,
            destIP: "8.8.8.8",
            destPort: 53
        )
        
        XCTAssertEqual(message.transactionId, 0x1234)
        XCTAssertFalse(message.isResponse)
        XCTAssertEqual(message.opcode, .query)
        XCTAssertTrue(message.recursionDesired)
        XCTAssertFalse(message.recursionAvailable)
        XCTAssertEqual(message.questions.count, 1)
        XCTAssertEqual(message.questions[0].name, "example.com")
        XCTAssertEqual(message.questions[0].type, .a)
        XCTAssertEqual(message.questions[0].class, .in)
        XCTAssertEqual(message.answers.count, 0)
    }
    
    func testParseBasicDNSResponse() throws {
        // DNS response for "example.com" A record
        // Transaction ID: 0x1234
        // Flags: Response, recursion desired, recursion available
        // 1 question, 1 answer, 0 authorities, 0 additionals
        var data = Data()
        
        // Header (12 bytes)
        data.append(contentsOf: [0x12, 0x34]) // Transaction ID
        data.append(contentsOf: [0x81, 0x80]) // Flags: Response, RD=1, RA=1
        data.append(contentsOf: [0x00, 0x01]) // Questions: 1
        data.append(contentsOf: [0x00, 0x01]) // Answers: 1
        data.append(contentsOf: [0x00, 0x00]) // Authority: 0
        data.append(contentsOf: [0x00, 0x00]) // Additional: 0
        
        // Question: example.com A IN
        data.append(contentsOf: [0x07]) // Length of "example"
        data.append("example".data(using: .utf8)!)
        data.append(contentsOf: [0x03]) // Length of "com"
        data.append("com".data(using: .utf8)!)
        data.append(contentsOf: [0x00]) // End of name
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        
        // Answer: example.com A IN 300 93.184.216.34
        data.append(contentsOf: [0xC0, 0x0C]) // Pointer to name at offset 12
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        data.append(contentsOf: [0x00, 0x00, 0x01, 0x2C]) // TTL: 300 seconds
        data.append(contentsOf: [0x00, 0x04]) // Data length: 4
        data.append(contentsOf: [93, 184, 216, 34]) // IP: 93.184.216.34
        
        let message = try DNSParser.parse(
            data: data,
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.100",
            destPort: 54321
        )
        
        XCTAssertEqual(message.transactionId, 0x1234)
        XCTAssertTrue(message.isResponse)
        XCTAssertEqual(message.opcode, .query)
        XCTAssertTrue(message.recursionDesired)
        XCTAssertTrue(message.recursionAvailable)
        XCTAssertEqual(message.responseCode, .noError)
        XCTAssertEqual(message.questions.count, 1)
        XCTAssertEqual(message.answers.count, 1)
        
        let answer = message.answers[0]
        XCTAssertEqual(answer.name, "example.com")
        XCTAssertEqual(answer.type, .a)
        XCTAssertEqual(answer.ttl, 300)
        XCTAssertEqual(answer.dataString, "93.184.216.34")
    }
    
    // MARK: - Name Compression Tests
    
    func testParseDNSNameCompression() throws {
        // DNS response with name compression
        var data = Data()
        
        // Header
        data.append(contentsOf: [0x12, 0x34]) // Transaction ID
        data.append(contentsOf: [0x81, 0x80]) // Flags: Response
        data.append(contentsOf: [0x00, 0x01]) // Questions: 1
        data.append(contentsOf: [0x00, 0x02]) // Answers: 2
        data.append(contentsOf: [0x00, 0x00]) // Authority: 0
        data.append(contentsOf: [0x00, 0x00]) // Additional: 0
        
        // Question: www.example.com A IN (offset 12)
        data.append(contentsOf: [0x03]) // Length of "www"
        data.append("www".data(using: .utf8)!)
        data.append(contentsOf: [0x07]) // Length of "example"
        data.append("example".data(using: .utf8)!)
        data.append(contentsOf: [0x03]) // Length of "com"
        data.append("com".data(using: .utf8)!)
        data.append(contentsOf: [0x00]) // End of name
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        
        // Answer 1: www.example.com A (using pointer)
        data.append(contentsOf: [0xC0, 0x0C]) // Pointer to offset 12
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x3C]) // TTL: 60
        data.append(contentsOf: [0x00, 0x04]) // Data length: 4
        data.append(contentsOf: [192, 0, 2, 1]) // IP
        
        // Answer 2: www.example.com A (using pointer again)
        data.append(contentsOf: [0xC0, 0x0C]) // Pointer to offset 12
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x3C]) // TTL: 60
        data.append(contentsOf: [0x00, 0x04]) // Data length: 4
        data.append(contentsOf: [192, 0, 2, 2]) // IP
        
        let message = try DNSParser.parse(
            data: data,
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.100",
            destPort: 54321
        )
        
        XCTAssertEqual(message.questions[0].name, "www.example.com")
        XCTAssertEqual(message.answers.count, 2)
        XCTAssertEqual(message.answers[0].name, "www.example.com")
        XCTAssertEqual(message.answers[1].name, "www.example.com")
        XCTAssertEqual(message.answers[0].dataString, "192.0.2.1")
        XCTAssertEqual(message.answers[1].dataString, "192.0.2.2")
    }
    
    // MARK: - AAAA Record Tests
    
    func testParseAAAARecord() throws {
        var data = Data()
        
        // Header
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0x81, 0x80])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00])
        
        // Question: example.com AAAA IN
        data.append(contentsOf: [0x07])
        data.append("example".data(using: .utf8)!)
        data.append(contentsOf: [0x03])
        data.append("com".data(using: .utf8)!)
        data.append(contentsOf: [0x00])
        data.append(contentsOf: [0x00, 0x1C]) // Type: AAAA
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        
        // Answer: example.com AAAA 2606:2800:220:1:248:1893:25c8:1946
        data.append(contentsOf: [0xC0, 0x0C])
        data.append(contentsOf: [0x00, 0x1C]) // Type: AAAA
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        data.append(contentsOf: [0x00, 0x00, 0x01, 0x2C]) // TTL: 300
        data.append(contentsOf: [0x00, 0x10]) // Data length: 16
        data.append(contentsOf: [0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01,
                                 0x02, 0x48, 0x18, 0x93, 0x25, 0xc8, 0x19, 0x46])
        
        let message = try DNSParser.parse(
            data: data,
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.100",
            destPort: 54321
        )
        
        XCTAssertEqual(message.questions[0].type, .aaaa)
        XCTAssertEqual(message.answers.count, 1)
        XCTAssertEqual(message.answers[0].type, .aaaa)
        XCTAssertEqual(message.answers[0].dataString, "2606:2800:220:1:248:1893:25c8:1946")
    }
    
    // MARK: - Error Response Tests
    
    func testParseNXDOMAINResponse() throws {
        var data = Data()
        
        // Header with NXDOMAIN response code
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0x81, 0x83]) // Flags: Response, RCODE=3 (NXDOMAIN)
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00]) // No answers
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00])
        
        // Question: nonexistent.example.com A IN
        data.append(contentsOf: [0x0B])
        data.append("nonexistent".data(using: .utf8)!)
        data.append(contentsOf: [0x07])
        data.append("example".data(using: .utf8)!)
        data.append(contentsOf: [0x03])
        data.append("com".data(using: .utf8)!)
        data.append(contentsOf: [0x00])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x01])
        
        let message = try DNSParser.parse(
            data: data,
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.100",
            destPort: 54321
        )
        
        XCTAssertTrue(message.isResponse)
        XCTAssertEqual(message.responseCode, .nameError)
        XCTAssertFalse(message.isSuccessful)
        XCTAssertEqual(message.answers.count, 0)
    }
    
    // MARK: - Validation Tests
    
    func testLooksLikeDNS_ValidPacket() {
        var data = Data()
        data.append(contentsOf: [0x12, 0x34]) // Transaction ID
        data.append(contentsOf: [0x01, 0x00]) // Flags
        data.append(contentsOf: [0x00, 0x01]) // 1 question
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        
        XCTAssertTrue(DNSParser.looksLikeDNS(data: data))
    }
    
    func testLooksLikeDNS_TooShort() {
        let data = Data([0x12, 0x34, 0x01])
        XCTAssertFalse(DNSParser.looksLikeDNS(data: data))
    }
    
    func testLooksLikeDNS_InvalidOpcode() {
        var data = Data()
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0xFF, 0x00]) // Invalid opcode
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        
        XCTAssertFalse(DNSParser.looksLikeDNS(data: data))
    }
    
    func testLooksLikeDNS_NoCounts() {
        var data = Data()
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0x01, 0x00])
        data.append(contentsOf: [0x00, 0x00]) // No questions
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        
        XCTAssertFalse(DNSParser.looksLikeDNS(data: data))
    }
    
    // MARK: - Error Handling Tests
    
    func testParseInvalidPacket_TooShort() {
        let data = Data([0x12, 0x34])
        
        do {
            _ = try DNSParser.parse(
                data: data,
                sourceIP: "192.168.1.100",
                sourcePort: 54321,
                destIP: "8.8.8.8",
                destPort: 53
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is DNSParser.DNSParsingError)
        }
    }

    func testParseInvalidPacket_LabelTooLong() async {
        var data = Data()

        // Header
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0x01, 0x00])
        data.append(contentsOf: [0x00, 0x01]) // Questions: 1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Question with label length 64 (invalid, >63)
        data.append(0x40)
        data.append(Data(repeating: 0x61, count: 64)) // 'a' * 64
        data.append(0x00) // End of name
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN

        await XCTAssertThrowsError(try DNSParser.parse(
            data: data,
            sourceIP: "192.168.1.100",
            sourcePort: 54321,
            destIP: "8.8.8.8",
            destPort: 53
        ))
    }

    func testParseInvalidPacket_NonUTF8Label() async {
        var data = Data()

        // Header
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0x01, 0x00])
        data.append(contentsOf: [0x00, 0x01]) // Questions: 1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Question with non-UTF8 label
        data.append(0x01)
        data.append(0xFF)
        data.append(0x00) // End of name
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN

        await XCTAssertThrowsError(try DNSParser.parse(
            data: data,
            sourceIP: "192.168.1.100",
            sourcePort: 54321,
            destIP: "8.8.8.8",
            destPort: 53
        ))
    }

    func testParseInvalidPacket_CompressionPointerLoop() async {
        var data = Data()

        // Header
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0x01, 0x00])
        data.append(contentsOf: [0x00, 0x01]) // Questions: 1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Question name points to itself (offset 12)
        data.append(contentsOf: [0xC0, 0x0C])
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN

        await XCTAssertThrowsError(try DNSParser.parse(
            data: data,
            sourceIP: "192.168.1.100",
            sourcePort: 54321,
            destIP: "8.8.8.8",
            destPort: 53
        ))
    }

    func testParseInvalidPacket_RecordDataTooShort() async {
        var data = Data()

        // Header
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0x81, 0x80])
        data.append(contentsOf: [0x00, 0x00]) // Questions: 0
        data.append(contentsOf: [0x00, 0x01]) // Answers: 1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Answer name: root (empty)
        data.append(0x00)
        data.append(contentsOf: [0x00, 0x01]) // Type: A
        data.append(contentsOf: [0x00, 0x01]) // Class: IN
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x3C]) // TTL: 60
        data.append(contentsOf: [0x00, 0x04]) // Data length: 4
        data.append(contentsOf: [0x7F, 0x00]) // Only 2 bytes provided

        await XCTAssertThrowsError(try DNSParser.parse(
            data: data,
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.100",
            destPort: 54321
        ))
    }
    
    func testParseSafely_ReturnsNilOnError() {
        let data = Data([0x12, 0x34])
        
        let message = DNSParser.parseSafely(
            data: data,
            sourceIP: "192.168.1.100",
            sourcePort: 54321,
            destIP: "8.8.8.8",
            destPort: 53
        )
        
        XCTAssertNil(message)
    }
    
    // MARK: - Multiple Questions/Answers Tests
    
    func testParseMultipleAnswers() throws {
        var data = Data()
        
        // Header
        data.append(contentsOf: [0x12, 0x34])
        data.append(contentsOf: [0x81, 0x80])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x03]) // 3 answers
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00])
        
        // Question
        data.append(contentsOf: [0x07])
        data.append("example".data(using: .utf8)!)
        data.append(contentsOf: [0x03])
        data.append("com".data(using: .utf8)!)
        data.append(contentsOf: [0x00])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x01])
        
        // Answer 1
        data.append(contentsOf: [0xC0, 0x0C])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x3C])
        data.append(contentsOf: [0x00, 0x04])
        data.append(contentsOf: [192, 0, 2, 1])
        
        // Answer 2
        data.append(contentsOf: [0xC0, 0x0C])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x3C])
        data.append(contentsOf: [0x00, 0x04])
        data.append(contentsOf: [192, 0, 2, 2])
        
        // Answer 3
        data.append(contentsOf: [0xC0, 0x0C])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x3C])
        data.append(contentsOf: [0x00, 0x04])
        data.append(contentsOf: [192, 0, 2, 3])
        
        let message = try DNSParser.parse(
            data: data,
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destIP: "192.168.1.100",
            destPort: 54321
        )
        
        XCTAssertEqual(message.answers.count, 3)
        XCTAssertEqual(message.resolvedIPs.count, 3)
        XCTAssertTrue(message.resolvedIPs.contains("192.0.2.1"))
        XCTAssertTrue(message.resolvedIPs.contains("192.0.2.2"))
        XCTAssertTrue(message.resolvedIPs.contains("192.0.2.3"))
    }
    
    // MARK: - DNS Message Model Tests
    
    func testDNSMessageProperties() {
        let message = DNSMessage.sampleResponse
        
        XCTAssertTrue(message.isResponse)
        XCTAssertTrue(message.isSuccessful)
        XCTAssertEqual(message.queryDomain, "api.github.com")
        XCTAssertEqual(message.queryType, .a)
        XCTAssertNotNil(message.responseTime)
        XCTAssertFalse(message.resolvedIPs.isEmpty)
    }
    
    func testDNSRecordTypeEnum() {
        XCTAssertEqual(DNSRecordType.a.displayName, "A")
        XCTAssertEqual(DNSRecordType.aaaa.displayName, "AAAA")
        XCTAssertEqual(DNSRecordType.cname.displayName, "CNAME")
        XCTAssertEqual(DNSRecordType.mx.displayName, "MX")
        
        XCTAssertTrue(DNSRecordType.common.contains(.a))
        XCTAssertTrue(DNSRecordType.common.contains(.aaaa))
    }
    
    func testDNSResponseCode() {
        XCTAssertTrue(DNSResponseCode.noError.isSuccess)
        XCTAssertFalse(DNSResponseCode.nameError.isSuccess)
        XCTAssertFalse(DNSResponseCode.serverFailure.isSuccess)
        
        XCTAssertEqual(DNSResponseCode.nameError.displayName, "NXDOMAIN")
        XCTAssertEqual(DNSResponseCode.noError.displayName, "NOERROR")
    }
}
