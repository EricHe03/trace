//
//  SSEFlowHandler.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/03.
//

import Foundation
import NIOCore
import NIOHTTP1
import TraceCore

final class SSEFlowHandler {
    unowned let connectHandler: NIOMITMHTTPConnectHandler

    init(connectHandler: NIOMITMHTTPConnectHandler) {
        self.connectHandler = connectHandler
    }

    func forward(
        _ outboundContext: NIOMITMHTTPConnectHandler.OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        let runtime = StreamSessionRuntime(
            protocolType: .sse,
            url: outboundContext.url,
            requestHeaders: outboundContext.requestSnapshot.requestHeaders,
            startTime: Date()
        )
        let session = runtime.snapshot()

        connectHandler.streamOpenInterceptionFuture(session: session, eventLoop: context.eventLoop).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self else { return }
                let decision = (try? result.get()) ?? .forward

                switch decision {
                case .block, .drop:
                    self.connectHandler.sendResponse(
                        status: .forbidden,
                        body: "SSE stream blocked by interceptor",
                        closeAfterSend: true,
                        context: context
                    )
                case let .modify(mutation):
                    runtime.mergeMetadata(mutation.metadata)
                    self.persistSession(runtime.snapshot())
                    self.connectHandler.forwardSSEStreamTransport(
                        outboundContext,
                        requestHead: requestHead,
                        outboundHeaders: outboundHeaders,
                        context: context,
                        streamRuntime: runtime
                    )
                case .forward, .inject, .replay:
                    self.persistSession(runtime.snapshot())
                    self.connectHandler.forwardSSEStreamTransport(
                        outboundContext,
                        requestHead: requestHead,
                        outboundHeaders: outboundHeaders,
                        context: context,
                        streamRuntime: runtime
                    )
                }
            }
        }
    }

    private func persistSession(_ session: StreamSession) {
        DispatchQueue.global(qos: .utility).async {
            try? AppGroupStorage.shared.upsertStreamSession(session)
        }
    }
}
