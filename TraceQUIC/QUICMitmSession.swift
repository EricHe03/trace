//
//  QUICMitmSession.swift
//  TraceQUIC
//
//  Created by Justin on 2026/02/18.
//

import Foundation
import TraceCore

#if canImport(CQuicheFFI)
import CQuicheFFI
#endif

public enum QUICMitmFailureReason: String, Sendable {
    case engineUnavailable
    case sessionCreateFailed
    case sessionNotReady
    case certificatePinning
    case echUnsupported
    case handshakeFailed
    case unsupportedALPN
    case tunnelRequiredUnavailable
    case protocolError
    case internalError
    /// Transparent proxy downgraded h3→h2/http1.1 because TCP MITM cannot handle QUIC.
    /// The QUIC engine was not invoked; enable full-tunnel mode to capture HTTP/3 traffic.
    case alpnH3Downgraded
}

public struct QUICMitmCertificateMaterial: Sendable {
    public let leafCertificateDER: Data
    public let privateKeyDER: Data

    public init(leafCertificateDER: Data, privateKeyDER: Data) {
        self.leafCertificateDER = leafCertificateDER
        self.privateKeyDER = privateKeyDER
    }
}

public struct QUICMitmResult: Sendable {
    public let outcome: QUICInspectionOutcome
    public let reason: QUICMitmFailureReason?
    public let reasonDetail: String?

    public init(
        outcome: QUICInspectionOutcome,
        reason: QUICMitmFailureReason? = nil,
        reasonDetail: String? = nil
    ) {
        self.outcome = outcome
        self.reason = reason
        self.reasonDetail = reasonDetail
    }
}

public struct QUICMitmIngestResult: Sendable {
    public let processedStreams: Int
    public let datagramsToClient: [Data]
    public let datagramsToUpstream: [Data]
    public let fallbackReason: QUICMitmFailureReason?
    public let fallbackReasonDetail: String?
    public let retryAuthorityHint: String?
    public let connectionClosed: Bool
    public let connectionCloseReason: QUICMitmFailureReason?
    public let connectionCloseReasonDetail: String?

    public init(
        processedStreams: Int,
        datagramsToClient: [Data] = [],
        datagramsToUpstream: [Data] = [],
        fallbackReason: QUICMitmFailureReason? = nil,
        fallbackReasonDetail: String? = nil,
        retryAuthorityHint: String? = nil,
        connectionClosed: Bool = false,
        connectionCloseReason: QUICMitmFailureReason? = nil,
        connectionCloseReasonDetail: String? = nil
    ) {
        self.processedStreams = processedStreams
        self.datagramsToClient = datagramsToClient
        self.datagramsToUpstream = datagramsToUpstream
        self.fallbackReason = fallbackReason
        self.fallbackReasonDetail = fallbackReasonDetail
        self.retryAuthorityHint = retryAuthorityHint
        self.connectionClosed = connectionClosed
        self.connectionCloseReason = connectionCloseReason
        self.connectionCloseReasonDetail = connectionCloseReasonDetail
    }
}

public enum QUICMitmSessionError: LocalizedError, Sendable {
    case sessionNotEstablished
    case ingestFailed(Int32)
    case tickFailed(Int32)
    case eventPollFailed(Int32)
    case submitResponseFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .sessionNotEstablished:
            "QUIC MITM session is not established"
        case let .ingestFailed(code):
            "QUIC MITM datagram ingest failed (\(code))"
        case let .tickFailed(code):
            "QUIC MITM session tick failed (\(code))"
        case let .eventPollFailed(code):
            "QUIC MITM event poll failed (\(code))"
        case let .submitResponseFailed(code):
            "QUIC MITM response submission failed (\(code))"
        }
    }
}

