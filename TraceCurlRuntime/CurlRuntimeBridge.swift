//
//  CurlRuntimeBridge.swift
//  TraceCurlRuntime
//
//  Created by Codex on 2026/02/08.
//

import CCurlShim
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct CurlRuntimeReport: Sendable {
    public let available: Bool
    public let supportsFullOptionParity: Bool
    public let supportsCLIExecution: Bool
    public let backendName: String
    public let supportedProtocols: Set<String>
    public let supportedOptions: Set<String>
    public let version: String

    public init(
        available: Bool,
        supportsFullOptionParity: Bool,
        supportsCLIExecution: Bool,
        backendName: String,
        supportedProtocols: Set<String>,
        supportedOptions: Set<String>,
        version: String
    ) {
        self.available = available
        self.supportsFullOptionParity = supportsFullOptionParity
        self.supportsCLIExecution = supportsCLIExecution
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

public enum CurlRuntimeExecutionError: LocalizedError {
    case backendUnavailable
    case invalidCommand
    case commandLaunchFailed
    case commandWaitFailed

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            "cURL runtime CLI backend is not available on this platform"
        case .invalidCommand:
            "Runtime backend received an empty cURL command"
        case .commandLaunchFailed:
            "Failed to launch cURL runtime command"
        case .commandWaitFailed:
            "cURL runtime command terminated unexpectedly"
        }
    }
}

public enum CurlRuntimeBridge {
    private static let metaPrefix = "TRACE_META:"
    private static let curlCLIPath = "/usr/bin/curl"
    private static let hostCapabilityLock = NSLock()
    nonisolated(unsafe) private static var cachedHostCapabilities: HostCapabilities?

    private struct HostCapabilities: Sendable {
        let protocols: Set<String>
        let options: Set<String>
        let version: String
    }

    public static func currentReport() -> CurlRuntimeReport {
        let available = trace_curl_runtime_available() != 0
        let backendName = String(cString: trace_curl_runtime_backend_name())
        let shimVersion = String(cString: trace_curl_runtime_version_string())
        let shimProtocols = parseCSVSet(String(cString: trace_curl_runtime_supported_protocols_csv()))
        let fullParityFlag = trace_curl_runtime_supports_full_option_parity() != 0
        let supportsCLI = available && canExecuteCurlCLI()

        var runtimeProtocols = shimProtocols
        var runtimeOptions: Set<String> = []
        var runtimeVersion = shimVersion

        if supportsCLI, let hostCapabilities = loadHostCapabilities() {
            if !hostCapabilities.protocols.isEmpty {
                runtimeProtocols = hostCapabilities.protocols
            }
            if !hostCapabilities.options.isEmpty {
                runtimeOptions = hostCapabilities.options
            }
            if !hostCapabilities.version.isEmpty {
                runtimeVersion = hostCapabilities.version
            }
        }

        return CurlRuntimeReport(
            available: available,
            supportsFullOptionParity: fullParityFlag && supportsCLI && !runtimeOptions.isEmpty,
            supportsCLIExecution: supportsCLI,
            backendName: backendName,
            supportedProtocols: runtimeProtocols,
            supportedOptions: runtimeOptions,
            version: runtimeVersion
        )
    }

    public static func executeTransferCommand(_ command: String) throws -> CurlRuntimeExecutionResult {
        try executeTransferCommand(argv: tokenizeCommand(command))
    }

