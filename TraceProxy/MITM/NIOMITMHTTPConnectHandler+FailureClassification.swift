//
//  NIOMITMHTTPConnectHandler+FailureClassification.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import AsyncHTTPClient
import Foundation
import NIOSSL
import TraceCore

extension NIOMITMHTTPConnectHandler {
    nonisolated(unsafe) static let connectStageLogSampler = LogSampler()

    func mitmHost() -> String? {
        if let connectTargetHost, !connectTargetHost.isEmpty {
            return connectTargetHost
        }
        switch ingressMode {
        case .proxy:
            guard let hintedHost = upstreamHint?.host.trimmingCharacters(in: .whitespacesAndNewlines),
                  !hintedHost.isEmpty
            else {
                return nil
            }
            return hintedHost
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
        let shouldEmitUnifiedLog = shouldEmitUnifiedLogForConnectStage(stage: stage, outcome: outcome)

        if let detailText {
            if shouldEmitUnifiedLog {
                ProxyLog.mitm.debug(
                    "event=proxy.nio_connect_stage stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public) mode=\(self.ingressModeLabel, privacy: .public) id=\(self.connectionID, privacy: .public) host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) state=\(stateLabel, privacy: .public) detail=\(detailText, privacy: .public)"
                )
            }
            eventLog?.append(
                type: "proxy_nio_connect_stage",
                msg: "stage=\(stage) outcome=\(outcome) mode=\(self.ingressModeLabel) id=\(self.connectionID) host_hash=\(hostHash) port=\(port) state=\(stateLabel) detail=\(detailText)"
            )
            return
        }

        if shouldEmitUnifiedLog {
            ProxyLog.mitm.debug(
                "event=proxy.nio_connect_stage stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public) mode=\(self.ingressModeLabel, privacy: .public) id=\(self.connectionID, privacy: .public) host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) state=\(stateLabel, privacy: .public)"
            )
        }
        eventLog?.append(
            type: "proxy_nio_connect_stage",
            msg: "stage=\(stage) outcome=\(outcome) mode=\(self.ingressModeLabel) id=\(self.connectionID) host_hash=\(hostHash) port=\(port) state=\(stateLabel)"
        )
    }

    func shouldEmitUnifiedLogForConnectStage(stage: String, outcome: String) -> Bool {
        switch outcome {
        case "failure", "error", "blocked", "unsupported":
            return true
        default:
            break
        }

        switch stage {
        case "handler_added",
             "handler_removed",
             "handler_tunnel_passthrough",
             "client_channel_inactive",
             "client_autoread",
             "connect_response",
             "response_pipeline":
            return Self.connectStageLogSampler.shouldLog(
                event: "proxy.nio_connect_stage",
                key: "\(stage)|\(outcome)|\(ingressModeLabel)",
                first: 2,
                every: 100
            )
        case "http_upstream" where outcome == "start" || outcome == "response":
            return Self.connectStageLogSampler.shouldLog(
                event: "proxy.nio_connect_stage",
                key: "\(stage)|\(outcome)|\(ingressModeLabel)",
                first: 2,
                every: 50
            )
        case "client_handler_error" where outcome == "ignored":
            return Self.connectStageLogSampler.shouldLog(
                event: "proxy.nio_connect_stage",
                key: "\(stage)|\(outcome)|\(ingressModeLabel)",
                first: 3,
                every: 50
            )
        default:
            return true
        }
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
        onRequestCaptured(marker)
    }
}
