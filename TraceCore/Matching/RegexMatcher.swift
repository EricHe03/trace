//
//  RegexMatcher.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public enum RegexSafetyError: Error {
    case patternTooLong
    case inputTooLong
    case compilationFailed
    case timedOut
}

public enum RegexMatcher {
    public static let defaultTimeoutMs: Int = 100
    public static let maxPatternLength: Int = 512
    public static let maxInputLength: Int = 100_000

    public static func safeMatch(
        pattern: String,
        in value: String,
        caseSensitive: Bool = false,
        timeoutMs: Int = defaultTimeoutMs
    ) -> Bool {
        guard pattern.count <= maxPatternLength else { return false }
        guard value.count <= maxInputLength else { return false }

        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return false
        }

        let group = DispatchGroup()
        var matched = false
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let range = NSRange(value.startIndex..., in: value)
            matched = regex.firstMatch(in: value, range: range) != nil
            group.leave()
        }

        if group.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            return false
        }
        return matched
    }
}