    public static func executeTransferCommand(argv: [String]) throws -> CurlRuntimeExecutionResult {
        let report = currentReport()
        guard report.supportsCLIExecution else {
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
        let stdoutURL = tempDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = tempDirectory.appendingPathComponent("stderr.txt")

        var invocation = argv
        invocation.append(contentsOf: [
            "--dump-header",
            headersURL.path,
            "--output",
            bodyURL.path,
            "--silent",
            "--show-error",
            "--write-out",
            "\(metaPrefix)%{json}\n"
        ])

        let exitCode = try runCurlCommand(
            arguments: invocation,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL
        )

        let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let (plainOutput, metaTexts) = splitStandardOutputAndMeta(stdoutText)
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
        let standardError = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

        return CurlRuntimeExecutionResult(
            exitCode: exitCode,
            transferCount: transferCount,
            statusCode: statusCode,
            statusLine: statusLine,
            effectiveURL: effectiveURL,
            responseHeaderLines: responseHeaderLines,
            responseBody: responseBody,
            timeTotal: timeTotal,
            standardOutput: plainOutput,
            standardError: standardError
        )
    }

    private static func canExecuteCurlCLI() -> Bool {
        #if targetEnvironment(simulator) || os(macOS) || targetEnvironment(macCatalyst)
        FileManager.default.isExecutableFile(atPath: curlCLIPath)
        #else
        false
        #endif
    }

    private static func loadHostCapabilities() -> HostCapabilities? {
        hostCapabilityLock.lock()
        defer { hostCapabilityLock.unlock() }

        if let cachedHostCapabilities {
            return cachedHostCapabilities
        }

        let versionOutput = runIntrospection(arguments: ["--version"])
        let helpOutput = runIntrospection(arguments: ["--help", "all"])
        guard versionOutput != nil || helpOutput != nil else {
            return nil
        }

        let hostCapabilities = HostCapabilities(
            protocols: parseProtocols(fromVersionOutput: versionOutput ?? ""),
            options: parseOptions(fromHelpOutput: helpOutput ?? ""),
            version: parseVersion(fromVersionOutput: versionOutput ?? "")
        )
        cachedHostCapabilities = hostCapabilities
        return hostCapabilities
    }

    private static func runIntrospection(arguments: [String]) -> String? {
        let fm = FileManager.default
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("trace-curl-introspect-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer {
            try? fm.removeItem(at: tempDirectory)
        }

        let stdoutURL = tempDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = tempDirectory.appendingPathComponent("stderr.txt")

        guard let exitCode = try? runCurlCommand(arguments: arguments, stdoutURL: stdoutURL, stderrURL: stderrURL) else {
            return nil
        }
        let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        if exitCode != 0 && stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return stdoutText
    }

    private static func runCurlCommand(
        arguments: [String],
        stdoutURL: URL,
        stderrURL: URL
    ) throws -> Int32 {
        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw CurlRuntimeExecutionError.commandLaunchFailed
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        let permissions = mode_t(S_IRUSR | S_IWUSR)
        let openFlags = O_WRONLY | O_CREAT | O_TRUNC

        guard posix_spawn_file_actions_addopen(
            &fileActions,
            STDOUT_FILENO,
            stdoutURL.path,
            openFlags,
            permissions
        ) == 0 else {
            throw CurlRuntimeExecutionError.commandLaunchFailed
        }
        guard posix_spawn_file_actions_addopen(
            &fileActions,
            STDERR_FILENO,
            stderrURL.path,
            openFlags,
            permissions
        ) == 0 else {
            throw CurlRuntimeExecutionError.commandLaunchFailed
        }

        var argv = (["curl"] + arguments).map { strdup($0) }
        argv.append(nil)
        defer {
            for ptr in argv where ptr != nil {
                free(ptr)
            }
        }

        var pid: pid_t = 0
        let spawnResult: Int32 = argv.withUnsafeMutableBufferPointer { argvBuffer in
            posix_spawn(
                &pid,
                curlCLIPath,
                &fileActions,
                nil,
                argvBuffer.baseAddress,
                environ
            )
        }

        guard spawnResult == 0 else {
            throw CurlRuntimeExecutionError.commandLaunchFailed
        }

        var status: Int32 = 0
        guard waitpid(pid, &status, 0) != -1 else {
            throw CurlRuntimeExecutionError.commandWaitFailed
        }

        return Int32((status >> 8) & 0xff)
        #else
        _ = arguments
        _ = stdoutURL
        _ = stderrURL
        throw CurlRuntimeExecutionError.backendUnavailable
        #endif
    }

    private static func parseCSVSet(_ value: String) -> Set<String> {
        Set(
            value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private static func parseVersion(fromVersionOutput output: String) -> String {
        let firstLine = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
        let tokens = firstLine?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard tokens.count >= 2 else {
            return ""
        }
        return String(tokens[1])
    }

    private static func parseProtocols(fromVersionOutput output: String) -> Set<String> {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let stringLine = String(line)
            guard stringLine.lowercased().hasPrefix("protocols:") else {
                continue
            }
            let value = stringLine.dropFirst("Protocols:".count)
            return Set(
                value
                    .split(whereSeparator: \.isWhitespace)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        }
        return []
    }

    private static func parseOptions(fromHelpOutput output: String) -> Set<String> {
        let pattern = #"(?<!\w)(--[A-Za-z0-9][A-Za-z0-9.:-]*|-[A-Za-z0-9:#])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)
        var options = Set<String>()
        for match in matches {
            guard let tokenRange = Range(match.range(at: 1), in: output) else { continue }
            options.insert(String(output[tokenRange]))
        }
        return options
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
