//
//  RequestInterceptor+LegacyCompatibility.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import TraceCore

public extension RequestInterceptor {
    @available(*, deprecated, message: "Use interceptRequest(flowId:url:method:headers:body:) with Data body to preserve binary content")
    func interceptRequest(
        url: String,
        method: String,
        headers: [String: String],
        body: String?,
        requestId: String = UUID().uuidString
    ) async -> InterceptionResult {
        let flowId = UUID(uuidString: requestId) ?? UUID()
        let bodyData = body?.data(using: .utf8)
        return await interceptRequest(flowId: flowId, url: url, method: method, headers: headers, body: bodyData)
    }

    @available(*, deprecated, message: "Use interceptResponse(request:statusCode:statusMessage:headers:body:) with Data body to preserve binary content")
    func interceptResponse(
        request: NetworkRequest,
        statusCode: Int,
        statusMessage: String,
        headers: [String: String],
        body: String?
    ) async -> NetworkRequest {
        let bodyData = body?.data(using: .utf8)
        let headerList = headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
        return await interceptResponse(request: request, statusCode: statusCode, statusMessage: statusMessage, headers: headerList, body: bodyData)
    }
}

extension RequestInterceptor: InterceptionProviding {}
