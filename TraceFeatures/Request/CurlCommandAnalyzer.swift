//
//  CurlCommandAnalyzer.swift
//  TraceFeatures
//
//  Created by Codex on 2026/02/07.
//

import Foundation
#if canImport(TraceCurlRuntime)
import TraceCurlRuntime
#endif

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

    private struct MutablePartitionState {
        var index: Int
        var localPrefixTokens: [String] = []
        var localOptions: [String: [String]] = [:]
        var nodes: [MutableNode] = []
    }

    private struct MutableNode {
        var url: String?
        var urlViaOption: Bool = false
        var perURLPrefixTokens: [String] = []
        var perURLOptions: [String: [String]] = [:]
        var outputAssigned: Bool = false
        var uploadAssigned: Bool = false
    }

    private struct MutableOperation {
        var url: String
        var commandTokens: [String]
        var effectiveOptions: [String: [String]]
    }

    private struct PartitionProgress {
        var index: Int
        var hadTokens: Bool = false
        var emittedURL: Bool = false
    }

    private let capabilities: CurlRuntimeCapabilities

    public init(capabilities: CurlRuntimeCapabilities = .resolvedDefault) {
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
        if capabilities.backendName != "ParityValidation" {
            diagnostics.append(
                CurlDiagnostic(
                    severity: .info,
                    message: "cURL backend: \(capabilities.backendName)"
                )
            )
            if capabilities.supportedOptions != CurlOptionRegistry.allOptions {
                diagnostics.append(
                    CurlDiagnostic(
                        severity: .warning,
                        message: "Backend has partial cURL support. Unsupported options fail fast."
                    )
                )
            }
        }
        var partitions: [MutablePartitionState] = [MutablePartitionState(index: 0)]
        var currentPartition = 0
        var partitionProgress = PartitionProgress(index: 0)
        var globalPrefixTokens: [String] = []
        var globalOptions: [String: [String]] = [:]
        var endOfOptions = false

        while let token = stream.next() {
            if !endOfOptions, token == "--" {
                partitionProgress.hadTokens = true
                endOfOptions = true
                continue
            }

            if !endOfOptions, isNextPartitionToken(token) {
                if partitionProgress.hadTokens, !partitionProgress.emittedURL {
                    diagnostics.append(
                        CurlDiagnostic(
                            severity: .error,
                            message: "Transfer #\(partitionProgress.index + 1) has no URL"
                        )
                    )
                }
                let nextPartitionIndex = partitions[currentPartition].index + 1
                partitions.append(MutablePartitionState(index: nextPartitionIndex))
                currentPartition = partitions.count - 1
                partitionProgress = PartitionProgress(index: nextPartitionIndex)
                endOfOptions = false
                continue
            }

            if !endOfOptions, token.hasPrefix("--") {
                partitionProgress.hadTokens = true
                handleLongOption(
                    token,
                    stream: &stream,
                    partition: &partitions[currentPartition],
                    globalPrefixTokens: &globalPrefixTokens,
                    globalOptions: &globalOptions,
                    diagnostics: &diagnostics,
                    onURLEmission: { partitionProgress.emittedURL = true }
                )
                continue
            }

            if !endOfOptions, token.hasPrefix("-"), token != "-" {
                partitionProgress.hadTokens = true
                if handleShortOption(
                    token,
                    stream: &stream,
                    partition: &partitions[currentPartition],
                    globalPrefixTokens: &globalPrefixTokens,
                    globalOptions: &globalOptions,
                    diagnostics: &diagnostics
                ) {
                    continue
                }
            }

            partitionProgress.hadTokens = true
            partitionProgress.emittedURL = true
            assignURL(token, partition: &partitions[currentPartition], viaOption: nil)
        }

        if partitionProgress.hadTokens, !partitionProgress.emittedURL {
            diagnostics.append(
                CurlDiagnostic(
                    severity: .error,
                    message: "Transfer #\(partitionProgress.index + 1) has no URL"
                )
            )
        }

        let plans = buildTransferPlans(
            partitions: partitions,
            globalPrefixTokens: globalPrefixTokens,
            globalOptions: globalOptions
        )
        if plans.isEmpty {
            diagnostics.append(CurlDiagnostic(severity: .error, message: "Missing URL in cURL command"))
        }

        validateCapabilities(for: plans, diagnostics: &diagnostics)
        validateRuntimeFeatureSupport(for: plans, diagnostics: &diagnostics)
        validateRuntimePreflight(for: plans, diagnostics: &diagnostics)

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
        partitions: [MutablePartitionState],
        globalPrefixTokens: [String],
        globalOptions: [String: [String]]
    ) -> [CurlCommandTransferPlan] {
        var plans: [CurlCommandTransferPlan] = []

        let operations = expandOperations(
            partitions: partitions,
            globalPrefixTokens: globalPrefixTokens,
            globalOptions: globalOptions
        )

        for (index, operation) in operations.enumerated() {
            let command = "curl " + operation.commandTokens.map(shellQuote).joined(separator: " ")
            plans.append(
                CurlCommandTransferPlan(
                    index: index,
                    command: command,
                    argv: operation.commandTokens,
                    urls: [operation.url],
                    effectiveOptions: operation.effectiveOptions
                )
            )
        }

        return plans
    }

    private func expandOperations(
        partitions: [MutablePartitionState],
        globalPrefixTokens: [String],
        globalOptions: [String: [String]]
    ) -> [MutableOperation] {
        var operations: [MutableOperation] = []

        for partition in partitions {
            for node in partition.nodes {
                guard let url = node.url else { continue }

                var effectiveOptions = globalOptions
                for (key, values) in partition.localOptions {
                    effectiveOptions[key, default: []].append(contentsOf: values)
                }
                for (key, values) in node.perURLOptions {
                    effectiveOptions[key, default: []].append(contentsOf: values)
                }

                var commandTokens = globalPrefixTokens + partition.localPrefixTokens + node.perURLPrefixTokens
                if !node.urlViaOption {
                    commandTokens.append(url)
                }

                operations.append(
                    MutableOperation(
                        url: url,
                        commandTokens: commandTokens,
                        effectiveOptions: effectiveOptions
                    )
                )
            }
        }

        return operations
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

    private func validateRuntimePreflight(
        for transfers: [CurlCommandTransferPlan],
        diagnostics: inout [CurlDiagnostic]
    ) {
        #if canImport(TraceCurlRuntime)
        guard shouldRunRuntimePreflight else { return }

        var emittedMessages: Set<String> = []

        for transfer in transfers {
            do {
                let preflight = try CurlRuntimeBridge.preflightTransferCommand(argv: transfer.argv)
                if preflight.hasBlockingError {
                    let stderr = preflight.standardError
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let details = stderr.isEmpty
                        ? "parameter error code \(preflight.parameterErrorCode)"
                        : stderr
                    let message = "Runtime parser rejected transfer #\(transfer.index + 1): \(details)"
                    if emittedMessages.insert(message).inserted {
                        diagnostics.append(
                            CurlDiagnostic(
                                severity: .error,
                                message: message
                            )
                        )
                    }
                }
            } catch {
                let message = "Runtime preflight failed for transfer #\(transfer.index + 1): \(error.localizedDescription)"
                if emittedMessages.insert(message).inserted {
                    diagnostics.append(
                        CurlDiagnostic(
                            severity: .error,
                            message: message
                        )
                    )
                }
            }
        }
        #else
        _ = transfers
        #endif
    }

    private var shouldRunRuntimePreflight: Bool {
        #if canImport(TraceCurlRuntime)
        capabilities.backendName.contains("CCurlShim")
        #else
        false
        #endif
    }

    private func validateRuntimeFeatureSupport(
        for transfers: [CurlCommandTransferPlan],
        diagnostics: inout [CurlDiagnostic]
    ) {
        var emittedKeys: Set<String> = []

        func emit(severity: CurlDiagnosticSeverity, option: String, message: String) {
            let key = "\(severity.rawValue)|\(option)|\(message)"
            guard emittedKeys.insert(key).inserted else { return }
            diagnostics.append(
                CurlDiagnostic(
                    severity: severity,
                    option: option,
                    message: message
                )
            )
        }

        for transfer in transfers {
            let options = transfer.effectiveOptions

            if optionEnabled("--http2", in: options) || optionEnabled("--http2-prior-knowledge", in: options),
               !capabilities.supportsHTTP2 {
                emit(
                    severity: .error,
                    option: "--http2",
                    message: "HTTP/2 is not supported by the \(capabilities.backendName) backend"
                )
            }

            if optionEnabled("--compressed", in: options), !capabilities.supportsContentDecoding {
                emit(
                    severity: .error,
                    option: "--compressed",
                    message: "Compressed response decoding is not supported by the \(capabilities.backendName) backend"
                )
            }

            if optionEnabled("--ca-native", in: options) || optionEnabled("--proxy-ca-native", in: options),
               !capabilities.supportsNativeCA {
                emit(
                    severity: .warning,
                    option: "--ca-native",
                    message: "Native CA store is not supported by the \(capabilities.backendName) backend; bundled CA PEM will be used"
                )
            }

            if optionEnabled("--ntlm", in: options) || optionEnabled("--proxy-ntlm", in: options),
               !capabilities.supportsNTLM {
                emit(
                    severity: .error,
                    option: "--ntlm",
                    message: "NTLM authentication is not supported by the \(capabilities.backendName) backend"
                )
            }
        }
    }

    private func optionEnabled(
        _ option: String,
        in options: [String: [String]]
    ) -> Bool {
        guard let values = options[option], !values.isEmpty else { return false }
        return values.contains { $0.lowercased() != "false" }
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
        partition: inout MutablePartitionState,
        globalPrefixTokens: inout [String],
        globalOptions: inout [String: [String]],
        diagnostics: inout [CurlDiagnostic],
        onURLEmission: () -> Void
    ) {
        var optionToken = token
        var inlineValue: String?

        if let equalsIndex = optionToken.firstIndex(of: "=") {
            inlineValue = String(optionToken[optionToken.index(after: equalsIndex)...])
            optionToken = String(optionToken[..<equalsIndex])
        }

        let expandedOptionToken: String = if optionToken.hasPrefix("--expand-") {
            "--" + optionToken.dropFirst("--expand-".count)
        } else {
            optionToken
        }

        let resolvedOption = resolveNegatedOption(expandedOptionToken)
        let isNegated = resolvedOption != expandedOptionToken

        guard let metadata = CurlOptionMetadataRegistry.metadata(for: resolvedOption) else {
            diagnostics.append(
                CurlDiagnostic(
                    severity: .error,
                    option: expandedOptionToken,
                    message: "Unsupported cURL option: \(expandedOptionToken)"
                )
            )
            return
        }

        switch metadata.arity {
        case .flag:
            storeOption(
                optionKey: resolvedOption,
                commandOption: expandedOptionToken,
                storedValue: isNegated ? "false" : nil,
                commandValue: nil,
                metadata: metadata,
                partition: &partition,
                globalPrefixTokens: &globalPrefixTokens,
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
            if resolvedOption == "--url" {
                assignURL(
                    value,
                    partition: &partition,
                    viaOption: (token: expandedOptionToken, option: resolvedOption)
                )
                onURLEmission()
                return
            }
            storeOption(
                optionKey: resolvedOption,
                commandOption: expandedOptionToken,
                storedValue: value,
                commandValue: value,
                metadata: metadata,
                partition: &partition,
                globalPrefixTokens: &globalPrefixTokens,
                globalOptions: &globalOptions
            )

        case .optionalValue:
            let value: String? = if let inlineValue {
                inlineValue
            } else if shouldConsumeOptionalValue(peekedToken: stream.peek()) {
                stream.next()
            } else {
                nil
            }
            storeOption(
                optionKey: resolvedOption,
                commandOption: expandedOptionToken,
                storedValue: value,
                commandValue: value,
                metadata: metadata,
                partition: &partition,
                globalPrefixTokens: &globalPrefixTokens,
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
        partition: inout MutablePartitionState,
        globalPrefixTokens: inout [String],
        globalOptions: inout [String: [String]],
        diagnostics: inout [CurlDiagnostic]
    ) -> Bool {
        if let metadata = CurlOptionMetadataRegistry.metadata(for: token) {
            return handleParsedShortOption(
                option: token,
                metadata: metadata,
                stream: &stream,
                partition: &partition,
                globalPrefixTokens: &globalPrefixTokens,
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
                return true
            }

            switch metadata.arity {
            case .flag:
                storeOption(
                    optionKey: option,
                    commandOption: option,
                    storedValue: nil,
                    commandValue: nil,
                    metadata: metadata,
                    partition: &partition,
                    globalPrefixTokens: &globalPrefixTokens,
                    globalOptions: &globalOptions
                )
                index += 1

            case .requiredValue, .optionalValue:
                let remainder: String? = if index + 1 < chars.count {
                    String(chars[(index + 1)...])
                } else {
                    nil
                }

                let value: String? = if let remainder {
                    remainder
                } else if metadata.arity == .requiredValue {
                    stream.next()
                } else if shouldConsumeOptionalValue(peekedToken: stream.peek()) {
                    stream.next()
                } else {
                    nil
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

                storeOption(
                    optionKey: option,
                    commandOption: option,
                    storedValue: value,
                    commandValue: value,
                    metadata: metadata,
                    partition: &partition,
                    globalPrefixTokens: &globalPrefixTokens,
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
        partition: inout MutablePartitionState,
        globalPrefixTokens: inout [String],
        globalOptions: inout [String: [String]],
        diagnostics: inout [CurlDiagnostic]
    ) -> Bool {
        switch metadata.arity {
        case .flag:
            storeOption(
                optionKey: option,
                commandOption: option,
                storedValue: nil,
                commandValue: nil,
                metadata: metadata,
                partition: &partition,
                globalPrefixTokens: &globalPrefixTokens,
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
            storeOption(
                optionKey: option,
                commandOption: option,
                storedValue: value,
                commandValue: value,
                metadata: metadata,
                partition: &partition,
                globalPrefixTokens: &globalPrefixTokens,
                globalOptions: &globalOptions
            )

        case .optionalValue:
            let value: String? = shouldConsumeOptionalValue(peekedToken: stream.peek()) ? stream.next() : nil
            storeOption(
                optionKey: option,
                commandOption: option,
                storedValue: value,
                commandValue: value,
                metadata: metadata,
                partition: &partition,
                globalPrefixTokens: &globalPrefixTokens,
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
        optionKey: String,
        commandOption: String,
        storedValue: String?,
        commandValue: String?,
        metadata: CurlOptionMetadata,
        partition: inout MutablePartitionState,
        globalPrefixTokens: inout [String],
        globalOptions: inout [String: [String]]
    ) {
        let persistedValue = storedValue ?? "true"

        if metadata.category == .global {
            globalPrefixTokens.append(commandOption)
            if let commandValue {
                globalPrefixTokens.append(commandValue)
            }
            globalOptions[optionKey, default: []].append(persistedValue)
            return
        }

        if shouldAssignToURLNode(optionKey: optionKey, storedValue: persistedValue) {
            assignOptionToURLNode(
                optionKey: optionKey,
                commandOption: commandOption,
                persistedValue: persistedValue,
                commandValue: commandValue,
                partition: &partition
            )
            return
        }

        partition.localPrefixTokens.append(commandOption)
        if let commandValue {
            partition.localPrefixTokens.append(commandValue)
        }
        partition.localOptions[optionKey, default: []].append(persistedValue)
    }

    private func shouldAssignToURLNode(optionKey: String, storedValue: String) -> Bool {
        let outputOptions: Set<String> = ["--output", "-o", "--out-null", "--remote-name", "-O"]
        let uploadOptions: Set<String> = ["--upload-file", "-T"]
        guard outputOptions.contains(optionKey) || uploadOptions.contains(optionKey) else {
            return false
        }

        if optionKey == "--remote-name" || optionKey == "--out-null", storedValue == "false" {
            return false
        }
        return true
    }

    private func assignOptionToURLNode(
        optionKey: String,
        commandOption: String,
        persistedValue: String,
        commandValue: String?,
        partition: inout MutablePartitionState
    ) {
        let outputOptions: Set<String> = ["--output", "-o", "--out-null", "--remote-name", "-O"]
        let uploadOptions: Set<String> = ["--upload-file", "-T"]

        let assignment: URLNodeAssignment = if outputOptions.contains(optionKey) {
            .output
        } else if uploadOptions.contains(optionKey) {
            .upload
        } else {
            .none
        }

        let index = nextAssignableNodeIndex(for: assignment, partition: &partition)
        partition.nodes[index].perURLPrefixTokens.append(commandOption)
        if let commandValue {
            partition.nodes[index].perURLPrefixTokens.append(commandValue)
        }
        partition.nodes[index].perURLOptions[optionKey, default: []].append(persistedValue)
    }

    private enum URLNodeAssignment {
        case none
        case output
        case upload
    }

    private func nextAssignableNodeIndex(
        for assignment: URLNodeAssignment,
        partition: inout MutablePartitionState
    ) -> Int {
        let existingIndex: Int? = switch assignment {
        case .none:
            partition.nodes.firstIndex { $0.url == nil }
        case .output:
            partition.nodes.firstIndex { !$0.outputAssigned }
        case .upload:
            partition.nodes.firstIndex { !$0.uploadAssigned }
        }

        let index: Int
        if let existingIndex {
            index = existingIndex
        } else {
            partition.nodes.append(MutableNode())
            index = partition.nodes.count - 1
        }

        switch assignment {
        case .none:
            break
        case .output:
            partition.nodes[index].outputAssigned = true
        case .upload:
            partition.nodes[index].uploadAssigned = true
        }

        return index
    }

    private func assignURL(
        _ url: String,
        partition: inout MutablePartitionState,
        viaOption: (token: String, option: String)?
    ) {
        let index: Int
        if let existingIndex = partition.nodes.firstIndex(where: { $0.url == nil }) {
            index = existingIndex
        } else {
            partition.nodes.append(MutableNode())
            index = partition.nodes.count - 1
        }

        partition.nodes[index].url = url
        if let viaOption {
            partition.nodes[index].urlViaOption = true
            partition.nodes[index].perURLPrefixTokens.append(viaOption.token)
            partition.nodes[index].perURLPrefixTokens.append(url)
            partition.nodes[index].perURLOptions[viaOption.option, default: []].append(url)
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
                justClosedQuote = false
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
