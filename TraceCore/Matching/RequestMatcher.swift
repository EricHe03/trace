//
//  RequestMatcher.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public enum MatchTarget: Sendable {
    case request
    case response
}

public struct MatcherEvaluation: Sendable {
    public let matcher: String
    public let passed: Bool
    public let message: String?

    public init(matcher: String, passed: Bool, message: String? = nil) {
        self.matcher = matcher
        self.passed = passed
        self.message = message
    }
}

public struct MatchEvaluation: Sendable {
    public let passed: Bool
    public let details: [MatcherEvaluation]

    public init(passed: Bool, details: [MatcherEvaluation]) {
        self.passed = passed
        self.details = details
    }
}

public enum RequestMatcher {
    public static func evaluate(
        _ criteria: MatchCriteria,
        request: NetworkRequest,
        target: MatchTarget
    ) -> MatchEvaluation {
        var results: [Bool] = []
        var details: [MatcherEvaluation] = []

        if let urlMatcher = criteria.url {
            let matched = urlMatcher.matches(request.url)
            results.append(matched)
            details.append(MatcherEvaluation(matcher: "url", passed: matched))
        }

        if !criteria.methods.isEmpty {
            let matched = criteria.methods.contains(request.method)
            results.append(matched)
            details.append(MatcherEvaluation(matcher: "method", passed: matched))
        }

        if !criteria.hosts.isEmpty {
            let host = parsedHost(from: request.url)
            let matched = criteria.hosts.contains { $0.matches(host) }
            results.append(matched)
            details.append(MatcherEvaluation(matcher: "host", passed: matched, message: host))
        }

        if !criteria.schemes.isEmpty {
            let scheme = parsedScheme(from: request.url)
            let matched = criteria.schemes.contains(scheme)
            results.append(matched)
            details.append(MatcherEvaluation(matcher: "scheme", passed: matched, message: scheme))
        }

        if !criteria.ports.isEmpty {
            let port = parsedPort(from: request.url)
            let matched = criteria.ports.contains(port)
            results.append(matched)
            details.append(MatcherEvaluation(matcher: "port", passed: matched, message: "\(port)"))
        }

        if !criteria.headers.isEmpty {
            let headerValues = normalizedHeaders(from: request, target: target)
            for matcher in criteria.headers {
                let matched = matchesHeader(matcher.normalized(), headers: headerValues)
                results.append(matched)
                details.append(MatcherEvaluation(matcher: "header:\(matcher.name)", passed: matched))
            }
        }

        if !criteria.queryParams.isEmpty {
            let queryItems = parsedQueryItems(from: request.url)
            for matcher in criteria.queryParams {
                let matched = matchesQueryParam(matcher.normalized(), items: queryItems)
                results.append(matched)
                details.append(MatcherEvaluation(matcher: "query:\(matcher.name)", passed: matched))
            }
        }

        if !criteria.statusCodes.isEmpty {
            let code = request.statusCode ?? -1
            let matched = criteria.statusCodes.contains(code)
            results.append(matched)
            details.append(MatcherEvaluation(matcher: "status", passed: matched, message: "\(code)"))
        }

        if !criteria.contentTypes.isEmpty {
            // `request.contentType` is extracted from response headers; only use it for response matching.
            let extracted = (target == .response) ? request.contentType : nil
            let contentType = extracted ?? headerValue(for: "content-type", request: request, target: target) ?? ""
            let matched = criteria.contentTypes.contains { $0.matches(contentType) }
            results.append(matched)
            details.append(MatcherEvaluation(matcher: "contentType", passed: matched, message: contentType))
        }

        if !criteria.bodyMatchers.isEmpty {
            let bodyData = target == .request ? request.requestBody.getData() : request.responseBody.getData()
            let bodyString = target == .request ? request.requestBody.getString() : request.responseBody.getString()
            for matcher in criteria.bodyMatchers {
                let matched = matchesBody(matcher, bodyData: bodyData, bodyString: bodyString)
                results.append(matched)
                details.append(MatcherEvaluation(matcher: "body:\(matcher.matcherType.rawValue)", passed: matched))
            }
        }

        let passed = evaluateResults(results, logic: criteria.logic)
        return MatchEvaluation(passed: passed, details: details)
    }

