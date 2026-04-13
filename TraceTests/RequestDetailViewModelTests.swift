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

    func testLoadInitialBodyPreviewDecodesGRPCWebTextMessages() async {
        let payload = Data([0x08, 0x96, 0x01]) // field 1, varint(150)
        let framedBody = makeGRPCFrame(flag: 0x00, payload: payload)
        let encodedBody = Data(framedBody.base64EncodedString().utf8)
        let request = NetworkRequest(
            url: "https://example.com/grpc",
            method: .post,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.1,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/grpc-web-text+proto")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/grpc-web-text+proto")],
            requestBody: .inline(encodedBody, charset: "utf-8"),
            responseBody: .inline(encodedBody, charset: "utf-8")
        )

        let viewModel = RequestDetailViewModel()
        await viewModel.loadInitialBodyPreview(for: request)
        await waitForDecodedMessages(in: viewModel)

        XCTAssertEqual(viewModel.requestProtobufMessages?.count, 1)
        XCTAssertEqual(viewModel.responseProtobufMessages?.count, 1)
        XCTAssertEqual(viewModel.requestProtobufMessages?.first?.first?.fieldNumber, 1)
        XCTAssertEqual(viewModel.responseProtobufMessages?.first?.first?.fieldNumber, 1)
    }

    func testImportProtoSchemaSelectsRPCRequestAndResponseDescriptors() async {
        let requestPayload = Data([0x08, 0x2A]) // query = 42
        let responsePayload = Data([0x08, 0x07]) // reply = 7
        let request = NetworkRequest(
            url: "https://example.com/trace.example.EchoService/Echo",
            method: .post,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.1,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/grpc+proto")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/grpc+proto")],
            requestBody: .inline(makeGRPCFrame(flag: 0x00, payload: requestPayload)),
            responseBody: .inline(makeGRPCFrame(flag: 0x00, payload: responsePayload))
        )
        let proto = """
        syntax = "proto3";
        package trace.example;

        message EchoRequest {
            uint64 query = 1;
        }

        message EchoResponse {
            uint64 reply = 1;
        }

        service EchoService {
            rpc Echo(EchoRequest) returns (EchoResponse);
        }
        """

        let viewModel = RequestDetailViewModel()
        await viewModel.loadInitialBodyPreview(for: request)
        viewModel.importProtoSchema(text: proto, for: request)
        await waitForDecodedMessageNames(
            requestFieldName: "query",
            responseFieldName: "reply",
            in: viewModel
        )

        XCTAssertEqual(viewModel.requestProtobufMessages?.first?.first?.name, "query")
        XCTAssertEqual(viewModel.responseProtobufMessages?.first?.first?.name, "reply")
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

    private func makeGRPCFrame(flag: UInt8, payload: Data) -> Data {
        let length = UInt32(payload.count)
        var frame = Data([
            flag,
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
        frame.append(payload)
        return frame
    }

    private func waitForDecodedMessages(in viewModel: RequestDetailViewModel) async {
        for _ in 0 ..< 20 {
            if viewModel.requestProtobufMessages != nil, viewModel.responseProtobufMessages != nil {
                return
            }
            await Task.yield()
        }
    }

    private func waitForDecodedMessageNames(
        requestFieldName: String,
        responseFieldName: String,
        in viewModel: RequestDetailViewModel
    ) async {
        for _ in 0 ..< 50 {
            if viewModel.requestProtobufMessages?.first?.first?.name == requestFieldName,
               viewModel.responseProtobufMessages?.first?.first?.name == responseFieldName
            {
                return
            }
            await Task.yield()
        }
    }
}
