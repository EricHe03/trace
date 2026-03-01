//
//  HTTP3RequestTransportTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/19.
//

import Foundation
import XCTest
@testable import TraceCore
@testable import TraceFeatures
@testable import TraceQUIC

final class HTTP3RequestTransportTests: XCTestCase {
    func testExecuteDoesNotFollowRedirectWhenDisabled() async throws {
        let startURL = URL(string: "https://start.example/path")!
        let nextURL = URL(string: "https://next.example/path")!
        let client = ScriptedHTTP3Client(
            responsesByURL: [
                startURL.absoluteString: [
                    HTTP3ClientResponse(
                        finalURL: startURL,
                        statusCode: 302,
                        headers: [HTTP3HeaderField(name: "Location", value: nextURL.absoluteString)],
                        body: Data(),
                        negotiatedProtocolName: "h3"
                    )
                ]
            ]
        )
        let transport = HTTP3RequestTransport(client: client)
        let request = RequestExecutorTransportRequest(
            url: startURL,
            methodRaw: "GET",
            headers: [:],
            body: nil,
            requestedProtocolVersion: .http3,
            enforceRequestedProtocolVersion: false,
            followRedirects: false,
            timeout: 10
        )

        let response = try await transport.execute(request)

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.finalURL, startURL)
        XCTAssertEqual(response.redirects.count, 1)
        XCTAssertEqual(response.redirects.first?.toURL, nextURL.absoluteString)

        let requests = await client.executedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests[0].followRedirects)
    }

    func testExecuteFollowsRedirectAndSanitizesCrossOriginHeaders() async throws {
        let startURL = URL(string: "https://a.example/path")!
        let nextURL = URL(string: "https://b.example/final")!
        let client = ScriptedHTTP3Client(
            responsesByURL: [
                startURL.absoluteString: [
                    HTTP3ClientResponse(
                        finalURL: startURL,
                        statusCode: 302,
                        headers: [HTTP3HeaderField(name: "Location", value: nextURL.absoluteString)],
                        body: Data(),
                        negotiatedProtocolName: "h3"
                    )
                ],
                nextURL.absoluteString: [
                    HTTP3ClientResponse(
                        finalURL: nextURL,
                        statusCode: 200,
                        headers: [],
                        body: Data("ok".utf8),
                        negotiatedProtocolName: "h3"
                    )
                ]
            ]
        )
        let transport = HTTP3RequestTransport(client: client)
        let request = RequestExecutorTransportRequest(
            url: startURL,
            methodRaw: "POST",
            headers: [
                "Authorization": "Bearer token",
                "Cookie": "a=1",
                "Proxy-Authorization": "Basic abc",
                "Origin": "https://a.example",
                "Content-Type": "application/json",
                "Content-Length": "7"
            ],
            body: Data("payload".utf8),
            requestedProtocolVersion: .http3,
            enforceRequestedProtocolVersion: false,
            followRedirects: true,
            timeout: 10
        )

        let response = try await transport.execute(request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.finalURL, nextURL)
        XCTAssertEqual(response.redirects.count, 1)
        XCTAssertEqual(response.redirects.first?.fromURL, startURL.absoluteString)
        XCTAssertEqual(response.redirects.first?.toURL, nextURL.absoluteString)

        let requests = await client.executedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertNotNil(requests[0].body)

        let redirectedRequest = requests[1]
        XCTAssertEqual(redirectedRequest.method, "GET")
        XCTAssertNil(redirectedRequest.body)
        XCTAssertNil(headerValue(named: "Authorization", in: redirectedRequest.headers))
        XCTAssertNil(headerValue(named: "Cookie", in: redirectedRequest.headers))
        XCTAssertNil(headerValue(named: "Proxy-Authorization", in: redirectedRequest.headers))
        XCTAssertNil(headerValue(named: "Origin", in: redirectedRequest.headers))
        XCTAssertNil(headerValue(named: "Content-Type", in: redirectedRequest.headers))
        XCTAssertNil(headerValue(named: "Content-Length", in: redirectedRequest.headers))
    }

    func testExecuteThrowsOnRedirectCycle() async throws {
        let firstURL = URL(string: "https://a.example/start")!
        let secondURL = URL(string: "https://b.example/next")!
        let client = ScriptedHTTP3Client(
            responsesByURL: [
                firstURL.absoluteString: [
                    HTTP3ClientResponse(
                        finalURL: firstURL,
                        statusCode: 302,
                        headers: [HTTP3HeaderField(name: "Location", value: secondURL.absoluteString)],
                        body: Data(),
                        negotiatedProtocolName: "h3"
                    )
                ],
                secondURL.absoluteString: [
                    HTTP3ClientResponse(
                        finalURL: secondURL,
                        statusCode: 302,
                        headers: [HTTP3HeaderField(name: "Location", value: firstURL.absoluteString)],
                        body: Data(),
                        negotiatedProtocolName: "h3"
                    )
                ]
            ]
        )
        let transport = HTTP3RequestTransport(client: client)
        let request = RequestExecutorTransportRequest(
            url: firstURL,
            methodRaw: "GET",
            headers: [:],
            body: nil,
            requestedProtocolVersion: .http3,
            enforceRequestedProtocolVersion: false,
            followRedirects: true,
            timeout: 10
        )

        do {
            _ = try await transport.execute(request)
            XCTFail("Expected redirect cycle error")
        } catch let error as RequestExecutorTransportError {
            guard case let .redirectCycleDetected(url) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(url, firstURL.absoluteString)
        }
    }
}

private actor ScriptedHTTP3Client: HTTP3Client {
    private var responsesByURL: [String: [HTTP3ClientResponse]]
    private var requests: [HTTP3ClientRequest] = []

    init(responsesByURL: [String: [HTTP3ClientResponse]]) {
        self.responsesByURL = responsesByURL
    }

    func execute(_ request: HTTP3ClientRequest) async throws -> HTTP3ClientResponse {
        requests.append(request)

        guard var queuedResponses = responsesByURL[request.url.absoluteString], !queuedResponses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let response = queuedResponses.removeFirst()
        responsesByURL[request.url.absoluteString] = queuedResponses
        return response
    }

    func executedRequests() -> [HTTP3ClientRequest] {
        requests
    }
}

private func headerValue(named name: String, in headers: [HTTP3HeaderField]) -> String? {
    headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
}
