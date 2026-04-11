//
//  GRPCStreamFlowHandler.swift
//  TraceProxy
//
//  Routes gRPC-Web stream connections through the NIO stream interception pipeline.
//  Mirrors SSEFlowHandler exactly, using protocolType: .grpc.
//

import Foundation
import NIOCore
import NIOHTTP1
import TraceCore

final class GRPCStreamFlowHandler {
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
            protocolType: .grpc,
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
                        body: "gRPC stream blocked by interceptor",
                        closeAfterSend: true,
                        context: context
                    )
                case let .modify(mutation):
                    runtime.mergeMetadata(mutation.metadata)
                    self.connectHandler.persistStreamRuntimeSnapshot(runtime)
                    self.connectHandler.forwardGRPCWebStreamTransport(
                        outboundContext,
                        requestHead: requestHead,
                        outboundHeaders: outboundHeaders,
                        context: context,
                        streamRuntime: runtime
                    )
                case .forward, .inject, .replay:
                    self.connectHandler.persistStreamRuntimeSnapshot(runtime)
                    self.connectHandler.forwardGRPCWebStreamTransport(
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
