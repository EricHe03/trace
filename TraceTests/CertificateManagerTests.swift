//
//  CertificateManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceSecurity

final class CertificateManagerTests: XCTestCase {

    var manager: CertificateManager!

    override func setUp() {
        super.setUp()
        manager = CertificateManager.shared
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let manager1 = CertificateManager.shared
        let manager2 = CertificateManager.shared

        XCTAssertTrue(manager1 === manager2, "CertificateManager should be a singleton")
    }

    // MARK: - Root CA Tests

    func testGetRootCA() {
        // This test will either create a new root CA or retrieve existing one
        XCTAssertNoThrow(try manager.getRootCA())
    }

    func testGetRootCAReturnsValidCertificate() throws {
        let (certificate, privateKey) = try manager.getRootCA()

        XCTAssertNotNil(certificate)
        XCTAssertNotNil(privateKey)
    }

    func testGetRootCAReturnsSameCertificate() throws {
        let (cert1, key1) = try manager.getRootCA()
        let (cert2, key2) = try manager.getRootCA()

        // Should return the same certificate and key on subsequent calls
        XCTAssertEqual(SecCertificateCopyData(cert1) as Data, SecCertificateCopyData(cert2) as Data)
    }

    // MARK: - Certificate Export Tests

    func testExportRootCertificate() {
        XCTAssertNoThrow(try manager.exportRootCertificate())
    }

    func testExportRootCertificateReturnsDERData() throws {
        let derData = try manager.exportRootCertificate()

        XCTAssertGreaterThan(derData.count, 0, "DER data should not be empty")
    }

    func testExportRootCertificatePEM() {
        XCTAssertNoThrow(try manager.exportRootCertificatePEM())
    }

    func testExportRootCertificatePEMFormat() throws {
        let pemString = try manager.exportRootCertificatePEM()

        XCTAssertTrue(pemString.hasPrefix("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(pemString.hasSuffix("-----END CERTIFICATE-----"))
        XCTAssertGreaterThan(pemString.count, 100)
    }

    func testSaveRootCertificateToFile() throws {
        let fileURL = try manager.saveRootCertificateToFile()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.lastPathComponent.hasSuffix(".cer"))

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testSaveRootCertificateToFileCreatesValidFile() throws {
        let fileURL = try manager.saveRootCertificateToFile()

        // Verify file is readable
        let data = try Data(contentsOf: fileURL)
        XCTAssertGreaterThan(data.count, 0)

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Domain Certificate Tests

    func testGenerateCertificateForDomain() {
        XCTAssertNoThrow(try manager.generateCertificateForDomain("example.com"))
    }

    func testGenerateCertificateForDomainReturnsValidCertificate() throws {
        let (certificate, privateKey) = try manager.generateCertificateForDomain("test.example.com")

        XCTAssertNotNil(certificate)
        XCTAssertNotNil(privateKey)
    }

    func testGenerateCertificateForDomainCaches() throws {
        let domain = "cached.example.com"

        let (cert1, _) = try manager.generateCertificateForDomain(domain)
        let (cert2, _) = try manager.generateCertificateForDomain(domain)

        // Should return the same cached certificate
        XCTAssertEqual(SecCertificateCopyData(cert1) as Data, SecCertificateCopyData(cert2) as Data)
    }

    func testGenerateCertificatesForMultipleDomains() throws {
        let domains = ["example1.com", "example2.com", "example3.com"]

        for domain in domains {
            let (certificate, privateKey) = try manager.generateCertificateForDomain(domain)
            XCTAssertNotNil(certificate)
            XCTAssertNotNil(privateKey)
        }
    }

    func testDomainKeychainIdentifiersAreCanonicalAndStable() {
        let ids1 = CertificateManager.keychainIdentifiers(forDomain: "Example.COM.")
        let ids2 = CertificateManager.keychainIdentifiers(forDomain: "example.com")

        XCTAssertEqual(ids1.keyApplicationTag, ids2.keyApplicationTag)
        XCTAssertEqual(ids1.certificateLabel, ids2.certificateLabel)
        XCTAssertTrue(ids1.certificateLabel.hasPrefix("Trace - "))
    }

    func testDomainKeychainIdentifiersLabelIsBoundedForLongDomains() {
        let veryLongDomain = String(repeating: "a", count: 400) + ".example.com"
        let ids = CertificateManager.keychainIdentifiers(forDomain: veryLongDomain)
        XCTAssertLessThan(ids.certificateLabel.count, 200)
        XCTAssertTrue(ids.certificateLabel.hasPrefix("Trace - "))
    }

    // MARK: - Certificate Extension Tests

    func testSecCertificateCommonName() throws {
        let (certificate, _) = try manager.getRootCA()

        let commonName = certificate.commonName
        XCTAssertNotNil(commonName)
    }

    func testSecCertificateSummary() throws {
        let (certificate, _) = try manager.getRootCA()

        let summary = certificate.summary
        XCTAssertFalse(summary.isEmpty)
        XCTAssertNotEqual(summary, "Unknown")
    }

    // MARK: - CertificateError Tests

    func testCertificateErrorDescriptions() {
        XCTAssertNotNil(CertificateError.publicKeyExtractionFailed.errorDescription)
        XCTAssertNotNil(CertificateError.rootCANotFound.errorDescription)
        XCTAssertNotNil(CertificateError.privateKeyNotFound.errorDescription)
        XCTAssertNotNil(CertificateError.certificateNotFound.errorDescription)
        XCTAssertNotNil(CertificateError.notImplemented("test").errorDescription)
    }

    func testCertificateErrorKeyGenerationFailed() {
        let error = CertificateError.keyGenerationFailed(nil)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Failed to generate key"))
    }

    func testCertificateErrorKeychainStorageFailed() {
        let error = CertificateError.keychainStorageFailed(-50)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("keychain"))
    }

    // MARK: - Integration Tests

    func testFullCertificateFlow() throws {
        // Get root CA
        let (rootCert, rootKey) = try manager.getRootCA()
        XCTAssertNotNil(rootCert)
        XCTAssertNotNil(rootKey)

        // Generate domain certificate
        let (domainCert, domainKey) = try manager.generateCertificateForDomain("integration.test.com")
        XCTAssertNotNil(domainCert)
        XCTAssertNotNil(domainKey)

        // Export root certificate
        let pemString = try manager.exportRootCertificatePEM()
        XCTAssertTrue(pemString.contains("BEGIN CERTIFICATE"))

        // Save to file
        let fileURL = try manager.saveRootCertificateToFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }
}
