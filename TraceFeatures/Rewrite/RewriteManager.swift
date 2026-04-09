//
//  RewriteManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

/// Manager for rewrite rules - handles loading, saving, matching, and executing rules
@MainActor
public final class RewriteManager: ObservableObject {
    public static let shared = RewriteManager()

    private let rulesManager: PersistentCollectionManager<RewriteRule>
    private let groupsManager: PersistentCollectionManager<RuleGroup>
    private var cancellables: Set<AnyCancellable> = []
    private let maxBodyModificationBytes = 10 * 1024 * 1024
    private let ruleStatsFlushIntervalSeconds: TimeInterval = 5
    private let ruleStatsFlushBatchSize: Int = 100
    private var pendingRuleStats: [UUID: PendingRuleStats] = [:]
    private var ruleStatsFlushTask: Task<Void, Never>?

    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    public var rules: [RewriteRule] {
        rulesManager.items
    }

    public var groups: [RuleGroup] {
        groupsManager.items.sorted { $0.priority < $1.priority }
    }

    private init() {
        self.rulesManager = PersistentCollectionManager(
            descriptor: .rewriteRules,
            logger: FeatureLog.rewrite
        )
        self.groupsManager = PersistentCollectionManager(
            descriptor: .ruleGroups,
            logger: FeatureLog.rewrite
        )

        rulesManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        groupsManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Rule Management (Delegate to Base Manager)

    /// Add a new rule
    public func addRule(_ rule: RewriteRule) {
        var newRule = rule
        newRule.priority = rules.count
        rulesManager.add(newRule)
        updatePriorities()
    }

    /// Update an existing rule
    public func updateRule(_ rule: RewriteRule) {
        rulesManager.update(rule)
    }

    /// Delete a rule
    public func deleteRule(_ rule: RewriteRule) {
        rulesManager.delete(rule)
    }

    /// Delete rules at indices
    public func deleteRules(at indices: IndexSet) {
        rulesManager.delete(at: indices)
    }

    /// Toggle rule enabled state
    public func toggleRule(_ rule: RewriteRule) {
        rulesManager.toggle(rule)
    }

    /// Move rules (for reordering priority)
    public func moveRules(from source: IndexSet, to destination: Int) {
        // Manual implementation of move
        var newRules = rules
        let itemsToMove = source.sorted().reversed().map { newRules.remove(at: $0) }.reversed()

        // Calculate the adjusted destination after removals
        let adjustedDestination = destination - source.count(where: { $0 < destination })

        // Insert items at the destination
        for (offset, item) in itemsToMove.enumerated() {
            newRules.insert(item, at: adjustedDestination + offset)
        }

        rulesManager.replaceAll(newRules)
        updatePriorities()
    }

    /// Update priorities based on array order
    private func updatePriorities() {
        var updatedRules = rules
        for (index, _) in updatedRules.enumerated() {
            updatedRules[index].priority = index
        }
        rulesManager.replaceAll(updatedRules)
    }

    // MARK: - Group Management

    public func addGroup(_ group: RuleGroup) {
        var newGroup = group
        newGroup.priority = groups.count
        groupsManager.add(newGroup)
        updateGroupPriorities()
    }

    public func updateGroup(_ group: RuleGroup) {
        groupsManager.update(group)
    }

    public func deleteGroup(_ group: RuleGroup) {
        groupsManager.delete(group)
        updateGroupPriorities()
    }

    public func toggleGroup(_ group: RuleGroup) {
        groupsManager.toggle(group)
    }

    public func moveGroups(from source: IndexSet, to destination: Int) {
        var current = groups
        let itemsToMove = source.sorted().reversed().map { current.remove(at: $0) }.reversed()
        let adjustedDestination = destination - source.count(where: { $0 < destination })
        for (offset, item) in itemsToMove.enumerated() {
            current.insert(item, at: adjustedDestination + offset)
        }
        groupsManager.replaceAll(current)
        updateGroupPriorities()
    }

    public func importGroups(_ groups: [RuleGroup], merge: Bool = true) {
        groupsManager.importItems(groups, merge: merge)
        updateGroupPriorities()
    }

    public func reloadGroupsIfNeeded() {
        groupsManager.reloadIfNeeded()
    }

    private func updateGroupPriorities() {
        var updatedGroups = groups
        for index in updatedGroups.indices {
            updatedGroups[index].priority = index
        }
        groupsManager.replaceAll(updatedGroups)
    }

    // MARK: - Rule Matching

    /// Find all enabled rules that match a given URL
    public func matchingRules(for url: String, type: RuleType? = nil) -> [RewriteRule] {
        var matching = rulesManager.matchingItems(for: url)
            .sorted { $0.priority < $1.priority }

        if let type {
            matching = matching.filter { $0.ruleType == type }
        }

        return matching
    }

    /// Find all enabled rules that match a request in a given execution phase.
    public func matchingRules(for request: NetworkRequest, phase: ExecutionPhase) -> [RewriteRule] {
        let ruleType: RuleType? = switch phase {
        case .block:
            .block
        case .redirect:
            .redirect
        case .mock:
            .map
        case .rewriteRequest:
            .modifyRequest
        case .rewriteResponse:
            .modifyResponse
        default:
            nil
        }

        var candidates = rules.filter(\.enabled)
        if let ruleType {
            candidates = candidates.filter { $0.ruleType == ruleType }
        }

        let matches = candidates.filter { rule in
            if let criteria = rule.matchCriteria, !criteria.isEmpty {
                return RequestMatcher.evaluate(criteria, request: request, target: rule.ruleType == .modifyResponse ? .response : .request).passed
            }
            return rule.matches(request.url)
        }

        let sorted = matches.sorted { $0.priority < $1.priority }
        guard let firstRule = sorted.first else { return [] }
        if firstRule.matchingStrategy == .firstMatch {
            return [firstRule]
        }
        return sorted
    }

    /// Get the first matching redirect rule
    public func getRedirectUrl(for url: String) -> String? {
        guard let rule = matchingRules(for: url, type: .redirect).first else {
            return nil
        }

        // Look for redirect action
        guard let redirectAction = rule.actions.first(where: { $0.actionType == .redirectTo }),
              let redirectUrl = redirectAction.redirectUrl else {
            return nil
        }

        // Handle wildcard replacement in redirect URL with multiple captures.
        // Use matchCriteria URL pattern when present (modern rules), falling back to legacy matchPattern.
        let capturePattern = rule.matchCriteria?.url?.pattern ?? rule.matchPattern
        if capturePattern.contains("*") && redirectUrl.contains("*"),
           let captures = wildcardCaptures(url: url, pattern: capturePattern) {
            return applyWildcardCaptures(to: redirectUrl, captures: captures)
        }

        return redirectUrl
    }

    /// Check if a URL should be blocked
    public func shouldBlock(url: String) -> Bool {
        !matchingRules(for: url, type: .block).isEmpty
    }

    // MARK: - Rule Application

    private enum ActionTarget {
        case request
        case response
    }

    /// Apply request modification rules to a network request
    public func applyRequestRules(to request: inout NetworkRequest) {
        let rules = matchingRules(for: request, phase: .rewriteRequest)

        for rule in rules {
            for action in rule.actions {
                applyAction(action, to: &request, target: .request)
            }
            if rule.stopProcessing { break }
        }
    }

    /// Apply response modification rules to a network request
    public func applyResponseRules(to request: inout NetworkRequest) {
        let rules = matchingRules(for: request, phase: .rewriteResponse)

        for rule in rules {
            for action in rule.actions {
                applyAction(action, to: &request, target: .response)
            }
            if rule.stopProcessing { break }
        }
    }

    /// Calculate total delay (in milliseconds) for matching rules.
    public func totalDelay(for url: String, type: RuleType) -> Int {
        let rules = matchingRules(for: url, type: type)
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

    /// Apply a single action to a request
    // swiftlint:disable:next cyclomatic_complexity
    private func applyAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) {
        switch action.actionType {
        case .setHeader:
            guard let key = action.headerKey, let value = action.headerValue else { return }

            switch target {
            case .request:
                var updatedRequestHeaders = request.requestHeaders
                if let index = updatedRequestHeaders.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) {
                    updatedRequestHeaders[index] = TraceHTTPHeader(key: key, value: value)
                } else {
                    updatedRequestHeaders.append(TraceHTTPHeader(key: key, value: value))
                }
                request.requestHeaders = updatedRequestHeaders
            case .response:
                var updatedResponseHeaders = request.responseHeaders
                if let index = updatedResponseHeaders.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) {
                    updatedResponseHeaders[index] = TraceHTTPHeader(key: key, value: value)
                } else {
                    updatedResponseHeaders.append(TraceHTTPHeader(key: key, value: value))
                }
                request.responseHeaders = updatedResponseHeaders
            }

        case .removeHeader:
            guard let key = action.headerKey else { return }
            switch target {
            case .request:
                request.requestHeaders.removeAll { $0.key.lowercased() == key.lowercased() }
            case .response:
                request.responseHeaders.removeAll { $0.key.lowercased() == key.lowercased() }
            }

        case .replaceBody:
            guard let pattern = action.bodyPattern,
                  let replacement = action.bodyReplacement else { return }
            let bodyString: String? = switch target {
            case .request:
                request.requestBody.getString()
            case .response:
                request.responseBody.getString()
            }
            guard let bodyString else { return }
            guard pattern.count <= RegexMatcher.maxPatternLength else { return }
            guard bodyString.count <= RegexMatcher.maxInputLength else { return }

            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(bodyString.startIndex..., in: bodyString)
                let replaced = regex.stringByReplacingMatches(
                    in: bodyString,
                    range: range,
                    withTemplate: replacement
                )
                switch target {
                case .request:
                    request.requestBody = BodyStorage.from(string: replaced)
                case .response:
                    request.responseBody = BodyStorage.from(string: replaced)
                }
            } catch {
                FeatureLog.rewrite.error("event=rewrite.regex_replace outcome=failure pattern=\(pattern, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }

        case .setBody:
            guard let content = action.bodyContent else { return }
            switch target {
            case .request:
                request.requestBody = BodyStorage.from(string: content)
                request.requestBodyModified = true
            case .response:
                request.responseBody = BodyStorage.from(string: content)
                request.wasRewritten = true
            }

        case .setStatusCode:
            guard let code = action.statusCode else { return }
            if target == .response {
                request.statusCode = code
            }

        case .addDelay:
            // Delay would be handled during request execution
            break

        case .redirectTo:
            // Redirect is handled separately in getRedirectUrl
            break

        case .setQueryParam:
            guard target == .request, let name = action.queryParamName else { return }
            let value = action.queryParamValue
            request.url = updateQueryParameter(url: request.url, name: name, value: value)
            request.wasRewritten = true

        case .removeQueryParam:
            guard target == .request, let name = action.queryParamName else { return }
            request.url = removeQueryParameter(url: request.url, name: name)
            request.wasRewritten = true

        case .setCookie:
            guard let name = action.cookieName else { return }
            let value = action.cookieValue ?? ""
            switch target {
            case .request:
                request.requestHeaders = setCookieHeader(headers: request.requestHeaders, name: name, value: value)
            case .response:
                request.responseHeaders = setSetCookieHeader(headers: request.responseHeaders, name: name, value: value)
            }

        case .removeCookie:
            guard let name = action.cookieName else { return }
            switch target {
            case .request:
                request.requestHeaders = removeCookieHeader(headers: request.requestHeaders, name: name)
            case .response:
                request.responseHeaders = removeSetCookieHeader(headers: request.responseHeaders, name: name)
            }

        case .base64Encode:
            transformBody(request: &request, target: target) { data in
                Data(data.base64EncodedString().utf8)
            }

        case .base64Decode:
            transformBody(request: &request, target: target) { data in
                Data(base64Encoded: data) ?? data
            }

        case .urlEncode:
            transformBody(request: &request, target: target) { data in
                guard let str = String(data: data, encoding: .utf8) else { return data }
                return Data((str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str).utf8)
            }

        case .urlDecode:
            transformBody(request: &request, target: target) { data in
                guard let str = String(data: data, encoding: .utf8) else { return data }
                return Data((str.removingPercentEncoding ?? str).utf8)
            }

        case .compress:
            transformBody(request: &request, target: target) { data in
                CompressionHelper.compress(data: data, algorithm: action.compressionAlgorithm) ?? data
            }

        case .decompress:
            transformBody(request: &request, target: target) { data in
                CompressionHelper.decompress(
                    data: data,
                    algorithm: action.compressionAlgorithm,
                    maxOutputBytes: maxBodyModificationBytes
                ) ?? data
            }

        case .jsonToXml:
            transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonToXML(data: data) ?? data
            }

        case .xmlToJson:
            transformBody(request: &request, target: target) { data in
                JSONXMLConverter.xmlToJSON(data: data) ?? data
            }

        case .jsonPathSet:
            guard let path = action.jsonPath, let rawValue = action.jsonValue else { return }
            transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonPathSet(data: data, path: path, rawValue: rawValue) ?? data
            }

