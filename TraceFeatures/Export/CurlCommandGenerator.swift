//
//  CurlCommandGenerator.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

public struct CurlExportOptions {
    public var followRedirects: Bool

    public init(followRedirects: Bool = false) {
        self.followRedirects = followRedirects
    }
}

/// Utility for generating cURL commands from NetworkRequest objects
public enum CurlCommandGenerator {
    /// Generates a cURL command string from a NetworkRequest
    /// - Parameter request: The network request to convert
    /// - Returns: A formatted cURL command string
    public static func generate(from request: NetworkRequest, options: CurlExportOptions = .init()) -> String {
        var curl = "curl"
        switch request.protocolVersion {
        case .http10:
            curl += " --http1.0"
        case .http11:
            curl += " --http1.1"
        case .http2:
            curl += " --http2"
        case .http3:
            curl += " --http3"
        case .none:
            break
        }

        if options.followRedirects {
            curl += " -L"
        }

        curl += " -X \(request.method.rawValue) \\\n"
        curl += "  '\(shellEscape(request.url))'"

        // Headers to exclude (browser-specific, automatic, or redundant)
        let excludedHeaders = [
            "accept-encoding", // curl handles compression automatically
            "cache-control", // cache directives
            "content-length", // curl computes this automatically
            "pragma", // legacy cache directive
            "priority", // browser priority hints
            "upgrade-insecure-requests"
        ]

        let excludedPrefixes = [
            ":", // HTTP/2 pseudo-headers
            "sec-ch-ua", // Client hints
            "sec-fetch-", // Fetch metadata
            "next-router-", // Next.js internal
            "x-deployment-" // Deployment-specific
        ]

        // Filter headers
        let validHeaders = request.requestHeaders.filter { header in
            let lowerKey = header.key.lowercased()

            // Exclude if in excluded list
            if excludedHeaders.contains(lowerKey) {
                return false
            }

            // Exclude if matches any excluded prefix
            for prefix in excludedPrefixes {
                if lowerKey.hasPrefix(prefix) {
                    return false
                }
            }

            return true
        }

        for header in validHeaders {
            let headerValue = "\(header.key): \(header.value)"
            curl += " \\\n  -H '\(shellEscape(headerValue))'"
        }

        if let body = request.requestBody.getString() {
            curl += " \\\n  --data-raw '\(shellEscape(body))'"
        }

        return curl
    }

    private static func shellEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}
