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
    @available(*, deprecated, message: "NSRegularExpression does not support cancellation/timeouts; this is retained for API compatibility only.")
    case timedOut
}

public enum RegexMatcher {
    /// Retained for source compatibility; timeouts are not enforceable with `NSRegularExpression`.
    public static let defaultTimeoutMs: Int = 100
    public static let maxPatternLength: Int = 512
    public static let maxInputLength: Int = 100_000

    /// A detailed variant of `safeMatch` that explains rejection reasons.
    public static func safeMatchDetailed(
        pattern: String,
        in value: String,
        caseSensitive: Bool = true
    ) -> Result<Bool, RegexSafetyError> {
        guard !pattern.isEmpty else { return .success(false) }
        guard pattern.count <= maxPatternLength else { return .failure(.patternTooLong) }
        guard value.count <= maxInputLength else { return .failure(.inputTooLong) }

        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return .failure(.compilationFailed)
        }

        let range = NSRange(value.startIndex..., in: value)
        let matched = regex.firstMatch(in: value, range: range) != nil
        return .success(matched)
    }

    public static func safeMatch(
        pattern: String,
        in value: String,
        caseSensitive: Bool = true,
        timeoutMs _: Int = defaultTimeoutMs
    ) -> Bool {
        // Note: NSRegularExpression does not support cancellation/timeouts. We intentionally avoid
        // spawning background work that would continue after returning.
        switch safeMatchDetailed(pattern: pattern, in: value, caseSensitive: caseSensitive) {
        case let .success(matched):
            return matched
        case .failure:
            return false
        }
    }
}
