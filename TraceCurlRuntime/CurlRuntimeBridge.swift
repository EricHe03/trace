//
//  CurlRuntimeBridge.swift
//  TraceCurlRuntime
//
//  Created by Codex on 2026/02/08.
//

import CCurlShim
import Foundation

public struct CurlRuntimeReport: Sendable {
    public let available: Bool
    public let supportsFullOptionParity: Bool
    public let supportsCLIExecution: Bool
    public let supportsHTTP2: Bool
    public let supportsContentDecoding: Bool
    public let supportsNativeCA: Bool
    public let supportsNTLM: Bool
    public let backendName: String
    public let supportedProtocols: Set<String>
    public let supportedOptions: Set<String>
    public let version: String

    public init(
        available: Bool,
        supportsFullOptionParity: Bool,
        supportsCLIExecution: Bool,
        supportsHTTP2: Bool,
        supportsContentDecoding: Bool,
        supportsNativeCA: Bool,
        supportsNTLM: Bool,
        backendName: String,
        supportedProtocols: Set<String>,
        supportedOptions: Set<String>,
        version: String
    ) {
        self.available = available
        self.supportsFullOptionParity = supportsFullOptionParity
        self.supportsCLIExecution = supportsCLIExecution
        self.supportsHTTP2 = supportsHTTP2
        self.supportsContentDecoding = supportsContentDecoding
        self.supportsNativeCA = supportsNativeCA
        self.supportsNTLM = supportsNTLM
        self.backendName = backendName
        self.supportedProtocols = supportedProtocols
        self.supportedOptions = supportedOptions
        self.version = version
    }
}

public struct CurlRuntimeExecutionResult: Sendable {
    public let exitCode: Int32
    public let transferCount: Int
    public let statusCode: Int?
    public let statusLine: String?
    public let effectiveURL: String?
    public let responseHeaderLines: [String]
    public let responseBody: Data
    public let timeTotal: TimeInterval?
    public let standardOutput: String
    public let standardError: String

    public init(
        exitCode: Int32,
        transferCount: Int,
        statusCode: Int?,
        statusLine: String?,
        effectiveURL: String?,
        responseHeaderLines: [String],
        responseBody: Data,
        timeTotal: TimeInterval?,
        standardOutput: String,
        standardError: String
    ) {
        self.exitCode = exitCode
        self.transferCount = transferCount
        self.statusCode = statusCode
        self.statusLine = statusLine
        self.effectiveURL = effectiveURL
        self.responseHeaderLines = responseHeaderLines
        self.responseBody = responseBody
        self.timeTotal = timeTotal
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct CurlRuntimePreflightResult: Sendable {
    public let parameterErrorCode: Int32
    public let transferCount: Int
    public let urlCount: Int
    public let standardError: String

    public init(
        parameterErrorCode: Int32,
        transferCount: Int,
        urlCount: Int,
        standardError: String
    ) {
        self.parameterErrorCode = parameterErrorCode
        self.transferCount = transferCount
        self.urlCount = urlCount
        self.standardError = standardError
    }

    public var hasBlockingError: Bool {
        parameterErrorCode != 0
    }
}

public enum CurlRuntimeExecutionError: LocalizedError {
    case backendUnavailable
    case invalidCommand
    case runtimeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            "cURL in-process runtime is not available"
        case .invalidCommand:
            "Runtime backend received an empty cURL command"
        case let .runtimeFailure(message):
            "In-process cURL runtime failed: \(message)"
        }
    }
}

public enum CurlRuntimeBridge {
    private static let metaPrefix = "TRACE_META:"

    public static func currentReport() -> CurlRuntimeReport {
        let available = trace_curl_runtime_available() != 0
        let backendName = String(cString: trace_curl_runtime_backend_name())
        let version = String(cString: trace_curl_runtime_version_string())
        let protocols = parseCSVSet(String(cString: trace_curl_runtime_supported_protocols_csv()))
        let supportsFullParity = trace_curl_runtime_supports_full_option_parity() != 0
        let supportsHTTP2 = trace_curl_runtime_supports_http2() != 0
        let supportsContentDecoding = trace_curl_runtime_supports_content_decoding() != 0
        let supportsNativeCA = trace_curl_runtime_supports_native_ca() != 0
        let supportsNTLM = trace_curl_runtime_supports_ntlm() != 0

        return CurlRuntimeReport(
            available: available,
            supportsFullOptionParity: available && supportsFullParity,
            supportsCLIExecution: available,
            supportsHTTP2: supportsHTTP2,
            supportsContentDecoding: supportsContentDecoding,
            supportsNativeCA: supportsNativeCA,
            supportsNTLM: supportsNTLM,
            backendName: backendName,
            supportedProtocols: protocols,
            supportedOptions: [],
            version: version
        )
    }

    public static func executeTransferCommand(_ command: String) throws -> CurlRuntimeExecutionResult {
        try executeTransferCommand(argv: tokenizeCommand(command))
    }

