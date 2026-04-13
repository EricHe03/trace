//
//  StreamFlowController.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/03.
//

import NIOCore
import NIOHTTP1

final class StreamFlowController {
    unowned let connectHandler: NIOMITMHTTPConnectHandler

    init(connectHandler: NIOMITMHTTPConnectHandler) {
        self.connectHandler = connectHandler
    }

    func forwardSSE(
        _ outboundContext: NIOMITMHTTPConnectHandler.OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        let handler = SSEFlowHandler(connectHandler: connectHandler)
        handler.forward(
            outboundContext,
            requestHead: requestHead,
            outboundHeaders: outboundHeaders,
            context: context
        )
    }

    func forwardWebSocket(
        _ outboundContext: NIOMITMHTTPConnectHandler.OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        let handler = WebSocketFlowHandler(connectHandler: connectHandler)
        handler.forward(
            outboundContext,
            requestHead: requestHead,
            outboundHeaders: outboundHeaders,
            context: context
        )
    }

    func forwardGRPCWeb(
        _ outboundContext: NIOMITMHTTPConnectHandler.OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        let handler = GRPCStreamFlowHandler(connectHandler: connectHandler)
        handler.forward(
            outboundContext,
            requestHead: requestHead,
            outboundHeaders: outboundHeaders,
            context: context
        )
    }
}
