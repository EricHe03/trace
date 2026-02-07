//
//  CurlCommandAnalyzer.swift
//  TraceFeatures
//
//  Created by Codex on 2026/02/07.
//

import Foundation

public final class CurlCommandAnalyzer {
    private struct TokenStream {
        var tokens: [String]
        var index: Int = 0

        mutating func next() -> String? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            index += 1
            return token
        }

        mutating func peek() -> String? {
            guard index < tokens.count else { return nil }
            return tokens[index]
        }
    }

    private struct MutableTransfer {
        var index: Int
        var rawTokens: [String] = []
        var urls: [String] = []
        var options: [String: [String]] = [:]

        mutating func addOption(_ option: String, value: String?) {
            let storedValue = value ?? "true"
            options[option, default: []].append(storedValue)
        }
    }

    private let capabilities: CurlRuntimeCapabilities

    public init(capabilities: CurlRuntimeCapabilities = .urlSession) {
        self.capabilities = capabilities
    }

    public func analyze(_ command: String) -> CurlCommandPlan {
        let original = command
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CurlCommandPlan(
                originalCommand: original,
                normalizedCommand: "",
                argv: [],
                transfers: [],
                diagnostics: [CurlDiagnostic(severity: .error, message: "Missing cURL command")]
            )
        }

        let tokens = tokenize(normalizeLeadingCurl(trimmed))
        guard !tokens.isEmpty else {
            return CurlCommandPlan(
                originalCommand: original,
                normalizedCommand: "",
                argv: [],
                transfers: [],
                diagnostics: [CurlDiagnostic(severity: .error, message: "Missing cURL command")]
            )
        }

        var stream = TokenStream(tokens: tokens)
        var diagnostics: [CurlDiagnostic] = []
        var transfers: [MutableTransfer] = [MutableTransfer(index: 0)]
        var globalOptions: [String: [String]] = [:]
        var endOfOptions = false

        while let token = stream.next() {
            if !endOfOptions, token == "--" {
                transfers[transfers.count - 1].rawTokens.append(token)
                endOfOptions = true
                continue
            }

            if !endOfOptions, isNextPartitionToken(token) {
                if !transfers[transfers.count - 1].rawTokens.isEmpty || !transfers[transfers.count - 1].urls.isEmpty {
                    transfers.append(MutableTransfer(index: transfers.count))
                }
                endOfOptions = false
                continue
            }

            if !endOfOptions, token.hasPrefix("--") {
                handleLongOption(
                    token,
                    stream: &stream,
                    transfer: &transfers[transfers.count - 1],
                    globalOptions: &globalOptions,
                    diagnostics: &diagnostics
                )
                continue
            }

            if !endOfOptions, token.hasPrefix("-"), token != "-" {
                if handleShortOption(
                    token,
                    stream: &stream,
                    transfer: &transfers[transfers.count - 1],
                    globalOptions: &globalOptions,
                    diagnostics: &diagnostics
                ) {
                    continue
                }
            }

            transfers[transfers.count - 1].rawTokens.append(token)
            transfers[transfers.count - 1].urls.append(token)
        }

        let plans = buildTransferPlans(transfers, globalOptions: globalOptions, diagnostics: &diagnostics)
        if plans.isEmpty {
            diagnostics.append(CurlDiagnostic(severity: .error, message: "Missing URL in cURL command"))
        }

        validateCapabilities(for: plans, diagnostics: &diagnostics)

        return CurlCommandPlan(
            originalCommand: original,
            normalizedCommand: normalizedCommand(from: tokens),
            argv: tokens,
            transfers: plans,
            diagnostics: diagnostics
        )
    }

    private func isNextPartitionToken(_ token: String) -> Bool {
        token == "--next" || token == "-:"
    }

    private func normalizeLeadingCurl(_ command: String) -> String {
        let lowered = command.lowercased()
        if lowered == "curl" {
            return ""
        }
        if lowered.hasPrefix("curl ") {
            return String(command.dropFirst(5))
        }
        return command
    }

    private func normalizedCommand(from tokens: [String]) -> String {
        guard !tokens.isEmpty else { return "" }
        return "curl " + tokens.map(shellQuote).joined(separator: " ")
    }

    private func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.range(of: #"[\s'"\\]"#, options: .regularExpression) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func buildTransferPlans(
        _ transfers: [MutableTransfer],
        globalOptions: [String: [String]],
        diagnostics: inout [CurlDiagnostic]
    ) -> [CurlCommandTransferPlan] {
        var plans: [CurlCommandTransferPlan] = []

        for transfer in transfers where !transfer.rawTokens.isEmpty || !transfer.urls.isEmpty {
            guard !transfer.urls.isEmpty else {
                diagnostics.append(
                    CurlDiagnostic(
                        severity: .error,
                        message: "Transfer #\(transfer.index + 1) has no URL"
                    )
                )
                continue
            }

            var effectiveOptions = globalOptions
            for (key, values) in transfer.options {
                effectiveOptions[key, default: []].append(contentsOf: values)
            }

            let command = "curl " + transfer.rawTokens.map(shellQuote).joined(separator: " ")
            plans.append(
                CurlCommandTransferPlan(
                    index: transfer.index,
                    command: command,
                    urls: transfer.urls,
                    effectiveOptions: effectiveOptions
                )
            )
        }

        return plans
    }

    private func validateCapabilities(
        for transfers: [CurlCommandTransferPlan],
        diagnostics: inout [CurlDiagnostic]
    ) {
        var emittedKeys: Set<String> = []

        func emit(_ diagnostic: CurlDiagnostic) {
            let key = "\(diagnostic.severity.rawValue)|\(diagnostic.option ?? "")|\(diagnostic.message)"
            if emittedKeys.insert(key).inserted {
                diagnostics.append(diagnostic)
            }
        }

        for transfer in transfers {
            for option in transfer.effectiveOptions.keys where !capabilities.supportedOptions.contains(option) {
                emit(
                    CurlDiagnostic(
                        severity: .error,
                        option: option,
                        message: "Option '\(option)' is recognized but not supported by the \(capabilities.backendName) backend"
                    )
                )
            }

            for url in transfer.urls {
                guard let scheme = scheme(from: url) else { continue }
                if !capabilities.supportedProtocols.contains(scheme) {
                    emit(
                        CurlDiagnostic(
                            severity: .error,
                            option: "--url",
                            message: "Protocol '\(scheme)' is not supported by the \(capabilities.backendName) backend"
                        )
                    )
                }
            }

            validateConfigFiles(for: transfer, emit: emit)
            validateVariables(for: transfer, emit: emit)
        }
    }

    private func validateConfigFiles(
        for transfer: CurlCommandTransferPlan,
        emit: (CurlDiagnostic) -> Void
    ) {
        let configOptionKeys = ["--config", "-K"]
        for key in configOptionKeys {
            for value in transfer.effectiveOptions[key] ?? [] {
                if value == "true" || value == "-" {
                    continue
                }
                if !FileManager.default.isReadableFile(atPath: value) {
                    emit(
                        CurlDiagnostic(
                            severity: .error,
                            option: key,
                            message: "Config file not found or not readable: \(value)"
                        )
                    )
                }
            }
        }
    }

    private func validateVariables(
        for transfer: CurlCommandTransferPlan,
        emit: (CurlDiagnostic) -> Void
    ) {
        for value in transfer.effectiveOptions["--variable"] ?? [] where value != "true" {
            if value.hasPrefix("%") {
                continue
            }
            let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count != 2 || parts[0].isEmpty {
                emit(
                    CurlDiagnostic(
                        severity: .error,
                        option: "--variable",
                        message: "Invalid variable definition: \(value)"
                    )
                )
            }
        }
    }

    private func scheme(from value: String) -> String? {
        if let colon = value.firstIndex(of: ":") {
            let maybeScheme = String(value[..<colon]).lowercased()
            if maybeScheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }) {
                return maybeScheme
            }
            return nil
        }
        return "http"
    }

    private func handleLongOption(
        _ token: String,
        stream: inout TokenStream,
        transfer: inout MutableTransfer,
        globalOptions: inout [String: [String]],
        diagnostics: inout [CurlDiagnostic]
    ) {
        var optionToken = token
        var inlineValue: String?

        if let equalsIndex = optionToken.firstIndex(of: "=") {
            inlineValue = String(optionToken[optionToken.index(after: equalsIndex)...])
            optionToken = String(optionToken[..<equalsIndex])
        }

        let expandedOptionToken: String
        if optionToken.hasPrefix("--expand-") {
            expandedOptionToken = "--" + optionToken.dropFirst("--expand-".count)
        } else {
            expandedOptionToken = optionToken
        }

        let resolvedOption = resolveNegatedOption(expandedOptionToken)
        let isNegated = resolvedOption != expandedOptionToken

        guard let metadata = CurlOptionMetadataRegistry.metadata(for: resolvedOption) else {
            transfer.rawTokens.append(token)
            diagnostics.append(
                CurlDiagnostic(
                    severity: .error,
                    option: resolvedOption,
                    message: "Unsupported cURL option: \(resolvedOption)"
                )
            )
            return
        }

        transfer.rawTokens.append(resolvedOption)

        switch metadata.arity {
        case .flag:
            storeOption(
                option: resolvedOption,
                value: isNegated ? "false" : nil,
                metadata: metadata,
                transfer: &transfer,
                globalOptions: &globalOptions
            )

        case .requiredValue:
            let value = inlineValue ?? stream.next()
            guard let value else {
                diagnostics.append(
                    CurlDiagnostic(
                        severity: .error,
                        option: resolvedOption,
                        message: "Option '\(resolvedOption)' requires a value"
                    )
                )
                return
            }
            transfer.rawTokens.append(value)
            storeOption(
                option: resolvedOption,
                value: value,
                metadata: metadata,
                transfer: &transfer,
                globalOptions: &globalOptions
            )
            if resolvedOption == "--url" {
                transfer.urls.append(value)
            }

        case .optionalValue:
            let value: String?
            if let inlineValue {
                value = inlineValue
            } else if shouldConsumeOptionalValue(peekedToken: stream.peek()) {
                value = stream.next()
            } else {
                value = nil
            }
            if let value {
                transfer.rawTokens.append(value)
            }
            storeOption(
                option: resolvedOption,
                value: value,
                metadata: metadata,
                transfer: &transfer,
                globalOptions: &globalOptions
            )
        }
    }

    private func resolveNegatedOption(_ option: String) -> String {
        guard option.hasPrefix("--no-") else { return option }
        let base = "--" + option.dropFirst(5)
        let baseOption = String(base)
        return CurlOptionRegistry.isKnown(baseOption) ? baseOption : option
    }

    private func handleShortOption(
        _ token: String,
        stream: inout TokenStream,
        transfer: inout MutableTransfer,
        globalOptions: inout [String: [String]],
        diagnostics: inout [CurlDiagnostic]
    ) -> Bool {
        if let metadata = CurlOptionMetadataRegistry.metadata(for: token) {
            transfer.rawTokens.append(token)
            return handleParsedShortOption(
                option: token,
                metadata: metadata,
                stream: &stream,
                transfer: &transfer,
                globalOptions: &globalOptions,
                diagnostics: &diagnostics
            )
        }

        guard token.count > 2 else {
            diagnostics.append(
                CurlDiagnostic(
                    severity: .error,
                    option: token,
                    message: "Unsupported cURL option: \(token)"
                )
            )
            transfer.rawTokens.append(token)
            return true
        }

        let chars = Array(token.dropFirst())
        var index = 0

        while index < chars.count {
            let option = "-" + String(chars[index])
            guard let metadata = CurlOptionMetadataRegistry.metadata(for: option) else {
                diagnostics.append(
                    CurlDiagnostic(
                        severity: .error,
                        option: option,
                        message: "Unsupported cURL option: \(option)"
                    )
                )
                transfer.rawTokens.append(token)
                return true
            }

            transfer.rawTokens.append(option)

            switch metadata.arity {
            case .flag:
                storeOption(
                    option: option,
                    value: nil,
                    metadata: metadata,
                    transfer: &transfer,
                    globalOptions: &globalOptions
                )
                index += 1

            case .requiredValue, .optionalValue:
                let remainder: String? = if index + 1 < chars.count {
                    String(chars[(index + 1)...])
                } else {
                    nil
                }

                let value: String?
                if let remainder {
                    value = remainder
                } else if metadata.arity == .requiredValue {
                    value = stream.next()
                } else if shouldConsumeOptionalValue(peekedToken: stream.peek()) {
                    value = stream.next()
                } else {
                    value = nil
                }

                if metadata.arity == .requiredValue, value == nil {
                    diagnostics.append(
                        CurlDiagnostic(
                            severity: .error,
                            option: option,
                            message: "Option '\(option)' requires a value"
                        )
                    )
                    return true
                }

                if let value {
                    transfer.rawTokens.append(value)
                }
                storeOption(
                    option: option,
                    value: value,
                    metadata: metadata,
                    transfer: &transfer,
                    globalOptions: &globalOptions
                )
                return true
            }
        }

        return true
    }

    private func handleParsedShortOption(
        option: String,
        metadata: CurlOptionMetadata,
        stream: inout TokenStream,
        transfer: inout MutableTransfer,
        globalOptions: inout [String: [String]],
        diagnostics: inout [CurlDiagnostic]
    ) -> Bool {
        switch metadata.arity {
        case .flag:
            storeOption(
                option: option,
                value: nil,
                metadata: metadata,
                transfer: &transfer,
                globalOptions: &globalOptions
            )

        case .requiredValue:
            guard let value = stream.next() else {
                diagnostics.append(
                    CurlDiagnostic(
                        severity: .error,
                        option: option,
                        message: "Option '\(option)' requires a value"
                    )
                )
                return true
            }
            transfer.rawTokens.append(value)
            storeOption(
                option: option,
                value: value,
                metadata: metadata,
                transfer: &transfer,
                globalOptions: &globalOptions
            )

        case .optionalValue:
            let value: String? = shouldConsumeOptionalValue(peekedToken: stream.peek()) ? stream.next() : nil
            if let value {
                transfer.rawTokens.append(value)
            }
            storeOption(
                option: option,
                value: value,
                metadata: metadata,
                transfer: &transfer,
                globalOptions: &globalOptions
            )
        }

        return true
    }

    private func shouldConsumeOptionalValue(peekedToken: String?) -> Bool {
        guard let peekedToken else { return false }
        return !peekedToken.hasPrefix("-")
    }

    private func storeOption(
        option: String,
        value: String?,
        metadata: CurlOptionMetadata,
        transfer: inout MutableTransfer,
        globalOptions: inout [String: [String]]
    ) {
        transfer.addOption(option, value: value)
        if metadata.category == .global {
            let storedValue = value ?? "true"
            globalOptions[option, default: []].append(storedValue)
        }
    }

    private func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var currentToken = ""
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var escaped = false
        var justClosedQuote = false
        let chars = Array(command)
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
}