    private static func evaluateResults(_ results: [Bool], logic: MatchLogic) -> Bool {
        guard !results.isEmpty else { return true }
        switch logic {
        case .and:
            return results.allSatisfy(\.self)
        case .or:
            return results.contains(true)
        }
    }

    private static func normalizedHeaders(from request: NetworkRequest, target: MatchTarget) -> [String: [String]] {
        let headers = (target == .request) ? request.requestHeaders : request.responseHeaders
        var dict: [String: [String]] = [:]
        for header in headers {
            dict[header.key.lowercased(), default: []].append(header.value)
        }
        return dict
    }

    private static func matchesHeader(_ matcher: HeaderMatcher, headers: [String: [String]]) -> Bool {
        let name = matcher.name.lowercased()
        let values = headers[name] ?? []
        return matchesCondition(matcher.condition, values: values, matcher: matcher.matcher)
    }

    private static func matchesQueryParam(_ matcher: QueryParamMatcher, items: [URLQueryItem]) -> Bool {
        let matches = items.filter { $0.name == matcher.name }
        let values = matches.compactMap(\.value)
        return matchesCondition(matcher.condition, values: values, matcher: matcher.matcher, exists: !matches.isEmpty)
    }

    private static func matchesCondition(
        _ condition: MatchCondition,
        values: [String],
        matcher: StringMatcher?,
        exists: Bool? = nil
    ) -> Bool {
        let valueExists = exists ?? !values.isEmpty
        switch condition {
        case .exists:
            return valueExists
        case .notExists:
            return !valueExists
        case .equals:
            guard valueExists, let matcher else { return false }
            return values.contains(where: { matcher.matches($0) })
        case .notEquals:
            // Note: Use `.notExists` to match absence explicitly.
            guard valueExists, let matcher else { return false }
            return !values.contains(where: { matcher.matches($0) })
        case .contains:
            guard valueExists, let matcher else { return false }
            return values.contains(where: { matcher.matches($0) })
        case .regex:
            guard valueExists, let matcher else { return false }
            return values.contains(where: { matcher.matches($0) })
        }
    }

    private static func matchesBody(_ matcher: BodyMatcher, bodyData: Data?, bodyString: String?) -> Bool {
        switch matcher.matcherType {
        case .contains:
            guard let bodyString else { return false }
            return bodyString.contains(matcher.pattern)
        case .regex:
            guard let bodyString else { return false }
            return RegexMatcher.safeMatch(pattern: matcher.pattern, in: bodyString, caseSensitive: false)
        case .jsonPath:
            guard let bodyData else { return false }
            return JSONPathEvaluator().get(json: bodyData, path: matcher.pattern) != nil
        case .xpath:
            guard let bodyString else { return false }
            return XPathMatcher.matches(xpath: matcher.pattern, in: bodyString)
        }
    }

    private static func parsedHost(from url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private static func parsedScheme(from url: String) -> String {
        URL(string: url)?.scheme?.lowercased() ?? ""
    }

    private static func parsedPort(from url: String) -> Int {
        guard let components = URLComponents(string: url) else { return 0 }
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return 0
        }
    }

    private static func parsedQueryItems(from url: String) -> [URLQueryItem] {
        URLComponents(string: url)?.queryItems ?? []
    }

    private static func headerValue(for name: String, request: NetworkRequest, target: MatchTarget) -> String? {
        let headers = target == .request ? request.requestHeaders : request.responseHeaders
        return headers.first(where: { $0.key.lowercased() == name.lowercased() })?.value
    }
}

private extension HeaderMatcher {
    func normalized() -> HeaderMatcher {
        guard var matcher else { return self }
        switch condition {
        case .equals, .notEquals:
            matcher.matchType = .exact
        case .contains:
            matcher.matchType = .contains
        case .regex:
            matcher.matchType = .regex
        case .exists, .notExists:
            break
        }
        return HeaderMatcher(name: name, matcher: matcher, condition: condition)
    }
}

private extension QueryParamMatcher {
    func normalized() -> QueryParamMatcher {
        guard var matcher else { return self }
        switch condition {
        case .equals, .notEquals:
            matcher.matchType = .exact
        case .contains:
            matcher.matchType = .contains
        case .regex:
            matcher.matchType = .regex
        case .exists, .notExists:
            break
        }
        return QueryParamMatcher(name: name, matcher: matcher, condition: condition)
    }
}
