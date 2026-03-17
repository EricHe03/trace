//
//  MigrationParityRegressionTests.swift
//  TraceTests
//
//  Golden equivalence + failure-mode matrix coverage for SwiftNIO migration.
//

import XCTest
@testable import TraceCore
@testable import TraceFeatures
@testable import TraceProxy

private final class ParityMockTransport: RequestExecutorTransport {
    var handler: ((RequestExecutorTransportRequest) throws -> RequestExecutorTransportResponse)?
    var forcedError: Error?
    private(set) var capturedRequests: [RequestExecutorTransportRequest] = []

    func execute(_ request: RequestExecutorTransportRequest) async throws -> RequestExecutorTransportResponse {
        capturedRequests.append(request)

        if let forcedError {
            throw forcedError
        }

        guard let handler else {
            throw URLError(.unknown)
        }

        return try handler(request)
    }
}

private final class SequencedCookieStore: CookieStore {
    private var queue: [[Foundation.HTTPCookie]]

    init(_ queue: [[Foundation.HTTPCookie]]) {
        self.queue = queue
    }

    func cookies(for _: URL) -> [Foundation.HTTPCookie] {
        guard !queue.isEmpty else { return [] }
        return queue.removeFirst()
    }
}

@MainActor
final class MigrationParityRegressionTests: XCTestCase {
    func testGoldenCaptureEquivalence_RequestResponseShaping() async throws {
        let transport = ParityMockTransport()
        transport.handler = { request in
            XCTAssertEqual(request.followRedirects, false)
            return RequestExecutorTransportResponse(
                finalURL: request.url,
                statusCode: 200,
                statusMessage: "OK",
                protocolVersion: .http11,
                responseHeaders: [
                    TraceHTTPHeader(key: "Content-Type", value: "application/json"),
                    TraceHTTPHeader(key: "X-Trace", value: "golden")
                ],
                body: Data("{\"ok\":true}".utf8),
                redirects: [
                    RedirectInfo(
                        fromURL: "http://example.com",
                        toURL: "https://example.com",
                        statusCode: 301,
                        location: "https://example.com"
                    )
                ],
                responseCookies: [
                    TraceCore.HTTPCookie(name: "session", value: "abc", domain: "example.com", path: "/", expires: nil, secure: true, httpOnly: true, sameSite: .lax)
                ]
            )
        }

        let cookieStore = SequencedCookieStore([[], [], []])
        let executor = RequestExecutor(transport: transport, cookieStore: cookieStore)

        let builder = RequestBuilder(
            url: "https://example.com/api",
            method: .get,
            headers: ["Accept": "application/json"],
            body: nil,
            followRedirects: false
        )

        let captured = try await executor.execute(builder)

        XCTAssertEqual(captured.url, "https://example.com/api")
        XCTAssertEqual(captured.method, .get)
        XCTAssertEqual(captured.statusCode, 200)
        XCTAssertEqual(captured.statusMessage, "OK")
        XCTAssertEqual(captured.redirectChain.count, 1)
        XCTAssertEqual(captured.redirectChain.first?.statusCode, 301)
        XCTAssertEqual(captured.responseCookies?.first?.name, "session")
        XCTAssertEqual(captured.responseHeaders.first(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value, "application/json")
        XCTAssertEqual(captured.responseBody.getString(), "{\"ok\":true}")
        XCTAssertTrue(captured.isManual)
    }

    func testGoldenCaptureEquivalence_CookieDiffFallback() async throws {
        let beforeCookie = try XCTUnwrap(
            Foundation.HTTPCookie(properties: [
                .domain: "example.com",
                .path: "/",
                .name: "session",
                .value: "old"
            ])
        )
        let afterCookie1 = try XCTUnwrap(
            Foundation.HTTPCookie(properties: [
                .domain: "example.com",
                .path: "/",
                .name: "session",
                .value: "old"
            ])
        )
        let afterCookie2 = try XCTUnwrap(
            Foundation.HTTPCookie(properties: [
                .domain: "example.com",
                .path: "/",
                .name: "csrftoken",
                .value: "new"
            ])
        )

        let cookieStore = SequencedCookieStore([
            [beforeCookie],
            [beforeCookie],
            [afterCookie1, afterCookie2]
        ])

        let transport = ParityMockTransport()
        transport.handler = { request in
            RequestExecutorTransportResponse(
                finalURL: request.url,
                statusCode: 204,
                statusMessage: "No Content",
                protocolVersion: .http11,
                responseHeaders: [],
                body: Data(),
                redirects: [],
                responseCookies: []
            )
        }

        let executor = RequestExecutor(transport: transport, cookieStore: cookieStore)
        let result = try await executor.get(url: "https://example.com")

        XCTAssertEqual(result.statusCode, 204)
        XCTAssertEqual(result.responseCookies?.count, 1)
        XCTAssertEqual(result.responseCookies?.first?.name, "csrftoken")
    }

    func testGoldenCaptureEquivalence_BodyTruncationMetricsAndPCAP() async {
        let payload = Data(repeating: 0x61, count: 4096)
        let storage = BodyStorage.from(data: payload, maxSize: 256, decodeCompressedContent: false)

        XCTAssertTrue(storage.isTruncated)
        XCTAssertEqual(storage.totalSize, 4096)

        await ProxyNetworkMetrics.shared.reset()
        await ProxyNetworkMetrics.shared.recordHTTPRequestParsed()
        await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
        await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed()

        let metrics = await ProxyNetworkMetrics.shared.getAllMetrics()
        XCTAssertEqual(metrics.http.requestsParsed, 1)
        XCTAssertEqual(metrics.http.responsesParsed, 1)
        XCTAssertEqual(metrics.http2.framesParsed, 1)

        let httpPayload = Data("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
        let packet = PCAPHTTPPacketSynthesizer.makePacket(payload: httpPayload, proxyPort: 8080, isRequest: true)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.count, 40 + httpPayload.count)

        // TCP src port for request path = 12345 (0x3039)
        XCTAssertEqual(packet?[20], 0x30)
        XCTAssertEqual(packet?[21], 0x39)
        // TCP dst port for request path = proxy port 8080 (0x1F90)
        XCTAssertEqual(packet?[22], 0x1F)
        XCTAssertEqual(packet?[23], 0x90)
    }

    func testFailureModeMatrix_TransportErrorsRemainDeterministic() async {
        let scenarios: [(String, Error)] = [
            ("dns_fail", URLError(.cannotFindHost)),
            ("tls_handshake_fail", URLError(.secureConnectionFailed)),
            ("upstream_reset", URLError(.networkConnectionLost)),
            ("client_reset", URLError(.cancelled)),
            ("idle_timeout", URLError(.timedOut)),
            ("oversized_body", NSError(domain: NSPOSIXErrorDomain, code: 40, userInfo: [NSLocalizedDescriptionKey: "Message too long"]))
        ]

        for (name, underlying) in scenarios {
            let transport = ParityMockTransport()
            transport.forcedError = underlying
            let executor = RequestExecutor(transport: transport)

            do {
                _ = try await executor.get(url: "https://example.com/\(name)")
                XCTFail("Expected error for scenario \(name)")
            } catch let error as RequestExecutionError {
                switch error {
                case let .transport(mapped):
                    let nsMapped = mapped as NSError
                    let nsOriginal = underlying as NSError
                    XCTAssertEqual(nsMapped.domain, nsOriginal.domain, "Scenario: \(name)")
                    XCTAssertEqual(nsMapped.code, nsOriginal.code, "Scenario: \(name)")
                default:
                    XCTFail("Unexpected mapping for scenario \(name): \(error)")
                }
            } catch {
                XCTFail("Unexpected error type for scenario \(name): \(error)")
            }
        }
    }
}
