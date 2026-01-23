//
//  RedirectChainResolver.swift
//  TraceCore
//
//  Created by Justin on 2026/01/23.
//

import Foundation

public struct RedirectChainResolver {
    public var maxMatchInterval: TimeInterval

    public init(maxMatchInterval: TimeInterval = 30) {
        self.maxMatchInterval = maxMatchInterval
    }

    public func enrich(_ requests: [NetworkRequest]) -> [NetworkRequest] {
        guard !requests.isEmpty else { return requests }

        var enriched = requests
        var indexById: [UUID: Int] = [:]
        indexById.reserveCapacity(enriched.count)
        for (index, request) in enriched.enumerated() {
            indexById[request.id] = index
        }

        let sortedRequests = enriched.sorted { $0.timestamp < $1.timestamp }
        var pendingByDestination: [String: [PendingRedirect]] = [:]

        for request in sortedRequests {
            guard let index = indexById[request.id] else { continue }
            var updated = enriched[index]
            updated.extractHTTPFields()

            if updated.redirectChain.isEmpty, let requestKey = normalizeRedirectKey(updated.url) {
                if var pendingList = pendingByDestination[requestKey] {
                    pendingList = pendingList.filter { updated.timestamp.timeIntervalSince($0.timestamp) <= maxMatchInterval }
                    if let matchIndex = mostRecentPendingIndex(in: pendingList, for: updated.timestamp) {
                        let matched = pendingList.remove(at: matchIndex)
                        if pendingList.isEmpty {
                            pendingByDestination.removeValue(forKey: requestKey)
                        } else {
                            pendingByDestination[requestKey] = pendingList
                        }
                        updated.redirectChain = matched.chain
                        let mergedCookies = mergeCookies(prior: matched.cookies, current: updated.responseCookies ?? [])
                        if !mergedCookies.isEmpty {
                            updated.responseCookies = mergedCookies
                        }
                    } else if pendingList.isEmpty {
                        pendingByDestination.removeValue(forKey: requestKey)
                    } else {
                        pendingByDestination[requestKey] = pendingList
                    }
                }
            }

            if let statusCode = updated.statusCode,
               (300 ... 399).contains(statusCode),
               let locationHeader = updated.responseHeaders.first(where: { $0.key.lowercased() == "location" })?.value,
               let destinationURL = resolveRedirectURL(locationHeader, base: updated.url),
               let destinationKey = normalizeRedirectKey(destinationURL),
               let requestKey = normalizeRedirectKey(updated.url),
               destinationKey != requestKey {
                let redirectInfo = RedirectInfo(
                    fromURL: updated.url,
                    toURL: destinationURL,
                    statusCode: statusCode,
                    location: locationHeader
                )
                var chain = updated.redirectChain
                chain.append(redirectInfo)
                let cookiesToCarry = mergeCookies(prior: updated.responseCookies ?? [], current: [])
                let pending = PendingRedirect(timestamp: updated.timestamp, chain: chain, cookies: cookiesToCarry)
                pendingByDestination[destinationKey, default: []].append(pending)
            }

            enriched[index] = updated
        }

        return enriched
    }

    private struct PendingRedirect {
        let timestamp: Date
        let chain: [RedirectInfo]
        let cookies: [HTTPCookie]
    }

    private func mostRecentPendingIndex(in list: [PendingRedirect], for timestamp: Date) -> Int? {
        for index in list.indices.reversed() {
            if list[index].timestamp <= timestamp {
                return index
            }
        }
        return nil
    }

    private func normalizeRedirectKey(_ urlString: String) -> String? {
        guard var components = URLComponents(string: urlString) else { return nil }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url?.absoluteString ?? urlString
    }

    private func resolveRedirectURL(_ location: String, base: String) -> String? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute.absoluteString
        }
        guard let baseURL = URL(string: base),
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        return resolved.absoluteString
    }

    private func mergeCookies(prior: [HTTPCookie], current: [HTTPCookie]) -> [HTTPCookie] {
        guard !prior.isEmpty || !current.isEmpty else { return [] }
        var order: [String] = []
        var bySignature: [String: HTTPCookie] = [:]
        for cookie in prior + current {
            let signature = cookieSignature(cookie)
            if bySignature[signature] == nil {
                order.append(signature)
            }
            bySignature[signature] = cookie
        }
        return order.compactMap { bySignature[$0] }
    }

    private func cookieSignature(_ cookie: HTTPCookie) -> String {
        let domain = cookie.domain ?? ""
        let path = cookie.path ?? ""
        return "\(cookie.name)|\(domain)|\(path)"
    }
}