        case .jsonPathDelete:
            guard let path = action.jsonPath else { return }
            transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonPathDelete(data: data, path: path) ?? data
            }

        case .setBodyFromTemplate:
            guard let template = action.templateBody else { return }
            let rendered = TemplateEngine().render(template, context: TemplateContext(request: request))
            switch target {
            case .request:
                request.requestBody = BodyStorage.from(string: rendered)
                request.requestBodyModified = true
            case .response:
                request.responseBody = BodyStorage.from(string: rendered)
                request.wasRewritten = true
            }

        case .throttle, .addJitter, .dropConnection, .resetConnection, .corruptData, .timeout, .packetLoss:
            // These are handled in the RequestInterceptor pipeline.
            break
        }
    }

    private func updateQueryParameter(url: String, name: String, value: String?) -> String {
        guard var components = URLComponents(string: url) else { return url }
        var items = components.queryItems ?? []
        if let index = items.firstIndex(where: { $0.name == name }) {
            items[index].value = value
        } else {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        return components.string ?? url
    }

    private func removeQueryParameter(url: String, name: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != name }
        return components.string ?? url
    }

    private func setCookieHeader(headers: [TraceHTTPHeader], name: String, value: String) -> [TraceHTTPHeader] {
        var updated = headers
        let cookieValue = "\(name)=\(value)"
        if let index = updated.firstIndex(where: { $0.key.lowercased() == "cookie" }) {
            var existing = updated[index].value
            if existing.isEmpty {
                existing = cookieValue
            } else if existing.contains("\(name)=") {
                existing = removeCookieValue(from: existing, name: name)
                existing = existing.isEmpty ? cookieValue : "\(existing); \(cookieValue)"
            } else {
                existing += "; \(cookieValue)"
            }
            updated[index] = TraceHTTPHeader(key: updated[index].key, value: existing)
        } else {
            updated.append(TraceHTTPHeader(key: "Cookie", value: cookieValue))
        }
        return updated
    }

    private func removeCookieHeader(headers: [TraceHTTPHeader], name: String) -> [TraceHTTPHeader] {
        var updated = headers
        guard let index = updated.firstIndex(where: { $0.key.lowercased() == "cookie" }) else { return updated }
        let cleaned = removeCookieValue(from: updated[index].value, name: name)
        if cleaned.isEmpty {
            updated.remove(at: index)
        } else {
            updated[index] = TraceHTTPHeader(key: updated[index].key, value: cleaned)
        }
        return updated
    }

    private func removeCookieValue(from headerValue: String, name: String) -> String {
        let parts = headerValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let filtered = parts.filter { !$0.hasPrefix("\(name)=") }
        return filtered.joined(separator: "; ")
    }

    private func setSetCookieHeader(headers: [TraceHTTPHeader], name: String, value: String) -> [TraceHTTPHeader] {
        var updated = headers
        let headerValue = "\(name)=\(value)"
        if let index = updated.firstIndex(where: { $0.key.lowercased() == "set-cookie" }) {
            updated[index] = TraceHTTPHeader(key: updated[index].key, value: headerValue)
        } else {
            updated.append(TraceHTTPHeader(key: "Set-Cookie", value: headerValue))
        }
        return updated
    }

    private func removeSetCookieHeader(headers: [TraceHTTPHeader], name: String) -> [TraceHTTPHeader] {
        headers.filter { header in
            guard header.key.lowercased() == "set-cookie" else { return true }
            return !header.value.hasPrefix("\(name)=")
        }
    }

    private func transformBody(
        request: inout NetworkRequest,
        target: ActionTarget,
        transform: (Data) -> Data
    ) {
        let originalData = (target == .request) ? (request.requestBody.getData() ?? Data()) : (request.responseBody.getData() ?? Data())
        if originalData.count > maxBodyModificationBytes {
            return
        }
        let contentType = resolvedContentType(for: request, target: target)
        if ContentSafety.shouldSkipTextOperation(originalData, contentType: contentType) {
            return
        }
        let transformed = transform(originalData)
        if target == .request {
            request.requestBody = BodyStorage.from(data: transformed)
            request.requestBodyModified = true
        } else {
            request.responseBody = BodyStorage.from(data: transformed)
            request.wasRewritten = true
        }
    }

    private func resolvedContentType(for request: NetworkRequest, target: ActionTarget) -> String? {
        switch target {
        case .request:
            request.requestHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value
        case .response:
            request.responseHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value ?? request.contentType
        }
    }

    // MARK: - Persistence (Delegate to Base Manager)

    /// Export rules to JSON file
    public func exportRules() throws -> URL {
        try rulesManager.exportItems()
    }

    /// Import rules from JSON file
    public func importRules(from url: URL, merge: Bool = true) throws {
        try rulesManager.importItems(from: url, merge: merge)
        updatePriorities()
    }

    /// Import rules from decoded data
    public func importRules(_ importedRules: [RewriteRule], merge: Bool = true) {
        rulesManager.importItems(importedRules, merge: merge)
        updatePriorities()
    }

    /// Clear all rules
    public func clearAllRules() {
        rulesManager.clearAll()
    }

    /// Reload rules if the backing file has changed.
    public func reloadIfNeeded() {
        rulesManager.reloadIfNeeded()
    }

    // MARK: - Helper Methods

    private func wildcardCaptures(url: String, pattern: String) -> [String]? {
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

    private func applyWildcardCaptures(to template: String, captures: [String]) -> String {
        var result = template
        var remainingCaptures = captures

        while let range = result.range(of: "*"), !remainingCaptures.isEmpty {
            result.replaceSubrange(range, with: remainingCaptures.removeFirst())
        }

        return result
    }

    // MARK: - Statistics (Delegate to Base Manager)

    public var enabledRulesCount: Int {
        rulesManager.enabledCount
    }

    public var totalRulesCount: Int {
        rulesManager.totalCount
    }

    public func rulesCount(for type: RuleType) -> Int {
        rules.count(where: { $0.ruleType == type })
    }

    public func previewRules(for request: NetworkRequest, phase: ExecutionPhase) -> [ExecutionLogEntry] {
        let rules = matchingRules(for: request, phase: phase)
        return rules.map { rule in
            ExecutionLogEntry(
                phase: phase,
                ruleId: rule.id,
                ruleName: rule.name,
                outcome: .matched,
                message: "Dry run"
            )
        }
    }

    public func recordRuleHit(_ ruleId: UUID, durationMs: Double) {
        let now = Date()
        var stats = pendingRuleStats[ruleId] ?? PendingRuleStats(hitCount: 0, totalDurationMs: 0, lastHitAt: now)
        stats.hitCount += 1
        stats.totalDurationMs += durationMs
        stats.lastHitAt = max(stats.lastHitAt, now)
        pendingRuleStats[ruleId] = stats

        let pendingCount = pendingRuleStats.values.reduce(0) { $0 + $1.hitCount }
        if pendingCount >= ruleStatsFlushBatchSize {
            flushPendingRuleStats()
            return
        }

        scheduleRuleStatsFlushIfNeeded()
    }
}

