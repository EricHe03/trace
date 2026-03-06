//
//  SharedMatching.swift
//  TraceCore
//
//  Created by Justin on 2026/03/06.
//

import Foundation

func matchSubject(for url: String, pattern: String, matchType: MatchType) -> (subject: String, isHostMatch: Bool) {
    if pattern.contains("://") || pattern.contains("/") {
        return (url, false)
    }

    if matchType == .wildcard, pattern.hasPrefix("*.") {
        let dotCount = pattern.count { $0 == "." }
        if dotCount == 1 {
            return (url, false)
        }
    }

    if let host = URL(string: url)?.host {
        return (host, true)
    }

    return (url, false)
}
