//
//  TemplateEngine.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public struct TemplateContext: Sendable {
    public var request: NetworkRequest

    public init(request: NetworkRequest) {
        self.request = request
    }
}

public final class TemplateEngine {
    private static let tokenRegex: NSRegularExpression? = {
        let pattern = #"\{\{\s*([^\}]+)\s*\}\}"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let isoFormatter: ISO8601DateFormatter = .init()

    public init() {}

    public func render(_ template: String, context: TemplateContext) -> String {
        guard let regex = Self.tokenRegex else {
            return template
        }

        let range = NSRange(template.startIndex..., in: template)
        let matches = regex.matches(in: template, range: range)
        guard !matches.isEmpty else { return template }

        let now = Date()
        var result = template
        for match in matches.reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let token = String(result[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = resolveToken(token, context: context, now: now)
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private func resolveToken(_ token: String, context: TemplateContext, now: Date) -> String {
        switch token {
        case "timestamp":
            return String(Int(now.timeIntervalSince1970))
        case "isoDate":
            return Self.isoFormatter.string(from: now)
        case "randomInt":
            return String(Int.random(in: 0 ... 999_999))
        case "randomUUID":
            return UUID().uuidString
        case "requestUrl":
            return context.request.url
        case "requestMethod":
            return context.request.method.rawValue
        default:
            break
        }

        if token.hasPrefix("requestHeader.") {
            let name = token.replacingOccurrences(of: "requestHeader.", with: "")
            return context.request.requestHeaders.first(where: { $0.key.lowercased() == name.lowercased() })?.value ?? ""
        }

        if token.hasPrefix("env.") {
            let key = token.replacingOccurrences(of: "env.", with: "")
            return ProcessInfo.processInfo.environment[key] ?? ""
        }

        return ""
    }
}
