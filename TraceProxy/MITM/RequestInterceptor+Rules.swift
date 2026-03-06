//
//  RequestInterceptor+Rules.swift
//  TraceProxy
//
//  Created by AI Assistant on 2026/03/06.
//

import Foundation
import TraceCore
import TraceFeatures

extension RequestInterceptor {
    func applyRequestRules(to request: inout NetworkRequest) -> Bool {
        let rules = matchingRules(for: request, type: .modifyRequest, target: .request)

        var didModifyBody = false

        for rule in rules {
            let start = Date()
            let before = request
            for action in rule.actions {
                didModifyBody = applyAction(action, to: &request, target: .request) || didModifyBody
            }
            request.appliedRuleIds.append(rule.id)
            validateContent(&request, target: .request, ruleId: rule.id)
            let summary = diffSummary(before: before, after: request, target: .request)
            let duration = Date().timeIntervalSince(start)
            request.executionLog.append(
                ExecutionLogEntry(
                    phase: .rewriteRequest,
                    ruleId: rule.id,
                    ruleName: rule.name,
                    outcome: .applied,
                    duration: duration,
                    diffSummary: summary
                )
            )
            Task { @MainActor in
                RewriteManager.shared.recordRuleHit(rule.id, durationMs: duration * 1000)
            }
            if rule.stopProcessing { break }
        }

        if !rules.isEmpty {
            request.wasRewritten = true
        }

        return didModifyBody
    }

    func applyResponseRules(to request: inout NetworkRequest) {
        let rules = matchingRules(for: request, type: .modifyResponse, target: .response)

        for rule in rules {
            let start = Date()
            let before = request
            for action in rule.actions {
                applyAction(action, to: &request, target: .response)
            }
            request.appliedRuleIds.append(rule.id)
            validateContent(&request, target: .response, ruleId: rule.id)
            let summary = diffSummary(before: before, after: request, target: .response)
            let duration = Date().timeIntervalSince(start)
            request.executionLog.append(
                ExecutionLogEntry(
                    phase: .rewriteResponse,
                    ruleId: rule.id,
                    ruleName: rule.name,
                    outcome: .applied,
                    duration: duration,
                    diffSummary: summary
                )
            )
            Task { @MainActor in
                RewriteManager.shared.recordRuleHit(rule.id, durationMs: duration * 1000)
            }
            if rule.stopProcessing { break }
        }

        if !rules.isEmpty {
            request.wasRewritten = true
        }
    }

    func totalDelay(for request: NetworkRequest, type: RuleType, target: MatchTarget) -> Int {
        let rules = matchingRules(for: request, type: type, target: target)

        return rules.reduce(0) { total, rule in
            let ruleDelay = rule.actions.reduce(0) { innerTotal, action in
                guard action.actionType == .addDelay, let delay = action.delayMilliseconds else {
                    return innerTotal
                }
                return innerTotal + delay
            }
            return total + ruleDelay
        }
    }

    func simulationActions(for request: NetworkRequest, type: RuleType, target: MatchTarget) -> [RewriteAction] {
        matchingRules(for: request, type: type, target: target)
            .flatMap(\.actions)
            .filter { action in
                switch action.actionType {
                case .throttle, .addJitter, .dropConnection, .resetConnection, .corruptData, .timeout, .packetLoss:
                    true
                default:
                    false
                }
            }
    }

    func applyNetworkSimulation(
        actions: [RewriteAction],
        request: inout NetworkRequest,
        target: ActionTarget
    ) async -> RequestInterceptionFailure? {
        guard !actions.isEmpty else { return nil }
        let simulator = NetworkSimulator()

        for action in actions {
            switch action.actionType {
            case .addJitter:
                let baseDelay = action.jitterBaseMs ?? 0
                let variance = action.jitterVarianceMs ?? 0
                await simulator.applyJitter(baseDelay: baseDelay, variance: variance)

            case .throttle:
                let bandwidth = action.throttleBytesPerSecond ?? 0
                let data = target == .request ? (request.requestBody.getData() ?? Data()) : (request.responseBody.getData() ?? Data())
                let throttled = await simulator.applyThrottle(bandwidth: bandwidth, to: data)
                if target == .request {
                    request.requestBody = BodyStorage.from(data: throttled)
                    request.requestBodyModified = true
                } else {
                    request.responseBody = BodyStorage.from(data: throttled)
                    request.wasRewritten = true
                }

            case .corruptData:
                corruptBody(request: &request, target: target)

            case .timeout:
                return .timeout

            case .resetConnection:
                return .connectionReset

            case .dropConnection:
                return .dropConnection

            case .packetLoss:
                return .packetLoss

            default:
                break
            }
        }
        return nil
    }

