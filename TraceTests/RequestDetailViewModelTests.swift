//
//  RequestDetailViewModelTests.swift
//  TraceTests
//
//  Created by Justin on 2026/03/01.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceUI

@MainActor
final class RequestDetailViewModelTests: XCTestCase {
    private var storage: AppGroupStorage!

    override func setUp() {
        super.setUp()
        storage = AppGroupStorage.shared
        try? storage.clearAllRequests()
    }

    override func tearDown() {
        try? storage.clearAllRequests()
        storage = nil
        super.tearDown()
    }

    func testLoadRequestBodyFullFetchesStoredRequestBody() async throws {
        let requestID = UUID()
        let fullText = String(repeating: "a", count: 180_000)
        let fullData = Data(fullText.utf8)

        let storedRequest = makeRequest(
            id: requestID,
            requestBody: .inline(fullData, charset: "utf-8"),
            responseBody: .empty
        )
        try storage.saveRequest(storedRequest)

        var listRequest = storedRequest
        listRequest.requestBody = .truncated(Data(fullData.prefix(256)), totalSize: fullData.count, charset: "utf-8")

        let viewModel = RequestDetailViewModel()
        await viewModel.loadRequestBody(for: listRequest, full: true)

        XCTAssertEqual(viewModel.requestBodyText?.count, fullText.count)
        XCTAssertEqual(viewModel.requestBodyText?.prefix(32), fullText.prefix(32))
        XCTAssertFalse(viewModel.isRequestBodyPreview)
    }

    func testLoadResponseBodyFullFetchesStoredResponseBody() async throws {
        let requestID = UUID()
        let fullText = String(repeating: "b", count: 170_000)
        let fullData = Data(fullText.utf8)

        let storedRequest = makeRequest(
            id: requestID,
            requestBody: .empty,
            responseBody: .inline(fullData, charset: "utf-8")
        )
        try storage.saveRequest(storedRequest)

        var listRequest = storedRequest
        listRequest.responseBody = .truncated(Data(fullData.prefix(512)), totalSize: fullData.count, charset: "utf-8")

        let viewModel = RequestDetailViewModel()
        await viewModel.loadResponseBody(for: listRequest, full: true)

        XCTAssertEqual(viewModel.responseBodyText?.count, fullText.count)
        XCTAssertEqual(viewModel.responseBodyText?.prefix(32), fullText.prefix(32))
        XCTAssertFalse(viewModel.isResponseBodyPreview)
    }

    func testLoadResponseBodyFullCapsViewerLoadForLargeBodies() async throws {
        let requestID = UUID()
        let fullText = String(repeating: "c", count: 800_000)
        let fullData = Data(fullText.utf8)

        let storedRequest = makeRequest(
            id: requestID,
            requestBody: .empty,
            responseBody: .inline(fullData, charset: "utf-8")
        )
        try storage.saveRequest(storedRequest)

        var listRequest = storedRequest
        listRequest.responseBody = .truncated(Data(fullData.prefix(256)), totalSize: fullData.count, charset: "utf-8")

        let viewModel = RequestDetailViewModel()
        await viewModel.loadResponseBody(for: listRequest, full: true)

        XCTAssertNotNil(viewModel.responseBodyNotice)
        XCTAssertEqual(viewModel.responseBodyText?.count, BodyViewerPolicy.expandedPlainTextLoadBytes)
        XCTAssertFalse(viewModel.isResponseBodyPreview)
    }

    private func makeRequest(id: UUID, requestBody: BodyStorage, responseBody: BodyStorage) -> NetworkRequest {
        NetworkRequest(
            id: id,
            url: "https://example.com/body",
            method: .post,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.2,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/plain; charset=utf-8")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/plain; charset=utf-8")],
            requestBody: requestBody,
            responseBody: responseBody
        )
    }
}