private extension RewriteManager {
    struct PendingRuleStats {
        var hitCount: Int
        var totalDurationMs: Double
        var lastHitAt: Date
    }

    func scheduleRuleStatsFlushIfNeeded() {
        guard ruleStatsFlushTask == nil else { return }
        ruleStatsFlushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.ruleStatsFlushIntervalSeconds * 1_000_000_000))
            await MainActor.run {
                self.flushPendingRuleStats()
            }
        }
    }

    func flushPendingRuleStats() {
        ruleStatsFlushTask?.cancel()
        ruleStatsFlushTask = nil

        guard !pendingRuleStats.isEmpty else { return }
        let deltas = pendingRuleStats
        pendingRuleStats.removeAll(keepingCapacity: true)

        var updated = rules
        var changed = false

        for index in updated.indices {
            let id = updated[index].id
            guard let delta = deltas[id], delta.hitCount > 0 else { continue }

            let previousHitCount = updated[index].hitCount
            let newHitCount = previousHitCount + delta.hitCount

            let previousTotal = (updated[index].averageExecutionTimeMs ?? 0) * Double(previousHitCount)
            let newTotal = previousTotal + delta.totalDurationMs

            updated[index].hitCount = newHitCount
            updated[index].lastHitAt = max(updated[index].lastHitAt ?? delta.lastHitAt, delta.lastHitAt)
            updated[index].averageExecutionTimeMs = newHitCount > 0 ? (newTotal / Double(newHitCount)) : nil
            changed = true
        }

        guard changed else { return }
        rulesManager.replaceAll(updated)
    }
}
