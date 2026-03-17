//
//  HTTP3MitmPipelineTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/18.
//

import Foundation
@testable import TraceCore
@testable import TraceQUIC
import XCTest

final class HTTP3MitmPipelineTests: XCTestCase {
    private var originalCaptureConfiguration: CaptureConfiguration?
    private var originalSamplingConfiguration: SamplingConfig?

    override func setUpWithError() throws {
        try super.setUpWithError()

        let storage = AppGroupStorage.shared
        originalCaptureConfiguration = storage.loadConfiguration()
        originalSamplingConfiguration = storage.loadSamplingConfig()

        if var capture = originalCaptureConfiguration {
            capture.isEnabled = false
            try storage.saveConfiguration(capture)
        }

        if var sampling = originalSamplingConfiguration {
            sampling.enabled = false
            try storage.saveSamplingConfig(sampling)
        }
    }

    override func tearDownWithError() throws {
        let storage = AppGroupStorage.shared
        if let originalCaptureConfiguration {
            try storage.saveConfiguration(originalCaptureConfiguration)
        }
        if let originalSamplingConfiguration {
            try storage.saveSamplingConfig(originalSamplingConfiguration)
        }
        try super.tearDownWithError()
    }

    func testProcessRunsInterceptionAndReturnsModifiedResponse() async throws {
        let client = try MockHTTP3Client(
            response: HTTP3ClientResponse(
                finalURL: XCTUnwrap(URL(string: "https://example.com/final")),
                statusCode: 201,
                headers: [
                    HTTP3HeaderField(name: "content-type", value: "text/plain")
                ],
                body: Data("upstream-body".utf8),
                negotiatedProtocolName: "h3"
            )
        )
        let interceptor = ModifyingInterceptor()
        let pipeline = HTTP3MitmPipeline(interceptor: interceptor, http3Client: client)

        let event = HTTP3StreamEvent(
            streamID: 7,
            headers: [
                HTTP3HeaderField(name: ":method", value: "POST"),
                HTTP3HeaderField(name: ":scheme", value: "https"),
                HTTP3HeaderField(name: ":authority", value: "example.com"),
                HTTP3HeaderField(name: ":path", value: "/input"),
                HTTP3HeaderField(name: "content-type", value: "text/plain")
            ],
            body: Data("hello".utf8)
        )

        let result = try await pipeline.process(
            flowID: UUID(),
            event: event,
            timeout: 5,
            requiresHTTP3: true,
            allowHTTPVersionFallback: true
        )

        XCTAssertEqual(result.streamID, 7)
        XCTAssertEqual(result.statusCode, 202)
        XCTAssertEqual(result.responseHeaders.first?.name, ":status")
        XCTAssertEqual(result.responseHeaders.first?.value, "202")
        XCTAssertEqual(String(data: result.responseBody, encoding: .utf8), "upstream-body")
        XCTAssertEqual(result.capturedRequest.protocolVersion, .http3)

        let forwarded = await client.lastRequest()
        XCTAssertEqual(forwarded?.method, "PUT")
        XCTAssertEqual(forwarded?.url.absoluteString, "https://example.com/modified")
        XCTAssertEqual(
            forwarded?.headers.first(where: { $0.name.caseInsensitiveCompare("x-from-interceptor") == .orderedSame })?.value,
            "1"
        )
    }