    public static func executeTransferCommand(argv: [String]) throws -> CurlRuntimeExecutionResult {
        let report = currentReport()
        guard report.available else {
            throw CurlRuntimeExecutionError.backendUnavailable
        }

        guard !argv.isEmpty else {
            throw CurlRuntimeExecutionError.invalidCommand
        }

        let fm = FileManager.default
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("trace-curl-runtime-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempDirectory)
        }

        let headersURL = tempDirectory.appendingPathComponent("headers.txt")
        let bodyURL = tempDirectory.appendingPathComponent("body.bin")

        var invocation = argv
        if shouldInjectDefaultCABundle(into: invocation),
           let bundlePath = defaultCABundlePath()
        {
            invocation.append(contentsOf: ["--cacert", bundlePath])
        }
        invocation.append(contentsOf: [
            "--dump-header",
            headersURL.path,
            "--output",
            bodyURL.path,
            "--silent",
            "--show-error",
            "--write-out",
            "\(metaPrefix)%{json}\\n"
        ])

        let execution = try runCurlCommand(arguments: invocation)
        let (plainOutput, metaTexts) = splitStandardOutputAndMeta(execution.stdout)
        let metadataEntries = metaTexts.compactMap(parseMetadata)
        let selectedMetadata = metadataEntries.last
        let transferCount = max(metaTexts.count, 1)

        let headerText = (try? String(contentsOf: headersURL, encoding: .utf8)) ?? ""
        let responseHeaderLines = parseLastHeaderBlock(from: headerText)
        let statusLine = responseHeaderLines.first(where: { $0.hasPrefix("HTTP/") })
        let statusCode = parseStatusCode(from: selectedMetadata, statusLine: statusLine)
        let effectiveURL = parseString(from: selectedMetadata, key: "url_effective")
        let timeTotal = parseDouble(from: selectedMetadata, key: "time_total")
        let responseBody = (try? Data(contentsOf: bodyURL)) ?? Data()

        return CurlRuntimeExecutionResult(
            exitCode: execution.exitCode,
            transferCount: transferCount,
            statusCode: statusCode,
            statusLine: statusLine,
            effectiveURL: effectiveURL,
            responseHeaderLines: responseHeaderLines,
            responseBody: responseBody,
            timeTotal: timeTotal,
            standardOutput: plainOutput,
            standardError: execution.stderr
        )
    }

    public static func preflightTransferCommand(argv: [String]) throws -> CurlRuntimePreflightResult {
        let report = currentReport()
        guard report.available else {
            throw CurlRuntimeExecutionError.backendUnavailable
        }

        guard !argv.isEmpty else {
            throw CurlRuntimeExecutionError.invalidCommand
        }

        return try runCurlPreflight(arguments: argv)
    }

    private static func runCurlCommand(arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        var executionResult = trace_curl_execute_result(exit_code: 0, stdout_utf8: nil, stderr_utf8: nil)

        let ownedArguments = arguments.map { strdup($0) }
        let cArguments: [UnsafePointer<CChar>?] = ownedArguments.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        defer {
            for pointer in ownedArguments where pointer != nil {
                free(pointer)
            }
            trace_curl_execute_result_dispose(&executionResult)
        }

        let status = cArguments.withUnsafeBufferPointer { buffer in
            trace_curl_execute_argv(
                Int32(arguments.count),
                buffer.baseAddress,
                &executionResult
            )
        }

        if status != 0 {
            let message = String(cString: trace_curl_runtime_last_error())
            throw CurlRuntimeExecutionError.runtimeFailure(message)
        }

        let stdout = executionResult.stdout_utf8.map { String(cString: $0) } ?? ""
        let stderr = executionResult.stderr_utf8.map { String(cString: $0) } ?? ""
        return (executionResult.exit_code, stdout, stderr)
    }

    private static func runCurlPreflight(arguments: [String]) throws -> CurlRuntimePreflightResult {
        var parseResult = trace_curl_parse_result(
            parameter_error: 0,
            transfer_count: 0,
            url_count: 0,
            stderr_utf8: nil
        )

        let ownedArguments = arguments.map { strdup($0) }
        let cArguments: [UnsafePointer<CChar>?] = ownedArguments.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        defer {
            for pointer in ownedArguments where pointer != nil {
                free(pointer)
            }
            trace_curl_parse_result_dispose(&parseResult)
        }

        let status = cArguments.withUnsafeBufferPointer { buffer in
            trace_curl_parse_argv(
                Int32(arguments.count),
                buffer.baseAddress,
                &parseResult
            )
        }

        if status != 0 {
            let message = String(cString: trace_curl_runtime_last_error())
            throw CurlRuntimeExecutionError.runtimeFailure(message)
        }

        let stderr = parseResult.stderr_utf8.map { String(cString: $0) } ?? ""
        return CurlRuntimePreflightResult(
            parameterErrorCode: parseResult.parameter_error,
            transferCount: Int(parseResult.transfer_count),
            urlCount: Int(parseResult.url_count),
            standardError: stderr
        )
    }

