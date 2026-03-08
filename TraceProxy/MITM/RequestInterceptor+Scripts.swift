//
//  RequestInterceptor+Scripts.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import TraceCore
import TraceFeatures

extension RequestInterceptor {
    func executeRequestScripts(on request: NetworkRequest) async -> NetworkRequest {
        let matchingScripts = configSnapshot.scripts.filter { script in
            script.enabled &&
                (script.scriptType == .request || script.scriptType == .both) &&
                scriptMatchesUrl(script: script, url: request.url)
        }

        guard !matchingScripts.isEmpty else { return request }

        var modifiedRequest = await scriptManager.executeRequestScriptsAsync(matchingScripts, on: request)

        if !matchingScripts.isEmpty {
            let scriptNames = matchingScripts.map(\.name).joined(separator: ", ")
            modifiedRequest.appliedScriptName = scriptNames
        }

        return modifiedRequest
    }

    func executeResponseScripts(on request: NetworkRequest) async -> NetworkRequest {
        let matchingScripts = configSnapshot.scripts.filter { script in
            script.enabled &&
                (script.scriptType == .response || script.scriptType == .both) &&
                scriptMatchesUrl(script: script, url: request.url)
        }

        guard !matchingScripts.isEmpty else { return request }

        var modifiedRequest = await scriptManager.executeResponseScriptsAsync(matchingScripts, on: request)

        if !matchingScripts.isEmpty {
            let scriptNames = matchingScripts.map(\.name).joined(separator: ", ")
            if let existing = modifiedRequest.appliedScriptName {
                modifiedRequest.appliedScriptName = "\(existing); \(scriptNames)"
            } else {
                modifiedRequest.appliedScriptName = scriptNames
            }
        }

        return modifiedRequest
    }

    func scriptMatchesUrl(script: Script, url: String) -> Bool {
        guard let pattern = script.matchPattern, !pattern.isEmpty else {
            return true
        }
        return matchesPattern(url: url, pattern: pattern, matchType: script.matchType)
    }
}
