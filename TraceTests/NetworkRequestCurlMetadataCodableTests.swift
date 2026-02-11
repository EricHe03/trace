//
//  NetworkRequestCurlMetadataCodableTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/08.
//

import Foundation
import XCTest
@testable import TraceCore

final class NetworkRequestCurlMetadataCodableTests: XCTestCase {

    func testNetworkRequestCodableRoundTripWithCurlExecutionMetadata() throws {
        let original = makeRequest(
            requestMethodRaw: "PURGE",
            metadata: CurlExecutionMetadata(
                originalCommand: "curl -X PURGE https://example.com",
                transferIndex: 0,
                transferCount: 1,
                effectiveOptions: ["--request": ["PURGE"]],
                diagnostics: [CurlExecutionDiagnostic(severity: "info", option: "--request", message: "custom method")]
            )
        )

        let encoded = try encode(original)
        let decoded = try decode(encoded)

        XCTAssertEqual(decoded.requestMethodRaw, "PURGE")
        XCTAssertEqual(decoded.curlExecutionMetadata?.originalCommand, original.curlExecutionMetadata?.originalCommand)
        XCTAssertEqual(decoded.curlExecutionMetadata?.effectiveOptions, original.curlExecutionMetadata?.effectiveOptions)
    }

    func testNetworkRequestDecodesWithoutNewCurlKeys() throws {
        let original = makeRequest(requestMethodRaw: nil, metadata: nil)
        var jsonObject = try jsonObject(from: encode(original))
        jsonObject.removeValue(forKey: "requestMethodRaw")
        jsonObject.removeValue(forKey: "curlExecutionMetadata")

        let decoded = try decode(data(from: jsonObject))

        XCTAssertNil(decoded.requestMethodRaw)
        XCTAssertNil(decoded.curlExecutionMetadata)
    }

    func testNetworkRequestDecodesLegacyRawMethodAndCurlMetadataKeys() throws {
        let original = makeRequest(
            requestMethodRaw: "PURGE",
            metadata: CurlExecutionMetadata(
                originalCommand: "curl -X PURGE https://example.com",
                transferIndex: 0,
                transferCount: 1,
                effectiveOptions: ["--request": ["PURGE"]],
                diagnostics: [CurlExecutionDiagnostic(severity: "info", option: nil, message: "legacy")]
            )
        )

        var jsonObject = try jsonObject(from: encode(original))
        jsonObject["rawMethod"] = jsonObject["requestMethodRaw"]
        jsonObject.removeValue(forKey: "requestMethodRaw")

        jsonObject["curlMetadata"] = jsonObject["curlExecutionMetadata"]
        jsonObject.removeValue(forKey: "curlExecutionMetadata")

        let decoded = try decode(data(from: jsonObject))

        XCTAssertEqual(decoded.requestMethodRaw, "PURGE")
        XCTAssertEqual(decoded.curlExecutionMetadata?.effectiveOptions["--request"], ["PURGE"])
        XCTAssertEqual(decoded.curlExecutionMetadata?.diagnostics.first?.message, "legacy")
    }
}

private extension NetworkRequestCurlMetadataCodableTests {
    func makeRequest(requestMethodRaw: String?, metadata: CurlExecutionMetadata?) -> NetworkRequest {
        NetworkRequest(
            url: "https://example.com",
            method: .get,
            requestMethodRaw: requestMethodRaw,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.2,
            requestHeaders: [TraceHTTPHeader(key: "Accept", value: "*/*")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            requestBody: .empty,
            responseBody: .empty,
            curlExecutionMetadata: metadata
        )
    }

    func encode(_ request: NetworkRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(request)
    }

    func decode(_ data: Data) throws -> NetworkRequest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NetworkRequest.self, from: data)
    }

    func jsonObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "NetworkRequestCurlMetadataCodableTests", code: 1)
        }
        return dictionary
    }

    func data(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
