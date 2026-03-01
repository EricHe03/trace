//
//  CurlRuntimeCapabilities.swift
//  TraceFeatures
//
//  Created by Justin on 2026/02/08.
//

import Foundation

public struct CurlRuntimeCapabilities: Sendable {
    public let backendName: String
    public let supportedProtocols: Set<String>
    public let supportedOptions: Set<String>
    public let supportsHTTP2: Bool
    public let supportsHTTP3: Bool
    public let supportsContentDecoding: Bool
    public let supportsNativeCA: Bool
    public let supportsNTLM: Bool

    public init(
        backendName: String,
        supportedProtocols: Set<String>,
        supportedOptions: Set<String>,
        supportsHTTP2: Bool = false,
        supportsHTTP3: Bool = false,
        supportsContentDecoding: Bool = false,
        supportsNativeCA: Bool = false,
        supportsNTLM: Bool = false
    ) {
        self.backendName = backendName
        self.supportedProtocols = supportedProtocols
        self.supportedOptions = supportedOptions
        self.supportsHTTP2 = supportsHTTP2
        self.supportsHTTP3 = supportsHTTP3
        self.supportsContentDecoding = supportsContentDecoding
        self.supportsNativeCA = supportsNativeCA
        self.supportsNTLM = supportsNTLM
    }
}

public extension CurlRuntimeCapabilities {
    /// Current iOS runtime path (SwiftNIO + AsyncHTTPClient-backed RequestExecutor).
    static let nioAsyncHTTPClient: CurlRuntimeCapabilities = .init(
        backendName: "SwiftNIO + AsyncHTTPClient + TraceQUIC",
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
            "--http3-only",
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
        supportsHTTP3: true,
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
        supportsHTTP3: true,
        supportsContentDecoding: true,
        supportsNativeCA: true,
        supportsNTLM: true
    )

    static var resolvedDefault: CurlRuntimeCapabilities {
        .nioAsyncHTTPClient
    }
}
