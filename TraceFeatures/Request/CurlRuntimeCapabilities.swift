//
//  CurlRuntimeCapabilities.swift
//  TraceFeatures
//
//  Created by Codex on 2026/02/08.
//

import Foundation

public struct CurlRuntimeCapabilities: Sendable {
    public let backendName: String
    public let supportedProtocols: Set<String>
    public let supportedOptions: Set<String>

    public init(
        backendName: String,
        supportedProtocols: Set<String>,
        supportedOptions: Set<String>
    ) {
        self.backendName = backendName
        self.supportedProtocols = supportedProtocols
        self.supportedOptions = supportedOptions
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
        ]
    )

    /// Used by tests to verify parser/analyzer option recognition independent of backend limits.
    static let parityValidation: CurlRuntimeCapabilities = .init(
        backendName: "ParityValidation",
        supportedProtocols: [
            "dict", "file", "ftp", "ftps", "gopher", "gophers", "http", "https", "imap", "imaps", "ipfs",
            "ipns", "ldap", "ldaps", "mqtt", "pop3", "pop3s", "rtmp", "rtmpe", "rtmps", "rtmpt", "rtmpte",
            "rtmpts", "rtsp", "scp", "sftp", "smb", "smbs", "smtp", "smtps", "telnet", "tftp", "ws", "wss"
        ],
        supportedOptions: CurlOptionRegistry.allOptions
    )
}