    func matchingRules(for request: NetworkRequest, type: RuleType, target: MatchTarget) -> [RewriteRule] {
        let enabledGroups = configSnapshot.ruleGroups.filter(\.enabled)
        let groupedRuleIds = Set(enabledGroups.flatMap(\.rules))
        let allowedGroupIds = Set(configSnapshot.activeProfile?.ruleGroups ?? enabledGroups.map(\.id))
        let allowedRuleIds = Set(enabledGroups.filter { allowedGroupIds.contains($0.id) }.flatMap(\.rules))

        let candidates = configSnapshot.rewriteRules.filter { rule in
            guard rule.enabled, rule.ruleType == type else { return false }
            if groupedRuleIds.contains(rule.id) {
                return allowedRuleIds.contains(rule.id)
            }
            return true
        }
        let matched = candidates.filter { ruleMatches($0, request: request, target: target) }
        let sorted = matched.sorted { $0.priority < $1.priority }
        guard let first = sorted.first else { return [] }
        if first.matchingStrategy == .firstMatch {
            return [first]
        }
        return sorted
    }

    func ruleMatches(_ rule: RewriteRule, request: NetworkRequest, target: MatchTarget) -> Bool {
        if let criteria = rule.matchCriteria, !criteria.isEmpty {
            return RequestMatcher.evaluate(criteria, request: request, target: target).passed
        }
        return matchesPattern(url: request.url, pattern: rule.matchPattern, matchType: rule.matchType)
    }

    func matchesPattern(url: String, pattern: String, matchType: MatchType) -> Bool {
        switch matchType {
        case .contains:
            url.localizedCaseInsensitiveContains(pattern)
        case .exact:
            url == pattern
        case .regex:
            RegexMatcher.safeMatch(pattern: pattern, in: url, caseSensitive: false)
        case .wildcard:
            matchesWildcard(url: url, pattern: pattern)
        }
    }

    func matchesWildcard(url: String, pattern: String) -> Bool {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = "^" + regexPattern + "$"

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive) else {
            return false
        }

        let range = NSRange(url.startIndex..., in: url)
        return regex.firstMatch(in: url, range: range) != nil
    }

    func wildcardCaptures(url: String, pattern: String) -> [String]? {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: "(.*?)")
        regexPattern = "^" + regexPattern + "$"

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(url.startIndex..., in: url)
        guard let match = regex.firstMatch(in: url, range: range) else {
            return nil
        }

        var captures: [String] = []
        for index in 1 ..< match.numberOfRanges {
            let captureRange = match.range(at: index)
            if let swiftRange = Range(captureRange, in: url) {
                captures.append(String(url[swiftRange]))
            } else {
                captures.append("")
            }
        }

        return captures
    }

    func applyWildcardCaptures(to template: String, captures: [String]) -> String {
        var result = template
        var remainingCaptures = captures

        while let range = result.range(of: "*"), !remainingCaptures.isEmpty {
            result.replaceSubrange(range, with: remainingCaptures.removeFirst())
        }

        return result
    }

    func corruptBody(request: inout NetworkRequest, target: ActionTarget) {
        var data = target == .request ? (request.requestBody.getData() ?? Data()) : (request.responseBody.getData() ?? Data())
        guard !data.isEmpty else { return }
        let index = max(0, data.count / 2)
        data[index] = data[index] ^ 0xFF
        if target == .request {
            request.requestBody = BodyStorage.from(data: data)
            request.requestBodyModified = true
        } else {
            request.responseBody = BodyStorage.from(data: data)
            request.wasRewritten = true
        }
    }
}
