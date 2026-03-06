//
//  RequestMap+Behavior.swift
//  TraceCore
//
//  Created by Justin on 2026/03/06.
//

import Foundation

public extension MockResponse {
    func getBody() throws -> Data {
        switch bodySource {
        case .inline:
            return bodyContent ?? Data()
        case .file:
            guard let filePath = bodyFilePath, !filePath.isEmpty else {
                throw RequestMapError.missingFilePath
            }
            let url = try resolveFilePath(filePath)
            return try Data(contentsOf: url)
        case .script:
            guard let scriptContent, !scriptContent.isEmpty else {
                throw RequestMapError.scriptExecutionNotSupported
            }
            throw RequestMapError.scriptExecutionNotSupported
        case .template:
            return bodyContent ?? Data()
        }
    }

    func executeScript(with context: [String: Any] = [:]) throws -> Data {
        guard bodySource == .script else {
            throw RequestMapError.invalidBodyData
        }
        guard let scriptContent, !scriptContent.isEmpty else {
            throw RequestMapError.scriptExecutionNotSupported
        }

        throw RequestMapError.scriptExecutionNotSupported
    }

    static func from(request: NetworkRequest) -> MockResponse {
        let bodyData = request.responseBody.getData()
        return MockResponse(
            statusCode: request.statusCode ?? 200,
            statusMessage: HTTPURLResponse.localizedString(forStatusCode: request.statusCode ?? 200),
            headers: request.responseHeaders,
            bodySource: .inline,
            bodyContent: bodyData,
            delay: 0
        )
    }
}

private extension MockResponse {
    func resolveFilePath(_ filePath: String) throws -> URL {
        if filePath.hasPrefix("/") {
            let url = URL(fileURLWithPath: filePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            throw RequestMapError.fileNotFound(filePath)
        }

        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfiguration.appGroupIdentifier) {
            let mockFilesDir = containerURL.appendingPathComponent("MockFiles", isDirectory: true)
            let fileURL = mockFilesDir.appendingPathComponent(filePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }

            let directURL = containerURL.appendingPathComponent(filePath)
            if FileManager.default.fileExists(atPath: directURL.path) {
                return directURL
            }
        }

        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let mockFilesDir = documentsURL.appendingPathComponent("MockFiles", isDirectory: true)
            let fileURL = mockFilesDir.appendingPathComponent(filePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
        }

        throw RequestMapError.fileNotFound(filePath)
    }
}

public extension RequestMap {
    func matches(_ url: String) -> Bool {
        guard enabled else { return false }

        switch matchType {
        case .exact:
            return url == matchPattern
        case .contains:
            return url.contains(matchPattern)
        case .wildcard:
            return matchesWildcard(url, pattern: matchPattern)
        case .regex:
            return RegexMatcher.safeMatch(pattern: matchPattern, in: url, caseSensitive: true)
        }
    }

    static func fromRequest(_ request: NetworkRequest, name: String? = nil) -> RequestMap {
        let mapName = name ?? "Mock for \(request.url)"
        let mockResponse = MockResponse.from(request: request)

        return RequestMap(
            name: mapName,
            enabled: true,
            matchType: .exact,
            matchPattern: request.url,
            mockResponse: mockResponse
        )
    }
}

private extension RequestMap {
    func matchesWildcard(_ url: String, pattern: String) -> Bool {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = "^" + regexPattern + "$"
        return RegexMatcher.safeMatch(pattern: regexPattern, in: url, caseSensitive: false)
    }
}
