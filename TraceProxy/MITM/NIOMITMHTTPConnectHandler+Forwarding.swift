//
//  NIOMITMHTTPConnectHandler+Forwarding.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/20.
//

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS
import NIOTransportServices
import NIOWebSocket
import TraceCore

extension NIOMITMHTTPConnectHandler {
    func forwardModifiedHTTPRequest(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard let httpClient = NIORuntime.shared.currentResources()?.httpClient else {
            sendResponse(status: .internalServerError, body: "NIO runtime unavailable", closeAfterSend: true, context: context)
            return
        }

        var outboundHeaders = makeHTTPHeaders(from: outboundContext.headers)
        let outboundBodyData = normalizeWireBody(
            outboundContext.body,
            headers: &outboundHeaders,
            compressionInfo: outboundContext.requestSnapshot.requestBody.getCompressionInfo(),
            direction: "request"
        )
        switch streamingRequestKind(requestHead: requestHead, headers: outboundHeaders) {
        case .webSocket:
            forwardWebSocketStream(
                outboundContext,
                requestHead: requestHead,
                outboundHeaders: outboundHeaders,
                context: context
            )
            return
        case .sse:
            forwardSSEStream(
                outboundContext,
                requestHead: requestHead,
                outboundHeaders: outboundHeaders,
                context: context
            )
            return
        case .none:
            break
        }

        let sanitizedHeaders = sanitizedRequestHeaders(from: outboundHeaders)
        let method = NIOHTTP1.HTTPMethod(rawValue: outboundContext.methodToken) ?? .RAW(value: outboundContext.methodToken)
        let outboundBodyBuffer = byteBuffer(from: outboundBodyData, allocator: context.channel.allocator)
        let outboundBody: HTTPClient.Body? = outboundBodyData.isEmpty ? nil : .byteBuffer(outboundBodyBuffer)

        let outboundRequest: HTTPClient.Request
        do {
            outboundRequest = try HTTPClient.Request(
                url: outboundContext.url,
                method: method,
                headers: sanitizedHeaders,
                body: outboundBody
            )
        } catch {
            sendResponse(status: .badRequest, body: "Invalid outbound request", closeAfterSend: true, context: context)
            return
        }

        throttle(
            direction: .upload,
            bytes: outboundBodyData.count,
            context: context
        ) { [weak self] in
            guard let self else { return }
            self.responsePipelineFuture(for: outboundContext.url, eventLoop: context.eventLoop)
                .and(self.blockQUICEnabledFuture(eventLoop: context.eventLoop))
                .whenComplete { [weak self] planResult in
                    context.eventLoop.execute {
                        guard let self, self.state == .forwardingHTTPRequest else { return }

                        let responsePipeline: ResponsePipeline
                        let blockQUIC: Bool
                        switch planResult {
                        case let .success(plan):
                            responsePipeline = plan.0
                            blockQUIC = plan.1
                        case let .failure(error):
                            responsePipeline = .bufferAndIntercept
                            blockQUIC = true
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_response_pipeline outcome=failure url=\(outboundContext.url, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public)"
                            )
                        }

                        self.logConnectStage(
                            stage: "response_pipeline",
                            outcome: "selected",
                            detail: responsePipeline == .streamAndCapture ? "stream_and_capture" : "buffer_and_intercept"
                        )

                        let upstreamDeadline = NIODeadline.now() + .seconds(Self.upstreamHTTPResponseDeadlineSeconds)
                        self.logConnectStage(
                            stage: "http_upstream",
                            outcome: "start",
                            detail: "deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds)"
                        )
                        if responsePipeline == .streamAndCapture {
                            self.forwardStreamingUpstreamResponse(
                                httpClient: httpClient,
                                request: outboundRequest,
                                outboundContext: outboundContext,
                                requestHead: requestHead,
                                context: context,
                                blockQUIC: blockQUIC,
                                upstreamDeadline: upstreamDeadline,
                                metricsAsParsedResponse: true
                            )
                            return
                        }
                        httpClient.execute(request: outboundRequest, deadline: upstreamDeadline).whenComplete { [weak self] result in
                            context.eventLoop.execute {
                                guard let self, self.state == .forwardingHTTPRequest else { return }
                                switch result {
                                case let .success(response):
                                    var forwardedHeaders = response.headers
                                    if blockQUIC, outboundContext.url.lowercased().hasPrefix("https://") {
                                        forwardedHeaders.remove(name: "Alt-Svc")
                                        forwardedHeaders.add(name: "Alt-Svc", value: "clear")
                                    }
                                    self.logConnectStage(
                                        stage: "http_upstream",
                                        outcome: "response",
                                        detail: "version=\(response.version.major).\(response.version.minor),status=\(response.status.code)"
                                    )

                                    let responseHeadersTrace = self.traceHeaders(from: forwardedHeaders)
                                    let responseBodyData = self.byteBufferToData(response.body ?? ByteBuffer())
                                    let declaredContentLength = self.contentLength(from: forwardedHeaders)
                                    let captureConfig = self.captureConfigProvider()
                                    var captured = outboundContext.requestSnapshot
                                    captured.protocolVersion = self.httpProtocolVersion(from: response.version)
                                    captured.statusCode = Int(response.status.code)
                                    captured.statusMessage = response.status.reasonPhrase
                                    captured.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                                    let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                                    let responseContentEncoding = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                                    captured.responseBody = self.bodyStorage(
                                        from: responseBodyData,
                                        charset: responseCharset,
                                        contentEncoding: responseContentEncoding,
                                        captureConfig: captureConfig
                                    )
                                    self.logResponseCaptureDecision(
                                        pipeline: "buffer_and_intercept",
                                        requestID: captured.id,
                                        statusCode: Int(response.status.code),
                                        responseHeaders: responseHeadersTrace,
                                        bodyStorage: captured.responseBody,
                                        observedBodyBytes: responseBodyData.count,
                                        declaredContentLength: declaredContentLength,
                                        captureBodyEnabled: captureConfig.captureBody,
                                        captureBodyLimit: captureConfig.maxBodySize,
                                        decodeCompressedContent: true,
                                        storageContentEncoding: responseContentEncoding
                                    )
                                    captured.extractHTTPFields()
                                    NetworkThrottlingController.shared.applyMetadata(to: &captured)

                                    self.responseInterceptionFuture(
                                        fallbackRequest: captured,
                                        statusCode: Int(response.status.code),
                                        statusMessage: response.status.reasonPhrase,
                                        responseHeaders: responseHeadersTrace,
                                        responseBodyData: responseBodyData,
                                        eventLoop: context.eventLoop
                                    ).whenComplete { [weak self] interceptResult in
                                        context.eventLoop.execute {
                                            guard let self, self.state == .forwardingHTTPRequest else { return }
                                            switch interceptResult {
                                            case let .success(interceptedRequest):
                                                self.deliverCapturedResponse(
                                                    interceptedRequest,
                                                    requestHead: requestHead,
                                                    context: context,
                                                    metricsAsParsedResponse: true
                                                )
                                            case .failure:
                                                self.deliverCapturedResponse(
                                                    captured,
                                                    requestHead: requestHead,
                                                    context: context,
                                                    metricsAsParsedResponse: true
                                                )
                                            }
                                        }
                                    }
                                case let .failure(error):
                                    let targetHost = URL(string: outboundContext.url)?.host ?? "unknown"
                                    self.logUpstreamHTTPFailure(
                                        error: error,
                                        methodToken: outboundContext.methodToken,
                                        targetHost: targetHost
                                    )
                                    self.sendResponse(
                                        status: .badGateway,
                                        body: "Upstream HTTP request failed",
                                        closeAfterSend: true,
                                        context: context
                                    )
                                }
                            }
                        }
                    }
                }
        }
    }

    func streamingRequestKind(requestHead: HTTPRequestHead, headers: HTTPHeaders) -> StreamingRequestKind {
        guard requestHead.version.major == 1 else {
            return .none
        }
        if isWebSocketUpgrade(headers: headers) {
            return .webSocket
        }
        if Self.isSSERequest(headers: headers) {
            return .sse
        }
        return .none
    }

    func forwardSSEStream(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        streamInterceptionV2EnabledFuture(eventLoop: context.eventLoop).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self else { return }
                let useV2 = (try? result.get()) ?? false
                guard useV2 else {
                    self.forwardSSEStreamLegacy(
                        outboundContext,
                        requestHead: requestHead,
                        outboundHeaders: outboundHeaders,
                        context: context
                    )
                    return
                }

                let flowController = StreamFlowController(connectHandler: self)
                flowController.forwardSSE(
                    outboundContext,
                    requestHead: requestHead,
                    outboundHeaders: outboundHeaders,
                    context: context
                )
            }
        }
    }

    func forwardWebSocketStream(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        streamInterceptionV2EnabledFuture(eventLoop: context.eventLoop).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self else { return }
                let useV2 = (try? result.get()) ?? false
                guard useV2 else {
                    self.forwardWebSocketStreamLegacy(
                        outboundContext,
                        requestHead: requestHead,
                        outboundHeaders: outboundHeaders,
                        context: context
                    )
                    return
                }

                let flowController = StreamFlowController(connectHandler: self)
                flowController.forwardWebSocket(
                    outboundContext,
                    requestHead: requestHead,
                    outboundHeaders: outboundHeaders,
                    context: context
                )
            }
        }
    }

    func forwardSSEStreamLegacy(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext,
        streamRuntime: StreamSessionRuntime? = nil,
        openDecision _: StreamInterceptionDecision? = nil
    ) {
        guard let targetURL = URL(string: outboundContext.url),
              let targetHost = targetURL.host
        else {
            sendResponse(status: .badRequest, body: "Invalid SSE request target", closeAfterSend: true, context: context)
            return
        }

        let targetPort = targetURL.port ?? ((targetURL.scheme?.lowercased() == "https" || targetURL.scheme?.lowercased() == "wss") ? 443 : 80)
        var requestHeaders = sanitizedStreamingRequestHeaders(from: outboundHeaders)
        requestHeaders.remove(name: "Accept-Encoding")
        requestHeaders.replaceOrAdd(name: "Accept-Encoding", value: "identity")
        guard let streamingRequestHead = makeStreamingUpstreamRequestHead(
            url: targetURL,
            methodToken: outboundContext.methodToken,
            headers: requestHeaders
        ) else {
            sendResponse(status: .badRequest, body: "Invalid SSE request headers", closeAfterSend: true, context: context)
            return
        }
        var sseBaseRequest = outboundContext.requestSnapshot
        annotateCaptureMetadata(&sseBaseRequest)
        let sseCapture = NIOMITMSSECaptureState(
            baseRequest: sseBaseRequest,
            sessionID: streamRuntime?.snapshot().id
        )
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)

        let bootstrap = NIOTSConnectionBootstrap(group: group)
        bootstrap.connect(host: targetHost, port: targetPort).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self, self.state == .forwardingHTTPRequest else {
                    if case let .success(upstream) = result {
                        upstream.close(promise: nil)
                    }
                    return
                }

                switch result {
                case let .success(upstream):
                    self.upstreamChannel = upstream
                    var closeAfterSend = false
                    var responseHeadSeen = false
                    let sseInterceptionRuntime = SSEInterceptionRuntime()
                    var bodyRelayChain = context.eventLoop.makeSucceededVoidFuture()

                    let onPart: @Sendable (HTTPClientResponsePart) -> Void = { [weak self, weak upstream] part in
                        let context = sendableContext.value
                        guard let self, let upstream else { return }
                        context.eventLoop.execute {
                            guard self.state == .forwardingHTTPRequest else { return }
                            switch part {
                            case let .head(head):
                                responseHeadSeen = true
                                closeAfterSend = self.shouldCloseConnection(requestHead: requestHead, responseHeaders: head.headers)
                                sseCapture.beginResponse(
                                    head: head,
                                    captureConfig: self.captureConfigProvider(),
                                    onRequestCaptured: self.onRequestCaptured
                                )
                                if let streamRuntime {
                                    streamRuntime.updateResponseHeaders(
                                        self.captureConfigProvider().captureHeaders
                                            ? self.traceHeaders(from: head.headers)
                                            : []
                                    )
                                    streamRuntime.setStatus(.streaming)
                                    self.persistStreamRuntimeSnapshot(streamRuntime)
                                }
                                var forwardedHead = head
                                forwardedHead.headers.remove(name: "Proxy-Connection")
                                context.write(self.wrapOutboundOut(.head(forwardedHead)), promise: nil)
                            case let .body(buffer):
                                let chunkData = self.byteBufferToData(buffer)
                                guard let streamRuntime else {
                                    sseCapture.consume(
                                        bodyChunk: chunkData,
                                        captureConfig: self.captureConfigProvider(),
                                        onRequestCaptured: self.onRequestCaptured
                                    )
                                    context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                                    return
                                }

                                bodyRelayChain = bodyRelayChain.flatMap {
                                    sseInterceptionRuntime.interceptChunk(
                                        chunkData,
                                        runtime: streamRuntime,
                                        decisionProvider: { [weak self] session, event, eventLoop in
                                            guard let self else {
                                                return eventLoop.makeSucceededFuture(.forward)
                                            }
                                            return self.streamEventInterceptionFuture(
                                                session: session,
                                                event: event,
                                                eventLoop: eventLoop
                                            )
                                        },
                                        replayEngine: .shared,
                                        eventLoop: context.eventLoop
                                    )
                                }.flatMap { forwardedChunk in
                                    sseCapture.consume(
                                        bodyChunk: forwardedChunk,
                                        captureConfig: self.captureConfigProvider(),
                                        onRequestCaptured: self.onRequestCaptured
                                    )
                                    guard !forwardedChunk.isEmpty else {
                                        return context.eventLoop.makeSucceededVoidFuture()
                                    }
                                    let forwardedBuffer = self.byteBuffer(
                                        from: forwardedChunk,
                                        allocator: context.channel.allocator
                                    )
                                    let promise = context.eventLoop.makePromise(of: Void.self)
                                    context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(forwardedBuffer))), promise: promise)
                                    return promise.futureResult
                                }
                                bodyRelayChain.whenFailure { [weak self] error in
                                    guard let self else { return }
                                    self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                                    self.completeStreamRuntime(
                                        streamRuntime,
                                        status: .failed,
                                        reason: error.localizedDescription,
                                        eventLoop: context.eventLoop
                                    )
                                }
                            case let .end(trailers):
                                bodyRelayChain.flatMap {
                                    sseCapture.finish(
                                        succeeded: true,
                                        captureConfig: self.captureConfigProvider(),
                                        onRequestCaptured: self.onRequestCaptured
                                    )
                                    self.completeStreamRuntime(
                                        streamRuntime,
                                        status: .closed,
                                        reason: nil,
                                        eventLoop: context.eventLoop
                                    )
                                    let promise = context.eventLoop.makePromise(of: Void.self)
                                    promise.futureResult.whenComplete { _ in
                                        self.upstreamChannel = nil
                                        upstream.close(promise: nil)
                                        self.transitionAfterResponse(closeAfterSend: closeAfterSend, context: context)
                                    }
                                    context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
                                    return promise.futureResult
                                }.whenFailure { error in
                                    self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                                    self.completeStreamRuntime(
                                        streamRuntime,
                                        status: .failed,
                                        reason: error.localizedDescription,
                                        eventLoop: context.eventLoop
                                    )
                                }
                            }
                        }
                    }

                    let onError: @Sendable (Error) -> Void = { [weak self] error in
                        let context = sendableContext.value
                        context.eventLoop.execute {
                            guard let self, self.state == .forwardingHTTPRequest else { return }
                            self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_sse_upstream_error outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                            sseCapture.finish(
                                succeeded: false,
                                captureConfig: self.captureConfigProvider(),
                                onRequestCaptured: self.onRequestCaptured
                            )
                            self.completeStreamRuntime(
                                streamRuntime,
                                status: .failed,
                                reason: error.localizedDescription,
                                eventLoop: context.eventLoop
                            )
                            self.sendResponse(
                                status: .badGateway,
                                body: "Upstream SSE request failed",
                                closeAfterSend: true,
                                context: context
                            )
                            self.state = .closed
                            self.upstreamChannel = nil
                        }
                    }

                    let onInactive: @Sendable () -> Void = { [weak self] in
                        let context = sendableContext.value
                        context.eventLoop.execute {
                            guard let self, self.state == .forwardingHTTPRequest else { return }
                            sseCapture.finish(
                                succeeded: responseHeadSeen,
                                captureConfig: self.captureConfigProvider(),
                                onRequestCaptured: self.onRequestCaptured
                            )
                            self.completeStreamRuntime(
                                streamRuntime,
                                status: responseHeadSeen ? .closed : .failed,
                                reason: responseHeadSeen ? nil : "upstream_inactive",
                                eventLoop: context.eventLoop
                            )
                            self.state = .closed
                            context.close(promise: nil)
                        }
                    }

                    self.installStreamingUpstreamHTTPPipeline(
                        on: upstream,
                        onResponsePart: onPart,
                        onError: onError,
                        onInactive: onInactive
                    )
                    .flatMap {
                        self.installStreamingUpstreamTLSIfNeeded(
                            on: upstream,
                            url: targetURL,
                            serverHostname: targetHost
                        )
                    }
                    .flatMap {
                        self.writeAndFlushStreamingUpstreamRequest(
                            head: streamingRequestHead,
                            body: outboundContext.body,
                            to: upstream
                        )
                    }
                    .whenComplete { [weak self] pipelineResult in
                        guard let self else { return }
                        if case let .failure(error) = pipelineResult {
                            self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_sse_setup outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                            sseCapture.finish(
                                succeeded: false,
                                captureConfig: self.captureConfigProvider(),
                                onRequestCaptured: self.onRequestCaptured
                            )
                            self.completeStreamRuntime(
                                streamRuntime,
                                status: .failed,
                                reason: error.localizedDescription,
                                eventLoop: context.eventLoop
                            )
                            self.sendResponse(
                                status: .badGateway,
                                body: "Failed to establish SSE upstream",
                                closeAfterSend: true,
                                context: context
                            )
                            self.state = .closed
                            self.upstreamChannel = nil
                            upstream.close(promise: nil)
                        }
                    }
                case let .failure(error):
                    self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_sse_connect outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.completeStreamRuntime(
                        streamRuntime,
                        status: .failed,
                        reason: error.localizedDescription,
                        eventLoop: context.eventLoop
                    )
                    self.sendResponse(
                        status: .badGateway,
                        body: "Failed to establish SSE upstream",
                        closeAfterSend: true,
                        context: context
                    )
                }
            }
        }
    }

    func forwardWebSocketStreamLegacy(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext,
        streamRuntime: StreamSessionRuntime? = nil,
        openDecision _: StreamInterceptionDecision? = nil
    ) {
        guard let targetURL = URL(string: outboundContext.url),
              let targetHost = targetURL.host
        else {
            sendResponse(status: .badRequest, body: "Invalid WebSocket request target", closeAfterSend: true, context: context)
            return
        }

        let targetPort = targetURL.port ?? ((targetURL.scheme?.lowercased() == "https" || targetURL.scheme?.lowercased() == "wss") ? 443 : 80)
        let requestHeaders = sanitizedStreamingRequestHeaders(from: outboundHeaders)
        guard let streamingRequestHead = makeStreamingUpstreamRequestHead(
            url: targetURL,
            methodToken: outboundContext.methodToken,
            headers: requestHeaders
        ) else {
            sendResponse(status: .badRequest, body: "Invalid WebSocket request headers", closeAfterSend: true, context: context)
            return
        }
        let normalizedURL = normalizedWebSocketURL(from: outboundContext.url)
        let wsCapture = NIOMITMWebSocketCaptureState(
            url: normalizedURL,
            requestHeaders: traceHeaders(from: requestHeaders),
            sessionID: streamRuntime?.snapshot().id
        )
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)

        let bootstrap = NIOTSConnectionBootstrap(group: group)
        bootstrap.connect(host: targetHost, port: targetPort).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self, self.state == .forwardingHTTPRequest else {
                    if case let .success(upstream) = result {
                        upstream.close(promise: nil)
                    }
                    return
                }

                switch result {
                case let .success(upstream):
                    self.upstreamChannel = upstream
                    var responseHead: HTTPResponseHead?
                    var responseBody = context.channel.allocator.buffer(capacity: 0)
                    var closeAfterSend = false

                    let onPart: @Sendable (HTTPClientResponsePart) -> Void = { [weak self, weak upstream] part in
                        let context = sendableContext.value
                        guard let self, let upstream else { return }
                        context.eventLoop.execute {
                            guard self.state == .forwardingHTTPRequest else { return }
                            switch part {
                            case let .head(head):
                                responseHead = head
                                closeAfterSend = self.shouldCloseConnection(
                                    requestHead: requestHead,
                                    responseHeaders: head.headers
                                )
                                if let streamRuntime {
                                    streamRuntime.updateResponseHeaders(
                                        self.captureConfigProvider().captureHeaders
                                            ? self.traceHeaders(from: head.headers)
                                            : []
                                    )
                                    self.persistStreamRuntimeSnapshot(streamRuntime)
                                }
                                var forwardedHead = head
                                forwardedHead.headers.remove(name: "Proxy-Connection")
                                context.write(self.wrapOutboundOut(.head(forwardedHead)), promise: nil)
                            case let .body(buffer):
                                guard responseHead?.status != .switchingProtocols else { return }
                                var mutable = buffer
                                responseBody.writeBuffer(&mutable)
                                context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                            case let .end(trailers):
                                guard let head = responseHead else {
                                    self.sendResponse(
                                        status: .badGateway,
                                        body: "Invalid WebSocket upstream response",
                                        closeAfterSend: true,
                                        context: context
                                    )
                                    self.state = .closed
                                    self.upstreamChannel = nil
                                    upstream.close(promise: nil)
                                    wsCapture.markFailed()
                                    return
                                }

                                let isUpgrade = head.status == .switchingProtocols &&
                                    self.isWebSocketUpgrade(headers: head.headers)
                                if isUpgrade {
                                    let perMessageDeflateEnabled = self.webSocketPerMessageDeflateEnabled(headers: head.headers)
                                    ProxyLog.mitm.info(
                                        "event=proxy.nio_ws_upgrade outcome=accepted ws_id=\(wsCapture.connectionID.uuidString, privacy: .public) host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) permessage_deflate=\(perMessageDeflateEnabled, privacy: .public)"
                                    )
                                    self.eventLog?.append(
                                        type: "proxy_nio_ws_upgrade",
                                        msg: "outcome=accepted mode=\(self.ingressModeLabel) id=\(self.connectionID) ws_id=\(wsCapture.connectionID.uuidString) url_hash=\(LogRedaction.hash(normalizedURL)) permessage_deflate=\(perMessageDeflateEnabled)"
                                    )
                                    wsCapture.markOpen(
                                        responseHeaders: self.captureConfigProvider().captureHeaders
                                            ? self.traceHeaders(from: head.headers)
                                            : []
                                    )
                                    if let streamRuntime {
                                        streamRuntime.setStatus(.open)
                                        self.persistStreamRuntimeSnapshot(streamRuntime)
                                    }
                                    let promise = context.eventLoop.makePromise(of: Void.self)
                                    promise.futureResult.whenComplete { [weak self] _ in
                                        guard let self else { return }
                                        self.installWebSocketRelay(
                                            clientContext: context,
                                            upstream: upstream,
                                            captureState: wsCapture,
                                            streamRuntime: streamRuntime,
                                            perMessageDeflateEnabled: perMessageDeflateEnabled
                                        )
                                    }
                                    context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
                                    return
                                }

                                ProxyLog.mitm.info(
                                    "event=proxy.nio_ws_upgrade outcome=rejected ws_id=\(wsCapture.connectionID.uuidString, privacy: .public) host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) status=\(Int(head.status.code), privacy: .public)"
                                )
                                self.eventLog?.append(
                                    type: "proxy_nio_ws_upgrade",
                                    msg: "outcome=rejected mode=\(self.ingressModeLabel) id=\(self.connectionID) ws_id=\(wsCapture.connectionID.uuidString) url_hash=\(LogRedaction.hash(normalizedURL)) status=\(head.status.code)"
                                )
                                let responseBodyData = self.byteBufferToData(responseBody)
                                let captureConfig = self.captureConfigProvider()
                                let responseHeadersTrace = self.traceHeaders(from: head.headers)
                                let declaredContentLength = self.contentLength(from: head.headers)
                                self.completeStreamRuntime(
                                    streamRuntime,
                                    status: .failed,
                                    reason: "websocket_upgrade_rejected",
                                    eventLoop: context.eventLoop
                                )
                                var captured = outboundContext.requestSnapshot
                                captured.protocolVersion = self.httpProtocolVersion(from: head.version)
                                captured.statusCode = Int(head.status.code)
                                captured.statusMessage = head.status.reasonPhrase
                                captured.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                                let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                                let responseContentEncoding = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                                captured.responseBody = self.bodyStorage(
                                    from: responseBodyData,
                                    charset: responseCharset,
                                    contentEncoding: responseContentEncoding,
                                    captureConfig: captureConfig
                                )
                                self.logResponseCaptureDecision(
                                    pipeline: "websocket_http_fallback",
                                    requestID: captured.id,
                                    statusCode: Int(head.status.code),
                                    responseHeaders: responseHeadersTrace,
                                    bodyStorage: captured.responseBody,
                                    observedBodyBytes: responseBodyData.count,
                                    declaredContentLength: declaredContentLength,
                                    captureBodyEnabled: captureConfig.captureBody,
                                    captureBodyLimit: captureConfig.maxBodySize,
                                    decodeCompressedContent: true,
                                    storageContentEncoding: responseContentEncoding
                                )
                                self.annotateCaptureMetadata(&captured)
                                captured.extractHTTPFields()
                                NetworkThrottlingController.shared.applyMetadata(to: &captured)
                                self.finalizeCapturedDuration(for: &captured)
                                self.onRequestCaptured?(captured)

                                let promise = context.eventLoop.makePromise(of: Void.self)
                                promise.futureResult.whenComplete { _ in
                                    self.upstreamChannel = nil
                                    upstream.close(promise: nil)
                                    self.transitionAfterResponse(closeAfterSend: closeAfterSend, context: context)
                                }
                                context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
                            }
                        }
                    }

                    let onError: @Sendable (Error) -> Void = { [weak self] error in
                        let context = sendableContext.value
                        context.eventLoop.execute {
                            guard let self, self.state == .forwardingHTTPRequest else { return }
                            self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_ws_upstream_error outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                            wsCapture.markFailed()
                            self.completeStreamRuntime(
                                streamRuntime,
                                status: .failed,
                                reason: error.localizedDescription,
                                eventLoop: context.eventLoop
                            )
                            self.sendResponse(
                                status: .badGateway,
                                body: "Upstream WebSocket request failed",
                                closeAfterSend: true,
                                context: context
                            )
                            self.state = .closed
                            self.upstreamChannel = nil
                        }
                    }

                    let onInactive: @Sendable () -> Void = { [weak self] in
                        let context = sendableContext.value
                        context.eventLoop.execute {
                            guard let self, self.state == .forwardingHTTPRequest else { return }
                            wsCapture.markClosed(code: nil, reason: nil)
                            self.completeStreamRuntime(
                                streamRuntime,
                                status: .closed,
                                reason: nil,
                                eventLoop: context.eventLoop
                            )
                            self.state = .closed
                            context.close(promise: nil)
                        }
                    }

                    self.installStreamingUpstreamHTTPPipeline(
                        on: upstream,
                        onResponsePart: onPart,
                        onError: onError,
                        onInactive: onInactive
                    )
                    .flatMap {
                        self.installStreamingUpstreamTLSIfNeeded(
                            on: upstream,
                            url: targetURL,
                            serverHostname: targetHost
                        )
                    }
                    .flatMap {
                        self.writeAndFlushStreamingUpstreamRequest(
                            head: streamingRequestHead,
                            body: outboundContext.body,
                            to: upstream
                        )
                    }
                    .whenComplete { [weak self] pipelineResult in
                        guard let self else { return }
                        if case let .failure(error) = pipelineResult {
                            self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_ws_setup outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                            wsCapture.markFailed()
                            self.completeStreamRuntime(
                                streamRuntime,
                                status: .failed,
                                reason: error.localizedDescription,
                                eventLoop: context.eventLoop
                            )
                            self.sendResponse(
                                status: .badGateway,
                                body: "Failed to establish WebSocket upstream",
                                closeAfterSend: true,
                                context: context
                            )
                            self.state = .closed
                            self.upstreamChannel = nil
                            upstream.close(promise: nil)
                        }
                    }
                case let .failure(error):
                    self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_ws_connect outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.completeStreamRuntime(
                        streamRuntime,
                        status: .failed,
                        reason: error.localizedDescription,
                        eventLoop: context.eventLoop
                    )
                    self.sendResponse(
                        status: .badGateway,
                        body: "Failed to establish WebSocket upstream",
                        closeAfterSend: true,
                        context: context
                    )
                }
            }
        }
    }

    func makeRawStreamingRequestBuffer(
        url: URL,
        method: String,
        headers: HTTPHeaders,
        body: Data,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        var requestHeaders = headers
        requestHeaders.remove(name: "Proxy-Connection")

        if requestHeaders.first(name: "Host") == nil, let host = url.host {
            let scheme = (url.scheme ?? "http").lowercased()
            let defaultPort = scheme == "https" || scheme == "wss" ? 443 : 80
            let hostValue: String = if let port = url.port, port != defaultPort {
                "\(host):\(port)"
            } else {
                host
            }
            requestHeaders.add(name: "Host", value: hostValue)
        }

        if !body.isEmpty,
           requestHeaders.first(name: "Content-Length") == nil,
           requestHeaders.first(name: "Transfer-Encoding") == nil {
            requestHeaders.add(name: "Content-Length", value: "\(body.count)")
        }

        var path = url.path
        if path.isEmpty {
            path = "/"
        }
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }

        var buffer = allocator.buffer(capacity: 512 + body.count)
        buffer.writeString("\(method) \(path) HTTP/1.1\r\n")
        for header in requestHeaders {
            buffer.writeString("\(header.name): \(header.value)\r\n")
        }
        buffer.writeString("\r\n")
        if !body.isEmpty {
            buffer.writeBytes(body)
        }
        return buffer
    }

    func makeStreamingUpstreamRequestHead(
        url: URL,
        methodToken: String,
        headers: HTTPHeaders
    ) -> HTTPRequestHead? {
        guard let host = url.host else { return nil }

        var requestHeaders = headers
        requestHeaders.remove(name: "Proxy-Connection")

        if requestHeaders.first(name: "Host") == nil {
            let scheme = (url.scheme ?? "http").lowercased()
            let defaultPort = scheme == "https" || scheme == "wss" ? 443 : 80
            let hostValue: String = if let port = url.port, port != defaultPort {
                "\(host):\(port)"
            } else {
                host
            }
            requestHeaders.add(name: "Host", value: hostValue)
        }

        var path = url.path
        if path.isEmpty {
            path = "/"
        }
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }

        let method = NIOHTTP1.HTTPMethod(rawValue: methodToken) ?? .RAW(value: methodToken)
        var head = HTTPRequestHead(version: .http1_1, method: method, uri: path)
        head.headers = requestHeaders
        return head
    }

    func installStreamingUpstreamTLSIfNeeded(
        on channel: Channel,
        url: URL,
        serverHostname: String
    ) -> EventLoopFuture<Void> {
        let scheme = (url.scheme ?? "http").lowercased()
        guard scheme == "https" || scheme == "wss" else {
            return channel.eventLoop.makeSucceededVoidFuture()
        }

        do {
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.applicationProtocols = ["http/1.1"]
            if RuntimeEnvironment.isRunningUnitTests {
                tlsConfiguration.certificateVerification = .none
            }

            let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsHandler = try NIOSSLClientHandler(context: tlsContext, serverHostname: serverHostname)
            return channel.pipeline.addHandler(tlsHandler, position: .first)
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    func writeAndFlushStreamingUpstreamRequest(
        head: HTTPRequestHead,
        body: Data,
        to channel: Channel
    ) -> EventLoopFuture<Void> {
        channel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)

        if !body.isEmpty {
            let buffer = byteBuffer(from: body, allocator: channel.allocator)
            channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
        }

        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: promise)
        return promise.futureResult
    }

    func deliverCapturedResponse(
        _ request: NetworkRequest,
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext,
        metricsAsParsedResponse: Bool
    ) {
        let responseStatusCode = request.statusCode ?? 200
        let responseStatus = HTTPResponseStatus(
            statusCode: responseStatusCode,
            reasonPhrase: request.statusMessage ?? HTTPResponseStatus(statusCode: responseStatusCode).reasonPhrase
        )
        var responseHeaders = makeHTTPHeaders(from: request.responseHeaders)
        var responseBodyData = request.responseBody.getData()
            ?? request.responseBody.getString()?.data(using: .utf8)
            ?? Data()
        responseBodyData = normalizeWireBody(
            responseBodyData,
            headers: &responseHeaders,
            compressionInfo: request.responseBody.getCompressionInfo(),
            direction: "response"
        )
        let closeAfterSend = shouldCloseConnection(requestHead: requestHead, responseHeaders: responseHeaders)
        let sanitizedHeaders = sanitizedResponseHeaders(
            from: responseHeaders,
            bodyBytes: responseBodyData.count,
            closeAfterSend: closeAfterSend
        )
        let responseBodyBuffer = byteBuffer(from: responseBodyData, allocator: context.channel.allocator)

        throttle(direction: .download, bytes: responseBodyData.count, context: context) { [weak self] in
            guard let self else { return }
            self.sendHTTPResponse(
                status: responseStatus,
                headers: sanitizedHeaders,
                body: responseBodyBuffer,
                closeAfterSend: closeAfterSend,
                context: context
            ) { [weak self] in
                guard let self else { return }
                var finalized = request
                self.annotateCaptureMetadata(&finalized)
                self.finalizeCapturedDuration(for: &finalized)
                self.onRequestCaptured?(finalized)
                if metricsAsParsedResponse {
                    Task {
                        await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                        await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
                    }
                }
                self.transitionAfterResponse(closeAfterSend: closeAfterSend, context: context)
            }
        }
    }

    func deliverRawUpstreamResponse(
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        bodyData: Data,
        capturedRequest: NetworkRequest,
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext,
        metricsAsParsedResponse: Bool
    ) {
        let closeAfterSend = shouldCloseConnection(requestHead: requestHead, responseHeaders: headers)
        let sanitizedHeaders = sanitizedResponseHeaders(
            from: headers,
            bodyBytes: bodyData.count,
            closeAfterSend: closeAfterSend
        )
        let responseBodyBuffer = byteBuffer(from: bodyData, allocator: context.channel.allocator)

        throttle(direction: .download, bytes: bodyData.count, context: context) { [weak self] in
            guard let self else { return }
            self.sendHTTPResponse(
                status: status,
                headers: sanitizedHeaders,
                body: responseBodyBuffer,
                closeAfterSend: closeAfterSend,
                context: context
            ) { [weak self] in
                guard let self else { return }
                var finalized = capturedRequest
                self.annotateCaptureMetadata(&finalized)
                self.finalizeCapturedDuration(for: &finalized)
                self.onRequestCaptured?(finalized)
                if metricsAsParsedResponse {
                    Task {
                        await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                        await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
                    }
                }
                self.transitionAfterResponse(closeAfterSend: closeAfterSend, context: context)
            }
        }
    }

    func forwardStreamingUpstreamResponse(
        httpClient: HTTPClient,
        request: HTTPClient.Request,
        outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext,
        blockQUIC: Bool,
        upstreamDeadline: NIODeadline,
        metricsAsParsedResponse: Bool
    ) {
        let captureConfig = captureConfigProvider()
        let maxCapturedBodyBytes = captureConfig.captureBody ? max(0, captureConfig.maxBodySize) : 0
        var capturedBodyData = Data()
        var receivedBodyBytes = 0
        var didTruncateCapturedBody = false
        var declaredResponseBodyBytes: Int?
        var capturedRequest = outboundContext.requestSnapshot
        var responseHead: HTTPResponseHead?
        var responseHeadersTrace: [TraceHTTPHeader] = []
        var responseContentEncoding: String?
        var sseCapture: NIOMITMSSECaptureState?
        var closeAfterSend = false
        var responseHeadSent = false
        var terminalStateReached = false
        let targetHost = URL(string: outboundContext.url)?.host ?? "unknown"
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)

        let onHead: @Sendable (HTTPResponseHead) -> EventLoopFuture<Void> = { [weak self] head in
            let context = sendableContext.value
            guard let self else {
                return context.eventLoop.makeSucceededVoidFuture()
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.eventLoop.execute {
                guard self.state == .forwardingHTTPRequest, !terminalStateReached else {
                    promise.succeed(())
                    return
                }

                responseHead = head
                responseHeadSent = true
                declaredResponseBodyBytes = self.contentLength(from: head.headers)
                capturedRequest.protocolVersion = self.httpProtocolVersion(from: head.version)
                self.logConnectStage(
                    stage: "http_upstream",
                    outcome: "response",
                    detail: "version=\(head.version.major).\(head.version.minor),status=\(head.status.code)"
                )

                var forwardedHeaders = head.headers
                if blockQUIC, outboundContext.url.lowercased().hasPrefix("https://") {
                    forwardedHeaders.remove(name: "Alt-Svc")
                    forwardedHeaders.add(name: "Alt-Svc", value: "clear")
                }
                closeAfterSend = self.shouldCloseConnection(requestHead: requestHead, responseHeaders: forwardedHeaders)
                responseHeadersTrace = self.traceHeaders(from: forwardedHeaders)
                responseContentEncoding = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                let responseContentType = self.responseHeaderValue(name: "content-type", in: responseHeadersTrace)
                if sseCapture == nil,
                   let responseContentType,
                   responseContentType.lowercased().contains("text/event-stream")
                {
                    self.annotateCaptureMetadata(&capturedRequest)
                    sseCapture = NIOMITMSSECaptureState(
                        baseRequest: capturedRequest,
                        sessionID: UUID(),
                        persistStreamEvents: captureConfig.captureBody
                    )
                    sseCapture?.beginResponse(
                        head: head,
                        captureConfig: captureConfig,
                        onRequestCaptured: self.onRequestCaptured
                    )
                }

                if head.status.code >= 400 {
                    self.logConnectStage(
                        stage: "response_emit",
                        outcome: "error",
                        detail: "status=\(head.status.code),close=\(closeAfterSend),h2_stream=\(self.usesHTTP2StreamSemantics)"
                    )
                    self.eventLog?.append(
                        type: "proxy_nio_error_response",
                        msg: "mode=\(self.ingressModeLabel) id=\(self.connectionID) status=\(head.status.code) close=\(closeAfterSend) h2_stream=\(self.usesHTTP2StreamSemantics)"
                    )
                }

                let responseHead = HTTPResponseHead(
                    version: .http1_1,
                    status: head.status,
                    headers: self.streamingResponseHeaders(from: forwardedHeaders, closeAfterSend: closeAfterSend)
                )
                context.writeAndFlush(self.wrapOutboundOut(.head(responseHead)), promise: promise)
            }
            return promise.futureResult
        }

        let onBodyPart: @Sendable (ByteBuffer) -> EventLoopFuture<Void> = { [weak self] buffer in
            let context = sendableContext.value
            guard let self else {
                return context.eventLoop.makeSucceededVoidFuture()
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.eventLoop.execute {
                guard self.state == .forwardingHTTPRequest, !terminalStateReached else {
                    promise.succeed(())
                    return
                }

                let chunkBytes = buffer.readableBytes
                if chunkBytes > 0 {
                    receivedBodyBytes += chunkBytes
                }

                if let sseCapture, chunkBytes > 0 {
                    let chunkData = self.byteBufferToData(buffer)
                    sseCapture.consume(
                        bodyChunk: chunkData,
                        captureConfig: captureConfig,
                        onRequestCaptured: self.onRequestCaptured
                    )
                } else if maxCapturedBodyBytes > 0, chunkBytes > 0 {
                    let remaining = maxCapturedBodyBytes - capturedBodyData.count
                    if remaining > 0 {
                        let chunkData = self.byteBufferToData(buffer)
                        if chunkData.count <= remaining {
                            capturedBodyData.append(chunkData)
                        } else {
                            capturedBodyData.append(chunkData.prefix(remaining))
                            didTruncateCapturedBody = true
                        }
                    } else {
                        didTruncateCapturedBody = true
                    }
                }

                let writeChunk = {
                    context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
                }
                if buffer.readableBytes > 0 {
                    self.throttle(
                        direction: .download,
                        bytes: buffer.readableBytes,
                        context: context,
                        operation: writeChunk
                    )
                } else {
                    writeChunk()
                }
            }
            return promise.futureResult
        }

        let onFinish: @Sendable () throws -> Void = { [weak self] in
            let context = sendableContext.value
            guard let self else { return }
            context.eventLoop.execute {
                guard self.state == .forwardingHTTPRequest, !terminalStateReached else { return }
                terminalStateReached = true

                if let sseCapture {
                    sseCapture.finish(
                        succeeded: responseHeadSent,
                        captureConfig: captureConfig,
                        onRequestCaptured: self.onRequestCaptured
                    )
                    let endPromise = context.eventLoop.makePromise(of: Void.self)
                    endPromise.futureResult.whenComplete { _ in
                        if metricsAsParsedResponse {
                            Task {
                                await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                                await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
                            }
                        }
                        self.transitionAfterResponse(closeAfterSend: closeAfterSend, context: context)
                    }
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: endPromise)
                    return
                }

                let finalStatus = responseHead?.status ?? .ok
                capturedRequest.statusCode = Int(finalStatus.code)
                capturedRequest.statusMessage = finalStatus.reasonPhrase
                capturedRequest.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                let observedResponseBodyBytes = max(receivedBodyBytes, capturedBodyData.count)
                let resolvedResponseBodyBytes = self.resolvedResponseBodyBytes(
                    declaredContentLength: declaredResponseBodyBytes,
                    observedBodyBytes: observedResponseBodyBytes
                )
                if didTruncateCapturedBody {
                    let totalSize = max(capturedBodyData.count, resolvedResponseBodyBytes)
                    capturedRequest.responseBody = self.truncatedBodyStorage(
                        fromCapturedData: capturedBodyData,
                        totalSize: totalSize,
                        charset: responseCharset,
                        contentEncoding: responseContentEncoding,
                        decodeCompressedContent: true,
                        maxStoredBodyBytes: max(0, captureConfig.maxBodySize)
                    )
                } else {
                    capturedRequest.responseBody = self.bodyStorage(
                        from: capturedBodyData,
                        charset: responseCharset,
                        contentEncoding: responseContentEncoding,
                        captureConfig: captureConfig,
                        decodeCompressedContent: true
                    )
                }
                self.logResponseCaptureDecision(
                    pipeline: "stream_and_capture",
                    requestID: capturedRequest.id,
                    statusCode: Int(finalStatus.code),
                    responseHeaders: responseHeadersTrace,
                    bodyStorage: capturedRequest.responseBody,
                    observedBodyBytes: observedResponseBodyBytes,
                    declaredContentLength: declaredResponseBodyBytes,
                    captureBodyEnabled: captureConfig.captureBody,
                    captureBodyLimit: captureConfig.maxBodySize,
                    decodeCompressedContent: true,
                    storageContentEncoding: responseContentEncoding
                )
                NetworkThrottlingController.shared.applyMetadata(to: &capturedRequest)

                let endPromise = context.eventLoop.makePromise(of: Void.self)
                endPromise.futureResult.whenComplete { _ in
                    var finalized = capturedRequest
                    self.annotateCaptureMetadata(&finalized)
                    self.finalizeCapturedDuration(for: &finalized)
                    self.onRequestCaptured?(finalized)
                    if metricsAsParsedResponse {
                        Task {
                            await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                            await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
                        }
                    }
                    self.transitionAfterResponse(closeAfterSend: closeAfterSend, context: context)
                }
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: endPromise)
            }
        }

        let onError: @Sendable (Error) -> Void = { [weak self] error in
            let context = sendableContext.value
            guard let self else { return }
            context.eventLoop.execute {
                guard self.state == .forwardingHTTPRequest, !terminalStateReached else { return }
                terminalStateReached = true

                if let sseCapture {
                    sseCapture.finish(
                        succeeded: responseHeadSent,
                        captureConfig: captureConfig,
                        onRequestCaptured: self.onRequestCaptured
                    )
                }

                self.logUpstreamHTTPFailure(
                    error: error,
                    methodToken: outboundContext.methodToken,
                    targetHost: targetHost
                )

                if responseHeadSent {
                    self.state = .closed
                    context.close(promise: nil)
                } else {
                    self.sendResponse(
                        status: .badGateway,
                        body: "Upstream HTTP request failed",
                        closeAfterSend: true,
                        context: context
                    )
                    self.state = .closed
                }
            }
        }

        let delegate = NIOMITMHTTPStreamingResponseDelegate(
            onHead: onHead,
            onBodyPart: onBodyPart,
            onFinish: onFinish,
            onError: onError
        )
        let task = httpClient.execute(request: request, delegate: delegate, deadline: upstreamDeadline)
        task.futureResult.whenFailure { error in
            onError(error)
        }
    }

    func sendHTTPResponse(
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        body: ByteBuffer,
        closeAfterSend: Bool,
        context: ChannelHandlerContext,
        onFlushed: (() -> Void)? = nil
    ) {
        var responseHeaders = headers
        if usesHTTP2StreamSemantics {
            // HTTP/2 forbids connection-specific headers.
            responseHeaders.remove(name: "Connection")
            responseHeaders.remove(name: "Proxy-Connection")
            responseHeaders.remove(name: "Keep-Alive")
            responseHeaders.remove(name: "Transfer-Encoding")
            responseHeaders.remove(name: "Upgrade")
        } else if responseHeaders.first(name: "Connection") == nil {
            responseHeaders.add(name: "Connection", value: closeAfterSend ? "close" : "keep-alive")
        } else if closeAfterSend {
            responseHeaders.replaceOrAdd(name: "Connection", value: "close")
        }

        if status.code >= 400 {
            logConnectStage(
                stage: "response_emit",
                outcome: "error",
                detail: "status=\(status.code),close=\(closeAfterSend),h2_stream=\(usesHTTP2StreamSemantics)"
            )
            eventLog?.append(
                type: "proxy_nio_error_response",
                msg: "mode=\(ingressModeLabel) id=\(connectionID) status=\(status.code) close=\(closeAfterSend) h2_stream=\(usesHTTP2StreamSemantics)"
            )
        }

        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: responseHeaders)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        if body.readableBytes > 0 {
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        }

        let flushPromise = context.eventLoop.makePromise(of: Void.self)
        flushPromise.futureResult.whenComplete { _ in
            onFlushed?()
            if closeAfterSend {
                context.close(promise: nil)
            }
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: flushPromise)
    }

    func resolveRequestURL(from head: HTTPRequestHead) -> String? {
        if case let .tunneledHTTPS(host, port) = ingressMode {
            let uri = head.uri
            if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
                return uri
            }

            let hostHeader = head.headers.first(name: "Host")
            let authority: String = if let hostHeader, !hostHeader.isEmpty {
                hostHeader
            } else if port == 443 {
                host
            } else {
                "\(host):\(port)"
            }
            let path = uri.hasPrefix("/") ? uri : "/\(uri)"
            return "https://\(authority)\(path)"
        }

        let uri = head.uri
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return uri
        }

        guard let host = head.headers.first(name: "Host"), !host.isEmpty else {
            return nil
        }
        let path = uri.hasPrefix("/") ? uri : "/\(uri)"
        return "http://\(host)\(path)"
    }

    func sanitizedRequestHeaders(from headers: HTTPHeaders) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Connection")
        sanitized.remove(name: "Keep-Alive")
        sanitized.remove(name: "TE")
        sanitized.remove(name: "Trailer")
        sanitized.remove(name: "Transfer-Encoding")
        sanitized.remove(name: "Content-Length")
        return sanitized
    }

    func sanitizedStreamingRequestHeaders(from headers: HTTPHeaders) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Proxy-Authorization")
        sanitized.remove(name: "Host")
        sanitized.remove(name: "Content-Length")
        sanitized.remove(name: "Transfer-Encoding")
        return sanitized
    }

    func isWebSocketUpgrade(headers: HTTPHeaders) -> Bool {
        headerContainsToken("Connection", token: "upgrade", in: headers) &&
            headers[canonicalForm: "Upgrade"].contains(where: { $0.lowercased().contains("websocket") })
    }

    func webSocketPerMessageDeflateEnabled(headers: HTTPHeaders) -> Bool {
        headers[canonicalForm: "Sec-WebSocket-Extensions"].contains { value in
            value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(where: { $0.contains("permessage-deflate") })
        }
    }

    func isSSERequest(headers: HTTPHeaders) -> Bool {
        Self.isSSERequest(headers: headers)
    }

    static func isSSERequest(headers: HTTPHeaders) -> Bool {
        for acceptHeaderValue in headers[canonicalForm: "Accept"] {
            for rawToken in acceptHeaderValue.split(separator: ",", omittingEmptySubsequences: true) {
                let token = String(rawToken)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !token.isEmpty else { continue }
                let mimeType = token
                    .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? token
                if mimeType == "text/event-stream" {
                    return true
                }
            }
        }
        return false
    }

    func normalizedWebSocketURL(from url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        guard let scheme = components.scheme?.lowercased() else { return url }
        switch scheme {
        case "http":
            components.scheme = "ws"
            return components.string ?? url
        case "https":
            components.scheme = "wss"
            return components.string ?? url
        default:
            return url
        }
    }

    func normalizeWireBody(
        _ body: Data,
        headers: inout HTTPHeaders,
        compressionInfo: CompressionInfo?,
        direction: String
    ) -> Data {
        guard !body.isEmpty else { return body }
        guard let compressionInfo, compressionInfo.decompressionSuccess else { return body }
        guard let contentEncoding = headers.first(name: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !contentEncoding.isEmpty,
            contentEncoding.lowercased() != "identity"
        else {
            return body
        }

        let encodings = contentEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }

        guard !encodings.isEmpty else {
            headers.remove(name: "Content-Encoding")
            return body
        }

        var encodedBody = body
        for encoding in encodings {
            guard let compressed = CompressionHelper.compress(data: encodedBody, algorithm: encoding) else {
                headers.remove(name: "Content-Encoding")
                logConnectStage(
                    stage: "body_encoding_normalize",
                    outcome: "fallback_identity",
                    detail: "\(direction),encoding=\(contentEncoding),failed=\(encoding)"
                )
                eventLog?.append(
                    type: "proxy_nio_body_encoding_normalize",
                    msg: "mode=\(ingressModeLabel) id=\(connectionID) direction=\(direction) action=strip content_encoding=\(contentEncoding) failed=\(encoding)"
                )
                return body
            }
            encodedBody = compressed
        }

        logConnectStage(
            stage: "body_encoding_normalize",
            outcome: "recompressed",
            detail: "\(direction),encoding=\(contentEncoding),bytes=\(body.count)->\(encodedBody.count)"
        )
        eventLog?.append(
            type: "proxy_nio_body_encoding_normalize",
            msg: "mode=\(ingressModeLabel) id=\(connectionID) direction=\(direction) action=recompress content_encoding=\(contentEncoding) bytes_in=\(body.count) bytes_out=\(encodedBody.count)"
        )
        return encodedBody
    }

    func streamingResponseHeaders(
        from headers: HTTPHeaders,
        closeAfterSend: Bool
    ) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")

        if usesHTTP2StreamSemantics {
            sanitized.remove(name: "Connection")
            sanitized.remove(name: "Keep-Alive")
            sanitized.remove(name: "Transfer-Encoding")
            sanitized.remove(name: "Upgrade")
        } else if sanitized.first(name: "Connection") == nil {
            sanitized.add(name: "Connection", value: closeAfterSend ? "close" : "keep-alive")
        } else if closeAfterSend {
            sanitized.replaceOrAdd(name: "Connection", value: "close")
        }

        return sanitized
    }

    func sanitizedResponseHeaders(
        from headers: HTTPHeaders,
        bodyBytes: Int,
        closeAfterSend: Bool
    ) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Connection")
        sanitized.remove(name: "Keep-Alive")
        sanitized.remove(name: "Trailer")
        sanitized.remove(name: "Transfer-Encoding")
        sanitized.replaceOrAdd(name: "Content-Length", value: "\(bodyBytes)")
        if !usesHTTP2StreamSemantics {
            sanitized.replaceOrAdd(name: "Connection", value: closeAfterSend ? "close" : "keep-alive")
        }
        return sanitized
    }

    func shouldCloseConnection(requestHead: HTTPRequestHead, responseHeaders: HTTPHeaders) -> Bool {
        if headerContainsToken("Connection", token: "close", in: requestHead.headers) {
            return true
        }
        if headerContainsToken("Connection", token: "close", in: responseHeaders) {
            return true
        }

        if requestHead.version.major == 1, requestHead.version.minor == 0 {
            return !headerContainsToken("Connection", token: "keep-alive", in: requestHead.headers)
        }

        return false
    }

    func httpProtocolVersion(from version: HTTPVersion) -> HTTPProtocolVersion {
        switch version.major {
        case 1:
            version.minor == 0 ? .http10 : .http11
        case 2:
            .http2
        case 3:
            .http3
        default:
            .http11
        }
    }

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
        flowID: UUID,
        requestURL: String,
        methodToken: String,
        requestHeaders: [String: String],
        requestBodyData: Data,
        fallbackRequest: NetworkRequest,
        eventLoop: EventLoop
    ) -> EventLoopFuture<InterceptionResult> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(.modified(fallbackRequest))
        }

        let promise = eventLoop.makePromise(of: InterceptionResult.self)
        promise.completeWithTask { [fallbackRequest] in
            let result = await interceptor.interceptRequest(
                flowId: flowID,
                url: requestURL,
                method: methodToken,
                headers: requestHeaders,
                body: requestBodyData.isEmpty ? nil : requestBodyData
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

    func makeOutboundRequestContext(from request: NetworkRequest, fallbackBody: Data) -> OutboundRequestContext? {
        let methodToken = request.requestMethodRaw ?? request.method.rawValue
        let requestHeaders = dictionary(from: request.requestHeaders)
        let requestBodyData = request.requestBody.getData()
            ?? request.requestBody.getString()?.data(using: .utf8)
            ?? fallbackBody
        guard URL(string: request.url) != nil else {
            return nil
        }

        return OutboundRequestContext(
            requestSnapshot: request,
            methodToken: methodToken,
            url: request.url,
            headers: requestHeaders,
            body: requestBodyData
        )
    }

    func makeBaseNetworkRequest(
        flowID: UUID,
        requestURL: String,
        methodToken: String,
        requestHeaders: [String: String],
        requestBodyData: Data,
        startTime: Date,
        captureConfig: CaptureConfiguration
    ) -> NetworkRequest {
        let uppercasedMethod = methodToken.uppercased()
        let mappedMethod = HTTPMethod(rawValue: uppercasedMethod) ?? .get
        let methodRaw = HTTPMethod(rawValue: uppercasedMethod) == nil ? methodToken : nil
        let traceHeaders = captureConfig.captureHeaders ? traceHeaders(from: requestHeaders) : []
        let requestCharset = BodyStorage.extractCharset(from: requestHeaders)
        let requestContentEncoding = requestHeaders.first(where: { $0.key.lowercased() == "content-encoding" })?.value
        let requestBody = bodyStorage(
            from: requestBodyData,
            charset: requestCharset,
            contentEncoding: requestContentEncoding,
            captureConfig: captureConfig
        )
        var request = NetworkRequest(
            id: flowID,
            url: requestURL,
            method: mappedMethod,
            requestMethodRaw: methodRaw,
            statusCode: nil,
            statusMessage: nil,
            timestamp: startTime,
            duration: 0,
            requestHeaders: traceHeaders,
            responseHeaders: [],
            requestBody: requestBody,
            responseBody: .empty,
            protocolVersion: usesHTTP2StreamSemantics ? .http2 : nil
        )
        annotateCaptureMetadata(&request)
        return request
    }

    func bodyStorage(
        from data: Data,
        charset: String?,
        contentEncoding: String?,
        captureConfig: CaptureConfiguration,
        decodeCompressedContent: Bool = true
    ) -> BodyStorage {
        guard captureConfig.captureBody, captureConfig.maxBodySize > 0, !data.isEmpty else { return .empty }
        return BodyStorage.from(
            data: data,
            charset: charset,
            maxSize: max(0, captureConfig.maxBodySize),
            contentEncoding: contentEncoding,
            decodeCompressedContent: decodeCompressedContent
        )
    }

    func contentLength(from headers: HTTPHeaders) -> Int? {
        guard let rawValue = headers.first(name: "Content-Length") else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentLength = Int(trimmed), contentLength >= 0 else { return nil }
        return contentLength
    }

    func resolvedResponseBodyBytes(
        declaredContentLength: Int?,
        observedBodyBytes: Int
    ) -> Int {
        if let declaredContentLength, declaredContentLength >= 0 {
            return max(declaredContentLength, observedBodyBytes)
        }
        return observedBodyBytes
    }

    func truncatedBodyStorage(
        fromCapturedData capturedData: Data,
        totalSize: Int,
        charset: String?,
        contentEncoding: String?,
        decodeCompressedContent: Bool,
        maxStoredBodyBytes: Int = Int.max
    ) -> BodyStorage {
        guard !capturedData.isEmpty else { return .empty }
        let effectiveMaxStoredBodyBytes = maxStoredBodyBytes > 0 ? maxStoredBodyBytes : Int.max

        let capturedStorage = BodyStorage.from(
            data: capturedData,
            charset: charset,
            maxSize: effectiveMaxStoredBodyBytes,
            contentEncoding: contentEncoding,
            decodeCompressedContent: decodeCompressedContent
        )

        switch capturedStorage {
        case let .inline(data, capturedCharset, compressionInfo):
            return .truncated(
                data,
                totalSize: max(totalSize, data.count),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .file(url, capturedCharset, compressionInfo):
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? capturedData.count
            return .truncatedFile(
                url,
                totalSize: max(totalSize, fileSize),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .truncated(data, capturedTotalSize, capturedCharset, compressionInfo):
            return .truncated(
                data,
                totalSize: max(totalSize, max(capturedTotalSize, data.count)),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .truncatedFile(url, capturedTotalSize, capturedCharset, compressionInfo):
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? capturedData.count
            return .truncatedFile(
                url,
                totalSize: max(totalSize, max(capturedTotalSize, fileSize)),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case .empty:
            return .empty
        }
    }

    func transitionAfterResponse(
        closeAfterSend: Bool,
        context: ChannelHandlerContext
    ) {
        let shouldEmitPipeliningBadRequest = shouldCloseAfterForwardingResponse && !closeAfterSend
        if shouldEmitPipeliningBadRequest {
            logConnectStage(
                stage: "request_pipelining",
                outcome: "emit_400_after_response",
                detail: "reason=unsupported"
            )
        }
        shouldCloseAfterForwardingResponse = false
        if shouldEmitPipeliningBadRequest {
            state = .closed
            sendResponse(
                status: .badRequest,
                body: "HTTP request pipelining is not supported by the NIO engine yet",
                closeAfterSend: true,
                context: context
            )
            return
        }

        state = closeAfterSend ? .closed : .waitingForRequest
        if closeAfterSend {
            context.close(promise: nil)
        }
    }

    func logResponseCaptureDecision(
        pipeline: String,
        requestID: UUID,
        statusCode: Int?,
        responseHeaders: [TraceHTTPHeader],
        bodyStorage: BodyStorage,
        observedBodyBytes: Int,
        declaredContentLength: Int?,
        captureBodyEnabled: Bool,
        captureBodyLimit: Int,
        decodeCompressedContent: Bool,
        storageContentEncoding: String?
    ) {
        let hostHash = connectTargetHost.map { LogRedaction.hash($0) } ?? "unknown"
        let statusToken = statusCode.map(String.init) ?? "nil"
        let declaredContentLengthToken = declaredContentLength.map(String.init) ?? "nil"
        let contentType = responseHeaderValue(name: "content-type", in: responseHeaders)
        let headerContentEncoding = responseHeaderValue(name: "content-encoding", in: responseHeaders)
        let transferEncoding = responseHeaderValue(name: "transfer-encoding", in: responseHeaders)
        let compressionInfo = bodyStorage.getCompressionInfo()
        let decompressionState = if let compressionInfo {
            compressionInfo.decompressionSuccess ? "success" : "failed"
        } else {
            "none"
        }
        let previewHint = responsePreviewHint(
            contentType: contentType,
            headerContentEncoding: headerContentEncoding,
            decodeCompressedContent: decodeCompressedContent,
            compressionInfo: compressionInfo
        )
        let responseUIRenderHint = responseUIRenderHint(previewHint: previewHint)
        var messageParts = [
            "mode=\(ingressModeLabel)",
            "id=\(connectionID)",
            "host_hash=\(hostHash)",
            "request_id=\(requestID.uuidString)",
            "capture_path=\(capturePathForCurrentContext().rawValue)",
            "pipeline=\(pipeline)",
            "status=\(statusToken)",
            "capture_body=\(captureBodyEnabled)",
            "capture_limit=\(max(0, captureBodyLimit))",
            "observed_bytes=\(max(0, observedBodyBytes))",
            "declared_content_length=\(declaredContentLengthToken)",
            "storage=\(bodyStorageKindToken(bodyStorage))",
            "stored_total_bytes=\(bodyStorage.totalSize)",
            "stored_captured_bytes=\(bodyStorage.capturedSize)",
            "stored_truncated=\(bodyStorage.isTruncated)",
            "stored_file=\(bodyStorage.isFile)",
            "charset=\(normalizedToken(bodyStorage.getCharset()))",
            "header_content_type=\(normalizedContentTypeToken(contentType))",
            "header_content_encoding=\(normalizedHeaderListToken(headerContentEncoding))",
            "storage_content_encoding=\(normalizedHeaderListToken(storageContentEncoding))",
            "transfer_encoding=\(normalizedHeaderListToken(transferEncoding))",
            "decode_compressed=\(decodeCompressedContent)",
            "compression_algorithm=\(normalizedHeaderListToken(compressionInfo?.algorithm))",
            "decompression=\(decompressionState)",
            "preview_hint=\(previewHint)",
            "ui_render_hint=\(responseUIRenderHint)"
        ]
        if let flowID = upstreamHint?.flowID {
            messageParts.append("capture_flow_id=\(flowID)")
        }
        if let metadataVersion = upstreamHint?.version.rawValue {
            messageParts.append("capture_metadata_version=\(metadataVersion)")
        }
        let message = messageParts.joined(separator: " ")

        ProxyLog.mitm.debug("event=proxy.nio_response_capture \(message, privacy: .public)")
        eventLog?.append(type: "proxy_nio_response_capture", msg: message)
    }

    func responseHeaderValue(name: String, in headers: [TraceHTTPHeader]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func bodyStorageKindToken(_ storage: BodyStorage) -> String {
        switch storage {
        case .inline:
            "inline"
        case .file:
            "file"
        case .truncated:
            "truncated"
        case .truncatedFile:
            "truncated_file"
        case .empty:
            "empty"
        }
    }

    func normalizedToken(_ value: String?) -> String {
        guard let value else { return "none" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        return trimmed.lowercased()
            .replacingOccurrences(of: "\t", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    func normalizedHeaderListToken(_ value: String?) -> String {
        guard let value else { return "none" }
        let tokens = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "none" }
        return tokens.joined(separator: "+")
    }

    func normalizedContentTypeToken(_ value: String?) -> String {
        guard let value else { return "none" }
        let mimeType = value
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedToken(mimeType.map { String($0) })
    }

    func responsePreviewHint(
        contentType: String?,
        headerContentEncoding: String?,
        decodeCompressedContent: Bool,
        compressionInfo: CompressionInfo?
    ) -> String {
        let normalizedContentEncoding = normalizedHeaderListToken(headerContentEncoding)
        if !decodeCompressedContent,
           normalizedContentEncoding != "none",
           normalizedContentEncoding != "identity" {
            return "compressed_raw_passthrough"
        }
        if let compressionInfo, !compressionInfo.decompressionSuccess {
            return "decompression_failed"
        }
        let contentTypeToken = normalizedContentTypeToken(contentType)
        if isLikelyTextContentType(contentTypeToken) {
            return "text_candidate"
        }
        if contentTypeToken == "none" {
            return "unknown_mime"
        }
        return "binary_candidate"
    }

    func responseUIRenderHint(previewHint: String) -> String {
        switch previewHint {
        case "text_candidate":
            "text"
        case "decompression_failed":
            "hex_fallback"
        case "compressed_raw_passthrough", "binary_candidate", "unknown_mime":
            "hex"
        default:
            "auto"
        }
    }

    func isLikelyTextContentType(_ contentTypeToken: String) -> Bool {
        if contentTypeToken.hasPrefix("text/") {
            return true
        }
        let textMarkers = [
            "json",
            "xml",
            "javascript",
            "x-www-form-urlencoded",
            "graphql",
            "yaml",
            "toml",
            "csv"
        ]
        return textMarkers.contains { contentTypeToken.contains($0) }
    }

    func annotateCaptureMetadata(_ request: inout NetworkRequest) {
        request.capturePath = capturePathForCurrentContext()
        request.captureFlowID = upstreamHint?.flowID
        request.capturePolicyModeRaw = upstreamHint?.policyModeRaw
        request.captureMetadataVersion = upstreamHint?.version.rawValue
    }

    func capturePathForCurrentContext() -> NetworkCapturePath {
        switch ingressMode {
        case .proxy:
            upstreamHint == nil ? .proxy : .proxyWithUpstreamHint
        case .tunneledHTTPS:
            upstreamHint == nil ? .tunneledHTTPS : .tunneledHTTPSWithUpstreamHint
        }
    }

    func finalizeCapturedDuration(for request: inout NetworkRequest) {
        let elapsed = Date().timeIntervalSince(request.timestamp)
        guard elapsed.isFinite else { return }
        request.duration = max(request.duration, max(0, elapsed))
    }

    func throttle(
        direction: PacketThrottler.Direction,
        bytes: Int,
        context: ChannelHandlerContext,
        operation: @escaping () -> Void
    ) {
        guard let throttler, bytes > 0 else {
            operation()
            return
        }
        let markerBytes = min(max(bytes, 1), 64 * 1024)
        let marker = Data(repeating: 0, count: markerBytes)
        throttler.process(packet: marker, direction: direction) {
            context.eventLoop.execute {
                operation()
            }
        }
    }

    func mitmHost() -> String? {
        if let connectTargetHost, !connectTargetHost.isEmpty {
            return connectTargetHost
        }
        switch ingressMode {
        case .proxy:
            return nil
        case let .tunneledHTTPS(host, _):
            return host
        }
    }

    var ingressModeLabel: String {
        switch ingressMode {
        case .proxy:
            "proxy"
        case .tunneledHTTPS:
            "tunneled_https"
        }
    }

    func logConnectStage(stage: String, outcome: String, detail: String? = nil) {
        guard let host = connectTargetHost, let port = connectTargetPort else { return }
        let hostHash = LogRedaction.hash(host)
        let stateLabel = String(describing: state)
        let detailText = detail.flatMap { $0.isEmpty ? nil : $0 }

        if let detailText {
            ProxyLog.mitm.debug(
                "event=proxy.nio_connect_stage stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public) mode=\(self.ingressModeLabel, privacy: .public) id=\(self.connectionID, privacy: .public) host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) state=\(stateLabel, privacy: .public) detail=\(detailText, privacy: .public)"
            )
            eventLog?.append(
                type: "proxy_nio_connect_stage",
                msg: "stage=\(stage) outcome=\(outcome) mode=\(self.ingressModeLabel) id=\(self.connectionID) host_hash=\(hostHash) port=\(port) state=\(stateLabel) detail=\(detailText)"
            )
            return
        }

        ProxyLog.mitm.debug(
            "event=proxy.nio_connect_stage stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public) mode=\(self.ingressModeLabel, privacy: .public) id=\(self.connectionID, privacy: .public) host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) state=\(stateLabel, privacy: .public)"
        )
        eventLog?.append(
            type: "proxy_nio_connect_stage",
            msg: "stage=\(stage) outcome=\(outcome) mode=\(self.ingressModeLabel) id=\(self.connectionID) host_hash=\(hostHash) port=\(port) state=\(stateLabel)"
        )
    }

    func reportMITMFailure(host: String, reason: String) {
        onMITMFailure?(host, reason)
    }

    func reportMITMFailure(reason: String) {
        guard let host = mitmHost() else {
            ProxyLog.mitm.debug(
                "event=proxy.mitm_failure_unattributed outcome=ignored mode=\(self.ingressModeLabel, privacy: .public) id=\(self.connectionID, privacy: .public) reason=\(reason, privacy: .public)"
            )
            eventLog?.append(
                type: "mitm_failure_unattributed",
                msg: "mode=\(self.ingressModeLabel) id=\(self.connectionID) reason=\(reason)"
            )
            return
        }
        onMITMFailure?(host, reason)
    }

    func logUpstreamHTTPFailure(error: Error, methodToken: String, targetHost: String) {
        let classifiedFailure = classifyMITMFailure(error)
        if classifiedFailure == "upstream_cancelled" {
            logConnectStage(stage: "http_upstream", outcome: "ignored", detail: error.localizedDescription)
            ProxyLog.mitm.info(
                "event=proxy.nio_http_upstream outcome=ignored method=\(methodToken, privacy: .public) host=\(targetHost, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public) classified=\(classifiedFailure, privacy: .public) deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds, privacy: .public)"
            )
            eventLog?.append(
                type: "proxy_nio_http_upstream_ignored",
                msg: "method=\(methodToken) host_hash=\(LogRedaction.hash(targetHost)) error=\(error.localizedDescription) classified=\(classifiedFailure) deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds)"
            )
            return
        }

        reportMITMFailure(reason: classifiedFailure)
        logConnectStage(stage: "http_upstream", outcome: "failure", detail: error.localizedDescription)
        ProxyLog.mitm.warning(
            "event=proxy.nio_http_upstream outcome=failure method=\(methodToken, privacy: .public) host=\(targetHost, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public) classified=\(classifiedFailure, privacy: .public) deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds, privacy: .public)"
        )
        eventLog?.append(
            type: "proxy_nio_http_upstream_failure",
            msg: "method=\(methodToken) host_hash=\(LogRedaction.hash(targetHost)) error=\(error.localizedDescription) classified=\(classifiedFailure) deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds)"
        )
    }

    func classifyMITMFailure(_ error: Error) -> String {
        if let classified = classifyTypedMITMFailure(error) {
            return classified
        }

        if let classified = classifyNSErrorMITMFailure(error as NSError) {
            return classified
        }

        if let underlying = underlyingError(from: error),
           let classified = classifyTypedMITMFailure(underlying) {
            return classified
        }

        if let underlying = underlyingError(from: error),
           let classified = classifyNSErrorMITMFailure(underlying as NSError) {
            return classified
        }

        let detail = error.localizedDescription.lowercased()
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return "upstream_timeout"
            case NSURLErrorCancelled:
                return "upstream_cancelled"
            default:
                break
            }
        }

        if detail.contains("timed out") || detail.contains("timeout") || detail.contains("deadline") {
            return "upstream_timeout"
        }
        if detail.contains("cancelled") || detail.contains("canceled") {
            return "upstream_cancelled"
        }
        if detail.contains("httpparsererror") {
            return "mitm_non_http_protocol"
        }
        if detail.contains("httpclienterror error 1") {
            return "possible_pinning_or_strict_trust: \(error.localizedDescription)"
        }
        if detail.contains("connection reset") ||
            detail.contains("connection closed") ||
            detail.contains("remote closed") ||
            detail.contains("channelerror error 5") ||
            detail.contains("nwerror error 54") ||
            detail.contains("streamclosed") {
            return "upstream_connection_closed"
        }
        if detail.contains("hostname") && detail.contains("mismatch") {
            return "tls_upstream_hostname_mismatch"
        }
        if detail.contains("failedtovalidatehostname") {
            return "tls_upstream_hostname_mismatch"
        }
        if detail.contains("certificate") ||
            detail.contains("trust") ||
            detail.contains("x509") ||
            detail.contains("unabletovalidatecertificate") {
            return "tls_upstream_trust_failed"
        }
        if detail.contains("tls") && detail.contains("handshake") {
            return "tls_upstream_handshake_failed"
        }
        return "upstream_transport_error: \(error.localizedDescription)"
    }

    func classifyClientHandlerFailure(_ error: Error) -> (reason: String, shouldReport: Bool) {
        let classifiedFailure = classifyMITMFailure(error)
        guard classifiedFailure == "upstream_connection_closed",
              isTLSUncleanShutdown(error)
        else {
            return (classifiedFailure, true)
        }
        // Client channels frequently close TLS without close_notify during retries/preconnects.
        // Do not treat that as an upstream MITM failure (it would incorrectly trigger auto-bypass).
        return ("client_connection_closed", false)
    }

    func isTLSUncleanShutdown(_ error: Error) -> Bool {
        if let sslError = error as? NIOSSLError,
           sslError == .uncleanShutdown {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "NIOSSL.NIOSSLError",
           nsError.code == 12 {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTLSUncleanShutdown(underlying)
        }
        return false
    }

    func classifyNSErrorMITMFailure(_ nsError: NSError) -> String? {
        if nsError.domain == "NIOSSL.NIOSSLError" {
            switch nsError.code {
            case 12:
                // `uncleanShutdown`: common for servers that close TLS without close_notify.
                return "upstream_connection_closed"
            case 7:
                return "tls_upstream_hostname_mismatch"
            case 8, 9:
                return "tls_upstream_trust_failed"
            default:
                return nil
            }
        }

        return nil
    }

    func classifyTypedMITMFailure(_ error: Error) -> String? {
        if let sslError = error as? NIOSSLError {
            switch sslError {
            case .uncleanShutdown:
                return "upstream_connection_closed"
            case .noCertificateToValidate, .unableToValidateCertificate:
                return "tls_upstream_trust_failed"
            case .cannotMatchULabel:
                return "tls_upstream_hostname_mismatch"
            case let .handshakeFailed(sslDetail), let .shutdownFailed(sslDetail):
                if let classified = classifyTLSStackDescription(String(describing: sslDetail).lowercased()) {
                    return classified
                }
                return "tls_upstream_handshake_failed"
            default:
                break
            }
        }

        if let sslExtraError = error as? NIOSSLExtraError {
            if sslExtraError == .failedToValidateHostname ||
                sslExtraError == .serverHostnameImpossibleToMatch ||
                sslExtraError == .cannotUseIPAddressInSNI ||
                sslExtraError == .invalidSNIHostname {
                return "tls_upstream_hostname_mismatch"
            }
        }

        if let httpClientError = error as? HTTPClientError {
            if httpClientError == .readTimeout ||
                httpClientError == .writeTimeout ||
                httpClientError == .connectTimeout ||
                httpClientError == .tlsHandshakeTimeout ||
                httpClientError == .socksHandshakeTimeout ||
                httpClientError == .httpProxyHandshakeTimeout ||
                httpClientError == .deadlineExceeded ||
                httpClientError == .getConnectionFromPoolTimeout {
                return "upstream_timeout"
            }

            if httpClientError == .cancelled || httpClientError == .requestStreamCancelled {
                return "upstream_cancelled"
            }

            if httpClientError == .remoteConnectionClosed || httpClientError == .uncleanShutdown {
                return "upstream_connection_closed"
            }
        }

        return nil
    }

    func classifyTLSStackDescription(_ detail: String) -> String? {
        if detail.contains("hostname") && detail.contains("mismatch") {
            return "tls_upstream_hostname_mismatch"
        }
        if detail.contains("x509") ||
            detail.contains("certificate") ||
            detail.contains("verify") ||
            detail.contains("trust") {
            return "tls_upstream_trust_failed"
        }
        return nil
    }

    func underlyingError(from error: Error) -> Error? {
        let nsError = error as NSError
        return nsError.userInfo[NSUnderlyingErrorKey] as? Error
    }

    func emitConnectMarker(host: String, port: Int, note: String, startTime: Date? = nil) {
        guard let onRequestCaptured else { return }

        let markerTimestamp = startTime ?? Date()
        let elapsed = max(0, Date().timeIntervalSince(markerTimestamp))
        let connectURL = "https://\(host):\(port)"
        var marker = NetworkRequest(
            id: UUID(),
            url: connectURL,
            method: .connect,
            statusCode: 200,
            statusMessage: "CONNECT established",
            timestamp: markerTimestamp,
            duration: elapsed,
            requestHeaders: [TraceHTTPHeader(key: "Host", value: "\(host):\(port)")],
            responseHeaders: [TraceHTTPHeader(key: "X-Trace-Note", value: note)],
            requestBody: .empty,
            responseBody: .empty
        )
        annotateCaptureMetadata(&marker)
        marker.extractHTTPFields()
        NetworkThrottlingController.shared.applyMetadata(to: &marker)
        onRequestCaptured(marker)
    }

    func headerContainsToken(_ headerName: String, token: String, in headers: HTTPHeaders) -> Bool {
        headers[canonicalForm: headerName].contains { value in
            value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(token.lowercased())
        }
    }

    func dictionary(from headers: HTTPHeaders) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            result[header.name] = header.value
        }
        return result
    }

    func dictionary(from headers: [TraceHTTPHeader]) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            result[header.key] = header.value
        }
        return result
    }

    func traceHeaders(from headers: HTTPHeaders) -> [TraceHTTPHeader] {
        headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) }
    }

    func traceHeaders(from headers: [String: String]) -> [TraceHTTPHeader] {
        headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
    }

    func makeHTTPHeaders(from headers: [String: String]) -> HTTPHeaders {
        var result = HTTPHeaders()
        for (key, value) in headers {
            result.add(name: key, value: value)
        }
        return result
    }

    func makeHTTPHeaders(from headers: [TraceHTTPHeader]) -> HTTPHeaders {
        var result = HTTPHeaders()
        for header in headers {
            result.add(name: header.key, value: header.value)
        }
        return result
    }

    func byteBuffer(from data: Data, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func byteBufferToData(_ buffer: ByteBuffer) -> Data {
        var mutableBuffer = buffer
        return mutableBuffer.readData(length: mutableBuffer.readableBytes) ?? Data()
    }
}