public actor QUICMitmSession {
    public let flowID: UUID
    public let host: String
    public let port: Int

    private struct PendingStreamState {
        var headers: [HTTP3HeaderField] = []
        var body = Data()
    }

    private enum PolledAction {
        case datagramToClient(Data)
        case datagramToUpstream(Data)
        case requestHeaders(streamID: UInt64, headers: [HTTP3HeaderField])
        case requestBody(streamID: UInt64, bodyChunk: Data)
        case requestEnd(streamID: UInt64)
        case fallback(reason: QUICMitmFailureReason, detail: String?)
        case retryWithAuthority(String)
        case connectionClosed(reason: QUICMitmFailureReason?, detail: String?)
        case resetStream(streamID: UInt64)
    }

    private let pipeline: HTTP3MitmPipeline
    private let certificateMaterial: QUICMitmCertificateMaterial?
    private let tunnelPolicyRequired: Bool
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private var connectionAttemptID: UUID?
    private var isEstablished = false
    private var pendingStreams: [UInt64: PendingStreamState] = [:]

    #if canImport(CQuicheFFI)
    private var ffiSession: OpaquePointer?
    #endif

    public init(
        flowID: UUID,
        host: String,
        port: Int,
        interceptor: (any InterceptionProviding)? = nil,
        http3Client: any HTTP3Client = URLSessionHTTP3Client(),
        certificateMaterial: QUICMitmCertificateMaterial? = nil,
        tunnelPolicyRequired: Bool = false,
        eventLogHandler: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.flowID = flowID
        self.host = host
        self.port = port
        self.certificateMaterial = certificateMaterial
        self.tunnelPolicyRequired = tunnelPolicyRequired
        self.eventLogHandler = eventLogHandler
        pipeline = HTTP3MitmPipeline(
            interceptor: interceptor,
            http3Client: http3Client,
            captureEventHandler: eventLogHandler
        )
    }

    public func establish() async -> QUICMitmResult {
        if isEstablished {
            return QUICMitmResult(outcome: .intercepted)
        }

        let attemptID = await QUICConnectionManager.shared.openConnectionAttempt()
        connectionAttemptID = attemptID

        let engineStatus = QUICEngineRuntime.currentStatus()
        let certMaterialState = certificateMaterial == nil ? "missing" : "present"
        eventLogHandler?(
            "quic_mitm_session",
            "stage=establish flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) port=\(port) engine_availability=\(engineStatus.availability.rawValue) engine_version=\(engineStatus.version) ffi=\(engineStatus.usingQuicheFFI) cert_material=\(certMaterialState)"
        )
        guard engineStatus.availability == .available else {
            return await failOpen(
                reason: .engineUnavailable,
                detail: "engine_availability=\(engineStatus.availability.rawValue) engine_version=\(engineStatus.version) ffi=\(engineStatus.usingQuicheFFI)"
            )
        }

        #if canImport(CQuicheFFI)
        guard let openedSession = openFFISession() else {
            return await failOpen(
                reason: .sessionCreateFailed,
                detail: "open_failed cert_material=\(certMaterialState) engine_version=\(engineStatus.version)"
            )
        }
        ffiSession = openedSession

        guard cquiche_mitm_session_ready(openedSession) else {
            let reasonCode = cquiche_mitm_session_last_failure_reason(openedSession)
            let mappedReason = mapFailureReason(code: reasonCode)
            let failureDetail = normalizedFailureDetail(from: openedSession) ?? "none"
            cquiche_mitm_session_close(openedSession)
            ffiSession = nil
            return await failOpen(
                reason: mappedReason,
                detail: "session_not_ready reason_code=\(reasonCode) mapped_reason=\(mappedReason.rawValue) failure_detail=\(failureDetail) cert_material=\(certMaterialState)"
            )
        }
        #else
        return await failOpen(reason: .engineUnavailable, detail: "ffi_not_linked")
        #endif

        isEstablished = true
        eventLogHandler?(
            "quic_mitm_session",
            "outcome=established flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) port=\(port)"
        )
        await QUICConnectionManager.shared.recordIntercepted()
        return QUICMitmResult(outcome: .intercepted)
    }

    public func processHTTP3Stream(
        _ event: HTTP3StreamEvent,
        timeout: TimeInterval = 30,
        requiresHTTP3: Bool = true,
        allowHTTPVersionFallback: Bool = false
    ) async throws -> HTTP3MitmPipelineResponse {
        guard isEstablished else {
            throw QUICMitmSessionError.sessionNotEstablished
        }

        do {
            return try await pipeline.process(
                flowID: flowID,
                event: event,
                authorityFallback: host,
                timeout: timeout,
                requiresHTTP3: requiresHTTP3,
                allowHTTPVersionFallback: allowHTTPVersionFallback
            )
        } catch {
            await QUICConnectionManager.shared.recordFailure(reason: "http3_mitm_pipeline_failed")
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=http3_pipeline_failed flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) error=\(error.localizedDescription)"
            )
            throw error
        }
    }

    public func close() async {
        isEstablished = false
        pendingStreams.removeAll(keepingCapacity: false)

        #if canImport(CQuicheFFI)
        if let ffiSession {
            cquiche_mitm_session_close(ffiSession)
            self.ffiSession = nil
        }
        #endif

        if let connectionAttemptID {
            self.connectionAttemptID = nil
            await QUICConnectionManager.shared.closeConnection(connectionAttemptID)
        }
    }

    public func ingestDatagram(
        _ payload: Data,
        fromClient: Bool
    ) async throws -> QUICMitmIngestResult {
        guard isEstablished else {
            throw QUICMitmSessionError.sessionNotEstablished
        }
        guard !payload.isEmpty else {
            return QUICMitmIngestResult(processedStreams: 0)
        }

        #if canImport(CQuicheFFI)
        guard let ffiSession else {
            throw QUICMitmSessionError.sessionNotEstablished
        }

        let ingestCode: Int32 = payload.withUnsafeBytes { raw in
            let bound = raw.bindMemory(to: UInt8.self)
            guard let baseAddress = bound.baseAddress else {
                return -1
            }
            return cquiche_mitm_session_ingest_datagram(
                ffiSession,
                baseAddress,
                bound.count,
                fromClient
            )
        }

        guard ingestCode == 0 else {
            let failureCode = cquiche_mitm_session_last_failure_reason(ffiSession)
            let failureReason = mapFailureReasonAllowNone(code: failureCode)?.rawValue ?? "none"
            let failureDetail = normalizedFailureDetail(from: ffiSession) ?? "none"
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=ingest_error flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) direction=\(fromClient ? "client" : "upstream") payload_bytes=\(payload.count) code=\(ingestCode) failure_code=\(failureCode) failure_reason=\(failureReason) failure_detail=\(failureDetail)"
            )
            await QUICConnectionManager.shared.recordFailure(reason: "quic_mitm_ingest_failed")
            throw QUICMitmSessionError.ingestFailed(ingestCode)
        }

        return try await drainPolledActions(from: ffiSession)
        #else
        await QUICConnectionManager.shared.recordFailure(reason: "quic_mitm_engine_unavailable")
        throw QUICMitmSessionError.ingestFailed(-1)
        #endif
    }

    public func tick(nowNanoseconds: UInt64) async throws -> QUICMitmIngestResult {
        guard isEstablished else {
            throw QUICMitmSessionError.sessionNotEstablished
        }

        #if canImport(CQuicheFFI)
        guard let ffiSession else {
            throw QUICMitmSessionError.sessionNotEstablished
        }

        let tickCode = cquiche_mitm_session_tick(ffiSession, nowNanoseconds)
        guard tickCode == 0 else {
            let failureCode = cquiche_mitm_session_last_failure_reason(ffiSession)
            let failureReason = mapFailureReasonAllowNone(code: failureCode)?.rawValue ?? "none"
            let failureDetail = normalizedFailureDetail(from: ffiSession) ?? "none"
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=tick_error flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) code=\(tickCode) failure_code=\(failureCode) failure_reason=\(failureReason) failure_detail=\(failureDetail)"
            )
            await QUICConnectionManager.shared.recordFailure(reason: "quic_mitm_tick_failed")
            throw QUICMitmSessionError.tickFailed(tickCode)
        }

        return try await drainPolledActions(from: ffiSession)
        #else
        await QUICConnectionManager.shared.recordFailure(reason: "quic_mitm_engine_unavailable")
        throw QUICMitmSessionError.tickFailed(-1)
        #endif
    }
}