    func testProcessThrowsWhenInterceptorBlocksRequest() async throws {
        let client = try MockHTTP3Client(
            response: HTTP3ClientResponse(
                finalURL: XCTUnwrap(URL(string: "https://example.com")),
                statusCode: 200,
                headers: [],
                body: Data(),
                negotiatedProtocolName: "h3"
            )
        )
        let pipeline = HTTP3MitmPipeline(
            interceptor: BlockingInterceptor(),
            http3Client: client
        )

        let event = HTTP3StreamEvent(
            streamID: 11,
            headers: [
                HTTP3HeaderField(name: ":method", value: "GET"),
                HTTP3HeaderField(name: ":authority", value: "example.com"),
                HTTP3HeaderField(name: ":path", value: "/")
            ],
            body: Data()
        )

        do {
            _ = try await pipeline.process(flowID: UUID(), event: event)
            XCTFail("Expected blockedByInterceptor error")
        } catch {
            guard case HTTP3MitmPipelineError.blockedByInterceptor = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        let executionCount = await client.executionCount()
        XCTAssertEqual(executionCount, 0)
    }

    func testProcessPreservesRepeatedSetCookieHeaders() async throws {
        let client = try MockHTTP3Client(
            response: HTTP3ClientResponse(
                finalURL: XCTUnwrap(URL(string: "https://example.com/cookies")),
                statusCode: 200,
                headers: [
                    HTTP3HeaderField(name: "Set-Cookie", value: "a=1; Path=/"),
                    HTTP3HeaderField(name: "Set-Cookie", value: "b=2; Path=/"),
                    HTTP3HeaderField(name: "content-type", value: "text/plain")
                ],
                body: Data("ok".utf8),
                negotiatedProtocolName: "h3"
            )
        )
        let pipeline = HTTP3MitmPipeline(interceptor: nil, http3Client: client)

        let event = HTTP3StreamEvent(
            streamID: 5,
            headers: [
                HTTP3HeaderField(name: ":method", value: "GET"),
                HTTP3HeaderField(name: ":scheme", value: "https"),
                HTTP3HeaderField(name: ":authority", value: "example.com"),
                HTTP3HeaderField(name: ":path", value: "/cookies")
            ],
            body: Data()
        )

        let result = try await pipeline.process(
            flowID: UUID(),
            event: event,
            requiresHTTP3: true,
            allowHTTPVersionFallback: true
        )

        let capturedSetCookies = result.capturedRequest.responseHeaders.filter {
            $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame
        }
        let responseSetCookies = result.responseHeaders.filter {
            $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame
        }

        XCTAssertEqual(capturedSetCookies.count, 2)
        XCTAssertEqual(responseSetCookies.count, 2)
        XCTAssertTrue(capturedSetCookies.contains { $0.value.contains("a=1") })
        XCTAssertTrue(capturedSetCookies.contains { $0.value.contains("b=2") })
    }
}

private actor MockHTTP3Client: HTTP3Client {
    private let response: HTTP3ClientResponse
    private var requests: [HTTP3ClientRequest] = []

    init(response: HTTP3ClientResponse) {
        self.response = response
    }

    func execute(_ request: HTTP3ClientRequest) async throws -> HTTP3ClientResponse {
        requests.append(request)
        return response
    }

    func lastRequest() -> HTTP3ClientRequest? {
        requests.last
    }

    func executionCount() -> Int {
        requests.count
    }
}

private actor ModifyingInterceptor: InterceptionProviding {
    func interceptRequest(
        flowId: UUID,
        url: String,
        method _: String,
        headers _: [String: String],
        body: Data?
    ) async -> InterceptionResult {
        let request = NetworkRequest(
            id: flowId,
            url: url.replacingOccurrences(of: "/input", with: "/modified"),
            method: .post,
            requestMethodRaw: "PUT",
            statusCode: nil,
            statusMessage: nil,
            timestamp: Date(),
            duration: 0,
            requestHeaders: [
                TraceHTTPHeader(key: "x-from-interceptor", value: "1")
            ],
            responseHeaders: [],
            requestBody: body.map { BodyStorage.from(data: $0) } ?? .empty,
            responseBody: .empty,
            protocolVersion: .http3
        )
        return .modified(request)
    }

    func interceptResponse(
        request: NetworkRequest,
        statusCode: Int,
        statusMessage _: String,
        headers: [TraceHTTPHeader],
        body: Data?
    ) async -> NetworkRequest {
        var response = request
        response.statusCode = statusCode + 1
        response.statusMessage = "intercepted"
        response.responseHeaders = headers + [TraceHTTPHeader(key: "x-intercepted", value: "1")]
        response.responseBody = body.map { BodyStorage.from(data: $0) } ?? .empty
        return response
    }
}

private actor BlockingInterceptor: InterceptionProviding {
    func interceptRequest(
        flowId _: UUID,
        url _: String,
        method _: String,
        headers _: [String: String],
        body _: Data?
    ) async -> InterceptionResult {
        .blocked
    }

    func interceptResponse(
        request: NetworkRequest,
        statusCode _: Int,
        statusMessage _: String,
        headers _: [TraceHTTPHeader],
        body _: Data?
    ) async -> NetworkRequest {
        request
    }
}
