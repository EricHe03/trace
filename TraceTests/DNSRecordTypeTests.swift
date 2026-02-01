//
//  DNSRecordTypeTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class DNSRecordTypeTests: XCTestCase {

    // MARK: - DNSRecordType Tests

    func testDNSRecordTypeRawValues() {
        XCTAssertEqual(DNSRecordType.a.rawValue, 1)
        XCTAssertEqual(DNSRecordType.ns.rawValue, 2)
        XCTAssertEqual(DNSRecordType.cname.rawValue, 5)
        XCTAssertEqual(DNSRecordType.aaaa.rawValue, 28)
        XCTAssertEqual(DNSRecordType.srv.rawValue, 33)
        XCTAssertEqual(DNSRecordType.any.rawValue, 255)
        XCTAssertEqual(DNSRecordType.caa.rawValue, 257)
        XCTAssertEqual(DNSRecordType.ta.rawValue, 32768)
        XCTAssertEqual(DNSRecordType.dlv.rawValue, 32769)
    }

    func testDNSRecordTypeFromRawValue() {
        XCTAssertEqual(DNSRecordType(rawValue: 1), .a)
        XCTAssertEqual(DNSRecordType(rawValue: 28), .aaaa)
        XCTAssertEqual(DNSRecordType(rawValue: 255), .any)
        XCTAssertNil(DNSRecordType(rawValue: 999))
    }

    func testDNSRecordTypeDisplayNames() {
        XCTAssertEqual(DNSRecordType.a.displayName, "A")
        XCTAssertEqual(DNSRecordType.aaaa.displayName, "AAAA")
        XCTAssertEqual(DNSRecordType.cname.displayName, "CNAME")
        XCTAssertEqual(DNSRecordType.mx.displayName, "MX")
        XCTAssertEqual(DNSRecordType.txt.displayName, "TXT")
        XCTAssertEqual(DNSRecordType.srv.displayName, "SRV")
        XCTAssertEqual(DNSRecordType.ptr.displayName, "PTR")
        XCTAssertEqual(DNSRecordType.soa.displayName, "SOA")
    }

    func testDNSRecordTypeDescriptions() {
        XCTAssertEqual(DNSRecordType.a.description, "IPv4 host address")
        XCTAssertEqual(DNSRecordType.aaaa.description, "IPv6 host address")
        XCTAssertEqual(DNSRecordType.cname.description, "Canonical name for an alias")
        XCTAssertEqual(DNSRecordType.mx.description, "Mail exchange")
        XCTAssertEqual(DNSRecordType.ns.description, "Authoritative name server")
        XCTAssertEqual(DNSRecordType.ptr.description, "Domain name pointer")
        XCTAssertEqual(DNSRecordType.soa.description, "Start of authority")
        XCTAssertEqual(DNSRecordType.txt.description, "Text strings")
        XCTAssertEqual(DNSRecordType.srv.description, "Service locator")
        XCTAssertEqual(DNSRecordType.caa.description, "Certification Authority Authorization")
        XCTAssertEqual(DNSRecordType.any.description, "Request for all records")
    }

    func testDNSRecordTypeDescriptionFallback() {
        // For types without specific descriptions, should return displayName
        XCTAssertEqual(DNSRecordType.md.description, DNSRecordType.md.displayName)
        XCTAssertEqual(DNSRecordType.mf.description, DNSRecordType.mf.displayName)
    }

    func testDNSRecordTypeCommonTypes() {
        let common = DNSRecordType.common
        XCTAssertEqual(common.count, 9)
        XCTAssertTrue(common.contains(.a))
        XCTAssertTrue(common.contains(.aaaa))
        XCTAssertTrue(common.contains(.cname))
        XCTAssertTrue(common.contains(.mx))
        XCTAssertTrue(common.contains(.ns))
        XCTAssertTrue(common.contains(.ptr))
        XCTAssertTrue(common.contains(.soa))
        XCTAssertTrue(common.contains(.txt))
        XCTAssertTrue(common.contains(.srv))
    }

    func testDNSRecordTypeCaseIterable() {
        let allCases = DNSRecordType.allCases
        XCTAssertGreaterThan(allCases.count, 90)
        XCTAssertTrue(allCases.contains(.a))
        XCTAssertTrue(allCases.contains(.aaaa))
        XCTAssertTrue(allCases.contains(.dlv))
    }

    func testDNSRecordTypeCodable() throws {
        let recordType = DNSRecordType.aaaa

        let encoder = JSONEncoder()
        let data = try encoder.encode(recordType)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DNSRecordType.self, from: data)

        XCTAssertEqual(decoded, recordType)
        XCTAssertEqual(decoded.rawValue, 28)
    }

    func testDNSRecordTypeCodableRoundTrip() throws {
        let types: [DNSRecordType] = [.a, .aaaa, .cname, .mx, .txt, .srv, .ptr, .any, .caa, .dlv]

        for type in types {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(DNSRecordType.self, from: data)
            XCTAssertEqual(decoded, type)
        }
    }

    // MARK: - DNSClass Tests

    func testDNSClassRawValues() {
        XCTAssertEqual(DNSClass.in.rawValue, 1)
        XCTAssertEqual(DNSClass.cs.rawValue, 2)
        XCTAssertEqual(DNSClass.ch.rawValue, 3)
        XCTAssertEqual(DNSClass.hs.rawValue, 4)
        XCTAssertEqual(DNSClass.none.rawValue, 254)
        XCTAssertEqual(DNSClass.any.rawValue, 255)
    }

    func testDNSClassFromRawValue() {
        XCTAssertEqual(DNSClass(rawValue: 1), .in)
        XCTAssertEqual(DNSClass(rawValue: 255), .any)
        XCTAssertNil(DNSClass(rawValue: 100))
    }

    func testDNSClassDisplayNames() {
        XCTAssertEqual(DNSClass.in.displayName, "IN")
        XCTAssertEqual(DNSClass.cs.displayName, "CS")
        XCTAssertEqual(DNSClass.ch.displayName, "CH")
        XCTAssertEqual(DNSClass.hs.displayName, "HS")
        XCTAssertEqual(DNSClass.none.displayName, "NONE")
        XCTAssertEqual(DNSClass.any.displayName, "ANY")
    }

    func testDNSClassDescriptions() {
        XCTAssertEqual(DNSClass.in.description, "Internet")
        XCTAssertEqual(DNSClass.cs.description, "CSNET")
        XCTAssertEqual(DNSClass.ch.description, "CHAOS")
        XCTAssertEqual(DNSClass.hs.description, "Hesiod")
        XCTAssertEqual(DNSClass.none.description, "None")
        XCTAssertEqual(DNSClass.any.description, "Any class")
    }

    func testDNSClassCodable() throws {
        let dnsClass = DNSClass.in

        let encoder = JSONEncoder()
        let data = try encoder.encode(dnsClass)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DNSClass.self, from: data)

        XCTAssertEqual(decoded, dnsClass)
        XCTAssertEqual(decoded.rawValue, 1)
    }

    func testDNSClassCodableRoundTrip() throws {
        let classes: [DNSClass] = [.in, .cs, .ch, .hs, .none, .any]

        for dnsClass in classes {
            let data = try JSONEncoder().encode(dnsClass)
            let decoded = try JSONDecoder().decode(DNSClass.self, from: data)
            XCTAssertEqual(decoded, dnsClass)
        }
    }

    // MARK: - DNSResponseCode Tests

    func testDNSResponseCodeRawValues() {
        XCTAssertEqual(DNSResponseCode.noError.rawValue, 0)
        XCTAssertEqual(DNSResponseCode.formatError.rawValue, 1)
        XCTAssertEqual(DNSResponseCode.serverFailure.rawValue, 2)
        XCTAssertEqual(DNSResponseCode.nameError.rawValue, 3)
        XCTAssertEqual(DNSResponseCode.notImplemented.rawValue, 4)
        XCTAssertEqual(DNSResponseCode.refused.rawValue, 5)
        XCTAssertEqual(DNSResponseCode.yxDomain.rawValue, 6)
        XCTAssertEqual(DNSResponseCode.yxRRSet.rawValue, 7)
        XCTAssertEqual(DNSResponseCode.nxRRSet.rawValue, 8)
        XCTAssertEqual(DNSResponseCode.notAuth.rawValue, 9)
        XCTAssertEqual(DNSResponseCode.notZone.rawValue, 10)
    }

    func testDNSResponseCodeFromRawValue() {
        XCTAssertEqual(DNSResponseCode(rawValue: 0), .noError)
        XCTAssertEqual(DNSResponseCode(rawValue: 3), .nameError)
        XCTAssertNil(DNSResponseCode(rawValue: 99))
    }

    func testDNSResponseCodeDisplayNames() {
        XCTAssertEqual(DNSResponseCode.noError.displayName, "NOERROR")
        XCTAssertEqual(DNSResponseCode.formatError.displayName, "FORMERR")
        XCTAssertEqual(DNSResponseCode.serverFailure.displayName, "SERVFAIL")
        XCTAssertEqual(DNSResponseCode.nameError.displayName, "NXDOMAIN")
        XCTAssertEqual(DNSResponseCode.notImplemented.displayName, "NOTIMP")
        XCTAssertEqual(DNSResponseCode.refused.displayName, "REFUSED")
        XCTAssertEqual(DNSResponseCode.yxDomain.displayName, "YXDOMAIN")
        XCTAssertEqual(DNSResponseCode.yxRRSet.displayName, "YXRRSET")
        XCTAssertEqual(DNSResponseCode.nxRRSet.displayName, "NXRRSET")
        XCTAssertEqual(DNSResponseCode.notAuth.displayName, "NOTAUTH")
        XCTAssertEqual(DNSResponseCode.notZone.displayName, "NOTZONE")
    }

    func testDNSResponseCodeDescriptions() {
        XCTAssertEqual(DNSResponseCode.noError.description, "No error")
        XCTAssertEqual(DNSResponseCode.formatError.description, "Format error")
        XCTAssertEqual(DNSResponseCode.serverFailure.description, "Server failure")
        XCTAssertEqual(DNSResponseCode.nameError.description, "Name does not exist")
        XCTAssertEqual(DNSResponseCode.notImplemented.description, "Not implemented")
        XCTAssertEqual(DNSResponseCode.refused.description, "Query refused")
        XCTAssertEqual(DNSResponseCode.yxDomain.description, "Name exists when it should not")
        XCTAssertEqual(DNSResponseCode.yxRRSet.description, "RR set exists when it should not")
        XCTAssertEqual(DNSResponseCode.nxRRSet.description, "RR set that should exist does not")
        XCTAssertEqual(DNSResponseCode.notAuth.description, "Server not authoritative for zone")
        XCTAssertEqual(DNSResponseCode.notZone.description, "Name not contained in zone")
    }

    func testDNSResponseCodeIsSuccess() {
        XCTAssertTrue(DNSResponseCode.noError.isSuccess)
        XCTAssertFalse(DNSResponseCode.formatError.isSuccess)
        XCTAssertFalse(DNSResponseCode.serverFailure.isSuccess)
        XCTAssertFalse(DNSResponseCode.nameError.isSuccess)
        XCTAssertFalse(DNSResponseCode.notImplemented.isSuccess)
        XCTAssertFalse(DNSResponseCode.refused.isSuccess)
    }

    func testDNSResponseCodeCodable() throws {
        let responseCode = DNSResponseCode.nameError

        let encoder = JSONEncoder()
        let data = try encoder.encode(responseCode)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DNSResponseCode.self, from: data)

        XCTAssertEqual(decoded, responseCode)
        XCTAssertEqual(decoded.rawValue, 3)
    }

    func testDNSResponseCodeCodableRoundTrip() throws {
        let codes: [DNSResponseCode] = [
            .noError, .formatError, .serverFailure, .nameError, .notImplemented,
            .refused, .yxDomain, .yxRRSet, .nxRRSet, .notAuth, .notZone
        ]

        for code in codes {
            let data = try JSONEncoder().encode(code)
            let decoded = try JSONDecoder().decode(DNSResponseCode.self, from: data)
            XCTAssertEqual(decoded, code)
        }
    }

    // MARK: - DNSOpcode Tests

    func testDNSOpcodeRawValues() {
        XCTAssertEqual(DNSOpcode.query.rawValue, 0)
        XCTAssertEqual(DNSOpcode.iquery.rawValue, 1)
        XCTAssertEqual(DNSOpcode.status.rawValue, 2)
        XCTAssertEqual(DNSOpcode.notify.rawValue, 4)
        XCTAssertEqual(DNSOpcode.update.rawValue, 5)
        XCTAssertEqual(DNSOpcode.dso.rawValue, 6)
    }

    func testDNSOpcodeFromRawValue() {
        XCTAssertEqual(DNSOpcode(rawValue: 0), .query)
        XCTAssertEqual(DNSOpcode(rawValue: 5), .update)
        XCTAssertNil(DNSOpcode(rawValue: 3))
    }

    func testDNSOpcodeDisplayNames() {
        XCTAssertEqual(DNSOpcode.query.displayName, "QUERY")
        XCTAssertEqual(DNSOpcode.iquery.displayName, "IQUERY")
        XCTAssertEqual(DNSOpcode.status.displayName, "STATUS")
        XCTAssertEqual(DNSOpcode.notify.displayName, "NOTIFY")
        XCTAssertEqual(DNSOpcode.update.displayName, "UPDATE")
        XCTAssertEqual(DNSOpcode.dso.displayName, "DSO")
    }

    func testDNSOpcodeCodable() throws {
        let opcode = DNSOpcode.query

        let encoder = JSONEncoder()
        let data = try encoder.encode(opcode)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DNSOpcode.self, from: data)

        XCTAssertEqual(decoded, opcode)
        XCTAssertEqual(decoded.rawValue, 0)
    }

    func testDNSOpcodeCodableRoundTrip() throws {
        let opcodes: [DNSOpcode] = [.query, .iquery, .status, .notify, .update, .dso]

        for opcode in opcodes {
            let data = try JSONEncoder().encode(opcode)
            let decoded = try JSONDecoder().decode(DNSOpcode.self, from: data)
            XCTAssertEqual(decoded, opcode)
        }
    }

    // MARK: - Edge Cases

    func testAllDNSRecordTypesHaveDisplayNames() {
        for recordType in DNSRecordType.allCases {
            let displayName = recordType.displayName
            XCTAssertFalse(displayName.isEmpty)
        }
    }

    func testAllDNSRecordTypesHaveDescriptions() {
        for recordType in DNSRecordType.allCases {
            let description = recordType.description
            XCTAssertFalse(description.isEmpty)
        }
    }

    func testDNSRecordTypeObsoleteTypes() {
        // Test obsolete types still work
        XCTAssertEqual(DNSRecordType.md.rawValue, 3)
        XCTAssertEqual(DNSRecordType.mf.rawValue, 4)
        XCTAssertEqual(DNSRecordType.a6.rawValue, 38)
        XCTAssertEqual(DNSRecordType.maila.rawValue, 254)
    }

    func testDNSRecordTypeExperimentalTypes() {
        // Test experimental types
        XCTAssertEqual(DNSRecordType.mb.rawValue, 7)
        XCTAssertEqual(DNSRecordType.mg.rawValue, 8)
        XCTAssertEqual(DNSRecordType.mr.rawValue, 9)
        XCTAssertEqual(DNSRecordType.null.rawValue, 10)
    }

    func testDNSRecordTypeDNSSECTypes() {
        // Test DNSSEC-related types
        XCTAssertEqual(DNSRecordType.ds.rawValue, 43)
        XCTAssertEqual(DNSRecordType.rrsig.rawValue, 46)
        XCTAssertEqual(DNSRecordType.nsec.rawValue, 47)
        XCTAssertEqual(DNSRecordType.dnskey.rawValue, 48)
        XCTAssertEqual(DNSRecordType.nsec3.rawValue, 50)
        XCTAssertEqual(DNSRecordType.tlsa.rawValue, 52)
    }

    func testDNSRecordTypeHighValueTypes() {
        // Test types with high raw values
        XCTAssertEqual(DNSRecordType.ta.rawValue, 32768)
        XCTAssertEqual(DNSRecordType.dlv.rawValue, 32769)
    }

    func testDNSClassObsoleteClass() {
        // Test obsolete class
        XCTAssertEqual(DNSClass.cs.rawValue, 2)
        XCTAssertEqual(DNSClass.cs.displayName, "CS")
    }

    // MARK: - Sendable Conformance

    func testDNSRecordTypeSendable() {
        let recordType = DNSRecordType.a
        let expectation = expectation(description: "Sendable DNS record type")

        Task {
            let captured = recordType
            XCTAssertEqual(captured.rawValue, 1)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testDNSClassSendable() {
        let dnsClass = DNSClass.in
        let expectation = expectation(description: "Sendable DNS class")

        Task {
            let captured = dnsClass
            XCTAssertEqual(captured.rawValue, 1)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testDNSResponseCodeSendable() {
        let responseCode = DNSResponseCode.noError
        let expectation = expectation(description: "Sendable DNS response code")

        Task {
            let captured = responseCode
            XCTAssertEqual(captured.rawValue, 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testDNSOpcodeSendable() {
        let opcode = DNSOpcode.query
        let expectation = expectation(description: "Sendable DNS opcode")

        Task {
            let captured = opcode
            XCTAssertEqual(captured.rawValue, 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Comparison Tests

    func testDNSRecordTypeEquality() {
        XCTAssertEqual(DNSRecordType.a, DNSRecordType.a)
        XCTAssertNotEqual(DNSRecordType.a, DNSRecordType.aaaa)
    }

    func testDNSClassEquality() {
        XCTAssertEqual(DNSClass.in, DNSClass.in)
        XCTAssertNotEqual(DNSClass.in, DNSClass.any)
    }

    func testDNSResponseCodeEquality() {
        XCTAssertEqual(DNSResponseCode.noError, DNSResponseCode.noError)
        XCTAssertNotEqual(DNSResponseCode.noError, DNSResponseCode.nameError)
    }

    func testDNSOpcodeEquality() {
        XCTAssertEqual(DNSOpcode.query, DNSOpcode.query)
        XCTAssertNotEqual(DNSOpcode.query, DNSOpcode.update)
    }
}