private extension QUICMitmSession {
    #if canImport(CQuicheFFI)
    static let actionPayloadBufferSize = 512 * 1024
    static let actionMetadataBufferSize = 32 * 1024

    func openFFISession() -> OpaquePointer? {
        let clampedPort = UInt16(clamping: port)
        return host.withCString { hostname in
            withDataBytes(certificateMaterial?.leafCertificateDER) { certPointer, certLength in
                withDataBytes(certificateMaterial?.privateKeyDER) { keyPointer, keyLength in
                    var config = cquiche_mitm_open_config_t(
                        authority: hostname,
                        port: clampedPort,
                        tunnel_policy_required: tunnelPolicyRequired,
                        downstream_leaf_cert_der: certPointer,
                        downstream_leaf_cert_der_len: certLength,
                        downstream_private_key_der: keyPointer,
                        downstream_private_key_der_len: keyLength
                    )
                    return cquiche_mitm_session_open_with_config(&config)
                }
            }
        }
    }

    func normalizedFailureDetail(from ffiSession: OpaquePointer) -> String? {
        guard let detailPointer = cquiche_mitm_session_last_failure_detail(ffiSession) else {
            return nil
        }
        let detail = String(cString: detailPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.asNonEmpty
    }

    private func pollAction(
        from ffiSession: OpaquePointer
    ) async throws -> PolledAction? {
        var actionInfo = cquiche_action_info_t(
            action_type: Int32(truncatingIfNeeded: CQUICHE_ACTION_NONE.rawValue),
            stream_id: 0,
            failure_reason: Int32(truncatingIfNeeded: CQUICHE_FAILURE_NONE.rawValue),
            payload_len: 0,
            metadata_len: 0
        )
        var payloadBuffer = [UInt8](repeating: 0, count: Self.actionPayloadBufferSize)
        var metadataBuffer = [CChar](repeating: 0, count: Self.actionMetadataBufferSize)

        let pollCode: Int32 = payloadBuffer.withUnsafeMutableBufferPointer { payloadPointer in
            metadataBuffer.withUnsafeMutableBufferPointer { metadataPointer in
                cquiche_mitm_session_poll_action(
                    ffiSession,
                    &actionInfo,
                    payloadPointer.baseAddress,
                    payloadPointer.count,
                    metadataPointer.baseAddress,
                    metadataPointer.count
                )
            }
        }

        if pollCode == 0 {
            return nil
        }
        guard pollCode == 1 else {
            let failureCode = cquiche_mitm_session_last_failure_reason(ffiSession)
            let failureReason = mapFailureReasonAllowNone(code: failureCode)?.rawValue ?? "none"
            let failureDetail = normalizedFailureDetail(from: ffiSession) ?? "none"
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=action_poll_error flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) code=\(pollCode) failure_code=\(failureCode) failure_reason=\(failureReason) failure_detail=\(failureDetail)"
            )
            await QUICConnectionManager.shared.recordFailure(reason: "quic_mitm_action_poll_failed")
            throw QUICMitmSessionError.eventPollFailed(pollCode)
        }

