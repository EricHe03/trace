//
//  WebSocketFlowHandler.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/03.
//

import Foundation
import NIOCore
import NIOHTTP1
import TraceCore

final class WebSocketFlowHandler {
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
            protocolType: .websocket,
            url: connectHandler.normalizedWebSocketURL(from: outboundContext.url),
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
                        body: "WebSocket stream blocked by interceptor",
                        closeAfterSend: true,
                        context: context
                    )
                case let .modify(mutation):
                    runtime.mergeMetadata(mutation.metadata)
                    self.connectHandler.persistStreamRuntimeSnapshot(runtime)
                    self.connectHandler.forwardWebSocketStreamTransport(
                        outboundContext,
                        requestHead: requestHead,
                        outboundHeaders: outboundHeaders,
                        context: context,
                        streamRuntime: runtime
                    )
                case .forward, .inject, .replay:
                    self.connectHandler.persistStreamRuntimeSnapshot(runtime)
                    self.connectHandler.forwardWebSocketStreamTransport(
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
}
