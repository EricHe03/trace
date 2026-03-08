//
//  RequestInterceptor+Actions.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import TraceCore
import TraceFeatures

enum ActionTarget {
    case request
    case response
}

extension RequestInterceptor {
    func applyAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) -> Bool {
        switch action.actionType {
        case .setHeader, .removeHeader:
            applyHeaderAction(action, to: &request, target: target)
        case .replaceBody, .setBody, .setStatusCode, .setBodyFromTemplate:
            applyContentMutationAction(action, to: &request, target: target)
        case .setQueryParam, .removeQueryParam:
            applyQueryAction(action, to: &request, target: target)
        case .setCookie, .removeCookie:
            applyCookieAction(action, to: &request, target: target)
        case .base64Encode, .base64Decode, .urlEncode, .urlDecode, .compress, .decompress:
            applyBodyEncodingAction(action, to: &request, target: target)
        case .jsonToXml, .xmlToJson, .jsonPathSet, .jsonPathDelete:
            applyStructuredBodyAction(action, to: &request, target: target)
        case .addDelay, .redirectTo, .throttle, .addJitter, .dropConnection, .resetConnection, .corruptData, .timeout, .packetLoss:
            false
        }
    }

    func applyHeaderAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) -> Bool {
        switch action.actionType {
        case .setHeader:
            guard let key = action.headerKey, let value = action.headerValue else { return false }
            switch target {
            case .request:
                upsertHeader(&request.requestHeaders, key: key, value: value)
            case .response:
                upsertHeader(&request.responseHeaders, key: key, value: value)
            }
            return false
        case .removeHeader:
            guard let key = action.headerKey else { return false }
            switch target {
            case .request:
                request.requestHeaders.removeAll { $0.key.lowercased() == key.lowercased() }
            case .response:
                request.responseHeaders.removeAll { $0.key.lowercased() == key.lowercased() }
            }
            return false
        default:
            return false
        }
    }

    func applyContentMutationAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) -> Bool {
        switch action.actionType {
        case .replaceBody:
            return replaceBody(action, in: &request, target: target)
        case .setBody:
            guard let content = action.bodyContent else { return false }
            setBody(content, on: &request, target: target)
            return target == .request
        case .setStatusCode:
            guard let code = action.statusCode, target == .response else { return false }
            request.statusCode = code
            return false
        case .setBodyFromTemplate:
            guard let template = action.templateBody else { return false }
            let rendered = TemplateEngine().render(template, context: TemplateContext(request: request))
            setBody(rendered, on: &request, target: target)
            return target == .request
        default:
            return false
        }
    }

    func applyQueryAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) -> Bool {
        guard target == .request, let name = action.queryParamName else { return false }
        switch action.actionType {
        case .setQueryParam:
            request.url = updateQueryParameter(url: request.url, name: name, value: action.queryParamValue)
            request.wasRewritten = true
            return false
        case .removeQueryParam:
            request.url = removeQueryParameter(url: request.url, name: name)
            request.wasRewritten = true
            return false
        default:
            return false
        }
    }

    func applyCookieAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) -> Bool {
        guard let name = action.cookieName else { return false }
        switch action.actionType {
        case .setCookie:
            let value = action.cookieValue ?? ""
            switch target {
            case .request:
                request.requestHeaders = setCookieHeader(headers: request.requestHeaders, name: name, value: value)
            case .response:
                request.responseHeaders = setSetCookieHeader(headers: request.responseHeaders, name: name, value: value)
            }
            return false
        case .removeCookie:
            switch target {
            case .request:
                request.requestHeaders = removeCookieHeader(headers: request.requestHeaders, name: name)
            case .response:
                request.responseHeaders = removeSetCookieHeader(headers: request.responseHeaders, name: name)
            }
            return false
        default:
            return false
        }
    }

    func applyBodyEncodingAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) -> Bool {
        switch action.actionType {
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
        default:
            false
        }
    }

    func applyStructuredBodyAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) -> Bool {
        switch action.actionType {
        case .jsonToXml:
            return transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonToXML(data: data) ?? data
            }
        case .xmlToJson:
            return transformBody(request: &request, target: target) { data in
                JSONXMLConverter.xmlToJSON(data: data) ?? data
            }
        case .jsonPathSet:
            guard let path = action.jsonPath, let rawValue = action.jsonValue else { return false }
            return transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonPathSet(data: data, path: path, rawValue: rawValue) ?? data
            }
        case .jsonPathDelete:
            guard let path = action.jsonPath else { return false }
            return transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonPathDelete(data: data, path: path) ?? data
            }
        default:
            return false
        }
    }

    func replaceBody(_ action: RewriteAction, in request: inout NetworkRequest, target: ActionTarget) -> Bool {
        guard let pattern = action.bodyPattern,
              let replacement = action.bodyReplacement else { return false }

        let bodyString: String? = switch target {
        case .request: request.requestBody.getString()
        case .response: request.responseBody.getString()
        }
        guard let bodyString else { return false }
        guard pattern.count <= RegexMatcher.maxPatternLength else { return false }
        guard bodyString.count <= RegexMatcher.maxInputLength else { return false }

        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(bodyString.startIndex..., in: bodyString)
            let replaced = regex.stringByReplacingMatches(
                in: bodyString,
                range: range,
                withTemplate: replacement
            )
            setBody(replaced, on: &request, target: target)
            return target == .request
        } catch {
            ProxyLog.interceptor.error("event=intercept.regex_replace outcome=failure pattern=\(pattern, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setBody(_ body: String, on request: inout NetworkRequest, target: ActionTarget) {
        switch target {
        case .request:
            request.requestBody = BodyStorage.from(string: body)
        case .response:
            request.responseBody = BodyStorage.from(string: body)
        }
    }

    func upsertHeader(_ headers: inout [TraceHTTPHeader], key: String, value: String) {
        if let index = headers.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) {
            headers[index] = TraceHTTPHeader(key: key, value: value)
        } else {
            headers.append(TraceHTTPHeader(key: key, value: value))
        }
    }

    func updateQueryParameter(url: String, name: String, value: String?) -> String {
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

    func removeQueryParameter(url: String, name: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != name }
        return components.string ?? url
    }

    func setCookieHeader(headers: [TraceHTTPHeader], name: String, value: String) -> [TraceHTTPHeader] {
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

    func removeCookieHeader(headers: [TraceHTTPHeader], name: String) -> [TraceHTTPHeader] {
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

    func removeCookieValue(from headerValue: String, name: String) -> String {
        let parts = headerValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let filtered = parts.filter { !$0.hasPrefix("\(name)=") }
        return filtered.joined(separator: "; ")
    }

    func setSetCookieHeader(headers: [TraceHTTPHeader], name: String, value: String) -> [TraceHTTPHeader] {
        var updated = headers
        let headerValue = "\(name)=\(value)"
        if let index = updated.firstIndex(where: { header in
            guard header.key.lowercased() == "set-cookie" else { return false }
            return header.value.trimmingCharacters(in: .whitespaces).hasPrefix("\(name)=")
        }) {
            updated[index] = TraceHTTPHeader(key: updated[index].key, value: headerValue)
        } else {
            updated.append(TraceHTTPHeader(key: "Set-Cookie", value: headerValue))
        }
        return updated
    }

    func removeSetCookieHeader(headers: [TraceHTTPHeader], name: String) -> [TraceHTTPHeader] {
        headers.filter { header in
            guard header.key.lowercased() == "set-cookie" else { return true }
            return !header.value.hasPrefix("\(name)=")
        }
    }

    func headerValue(for name: String, request: NetworkRequest, target: ActionTarget) -> String? {
        let headers = target == .request ? request.requestHeaders : request.responseHeaders
        return headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    func diffSummary(before: NetworkRequest, after: NetworkRequest, target: ActionTarget) -> String {
        let beforeHeaders = target == .request ? before.requestHeaders : before.responseHeaders
        let afterHeaders = target == .request ? after.requestHeaders : after.responseHeaders
        let beforeHeaderDict = Dictionary(uniqueKeysWithValues: beforeHeaders.map { ($0.key.lowercased(), $0.value) })
        let afterHeaderDict = Dictionary(uniqueKeysWithValues: afterHeaders.map { ($0.key.lowercased(), $0.value) })

        let added = afterHeaderDict.keys.filter { beforeHeaderDict[$0] == nil }
        let removed = beforeHeaderDict.keys.filter { afterHeaderDict[$0] == nil }
        let changed = afterHeaderDict.keys.filter { key in
            if let beforeValue = beforeHeaderDict[key], let afterValue = afterHeaderDict[key] {
                return beforeValue != afterValue
            }
            return false
        }

        let beforeBodySize = (target == .request ? before.requestBody.getData() : before.responseBody.getData())?.count ?? 0
        let afterBodySize = (target == .request ? after.requestBody.getData() : after.responseBody.getData())?.count ?? 0

        return "headers:+\(added.count)/-\(removed.count)/~\(changed.count) body:\(beforeBodySize)->\(afterBodySize)"
    }

    func validateContent(_ request: inout NetworkRequest, target: ActionTarget, ruleId: UUID) {
        let contentType = headerValue(for: "content-type", request: request, target: target) ?? ""
        let data = target == .request ? request.requestBody.getData() : request.responseBody.getData()
        guard let data else { return }

        if contentType.contains("json") {
            let result = ContentValidator().validateJSON(data)
            if !result.isValid {
                request.executionErrors.append(ExecutionError(ruleId: ruleId, message: "Invalid JSON after rewrite"))
            }
        } else if contentType.contains("xml") {
            let result = ContentValidator().validateXML(data)
            if !result.isValid {
                request.executionErrors.append(ExecutionError(ruleId: ruleId, message: "Invalid XML after rewrite"))
            }
        }
    }

    func failurePolicy(for ruleIds: [UUID]) -> FailurePolicy? {
        let groups = configSnapshot.ruleGroups
        for group in groups where group.rules.contains(where: { ruleIds.contains($0) }) {
            if group.failurePolicy == .failClosed {
                return .failClosed
            }
            if group.failurePolicy == .failMock {
                return .failMock
            }
        }
        return groups.contains { $0.failurePolicy == .failOpen } ? .failOpen : nil
    }

    func transformBody(
        request: inout NetworkRequest,
        target: ActionTarget,
        transform: (Data) -> Data
    ) -> Bool {
        let originalData = target == .request ? (request.requestBody.getData() ?? Data()) : (request.responseBody.getData() ?? Data())
        if originalData.count > maxBodyModificationBytes {
            return false
        }
        let contentType = headerValue(for: "content-type", request: request, target: target) ?? request.contentType
        if ContentSafety.shouldSkipTextOperation(originalData, contentType: contentType) {
            return false
        }
        let transformed = transform(originalData)
        if target == .request {
            request.requestBody = BodyStorage.from(data: transformed)
            return true
        } else {
            request.responseBody = BodyStorage.from(data: transformed)
            return false
        }
    }
}
