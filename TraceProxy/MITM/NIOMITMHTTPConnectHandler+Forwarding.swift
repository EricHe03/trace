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
            finalizeActiveRequestAsHTTPFailure(
                status: .internalServerError,
                reason: "nio_runtime_unavailable"
            )
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
        case .grpc:
            forwardGRPCWebStream(
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
            finalizeActiveRequestAsHTTPFailure(
                status: .badRequest,
                reason: "invalid_outbound_request"
            )
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
                        self.requestSentAt = Date()
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
                                    self.responseHeadAt = Date()
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
                                    let declaredContentLength = self.contentLength(from: forwardedHeaders)
                                    let captureConfig = self.captureConfigProvider()
                                    var captured = outboundContext.requestSnapshot
                                    captured.protocolVersion = self.mergedCapturedProtocolVersion(
                                        current: captured.protocolVersion,
                                        fallback: response.version
                                    )
                                    captured.statusCode = Int(response.status.code)
                                    captured.statusMessage = response.status.reasonPhrase
                                    captured.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                                    let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                                    let responseContentType = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-type" })?.value
                                    let responseContentEncoding = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                                    let effectiveCaptureBodyLimit = self.effectiveBodyCaptureLimit(
                                        captureConfig: captureConfig,
                                        contentType: responseContentType,
                                        contentEncoding: responseContentEncoding
                                    )
                                    // Optimization: Pass ByteBuffer directly to avoid intermediate Data conversion
                                    let responseBodyBuffer = response.body ?? ByteBuffer()
                                    captured.responseBody = self.bodyStorage(
                                        from: responseBodyBuffer,
                                        charset: responseCharset,
                                        contentType: responseContentType,
                                        contentEncoding: responseContentEncoding,
                                        captureConfig: captureConfig
                                    )
                                    let responseBodyData = self.byteBufferToData(responseBodyBuffer)
                                    if captured.isGRPC {
                                        let ct = responseContentType ?? ""
                                        if GRPCTrailerExtractor.isGRPCWeb(contentType: ct) {
                                            captured.grpcMetadata = GRPCTrailerExtractor.extractFromWebBody(
                                                responseBody: responseBodyData, contentType: ct)
                                        } else {
                                            captured.grpcMetadata = GRPCTrailerExtractor.extract(from: forwardedHeaders)
                                        }
                                        // Request-header-derived fields
                                        captured.grpcMetadata?.timeout = outboundHeaders["grpc-timeout"].first
                                        captured.grpcMetadata?.acceptEncoding = outboundHeaders["grpc-accept-encoding"].first
                                        if captured.grpcMetadata?.statusDetailsBin == nil {
                                            captured.grpcMetadata?.statusDetailsBin = forwardedHeaders["grpc-status-details-bin"].first
                                        }
                                        // Message counts
                                        captured.grpcMetadata?.requestMessageCount = GRPCTrailerExtractor.countMessages(in: outboundBodyData)
                                        let isGRPCWebText = GRPCTrailerExtractor.isGRPCWebText(contentType: ct)
                                        captured.grpcMetadata?.responseMessageCount = isGRPCWebText
                                            ? GRPCTrailerExtractor.countMessagesInGRPCWebText(in: responseBodyData)
                                            : GRPCTrailerExtractor.countMessages(in: responseBodyData)
                                    }
                                    self.logResponseCaptureDecision(
                                        pipeline: "buffer_and_intercept",
                                        requestID: captured.id,
                                        statusCode: Int(response.status.code),
                                        responseHeaders: responseHeadersTrace,
                                        bodyStorage: captured.responseBody,
                                        observedBodyBytes: responseBodyData.count,
                                        declaredContentLength: declaredContentLength,
                                        captureBodyEnabled: captureConfig.captureBody,
                                        captureBodyLimit: effectiveCaptureBodyLimit,
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
                                    let failureReason = self.classifyMITMFailure(error)
                                    self.finalizeActiveRequestAsHTTPFailure(
                                        status: .badGateway,
                                        reason: failureReason
                                    )
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
        // gRPC-Web: POST request with application/grpc-web* content-type.
        let contentType = headers["content-type"].first ?? ""
        if requestHead.method == .POST, GRPCTrailerExtractor.isGRPCWeb(contentType: contentType) {
            return .grpc
        }
        return .none
    }

    func forwardSSEStream(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        let flowController = StreamFlowController(connectHandler: self)
        flowController.forwardSSE(
            outboundContext,
            requestHead: requestHead,
            outboundHeaders: outboundHeaders,
            context: context
        )
    }

    func forwardWebSocketStream(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        let flowController = StreamFlowController(connectHandler: self)
        flowController.forwardWebSocket(
            outboundContext,
            requestHead: requestHead,
            outboundHeaders: outboundHeaders,
            context: context
        )
    }

    func forwardGRPCWebStream(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        let flowController = StreamFlowController(connectHandler: self)
        flowController.forwardGRPCWeb(
            outboundContext,
            requestHead: requestHead,
            outboundHeaders: outboundHeaders,
            context: context
        )
    }

    func forwardSSEStreamTransport(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext,
        streamRuntime: StreamSessionRuntime
    ) {
        guard let targetURL = URL(string: outboundContext.url),
              let targetHost = targetURL.host
        else {
            finalizeActiveRequestAsHTTPFailure(
                status: .badRequest,
                reason: "invalid_sse_request_target"
            )
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
            finalizeActiveRequestAsHTTPFailure(
                status: .badRequest,
                reason: "invalid_sse_request_headers"
            )
            sendResponse(status: .badRequest, body: "Invalid SSE request headers", closeAfterSend: true, context: context)
            return
        }
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)

        // Apply host override before connecting: use the overridden IP while keeping
        // targetHost for TLS SNI and the HTTP Host header.
        let capturedURL = outboundContext.url
        let capturedHost = targetHost
        let capturedPort = targetPort
        Task { [weak self, capturedURL, capturedHost, capturedPort, sendableContext, streamingRequestHead, requestHead] in
            guard let self else { return }
            let override = await RequestInterceptor.shared.hostOverride(for: capturedURL)
            let connectHost = override?.ip ?? capturedHost
            let connectPort = override?.port ?? capturedPort
            if let override {
                ProxyLog.mitm.info(
                    "event=proxy.sse_host_override outcome=applied original_host=\(capturedHost, privacy: .private(mask: .hash)) override_ip=\(override.ip, privacy: .private(mask: .hash)) url=\(capturedURL, privacy: .private(mask: .hash))"
                )
            }
            let bootstrap = NIOTSConnectionBootstrap(group: self.group)
            bootstrap.connect(host: connectHost, port: connectPort).whenComplete { [weak self] result in
                let context = sendableContext.value
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
                                    streamRuntime.updateResponseHeaders(
                                        self.captureConfigProvider().captureHeaders
                                            ? self.traceHeaders(from: head.headers)
                                            : []
                                    )
                                    streamRuntime.setStatus(.streaming)
                                    self.persistStreamRuntimeSnapshot(streamRuntime)
                                    var forwardedHead = head
                                    forwardedHead.headers.remove(name: "Proxy-Connection")
                                    context.write(self.wrapOutboundOut(.head(forwardedHead)), promise: nil)
                                case let .body(buffer):
                                    let chunkData = self.byteBufferToData(buffer)
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
                                            eventRecorder: { [weak self] event in
                                                guard let self else { return }
                                                self.persistStreamEvent(
                                                    event,
                                                    runtime: streamRuntime,
                                                    countPayloadBytes: false
                                                )
                                            },
                                            replayEngine: .shared,
                                            eventLoop: context.eventLoop
                                        )
                                    }.flatMap { forwardedChunk in
                                        if !forwardedChunk.isEmpty {
                                            streamRuntime.recordTransferredBytes(
                                                direction: .received,
                                                count: forwardedChunk.count
                                            )
                                            self.persistStreamRuntimeSnapshot(streamRuntime)
                                        }
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
                                        let failureReason = self.classifyMITMFailure(error)
                                        self.finalizeActiveRequestAsFailure(reason: failureReason)
                                        self.reportMITMFailure(reason: failureReason)
                                        self.completeStreamRuntime(
                                            streamRuntime,
                                            status: .failed,
                                            reason: error.localizedDescription,
                                            eventLoop: context.eventLoop
                                        )
                                    }
                                case let .end(trailers):
                                    bodyRelayChain.flatMap {
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
                                        let failureReason = self.classifyMITMFailure(error)
                                        self.finalizeActiveRequestAsFailure(reason: failureReason)
                                        self.reportMITMFailure(reason: failureReason)
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
                                let failureReason = self.classifyMITMFailure(error)
                                self.finalizeActiveRequestAsHTTPFailure(
                                    status: .badGateway,
                                    reason: failureReason
                                )
                                self.reportMITMFailure(reason: failureReason)
                                ProxyLog.mitm.warning(
                                    "event=proxy.nio_sse_upstream_error outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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
                                let failureReason = self.classifyMITMFailure(error)
                                self.finalizeActiveRequestAsHTTPFailure(
                                    status: .badGateway,
                                    reason: failureReason
                                )
                                self.reportMITMFailure(reason: failureReason)
                                ProxyLog.mitm.warning(
                                    "event=proxy.nio_sse_setup outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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
                        let failureReason = self.classifyMITMFailure(error)
                        self.finalizeActiveRequestAsHTTPFailure(
                            status: .badGateway,
                            reason: failureReason
                        )
                        self.reportMITMFailure(reason: failureReason)
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
        } // end Task (host override + connect)
    }

    func forwardGRPCWebStreamTransport(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext,
        streamRuntime: StreamSessionRuntime
    ) {
        guard let targetURL = URL(string: outboundContext.url),
              let targetHost = targetURL.host
        else {
            finalizeActiveRequestAsHTTPFailure(status: .badRequest, reason: "invalid_grpc_request_target")
            sendResponse(status: .badRequest, body: "Invalid gRPC request target", closeAfterSend: true, context: context)
            return
        }
        let targetPort = targetURL.port ?? ((targetURL.scheme?.lowercased() == "https") ? 443 : 80)
        var requestHeaders = sanitizedStreamingRequestHeaders(from: outboundHeaders)
        // gRPC-Web requires the HTTP transport not to apply content encoding on its own.
        requestHeaders.remove(name: "Accept-Encoding")
        requestHeaders.replaceOrAdd(name: "Accept-Encoding", value: "identity")
        guard let streamingRequestHead = makeStreamingUpstreamRequestHead(
            url: targetURL,
            methodToken: outboundContext.methodToken,
            headers: requestHeaders
        ) else {
            finalizeActiveRequestAsHTTPFailure(status: .badRequest, reason: "invalid_grpc_request_headers")
            sendResponse(status: .badRequest, body: "Invalid gRPC request headers", closeAfterSend: true, context: context)
            return
        }
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)
        let capturedURL = outboundContext.url
        let capturedHost = targetHost
        let capturedPort = targetPort
        Task { [weak self, capturedURL, capturedHost, capturedPort, sendableContext, streamingRequestHead, requestHead] in
            guard let self else { return }
            let override = await RequestInterceptor.shared.hostOverride(for: capturedURL)
            let connectHost = override?.ip ?? capturedHost
            let connectPort = override?.port ?? capturedPort
            let bootstrap = NIOTSConnectionBootstrap(group: self.group)
            bootstrap.connect(host: connectHost, port: connectPort).whenComplete { [weak self] result in
                let context = sendableContext.value
                context.eventLoop.execute {
                    guard let self, self.state == .forwardingHTTPRequest else {
                        if case let .success(upstream) = result { upstream.close(promise: nil) }
                        return
                    }
                    switch result {
                    case let .success(upstream):
                        self.upstreamChannel = upstream
                        var closeAfterSend = false
                        var responseHeadSeen = false
                        let grpcInterceptionRuntime = GRPCStreamInterceptionRuntime()
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
                                    streamRuntime.updateResponseHeaders(
                                        self.captureConfigProvider().captureHeaders
                                            ? self.traceHeaders(from: head.headers) : []
                                    )
                                    streamRuntime.setStatus(.streaming)
                                    self.persistStreamRuntimeSnapshot(streamRuntime)
                                    var forwardedHead = head
                                    forwardedHead.headers.remove(name: "Proxy-Connection")
                                    context.write(self.wrapOutboundOut(.head(forwardedHead)), promise: nil)
                                case let .body(buffer):
                                    let chunkData = self.byteBufferToData(buffer)
                                    bodyRelayChain = bodyRelayChain.flatMap {
                                        grpcInterceptionRuntime.interceptChunk(
                                            chunkData,
                                            runtime: streamRuntime,
                                            decisionProvider: { [weak self] session, event, eventLoop in
                                                guard let self else { return eventLoop.makeSucceededFuture(.forward) }
                                                return self.streamEventInterceptionFuture(
                                                    session: session, event: event, eventLoop: eventLoop)
                                            },
                                            eventRecorder: { [weak self] event in
                                                guard let self else { return }
                                                self.persistStreamEvent(event, runtime: streamRuntime, countPayloadBytes: true)
                                            },
                                            replayEngine: .shared,
                                            eventLoop: context.eventLoop
                                        )
                                    }.flatMap { forwardedChunk in
                                        if !forwardedChunk.isEmpty {
                                            streamRuntime.recordTransferredBytes(direction: .received, count: forwardedChunk.count)
                                            self.persistStreamRuntimeSnapshot(streamRuntime)
                                        }
                                        guard !forwardedChunk.isEmpty else { return context.eventLoop.makeSucceededVoidFuture() }
                                        let forwardedBuffer = self.byteBuffer(from: forwardedChunk, allocator: context.channel.allocator)
                                        let promise = context.eventLoop.makePromise(of: Void.self)
                                        context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(forwardedBuffer))), promise: promise)
                                        return promise.futureResult
                                    }
                                    bodyRelayChain.whenFailure { [weak self] error in
                                        guard let self else { return }
                                        let failureReason = self.classifyMITMFailure(error)
                                        self.finalizeActiveRequestAsFailure(reason: failureReason)
                                        self.reportMITMFailure(reason: failureReason)
                                        self.completeStreamRuntime(streamRuntime, status: .failed, reason: error.localizedDescription, eventLoop: context.eventLoop)
                                    }
                                case let .end(trailers):
                                    bodyRelayChain.flatMap {
                                        self.completeStreamRuntime(streamRuntime, status: .closed, reason: nil, eventLoop: context.eventLoop)
                                        let promise = context.eventLoop.makePromise(of: Void.self)
                                        promise.futureResult.whenComplete { _ in
                                            self.upstreamChannel = nil
                                            upstream.close(promise: nil)
                                            self.transitionAfterResponse(closeAfterSend: closeAfterSend, context: context)
                                        }
                                        context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
                                        return promise.futureResult
                                    }.whenFailure { error in
                                        let failureReason = self.classifyMITMFailure(error)
                                        self.finalizeActiveRequestAsFailure(reason: failureReason)
                                        self.reportMITMFailure(reason: failureReason)
                                        self.completeStreamRuntime(streamRuntime, status: .failed, reason: error.localizedDescription, eventLoop: context.eventLoop)
                                    }
                                }
                            }
                        }
                        let onError: @Sendable (Error) -> Void = { [weak self] error in
                            let context = sendableContext.value
                            context.eventLoop.execute {
                                guard let self, self.state == .forwardingHTTPRequest else { return }
                                let failureReason = self.classifyMITMFailure(error)
                                self.finalizeActiveRequestAsHTTPFailure(status: .badGateway, reason: failureReason)
                                self.reportMITMFailure(reason: failureReason)
                                self.completeStreamRuntime(streamRuntime, status: .failed, reason: error.localizedDescription, eventLoop: context.eventLoop)
                                self.sendResponse(status: .badGateway, body: "Upstream gRPC request failed", closeAfterSend: true, context: context)
                                self.state = .closed
                                self.upstreamChannel = nil
                            }
                        }
                        let onInactive: @Sendable () -> Void = { [weak self] in
                            let context = sendableContext.value
                            context.eventLoop.execute {
                                guard let self, self.state == .forwardingHTTPRequest else { return }
                                self.completeStreamRuntime(streamRuntime, status: responseHeadSeen ? .closed : .failed,
                                    reason: responseHeadSeen ? nil : "upstream_inactive", eventLoop: context.eventLoop)
                                self.state = .closed
                                context.close(promise: nil)
                            }
                        }
                        self.installStreamingUpstreamHTTPPipeline(on: upstream, onResponsePart: onPart, onError: onError, onInactive: onInactive)
                        .flatMap {
                            self.installStreamingUpstreamTLSIfNeeded(on: upstream, url: targetURL, serverHostname: targetHost)
                        }
                        .flatMap {
                            self.writeAndFlushStreamingUpstreamRequest(head: streamingRequestHead, body: outboundContext.body, to: upstream)
                        }
                        .whenComplete { [weak self] pipelineResult in
                            guard let self else { return }
                            if case let .failure(error) = pipelineResult {
                                let failureReason = self.classifyMITMFailure(error)
                                self.finalizeActiveRequestAsHTTPFailure(status: .badGateway, reason: failureReason)
                                self.reportMITMFailure(reason: failureReason)
                                self.completeStreamRuntime(streamRuntime, status: .failed, reason: error.localizedDescription, eventLoop: context.eventLoop)
                                self.sendResponse(status: .badGateway, body: "Failed to establish gRPC upstream", closeAfterSend: true, context: context)
                                self.state = .closed
                                self.upstreamChannel = nil
                                upstream.close(promise: nil)
                            }
                        }
                    case let .failure(error):
                        let failureReason = self.classifyMITMFailure(error)
                        self.finalizeActiveRequestAsHTTPFailure(status: .badGateway, reason: failureReason)
                        self.reportMITMFailure(reason: failureReason)
                        self.completeStreamRuntime(streamRuntime, status: .failed, reason: error.localizedDescription, eventLoop: context.eventLoop)
                        self.sendResponse(status: .badGateway, body: "Failed to establish gRPC upstream", closeAfterSend: true, context: context)
                    }
                }
            }
        } // end Task (host override + connect)
    }

    func forwardWebSocketStreamTransport(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext,
        streamRuntime: StreamSessionRuntime
    ) {
        guard let targetURL = URL(string: outboundContext.url),
              let targetHost = targetURL.host
        else {
            finalizeActiveRequestAsHTTPFailure(
                status: .badRequest,
                reason: "invalid_websocket_request_target"
            )
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
            finalizeActiveRequestAsHTTPFailure(
                status: .badRequest,
                reason: "invalid_websocket_request_headers"
            )
            sendResponse(status: .badRequest, body: "Invalid WebSocket request headers", closeAfterSend: true, context: context)
            return
        }
        let normalizedURL = normalizedWebSocketURL(from: outboundContext.url)
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)
        let taskState = NIOMITMUncheckedSendableBox(
            value: (
                outboundURL: outboundContext.url,
                requestSnapshot: outboundContext.requestSnapshot,
                requestBody: outboundContext.body,
                requestHead: requestHead,
                targetURL: targetURL,
                targetHost: targetHost,
                targetPort: targetPort,
                normalizedURL: normalizedURL,
                streamingRequestHead: streamingRequestHead,
                streamRuntime: streamRuntime
            )
        )

        // Apply host override before connecting: use the overridden IP while keeping
        // targetHost for TLS SNI and the HTTP Host header.
        Task { [weak self, sendableContext, taskState] in
            guard let self else { return }
            let state = taskState.value
            let context = sendableContext.value
            let override = await RequestInterceptor.shared.hostOverride(for: state.outboundURL)
            let connectHost = override?.ip ?? state.targetHost
            let connectPort = override?.port ?? state.targetPort
            if let override {
                ProxyLog.mitm.info(
                    "event=proxy.ws_host_override outcome=applied original_host=\(state.targetHost, privacy: .private(mask: .hash)) override_ip=\(override.ip, privacy: .private(mask: .hash)) url=\(state.outboundURL, privacy: .private(mask: .hash))"
                )
            }
            let bootstrap = NIOTSConnectionBootstrap(group: self.group)
            bootstrap.connect(host: connectHost, port: connectPort).whenComplete { [weak self] result in
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
                                        requestHead: state.requestHead,
                                        responseHeaders: head.headers
                                    )
                                    state.streamRuntime.updateResponseHeaders(
                                        self.captureConfigProvider().captureHeaders
                                            ? self.traceHeaders(from: head.headers)
                                            : []
                                    )
                                    self.persistStreamRuntimeSnapshot(state.streamRuntime)
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
                                        self.completeStreamRuntime(
                                            state.streamRuntime,
                                            status: .failed,
                                            reason: "invalid_upstream_response",
                                            eventLoop: context.eventLoop
                                        )
                                        return
                                    }

                                    let isUpgrade = head.status == .switchingProtocols &&
                                        self.isWebSocketUpgrade(headers: head.headers)
                                    if isUpgrade {
                                        let perMessageDeflateEnabled = self.webSocketPerMessageDeflateEnabled(headers: head.headers)
                                        ProxyLog.mitm.info(
                                            "event=proxy.nio_ws_upgrade outcome=accepted session_id=\(state.streamRuntime.snapshot().id.uuidString, privacy: .public) host=\(state.targetHost, privacy: .private(mask: .hash)) port=\(state.targetPort, privacy: .public) permessage_deflate=\(perMessageDeflateEnabled, privacy: .public)"
                                        )
                                        self.eventLog?.append(
                                            type: "proxy_nio_ws_upgrade",
                                            msg: "outcome=accepted mode=\(self.ingressModeLabel) id=\(self.connectionID) session_id=\(state.streamRuntime.snapshot().id.uuidString) url_hash=\(LogRedaction.hash(state.normalizedURL)) permessage_deflate=\(perMessageDeflateEnabled)"
                                        )
                                        state.streamRuntime.setStatus(.open)
                                        self.persistStreamRuntimeSnapshot(state.streamRuntime)
                                        let promise = context.eventLoop.makePromise(of: Void.self)
                                        promise.futureResult.whenComplete { [weak self] _ in
                                            guard let self else { return }
                                            self.installWebSocketRelay(
                                                clientContext: context,
                                                upstream: upstream,
                                                streamRuntime: state.streamRuntime,
                                                perMessageDeflateEnabled: perMessageDeflateEnabled
                                            )
                                        }
                                        context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
                                        return
                                    }

                                    ProxyLog.mitm.info(
                                        "event=proxy.nio_ws_upgrade outcome=rejected session_id=\(state.streamRuntime.snapshot().id.uuidString, privacy: .public) host=\(state.targetHost, privacy: .private(mask: .hash)) port=\(state.targetPort, privacy: .public) status=\(Int(head.status.code), privacy: .public)"
                                    )
                                    self.eventLog?.append(
                                        type: "proxy_nio_ws_upgrade",
                                        msg: "outcome=rejected mode=\(self.ingressModeLabel) id=\(self.connectionID) session_id=\(state.streamRuntime.snapshot().id.uuidString) url_hash=\(LogRedaction.hash(state.normalizedURL)) status=\(head.status.code)"
                                    )
                                    let responseBodyData = self.byteBufferToData(responseBody)
                                    let captureConfig = self.captureConfigProvider()
                                    let responseHeadersTrace = self.traceHeaders(from: head.headers)
                                    let declaredContentLength = self.contentLength(from: head.headers)
                                    self.completeStreamRuntime(
                                        state.streamRuntime,
                                        status: .failed,
                                        reason: "websocket_upgrade_rejected",
                                        eventLoop: context.eventLoop
                                    )
                                    var captured = state.requestSnapshot
                                    captured.protocolVersion = self.mergedCapturedProtocolVersion(
                                        current: captured.protocolVersion,
                                        fallback: head.version
                                    )
                                    captured.statusCode = Int(head.status.code)
                                    captured.statusMessage = head.status.reasonPhrase
                                    captured.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                                    let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                                    let responseContentType = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-type" })?.value
                                    let responseContentEncoding = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                                    let effectiveCaptureBodyLimit = self.effectiveBodyCaptureLimit(
                                        captureConfig: captureConfig,
                                        contentType: responseContentType,
                                        contentEncoding: responseContentEncoding
                                    )
                                    captured.responseBody = self.bodyStorage(
                                        from: responseBodyData,
                                        charset: responseCharset,
                                        contentType: responseContentType,
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
                                        captureBodyLimit: effectiveCaptureBodyLimit,
                                        decodeCompressedContent: true,
                                        storageContentEncoding: responseContentEncoding
                                    )
                                    self.annotateCaptureMetadata(&captured)
                                    captured.extractHTTPFields()
                                    NetworkThrottlingController.shared.applyMetadata(to: &captured)
                                    self.finalizeCapturedDuration(for: &captured)
                                    self.activeCapturedRequest = captured
                                    self.publishCapturedRequest(captured)

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
                                let failureReason = self.classifyMITMFailure(error)
                                self.finalizeActiveRequestAsHTTPFailure(
                                    status: .badGateway,
                                    reason: failureReason
                                )
                                self.reportMITMFailure(reason: failureReason)
                                ProxyLog.mitm.warning(
                                    "event=proxy.nio_ws_upstream_error outcome=failure host=\(state.targetHost, privacy: .private(mask: .hash)) port=\(state.targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                                )
                                self.completeStreamRuntime(
                                    state.streamRuntime,
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
                                self.completeStreamRuntime(
                                    state.streamRuntime,
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
                                url: state.targetURL,
                                serverHostname: state.targetHost
                            )
                        }
                        .flatMap {
                            self.writeAndFlushStreamingUpstreamRequest(
                                head: state.streamingRequestHead,
                                body: state.requestBody,
                                to: upstream
                            )
                        }
                        .whenComplete { [weak self] pipelineResult in
                            guard let self else { return }
                            if case let .failure(error) = pipelineResult {
                                let failureReason = self.classifyMITMFailure(error)
                                self.finalizeActiveRequestAsHTTPFailure(
                                    status: .badGateway,
                                    reason: failureReason
                                )
                                self.reportMITMFailure(reason: failureReason)
                                ProxyLog.mitm.warning(
                                    "event=proxy.nio_ws_setup outcome=failure host=\(state.targetHost, privacy: .private(mask: .hash)) port=\(state.targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                                )
                                self.completeStreamRuntime(
                                    state.streamRuntime,
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
                        let failureReason = self.classifyMITMFailure(error)
                        self.finalizeActiveRequestAsHTTPFailure(
                            status: .badGateway,
                            reason: failureReason
                        )
                        self.reportMITMFailure(reason: failureReason)
                        ProxyLog.mitm.warning(
                            "event=proxy.nio_ws_connect outcome=failure host=\(state.targetHost, privacy: .private(mask: .hash)) port=\(state.targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                        self.completeStreamRuntime(
                            state.streamRuntime,
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
        } // end Task (host override + connect)
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

        queueTerminalCapturedRequest(request)
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
                self.publishQueuedTerminalCapturedRequest()
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

        queueTerminalCapturedRequest(capturedRequest)
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
                self.publishQueuedTerminalCapturedRequest()
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
        var effectiveCapturedBodyLimit = effectiveBodyCaptureLimit(
            captureConfig: captureConfig,
            contentType: nil,
            contentEncoding: nil
        )
        var capturedBodyData = Data()
        var receivedBodyBytes = 0
        var didTruncateCapturedBody = false
        var declaredResponseBodyBytes: Int?
        var capturedRequest = outboundContext.requestSnapshot
        var responseHead: HTTPResponseHead?
        var responseHeadersTrace: [TraceHTTPHeader] = []
        var responseContentEncoding: String?
        var closeAfterSend = false
        var responseHeadSent = false
        var terminalStateReached = false
        let targetHost = URL(string: outboundContext.url)?.host ?? "unknown"
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)
        // Native gRPC over HTTP/2 streaming state (gated by enableGRPCStreamInterception flag).
        // All mutations happen exclusively on context.eventLoop — the @unchecked Sendable
        // annotation suppresses the Swift 6 concurrency warning without introducing races.
        final class GRPCNativeStreamState: @unchecked Sendable {
            var runtime: StreamSessionRuntime?
            var interception: GRPCStreamInterceptionRuntime?
            var enabled = false
        }
        let grpcState = GRPCNativeStreamState()
        grpcState.enabled = HardeningConfig.shared.enableGRPCStreamInterceptionSync
        var grpcBodyRelayChain = context.eventLoop.makeSucceededVoidFuture()

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
                if self.responseHeadAt == nil { self.responseHeadAt = Date() }
                declaredResponseBodyBytes = self.contentLength(from: head.headers)
                capturedRequest.protocolVersion = self.mergedCapturedProtocolVersion(
                    current: capturedRequest.protocolVersion,
                    fallback: head.version
                )
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
                let responseContentType = self.responseHeaderValue(name: "content-type", in: responseHeadersTrace)
                responseContentEncoding = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                effectiveCapturedBodyLimit = self.effectiveBodyCaptureLimit(
                    captureConfig: captureConfig,
                    contentType: responseContentType,
                    contentEncoding: responseContentEncoding
                )
                self.activeCapturedRequest = capturedRequest

                // Lazily initialize native gRPC stream interception for HTTP/2 gRPC responses.
                if capturedRequest.isGRPC && grpcState.enabled && grpcState.runtime == nil {
                    let runtime = StreamSessionRuntime(
                        protocolType: .grpc,
                        url: outboundContext.url,
                        requestHeaders: outboundContext.requestSnapshot.requestHeaders,
                        responseHeaders: captureConfig.captureHeaders ? self.traceHeaders(from: forwardedHeaders) : [],
                        startTime: Date()
                    )
                    runtime.setStatus(.streaming)
                    grpcState.runtime = runtime
                    grpcState.interception = GRPCStreamInterceptionRuntime()
                    self.persistStreamRuntimeSnapshot(runtime)
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

                if effectiveCapturedBodyLimit > 0, chunkBytes > 0 {
                    let remaining = effectiveCapturedBodyLimit - capturedBodyData.count
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

                // Emit per-message gRPC stream events for native HTTP/2 gRPC streaming.
                if let gRPCRuntime = grpcState.runtime, let gRPCInterception = grpcState.interception, chunkBytes > 0 {
                    let chunkData = self.byteBufferToData(buffer)
                    grpcBodyRelayChain = grpcBodyRelayChain.flatMap {
                        gRPCInterception.interceptChunk(
                            chunkData,
                            runtime: gRPCRuntime,
                            decisionProvider: { [weak self] session, event, eventLoop in
                                guard let self else { return eventLoop.makeSucceededFuture(.forward) }
                                return self.streamEventInterceptionFuture(session: session, event: event, eventLoop: eventLoop)
                            },
                            eventRecorder: { [weak self] event in
                                guard let self else { return }
                                self.persistStreamEvent(event, runtime: gRPCRuntime, countPayloadBytes: true)
                            },
                            replayEngine: .shared,
                            eventLoop: context.eventLoop
                        ).map { _ in () }
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

                let finalStatus = responseHead?.status ?? .ok
                capturedRequest.statusCode = Int(finalStatus.code)
                capturedRequest.statusMessage = finalStatus.reasonPhrase
                capturedRequest.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                if capturedRequest.isGRPC, let responseHead {
                    let responseContentType = self.responseHeaderValue(name: "content-type", in: responseHeadersTrace) ?? ""
                    if GRPCTrailerExtractor.isGRPCWeb(contentType: responseContentType) {
                        capturedRequest.grpcMetadata = GRPCTrailerExtractor.extractFromWebBody(
                            responseBody: capturedBodyData, contentType: responseContentType)
                        capturedRequest.grpcMetadata?.responseMessageCount = GRPCTrailerExtractor.isGRPCWebText(contentType: responseContentType)
                            ? GRPCTrailerExtractor.countMessagesInGRPCWebText(in: capturedBodyData)
                            : GRPCTrailerExtractor.countMessages(in: capturedBodyData)
                    } else {
                        capturedRequest.grpcMetadata = GRPCTrailerExtractor.extract(from: responseHead.headers)
                        capturedRequest.grpcMetadata?.responseMessageCount = GRPCTrailerExtractor.countMessages(in: capturedBodyData)
                    }
                    // Request-header-derived fields
                    let reqHeaders = outboundContext.requestSnapshot.requestHeaders
                    capturedRequest.grpcMetadata?.timeout = reqHeaders.first { $0.key.lowercased() == "grpc-timeout" }?.value
                    capturedRequest.grpcMetadata?.acceptEncoding = reqHeaders.first { $0.key.lowercased() == "grpc-accept-encoding" }?.value
                    if capturedRequest.grpcMetadata?.statusDetailsBin == nil {
                        capturedRequest.grpcMetadata?.statusDetailsBin = reqHeaders.first { $0.key.lowercased() == "grpc-status-details-bin" }?.value
                    }
                    capturedRequest.grpcMetadata?.requestMessageCount = GRPCTrailerExtractor.countMessages(
                        in: outboundContext.requestSnapshot.requestBody.getData() ?? Data()
                    )
                }
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
                        maxStoredBodyBytes: effectiveCapturedBodyLimit
                    )
                } else {
                    let responseContentType = self.responseHeaderValue(name: "content-type", in: responseHeadersTrace)
                    capturedRequest.responseBody = self.bodyStorage(
                        from: capturedBodyData,
                        charset: responseCharset,
                        contentType: responseContentType,
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
                    captureBodyLimit: effectiveCapturedBodyLimit,
                    decodeCompressedContent: true,
                    storageContentEncoding: responseContentEncoding
                )
                NetworkThrottlingController.shared.applyMetadata(to: &capturedRequest)
                self.queueTerminalCapturedRequest(capturedRequest)

                // Close native gRPC stream session if active.
                if let gRPCRuntime = grpcState.runtime {
                    self.completeStreamRuntime(gRPCRuntime, status: .closed, reason: nil, eventLoop: context.eventLoop)
                }

                let endPromise = context.eventLoop.makePromise(of: Void.self)
                endPromise.futureResult.whenComplete { _ in
                    self.publishQueuedTerminalCapturedRequest()
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

                self.logUpstreamHTTPFailure(
                    error: error,
                    methodToken: outboundContext.methodToken,
                    targetHost: targetHost
                )

                if responseHeadSent {
                    var failedRequest = capturedRequest
                    failedRequest.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                    if let status = responseHead?.status {
                        failedRequest.statusCode = Int(status.code)
                        failedRequest.statusMessage = status.reasonPhrase
                    }
                    let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                    let observedResponseBodyBytes = max(receivedBodyBytes, capturedBodyData.count)
                    let resolvedResponseBodyBytes = self.resolvedResponseBodyBytes(
                        declaredContentLength: declaredResponseBodyBytes,
                        observedBodyBytes: observedResponseBodyBytes
                    )
                    failedRequest.responseBody = didTruncateCapturedBody
                        ? self.truncatedBodyStorage(
                            fromCapturedData: capturedBodyData,
                            totalSize: max(capturedBodyData.count, resolvedResponseBodyBytes),
                            charset: responseCharset,
                            contentEncoding: responseContentEncoding,
                            decodeCompressedContent: true,
                            maxStoredBodyBytes: effectiveCapturedBodyLimit
                        )
                        : self.bodyStorage(
                            from: capturedBodyData,
                            charset: responseCharset,
                            contentType: self.responseHeaderValue(name: "content-type", in: responseHeadersTrace),
                            contentEncoding: responseContentEncoding,
                            captureConfig: captureConfig,
                            decodeCompressedContent: true
                        )
                    failedRequest.executionErrors.append(
                        ExecutionError(message: self.classifyMITMFailure(error))
                    )
                    NetworkThrottlingController.shared.applyMetadata(to: &failedRequest)
                    self.publishCapturedRequest(failedRequest)
                    self.state = .closed
                    context.close(promise: nil)
                } else {
                    self.finalizeActiveRequestAsHTTPFailure(
                        status: .badGateway,
                        reason: self.classifyMITMFailure(error)
                    )
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
