//
//  Script+Behavior.swift
//  TraceCore
//
//  Created by Justin on 2026/03/06.
//

import Foundation

public extension Script {
    func matches(_ url: String) -> Bool {
        guard enabled else { return false }
        guard let rawPattern = matchPattern else { return true }
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return true }

        let (subject, isHostMatch) = matchSubject(for: url, pattern: pattern, matchType: matchType)

        switch matchType {
        case .exact:
            if isHostMatch {
                return subject.lowercased() == pattern.lowercased()
            }
            return subject == pattern
        case .contains:
            if isHostMatch {
                let lowerPattern = pattern.lowercased()
                return subject.lowercased().contains(lowerPattern) || url.lowercased().contains(lowerPattern)
            }
            return subject.contains(pattern) || url.contains(pattern)
        case .wildcard:
            return matchesWildcard(subject, pattern: pattern)
        case .regex:
            return RegexMatcher.safeMatch(pattern: pattern, in: subject, caseSensitive: !isHostMatch)
        }
    }

    static var templates: [Script] {
        [
            Script(
                name: "Add Custom Header",
                scriptType: .request,
                code: """
                // Add a custom header to the request
                request.headers['X-Custom-Header'] = 'Custom Value';
                """
            ),
            Script(
                name: "Modify JSON Response",
                scriptType: .response,
                code: """
                // Parse and modify JSON response
                if (response.headers['Content-Type']?.includes('application/json')) {
                    var data = parseJSON(response.body);
                    if (data) {
                        // Modify the data
                        data.modified = true;
                        response.body = stringifyJSON(data);
                    }
                }
                """
            ),
            Script(
                name: "Log Request Details",
                scriptType: .request,
                code: """
                // Log request information
                console.log('Request to: ' + request.url);
                console.log('Method: ' + request.method);
                console.log('Headers: ' + stringifyJSON(request.headers));
                """
            ),
            Script(
                name: "Add CORS Headers",
                scriptType: .response,
                code: """
                // Add CORS headers to response
                response.headers['Access-Control-Allow-Origin'] = '*';
                response.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE';
                response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization';
                """
            ),
            Script(
                name: "Inject Data into Response",
                scriptType: .response,
                code: """
                // Inject additional data into JSON response
                if (response.headers['Content-Type']?.includes('application/json')) {
                    var data = parseJSON(response.body);
                    if (data) {
                        data.injectedField = 'Injected by script';
                        data.timestamp = new Date().toISOString();
                        response.body = stringifyJSON(data);
                    }
                }
                """
            )
        ]
    }
}

private extension Script {
    func matchesWildcard(_ url: String, pattern: String) -> Bool {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = "^" + regexPattern + "$"
        return RegexMatcher.safeMatch(pattern: regexPattern, in: url, caseSensitive: false)
    }
}
