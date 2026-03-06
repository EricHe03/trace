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
                   responseContentType.lowercased().contains("text/event-stream") {
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

}
