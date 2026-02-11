//
//  CurlRuntimeCapabilities.swift
//  TraceFeatures
//
//  Created by Justin on 2026/02/08.
//

import Foundation
#if canImport(TraceCurlRuntime)
import TraceCurlRuntime
#endif

public struct CurlRuntimeCapabilities: Sendable {
    public let backendName: String
    public let supportedProtocols: Set<String>
    public let supportedOptions: Set<String>
    public let supportsHTTP2: Bool
    public let supportsContentDecoding: Bool
    public let supportsNativeCA: Bool
    public let supportsNTLM: Bool

    public init(
        backendName: String,
        supportedProtocols: Set<String>,
        supportedOptions: Set<String>,
        supportsHTTP2: Bool = false,
        supportsContentDecoding: Bool = false,
        supportsNativeCA: Bool = false,
        supportsNTLM: Bool = false
    ) {
        self.backendName = backendName
        self.supportedProtocols = supportedProtocols
        self.supportedOptions = supportedOptions
        self.supportsHTTP2 = supportsHTTP2
        self.supportsContentDecoding = supportsContentDecoding
        self.supportsNativeCA = supportsNativeCA
        self.supportsNTLM = supportsNTLM
    }
}

public extension CurlRuntimeCapabilities {
    /// Current iOS runtime path (legacy parser + URLSession-based RequestExecutor).
    static let urlSession: CurlRuntimeCapabilities = .init(
        backendName: "URLSession",
        supportedProtocols: ["http", "https"],
        supportedOptions: [
            "--compressed",
            "--config",
            "--cookie",
            "--data",
            "--data-ascii",
            "--data-binary",
            "--data-raw",
            "--data-urlencode",
            "--form",
            "--form-string",
            "--get",
            "--globoff",
            "--head",
            "--header",
            "--http1.0",
            "--http1.1",
            "--http2",
            "--http2-prior-knowledge",
            "--http3",
            "--insecure",
            "--location",
            "--next",
            "--referer",
            "--request",
            "--upload-file",
            "--url",
            "--user",
            "--user-agent",
            "--variable",
            "-0",
            "-:",
            "-A",
            "-F",
            "-G",
            "-H",
            "-I",
            "-K",
            "-L",
            "-T",
            "-X",
            "-b",
            "-d",
            "-e",
            "-g",
            "-k",
            "-u"
        ],
        supportsHTTP2: true,
        supportsContentDecoding: true,
        supportsNativeCA: true,
        supportsNTLM: false
    )

    /// Used by tests to verify parser/analyzer option recognition independent of backend limits.
    static let parityValidation: CurlRuntimeCapabilities = .init(
        backendName: "ParityValidation",
        supportedProtocols: [
            "dict", "file", "ftp", "ftps", "gopher", "gophers", "http", "https", "imap", "imaps", "ipfs",
            "ipns", "ldap", "ldaps", "mqtt", "pop3", "pop3s", "rtmp", "rtmpe", "rtmps", "rtmpt", "rtmpte",
            "rtmpts", "rtsp", "scp", "sftp", "smb", "smbs", "smtp", "smtps", "telnet", "tftp", "ws", "wss"
        ],
        supportedOptions: CurlOptionRegistry.allOptions,
        supportsHTTP2: true,
        supportsContentDecoding: true,
        supportsNativeCA: true,
        supportsNTLM: true
    )

    static var resolvedDefault: CurlRuntimeCapabilities {
        #if canImport(TraceCurlRuntime)
        let report = CurlRuntimeBridge.currentReport()
        if report.available, report.supportsCLIExecution {
            let protocols = report.supportedProtocols.isEmpty ? parityValidation.supportedProtocols : report.supportedProtocols
            let runtimeKnownOptions = report.supportedOptions.intersection(CurlOptionRegistry.allOptions)
            let supportedOptions: Set<String>
            let backendSuffix: String
            if runtimeKnownOptions.isEmpty {
                supportedOptions = report.supportsFullOptionParity ? CurlOptionRegistry.allOptions : urlSession.supportedOptions
                backendSuffix = report.supportsFullOptionParity ? "" : " (partial option set)"
            } else {
                supportedOptions = runtimeKnownOptions
                backendSuffix = runtimeKnownOptions == CurlOptionRegistry.allOptions ? "" : " (partial option set)"
            }
            return .init(
                backendName: report.backendName + backendSuffix,
                supportedProtocols: protocols,
                supportedOptions: supportedOptions,
                supportsHTTP2: report.supportsHTTP2,
                supportsContentDecoding: report.supportsContentDecoding,
                supportsNativeCA: report.supportsNativeCA,
                supportsNTLM: report.supportsNTLM
            )
        }
        if report.available, !report.supportsCLIExecution {
            return .init(
                backendName: "\(report.backendName) -> URLSession fallback",
                supportedProtocols: urlSession.supportedProtocols,
                supportedOptions: urlSession.supportedOptions,
                supportsHTTP2: urlSession.supportsHTTP2,
                supportsContentDecoding: urlSession.supportsContentDecoding,
                supportsNativeCA: urlSession.supportsNativeCA,
                supportsNTLM: urlSession.supportsNTLM
            )
        }
        #endif
        return .urlSession
    }
}
