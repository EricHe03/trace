//
//  NetworkPermissionHeuristics.swift
//  TraceFeatures
//
//  Created by Codex on 2026/02/10.
//

import Foundation

/// Heuristics for classifying local-network permission related failures.
public enum NetworkPermissionHeuristics {
    private static let explicitPermissionTokens = [
        "permission denied",
        "operation not permitted",
        "not permitted",
        "not allowed",
        "access denied"
    ]

    private static let likelyOfflineTokens = [
        "not connected to internet",
        "internet connection appears to be offline",
        "network connection was lost",
        "nsurlerrordomain error -1009"
    ]

    private static let offlineErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost
    ]

    private static let permissionPOSIXErrorCodes: Set<Int> = [1, 13]

    public static func isLikelyPermissionIssue(messages: [String], urls: [String]) -> Bool {
        let normalizedMessages = messages.map { $0.lowercased() }
        let isLocalTarget = targetsLocalNetwork(urls)
        if isLocalTarget && normalizedMessages.contains(where: containsPermissionToken) {
            return true
        }

        let looksOffline = normalizedMessages.contains(where: containsOfflineToken)
        return looksOffline && isLocalTarget
    }

    public static func isLikelyPermissionIssue(error: Error, url: URL?) -> Bool {
        let nsError = error as NSError
        let messages = [
            error.localizedDescription,
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ]
        .compactMap(\.self)
        .filter { !$0.isEmpty }

        let urls = url.map { [$0.absoluteString] } ?? []
        if isLikelyPermissionIssue(messages: messages, urls: urls) {
            return true
        }

        guard let url else { return false }
        guard isLocalNetworkHost(url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? "") else {
            return false
        }

        if let urlError = error as? URLError, offlineErrorCodes.contains(urlError.errorCode) {
            return true
        }
        if nsError.domain == NSURLErrorDomain, offlineErrorCodes.contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, permissionPOSIXErrorCodes.contains(nsError.code) {
            return true
        }
        return false
    }

    public static func targetsLocalNetwork(_ urls: [String]) -> Bool {
        urls.contains(where: isLocalNetworkURL)
    }

    public static func isLocalNetworkURL(_ rawURL: String) -> Bool {
        guard let host = URL(string: rawURL)?
            .host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased() else {
            return false
        }
        return isLocalNetworkHost(host)
    }

    public static func isLocalNetworkHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        return isPrivateIPv4Address(host) || isPrivateIPv6Address(host)
    }

    public static func isPrivateIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".")
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { Int(String($0)) }
        guard values.count == 4, values.allSatisfy({ 0 ... 255 ~= $0 }) else { return false }

        switch (values[0], values[1]) {
        case (10, _), (127, _):
            return true
        case (172, 16 ... 31):
            return true
        case (192, 168):
            return true
        case (169, 254):
            return true
        default:
            return false
        }
    }

    public static func isPrivateIPv6Address(_ host: String) -> Bool {
        guard host.contains(":") else { return false }
        let base = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        if base == "::1" {
            return true
        }
        return base.hasPrefix("fe80:") || base.hasPrefix("fc") || base.hasPrefix("fd")
    }

    private static func containsPermissionToken(_ message: String) -> Bool {
        explicitPermissionTokens.contains(where: { message.contains($0) })
    }

    private static func containsOfflineToken(_ message: String) -> Bool {
        likelyOfflineTokens.contains(where: { message.contains($0) })
    }
}