        let payloadCount = max(0, min(Int(actionInfo.payload_len), payloadBuffer.count))
        let payloadData = Data(payloadBuffer.prefix(payloadCount))
        let metadataCount = max(0, min(Int(actionInfo.metadata_len), metadataBuffer.count))
        let metadataData = metadataBuffer.withUnsafeBytes { rawBuffer in
            Data(rawBuffer.prefix(metadataCount))
        }
        let metadataString = String(data: metadataData, encoding: .utf8) ?? ""
        let failureDetail = normalizedFailureDetail(from: ffiSession)

        switch actionInfo.action_type {
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_DATAGRAM_TO_CLIENT.rawValue):
            return .datagramToClient(payloadData)
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_DATAGRAM_TO_UPSTREAM.rawValue):
            return .datagramToUpstream(payloadData)
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_HTTP3_REQUEST_HEADERS.rawValue):
            return .requestHeaders(
                streamID: actionInfo.stream_id,
                headers: decodeHeaderBlock(metadataData)
            )
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_HTTP3_REQUEST_BODY.rawValue):
            return .requestBody(streamID: actionInfo.stream_id, bodyChunk: payloadData)
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_HTTP3_REQUEST_END.rawValue):
            return .requestEnd(streamID: actionInfo.stream_id)
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_HTTP3_RESET_STREAM.rawValue):
            return .resetStream(streamID: actionInfo.stream_id)
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_CONNECTION_CLOSED.rawValue):
            return .connectionClosed(
                reason: mapFailureReasonAllowNone(code: actionInfo.failure_reason),
                detail: failureDetail
            )
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_RETRY_WITH_AUTHORITY.rawValue):
            let authority = metadataString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authority.isEmpty else {
                return .fallback(reason: .handshakeFailed, detail: failureDetail)
            }
            return .retryWithAuthority(authority)
        case Int32(truncatingIfNeeded: CQUICHE_ACTION_FALLBACK_REQUIRED.rawValue):
            let reason = metadataString.asNonEmpty.flatMap(QUICMitmFailureReason.init(rawValue:)) ??
                mapFailureReason(code: actionInfo.failure_reason)
            return .fallback(reason: reason, detail: failureDetail)
        default:
            return nil
        }
    }

    func handleRequestCompletion(streamID: UInt64) async throws -> HTTP3MitmPipelineResponse {
        let state = pendingStreams.removeValue(forKey: streamID) ?? PendingStreamState()
        let event = HTTP3StreamEvent(
            streamID: streamID,
            headers: state.headers,
            body: state.body
        )
        return try await processHTTP3Stream(event)
    }

    func submitResponse(
        _ response: HTTP3MitmPipelineResponse,
        streamID: UInt64,
        ffiSession: OpaquePointer
    ) throws {
        let headersBlock = encodeHeaderBlock(response.responseHeaders)
        let bodyData = response.responseBody

        let submitCode: Int32 = headersBlock.withUnsafeBytes { headersRaw in
            let headersPointer = headersRaw.bindMemory(to: CChar.self).baseAddress
            return bodyData.withUnsafeBytes { bodyRaw in
                let bodyPointer = bodyRaw.bindMemory(to: UInt8.self).baseAddress
                return cquiche_mitm_session_submit_response(
                    ffiSession,
                    streamID,
                    UInt16(clamping: response.statusCode),
                    headersPointer,
                    headersRaw.count,
                    bodyPointer,
                    bodyRaw.count,
                    true
                )
            }
        }

        guard submitCode == 0 else {
            let failureCode = cquiche_mitm_session_last_failure_reason(ffiSession)
            let failureReason = mapFailureReasonAllowNone(code: failureCode)?.rawValue ?? "none"
            let failureDetail = normalizedFailureDetail(from: ffiSession) ?? "none"
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=submit_response_error flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) stream_id=\(streamID) status=\(response.statusCode) body_bytes=\(bodyData.count) code=\(submitCode) failure_code=\(failureCode) failure_reason=\(failureReason) failure_detail=\(failureDetail)"
            )
            throw QUICMitmSessionError.submitResponseFailed(submitCode)
        }

        eventLogHandler?(
            "quic_mitm_session",
            "outcome=submit_response_success flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) stream_id=\(streamID) status=\(response.statusCode) body_bytes=\(bodyData.count)"
        )
    }

    func drainPolledActions(from ffiSession: OpaquePointer) async throws -> QUICMitmIngestResult {
        var processedStreams = 0
        var datagramsToClient: [Data] = []
        var datagramsToUpstream: [Data] = []
        var fallbackReason: QUICMitmFailureReason?
        var fallbackReasonDetail: String?
        var retryAuthorityHint: String?
        var connectionClosed = false
        var connectionCloseReason: QUICMitmFailureReason?
        var connectionCloseReasonDetail: String?

        while true {
            guard let action = try await pollAction(from: ffiSession) else {
                break
            }

            switch action {
            case let .datagramToClient(datagram):
                datagramsToClient.append(datagram)
            case let .datagramToUpstream(datagram):
                datagramsToUpstream.append(datagram)
            case let .requestHeaders(streamID, headers):
                var state = pendingStreams[streamID] ?? PendingStreamState()
                state.headers = headers
                pendingStreams[streamID] = state
            case let .requestBody(streamID, bodyChunk):
                var state = pendingStreams[streamID] ?? PendingStreamState()
                state.body.append(bodyChunk)
                pendingStreams[streamID] = state
            case let .requestEnd(streamID):
                do {
                    let response = try await handleRequestCompletion(streamID: streamID)
                    try submitResponse(response, streamID: streamID, ffiSession: ffiSession)
                    processedStreams += 1
                } catch {
                    eventLogHandler?(
                        "quic_mitm_session",
                        "outcome=request_end_error flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) stream_id=\(streamID) error=\(String(describing: error))"
                    )
                    throw error
                }
            case let .fallback(reason, detail):
                fallbackReason = reason
                fallbackReasonDetail = detail
            case let .retryWithAuthority(authority):
                retryAuthorityHint = authority
                eventLogHandler?(
                    "quic_mitm_session",
                    "outcome=retry_with_authority flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) authority_hash=\(LogRedaction.hash(authority))"
                )
            case let .connectionClosed(reason, detail):
                connectionClosed = true
                if let reason {
                    connectionCloseReason = reason
                    connectionCloseReasonDetail = detail
                    fallbackReason = reason
                    fallbackReasonDetail = detail
                }
            case let .resetStream(streamID):
                pendingStreams.removeValue(forKey: streamID)
            }
        }

        return QUICMitmIngestResult(
            processedStreams: processedStreams,
            datagramsToClient: datagramsToClient,
            datagramsToUpstream: datagramsToUpstream,
            fallbackReason: fallbackReason,
            fallbackReasonDetail: fallbackReasonDetail,
            retryAuthorityHint: retryAuthorityHint,
            connectionClosed: connectionClosed,
            connectionCloseReason: connectionCloseReason,
            connectionCloseReasonDetail: connectionCloseReasonDetail
        )
    }

    func decodeHeaderBlock(_ data: Data) -> [HTTP3HeaderField] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return HTTP3HeaderField(
                name: String(parts[0]),
                value: String(parts[1])
            )
        }
    }

    func encodeHeaderBlock(_ headers: [HTTP3HeaderField]) -> Data {
        guard !headers.isEmpty else { return Data() }
        var text = ""
        for header in headers {
            text += "\(header.name)\t\(header.value)\n"
        }
        return Data(text.utf8)
    }
    #endif

    func mapFailureReason(code: Int32) -> QUICMitmFailureReason {
        #if canImport(CQuicheFFI)
        switch code {
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_CERTIFICATE_PINNING.rawValue):
            .certificatePinning
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_ECH_UNSUPPORTED.rawValue):
            .echUnsupported
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_HANDSHAKE_FAILED.rawValue):
            .handshakeFailed
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_UNSUPPORTED_ALPN.rawValue):
            .unsupportedALPN
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_TUNNEL_REQUIRED_UNAVAILABLE.rawValue):
            .tunnelRequiredUnavailable
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_PROTOCOL_ERROR.rawValue):
            .protocolError
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_SESSION_CREATE_FAILED.rawValue):
            .sessionCreateFailed
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_SESSION_NOT_READY.rawValue):
            .sessionNotReady
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_INTERNAL_ERROR.rawValue):
            .internalError
        case Int32(truncatingIfNeeded: CQUICHE_FAILURE_ENGINE_UNAVAILABLE.rawValue):
            .engineUnavailable
        default:
            .internalError
        }
        #else
        _ = code
        return .engineUnavailable
        #endif
    }

    func mapFailureReasonAllowNone(code: Int32) -> QUICMitmFailureReason? {
        #if canImport(CQuicheFFI)
        if code == Int32(truncatingIfNeeded: CQUICHE_FAILURE_NONE.rawValue) {
            return nil
        }
        #endif
        return mapFailureReason(code: code)
    }

    func failOpen(reason: QUICMitmFailureReason, detail: String? = nil) async -> QUICMitmResult {
        isEstablished = false
        pendingStreams.removeAll(keepingCapacity: false)
        var message = "outcome=pass_through flow_id=\(flowID.uuidString) host_hash=\(LogRedaction.hash(host)) reason=\(reason.rawValue)"
        if let detail, !detail.isEmpty {
            message += " detail=\(detail)"
        }
        eventLogHandler?(
            "quic_mitm_session",
            message
        )
        await QUICConnectionManager.shared.recordPassThroughFallback(reason: reason.rawValue)
        if let connectionAttemptID {
            self.connectionAttemptID = nil
            await QUICConnectionManager.shared.closeConnection(connectionAttemptID)
        }
        return QUICMitmResult(
            outcome: .passThroughMarked,
            reason: reason,
            reasonDetail: detail?.trimmingCharacters(in: .whitespacesAndNewlines).asNonEmpty
        )
    }
}

private extension QUICMitmSession {
    #if canImport(CQuicheFFI)
    func withDataBytes<T>(
        _ data: Data?,
        _ body: (UnsafePointer<UInt8>?, Int) -> T
    ) -> T {
        guard let data, !data.isEmpty else {
            return body(nil, 0)
        }

        return data.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return body(pointer, rawBuffer.count)
        }
    }
    #endif
}

private extension String {
    var asNonEmpty: String? {
        isEmpty ? nil : self
    }
}