    private static func defaultCABundlePath() -> String? {
        Bundle.module
            .url(forResource: "apple-system-roots", withExtension: "pem")?
            .path
    }

    private static func shouldInjectDefaultCABundle(into argv: [String]) -> Bool {
        var index = 0
        while index < argv.count {
            let token = argv[index]
            let lowered = token.lowercased()

            if lowered == "--insecure" || lowered.hasPrefix("--insecure=") {
                return false
            }

            if lowered == "--cacert" || lowered.hasPrefix("--cacert=") ||
                lowered == "--capath" || lowered.hasPrefix("--capath=") ||
                lowered == "--proxy-cacert" || lowered.hasPrefix("--proxy-cacert=")
            {
                return false
            }

            if token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1 {
                let shortCluster = token.dropFirst()
                if shortCluster.contains("k") {
                    return false
                }
            }

            if lowered == "--cacert" || lowered == "--capath" || lowered == "--proxy-cacert" {
                index += 1
            }

            index += 1
        }

        return true
    }

    private static func parseCSVSet(_ value: String) -> Set<String> {
        Set(
            value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private static func tokenizeCommand(_ command: String) -> [String] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let normalized: String
        let lowered = trimmed.lowercased()
        if lowered == "curl" {
            normalized = ""
        } else if lowered.hasPrefix("curl ") {
            normalized = String(trimmed.dropFirst(5))
        } else {
            normalized = trimmed
        }

        var tokens: [String] = []
        var currentToken = ""
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var escaped = false
        var justClosedQuote = false
        let chars = Array(normalized)
        var index = 0

        func appendTokenIfNeeded() {
            if justClosedQuote && currentToken.isEmpty {
                tokens.append("")
                justClosedQuote = false
            }
            if !currentToken.isEmpty {
                tokens.append(currentToken)
                currentToken = ""
            }
        }

        while index < chars.count {
            let char = chars[index]

            if escaped {
                currentToken.append(char)
                escaped = false
                index += 1
                continue
            }

            if char == "\\" {
                if inSingleQuotes {
                    currentToken.append(char)
                    index += 1
                    continue
                }
                if index + 1 < chars.count {
                    let next = chars[index + 1]
                    if next == "\n" || next == "\r" {
                        index += 2
                        if next == "\r", index < chars.count, chars[index] == "\n" {
                            index += 1
                        }
                        continue
                    }
                }
                escaped = true
                index += 1
                continue
            }

            if char == "'" && !inDoubleQuotes {
                inSingleQuotes.toggle()
                justClosedQuote = !inSingleQuotes
                index += 1
                continue
            }

            if char == "\"" && !inSingleQuotes {
                inDoubleQuotes.toggle()
                justClosedQuote = !inDoubleQuotes
                index += 1
                continue
            }

            if char.isWhitespace && !inSingleQuotes && !inDoubleQuotes {
                appendTokenIfNeeded()
                index += 1
                continue
            }

            if justClosedQuote {
                justClosedQuote = false
            }

            currentToken.append(char)
            index += 1
        }

        if justClosedQuote && currentToken.isEmpty {
            tokens.append("")
        }

        if !currentToken.isEmpty {
            tokens.append(currentToken)
        }

        return tokens
    }

    private static func splitStandardOutputAndMeta(_ output: String) -> (String, [String]) {
        guard !output.isEmpty else {
            return ("", [])
        }

        var plainLines: [String] = []
        var metadata: [String] = []
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let stringLine = String(line)
            if stringLine.hasPrefix(metaPrefix) {
                let payload = String(stringLine.dropFirst(metaPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !payload.isEmpty {
                    metadata.append(payload)
                }
            } else {
                plainLines.append(stringLine)
            }
        }

        let plainOutput = plainLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (plainOutput, metadata)
    }

    private static func parseMetadata(_ metaText: String) -> [String: Any]? {
        guard let data = metaText.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    private static func parseString(from metadata: [String: Any]?, key: String) -> String? {
        metadata?[key] as? String
    }

    private static func parseDouble(from metadata: [String: Any]?, key: String) -> Double? {
        if let value = metadata?[key] as? Double {
            return value
        }
        if let value = metadata?[key] as? NSNumber {
            return value.doubleValue
        }
        if let value = metadata?[key] as? String {
            return Double(value)
        }
        return nil
    }

    private static func parseStatusCode(from metadata: [String: Any]?, statusLine: String?) -> Int? {
        if let value = metadata?["response_code"] as? Int {
            return value
        }
        if let value = metadata?["response_code"] as? NSNumber {
            return value.intValue
        }
        if let value = metadata?["response_code"] as? String, let parsed = Int(value) {
            return parsed
        }

        guard let statusLine else { return nil }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private static func parseLastHeaderBlock(from headerText: String) -> [String] {
        guard !headerText.isEmpty else { return [] }

        let normalized = headerText.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let selectedBlock = blocks.last ?? ""
        if selectedBlock.isEmpty {
            return []
        }
        return selectedBlock
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
