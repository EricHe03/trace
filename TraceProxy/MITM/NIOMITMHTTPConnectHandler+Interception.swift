//
//  NIOMITMHTTPConnectHandler+Interception.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import NIOCore
import TraceCore

struct RequestInterceptionContext {
    let flowID: UUID
    let requestURL: String
    let methodToken: String
    let requestHeaders: [String: String]
    let requestBodyData: Data
}

extension NIOMITMHTTPConnectHandler {
    func persistStreamRuntimeSnapshot(_ runtime: StreamSessionRuntime) {
        let snapshot = runtime.snapshot()
        DispatchQueue.global(qos: .utility).async {
            try? AppGroupStorage.shared.upsertStreamSession(snapshot)
        }
    }

    func completeStreamRuntime(
        _ runtime: StreamSessionRuntime?,
        status: StreamSessionStatus,
        reason: String?,
        eventLoop: EventLoop
    ) {
        guard let runtime else { return }
        runtime.setStatus(status, endTime: status == .closed || status == .failed ? Date() : nil)
        let session = runtime.snapshot()
        persistStreamRuntimeSnapshot(runtime)
        streamCloseInterceptionFuture(
            session: session,
            reason: reason,
            eventLoop: eventLoop
        ).whenFailure { error in
            ProxyLog.mitm.warning(
                "event=proxy.stream_close_interception outcome=failure session_id=\(session.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func requestInterceptionFuture(
        _ requestContext: RequestInterceptionContext,
        fallbackRequest: NetworkRequest,
        eventLoop: EventLoop
    ) -> EventLoopFuture<InterceptionResult> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(.modified(fallbackRequest))
        }

        let promise = eventLoop.makePromise(of: InterceptionResult.self)
        promise.completeWithTask { [fallbackRequest] in
            let result = await interceptor.interceptRequest(
                flowId: requestContext.flowID,
                url: requestContext.requestURL,
                method: requestContext.methodToken,
                headers: requestContext.requestHeaders,
                body: requestContext.requestBodyData.isEmpty ? nil : requestContext.requestBodyData
            )

            switch result {
            case let .modified(request):
                var patched = request
                if patched.protocolVersion == nil || patched.protocolVersion == .http11 {
                    patched.protocolVersion = fallbackRequest.protocolVersion
                }
                return .modified(patched)
            case let .mocked(request):
                var patched = request
                if patched.protocolVersion == nil || patched.protocolVersion == .http11 {
                    patched.protocolVersion = fallbackRequest.protocolVersion
                }
                return .mocked(patched)
            case .blocked, .failed:
                return result
            }
        }
        return promise.futureResult
    }

    func responseInterceptionFuture(
        fallbackRequest: NetworkRequest,
        statusCode: Int,
        statusMessage: String,
        responseHeaders: [TraceHTTPHeader],
        responseBodyData: Data,
        eventLoop: EventLoop
    ) -> EventLoopFuture<NetworkRequest> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(fallbackRequest)
        }

        let promise = eventLoop.makePromise(of: NetworkRequest.self)
        promise.completeWithTask {
            await interceptor.interceptResponse(
                request: fallbackRequest,
                statusCode: statusCode,
                statusMessage: statusMessage,
                headers: responseHeaders,
                body: responseBodyData.isEmpty ? nil : responseBodyData
            )
        }
        return promise.futureResult
    }

    func responsePipelineFuture(for requestURL: String, eventLoop: EventLoop) -> EventLoopFuture<ResponsePipeline> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(.bufferAndIntercept)
        }

        let promise = eventLoop.makePromise(of: ResponsePipeline.self)
        promise.completeWithTask {
            await interceptor.responsePipeline(for: requestURL)
        }
        return promise.futureResult
    }

    func blockQUICEnabledFuture(eventLoop: EventLoop) -> EventLoopFuture<Bool> {
        let promise = eventLoop.makePromise(of: Bool.self)
        promise.completeWithTask {
            await HardeningConfig.shared.blockQUIC
        }
        return promise.futureResult
    }

    func streamInterceptionV2EnabledFuture(eventLoop: EventLoop) -> EventLoopFuture<Bool> {
        let promise = eventLoop.makePromise(of: Bool.self)
        promise.completeWithTask {
            await HardeningConfig.shared.enableStreamInterceptionV2
        }
        return promise.futureResult
    }

    func streamOpenInterceptionFuture(
        session: StreamSession,
        eventLoop: EventLoop
    ) -> EventLoopFuture<StreamInterceptionDecision> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(.forward)
        }

        let promise = eventLoop.makePromise(of: StreamInterceptionDecision.self)
        promise.completeWithTask {
            await interceptor.interceptStreamOpen(session: session)
        }
        return promise.futureResult
    }

    func streamEventInterceptionFuture(
        session: StreamSession,
        event: StreamEvent,
        eventLoop: EventLoop
    ) -> EventLoopFuture<StreamInterceptionDecision> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(.forward)
        }

        let promise = eventLoop.makePromise(of: StreamInterceptionDecision.self)
        promise.completeWithTask {
            await interceptor.interceptStreamEvent(session: session, event: event)
        }
        return promise.futureResult
    }

    func streamCloseInterceptionFuture(
        session: StreamSession,
        reason: String?,
        eventLoop: EventLoop
    ) -> EventLoopFuture<StreamInterceptionDecision> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(.forward)
        }

        let promise = eventLoop.makePromise(of: StreamInterceptionDecision.self)
        promise.completeWithTask {
            await interceptor.interceptStreamClose(session: session, reason: reason)
        }
        return promise.futureResult
    }
}
