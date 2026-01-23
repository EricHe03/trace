//
//  RequestRepeater.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public actor RequestRepeater {
    public init() {}

    public func repeatRequest(
        _ request: NetworkRequest,
        modifications: RequestModifications
    ) async throws -> NetworkRequest {
        var modified = request
        if let url = modifications.url {
            modified = NetworkRequest(
                id: modified.id,
                url: url,
                method: modified.method,
                statusCode: modified.statusCode,
                statusMessage: modified.statusMessage,
                timestamp: modified.timestamp,
                duration: modified.duration,
                requestHeaders: modified.requestHeaders,
                responseHeaders: modified.responseHeaders,
                requestBody: modified.requestBody,
                responseBody: modified.responseBody
            )
        }
        if let method = modifications.method {
            modified = NetworkRequest(
                id: modified.id,
                url: modified.url,
                method: method,
                statusCode: modified.statusCode,
                statusMessage: modified.statusMessage,
                timestamp: modified.timestamp,
                duration: modified.duration,
                requestHeaders: modified.requestHeaders,
                responseHeaders: modified.responseHeaders,
                requestBody: modified.requestBody,
                responseBody: modified.responseBody
            )
        }
        if let headers = modifications.headers {
            modified.requestHeaders = headers
        }
        if let body = modifications.body {
            modified.requestBody = BodyStorage.from(data: body)
        }

        let executor = await MainActor.run { RequestExecutor() }
        return try await executor.replay(modified)
    }
}

public struct RequestModifications: Sendable {
    public var url: String?
    public var method: HTTPMethod?
    public var headers: [TraceHTTPHeader]?
    public var body: Data?

    public init(
        url: String? = nil,
        method: HTTPMethod? = nil,
        headers: [TraceHTTPHeader]? = nil,
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}
