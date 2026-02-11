//
//  CurlCommandExecutor.swift
//  TraceFeatures
//
//  Created by Codex on 2026/02/07.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
#endif
#if canImport(TraceCurlRuntime)
import TraceCurlRuntime
#endif

@MainActor
public protocol CurlTransferRequestExecuting: AnyObject {
    func execute(_ request: RequestBuilder) async throws -> NetworkRequest
}

extension RequestExecutor: CurlTransferRequestExecuting {}

@MainActor
public final class CurlCommandExecutor {
    private let analyzer: CurlCommandAnalyzer
    private let requestExecutorFactory: () -> any CurlTransferRequestExecuting
    #if canImport(TraceCurlRuntime)
    typealias RuntimeTransferExecutor = @Sendable ([String]) async throws -> CurlRuntimeExecutionResult
    private let runtimeTransferExecutor: RuntimeTransferExecutor
    private let runtimeExecutionOverride: Bool?
    #endif

    public init(
        analyzer: CurlCommandAnalyzer = CurlCommandAnalyzer(),
        requestExecutorFactory: @escaping () -> any CurlTransferRequestExecuting = { RequestExecutor() }
    ) {
        self.analyzer = analyzer
        self.requestExecutorFactory = requestExecutorFactory
        #if canImport(TraceCurlRuntime)
        self.runtimeExecutionOverride = nil
        self.runtimeTransferExecutor = { argv in
            try await Task.detached(priority: .userInitiated) {
                try CurlRuntimeBridge.executeTransferCommand(argv: argv)
            }.value
        }
        #endif
    }

    #if canImport(TraceCurlRuntime)
    init(
        analyzer: CurlCommandAnalyzer = CurlCommandAnalyzer(),
        requestExecutorFactory: @escaping () -> any CurlTransferRequestExecuting = { RequestExecutor() },
        runtimeExecutionOverride: Bool,
        runtimeTransferExecutor: @escaping RuntimeTransferExecutor
    ) {
        self.analyzer = analyzer
        self.requestExecutorFactory = requestExecutorFactory
        self.runtimeExecutionOverride = runtimeExecutionOverride
        self.runtimeTransferExecutor = runtimeTransferExecutor
    }
    #endif

    public func analyze(_ command: String) -> CurlCommandPlan {
        analyzer.analyze(command)
    }

    public func execute(_ command: String) async -> CurlExecutionResult {
        let startedAt = Date()
        let plan = analyze(command)

        guard !plan.hasBlockingDiagnostics else {
            return CurlExecutionResult(plan: plan, transfers: [], startedAt: startedAt, finishedAt: Date())
        }

        if shouldUseRuntimeExecution(for: plan) {
            return await executeViaRuntimeCLI(plan: plan, startedAt: startedAt)
        }

        return await executeViaLegacyPath(plan: plan, startedAt: startedAt)
    }

    private func shouldUseRuntimeExecution(for plan: CurlCommandPlan) -> Bool {
        #if canImport(TraceCurlRuntime)
        if let runtimeExecutionOverride {
            return runtimeExecutionOverride
        }
        let backendHint = plan.diagnostics.contains {
            $0.severity == .info && $0.message.contains("CCurlShim")
        }
        guard backendHint else { return false }
        let report = CurlRuntimeBridge.currentReport()
        return report.available && report.supportsCLIExecution
        #else
        _ = plan
        return false
        #endif
    }

    private func executeViaRuntimeCLI(plan: CurlCommandPlan, startedAt: Date) async -> CurlExecutionResult {
        #if canImport(TraceCurlRuntime)
        var results: [CurlTransferExecution] = []

        for transfer in plan.transfers.sorted(by: { $0.index < $1.index }) {
            do {
                let runtimeResult = try await executeRuntimeTransfer(
                    argv: runtimeCommandArguments(for: transfer)
                )
                if runtimeResult.transferCount > 1 {
                    let message = "Runtime backend expanded transfer #\(transfer.index + 1) into \(runtimeResult.transferCount) operations; split with --next or explicit URLs for import"
                    results.append(
                        CurlTransferExecution(
                            transfer: transfer,
                            request: nil,
                            errorMessage: message,
                            diagnostics: [
                                CurlDiagnostic(
                                    severity: .error,
                                    message: message
                                )
                            ]
                        )
                    )
                    continue
                }

                if runtimeResult.exitCode == 0 {
                    let request = buildRuntimeRequest(
                        transfer: transfer,
                        runtimeResult: runtimeResult,
                        plan: plan
                    )
                    results.append(CurlTransferExecution(transfer: transfer, request: request))
                } else {
                    let stderr = runtimeResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = stderr.isEmpty
                        ? "curl exited with code \(runtimeResult.exitCode)"
                        : "curl exited with code \(runtimeResult.exitCode): \(stderr)"
                    results.append(
                        CurlTransferExecution(
                            transfer: transfer,
                            request: nil,
                            errorMessage: message,
                            diagnostics: [
                                CurlDiagnostic(
                                    severity: .error,
                                    message: "Transfer #\(transfer.index + 1) failed in runtime backend: \(message)"
                                )
                            ]
                        )
                    )
                }
            } catch {
                results.append(
                    CurlTransferExecution(
                        transfer: transfer,
                        request: nil,
                        errorMessage: error.localizedDescription,
                        diagnostics: [
                            CurlDiagnostic(
                                severity: .error,
                                message: "Transfer #\(transfer.index + 1) runtime execution failed: \(error.localizedDescription)"
                            )
                        ]
                    )
                )
            }
        }

        return CurlExecutionResult(plan: plan, transfers: results, startedAt: startedAt, finishedAt: Date())
        #else
        _ = plan
        return CurlExecutionResult(plan: plan, transfers: [], startedAt: startedAt, finishedAt: Date())
        #endif
    }

    #if canImport(TraceCurlRuntime)
    private func runtimeCommandArguments(for transfer: CurlCommandTransferPlan) -> [String] {
        if !transfer.argv.isEmpty {
            return transfer.argv
        }

        // Backward compatibility for plans serialized before argv was added.
        let tokenized = transfer.command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        if tokenized.first?.lowercased() == "curl" {
            return Array(tokenized.dropFirst())
        }
        return tokenized
    }

    private func executeRuntimeTransfer(argv: [String]) async throws -> CurlRuntimeExecutionResult {
        try await runtimeTransferExecutor(argv)
    }
    #endif

    private func executeViaLegacyPath(plan: CurlCommandPlan, startedAt: Date) async -> CurlExecutionResult {
        var results: [CurlTransferExecution] = []

        for transfer in plan.transfers.sorted(by: { $0.index < $1.index }) {
            do {
                let parsedRequests = try CurlParser.parseAll(transfer.command)
                guard !parsedRequests.isEmpty else {
                    results.append(
                        CurlTransferExecution(
                            transfer: transfer,
                            request: nil,
                            errorMessage: "No executable requests were produced for transfer #\(transfer.index + 1)",
                            diagnostics: [
                                CurlDiagnostic(
                                    severity: .error,
                                    message: "Transfer #\(transfer.index + 1) did not yield an executable request"
                                )
                            ]
                        )
                    )
                    continue
                }

                for request in parsedRequests {
                    var executableRequest = request
                    executableRequest.requestMethodRaw = methodOverride(from: transfer, fallback: request.method.rawValue)
                    executableRequest.curlExecutionMetadata = metadata(
                        for: transfer,
                        originalCommand: plan.originalCommand,
                        diagnostics: plan.diagnostics,
                        transferCount: plan.transfers.count
                    )

                    do {
                        let response = try await executeSingleRequest(executableRequest, transfer: transfer)
                        results.append(CurlTransferExecution(transfer: transfer, request: response))
                    } catch {
                        results.append(
                            CurlTransferExecution(
                                transfer: transfer,
                                request: nil,
                                errorMessage: error.localizedDescription,
                                diagnostics: [
                                    CurlDiagnostic(
                                        severity: .error,
                                        message: "Transfer #\(transfer.index + 1) failed during execution: \(error.localizedDescription)"
                                    )
                                ]
                            )
                        )
                    }
                }
            } catch {
                results.append(
                    CurlTransferExecution(
                        transfer: transfer,
                        request: nil,
                        errorMessage: error.localizedDescription,
                        diagnostics: [
                            CurlDiagnostic(
                                severity: .error,
                                message: "Transfer #\(transfer.index + 1) failed during parse: \(error.localizedDescription)"
                            )
                        ]
                    )
                )
            }
        }

        return CurlExecutionResult(plan: plan, transfers: results, startedAt: startedAt, finishedAt: Date())
    }

    #if canImport(TraceCurlRuntime)
    private func buildRuntimeRequest(
        transfer: CurlCommandTransferPlan,
        runtimeResult: CurlRuntimeExecutionResult,
        plan: CurlCommandPlan
    ) -> NetworkRequest {
        let parsedRequest = try? CurlParser.parseAll(transfer.command).first

        let fallbackMethodRaw = parsedRequest?.requestMethodRaw ?? parsedRequest?.method.rawValue ?? "GET"
        let methodRaw = methodOverride(from: transfer, fallback: fallbackMethodRaw)
        let method = HTTPMethod(rawValue: methodRaw.uppercased()) ?? parsedRequest?.method ?? .get
        let requestHeaders = parsedRequest?.requestHeaders ?? requestHeadersFromOptions(transfer)
        let requestBody = parsedRequest?.requestBody ?? requestBodyFromOptions(transfer)

        let statusLine = runtimeResult.statusLine
        let responseHeaders = responseHeaders(from: runtimeResult.responseHeaderLines)
        let statusCode = sanitizeStatusCode(runtimeResult.statusCode)
            ?? sanitizeStatusCode(parseStatusCode(fromStatusLine: statusLine))
        let statusMessage = parseStatusMessage(fromStatusLine: statusLine)
        let protocolVersion = protocolVersion(fromStatusLine: statusLine) ?? parsedRequest?.protocolVersion
        let responseBody = runtimeResult.responseBody.isEmpty ? BodyStorage.empty : BodyStorage.from(data: runtimeResult.responseBody)
        let resolvedURL = runtimeResult.effectiveURL
            ?? parsedRequest?.url
            ?? transfer.urls.last
            ?? transfer.urls.first
            ?? "about:blank"

        return NetworkRequest(
            url: resolvedURL,
            method: method,
            requestMethodRaw: methodRaw,
            statusCode: statusCode,
            statusMessage: statusMessage,
            timestamp: Date(),
            duration: runtimeResult.timeTotal ?? 0,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody,
            protocolVersion: protocolVersion,
            curlExecutionMetadata: metadata(
                for: transfer,
                originalCommand: plan.originalCommand,
                diagnostics: plan.diagnostics,
                transferCount: plan.transfers.count
            )
        )
    }

    private func requestHeadersFromOptions(_ transfer: CurlCommandTransferPlan) -> [TraceHTTPHeader] {
        let values = (transfer.effectiveOptions["--header"] ?? []) + (transfer.effectiveOptions["-H"] ?? [])
        return values.compactMap { raw in
            guard let colonIndex = raw.firstIndex(of: ":") else { return nil }
            let key = String(raw[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(raw[raw.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return TraceHTTPHeader(key: key, value: value)
        }
    }

    private func requestBodyFromOptions(_ transfer: CurlCommandTransferPlan) -> BodyStorage {
        let dataOptionKeys = [
            "--data",
            "-d",
            "--data-raw",
            "--data-binary",
            "--data-ascii",
            "--data-urlencode"
        ]

        let values = dataOptionKeys.flatMap { transfer.effectiveOptions[$0] ?? [] }
            .filter { $0 != "true" }
        guard !values.isEmpty else {
            return .empty
        }

        return .from(string: values.joined(separator: "&"))
    }

    private func responseHeaders(from lines: [String]) -> [TraceHTTPHeader] {
        lines.compactMap { line in
            guard !line.hasPrefix("HTTP/"), let colon = line.firstIndex(of: ":") else {
                return nil
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return TraceHTTPHeader(key: key, value: value)
        }
    }

    private func parseStatusCode(fromStatusLine statusLine: String?) -> Int? {
        guard let statusLine else { return nil }
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private func sanitizeStatusCode(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private func parseStatusMessage(fromStatusLine statusLine: String?) -> String? {
        guard let statusLine else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        return String(parts[2])
    }

    private func protocolVersion(fromStatusLine statusLine: String?) -> HTTPProtocolVersion? {
        guard let statusLine else { return nil }
        if statusLine.hasPrefix("HTTP/1.0") {
            return .http10
        }
        if statusLine.hasPrefix("HTTP/1.1") {
            return .http11
        }
        if statusLine.hasPrefix("HTTP/2") {
            return .http2
        }
        if statusLine.hasPrefix("HTTP/3") {
            return .http3
        }
        return nil
    }
    #endif

    private func executeSingleRequest(_ request: NetworkRequest, transfer: CurlCommandTransferPlan) async throws -> NetworkRequest {
        let executor = requestExecutorFactory()
        var builder = RequestBuilder(from: request)
        builder.followRedirects = followRedirects(from: transfer)

        var response = try await executor.execute(builder)
        response.requestMethodRaw = request.requestMethodRaw
        response.curlExecutionMetadata = metadata(
            for: transfer,
            originalCommand: request.curlExecutionMetadata?.originalCommand ?? transfer.command,
            diagnostics: request.curlExecutionMetadata?.diagnostics.map {
                CurlDiagnostic(
                    severity: CurlDiagnosticSeverity(rawValue: $0.severity) ?? .info,
                    option: $0.option,
                    message: $0.message
                )
            } ?? [],
            transferCount: request.curlExecutionMetadata?.transferCount ?? 1
        )
        return response
    }

    private func followRedirects(from transfer: CurlCommandTransferPlan) -> Bool {
        let values = transfer.effectiveOptions["--location"] ?? transfer.effectiveOptions["-L"]
        guard let last = values?.last else {
            return false
        }
        return last.lowercased() != "false"
    }

    private func methodOverride(from transfer: CurlCommandTransferPlan, fallback: String) -> String {
        let override = transfer.effectiveOptions["--request"]?.last ?? transfer.effectiveOptions["-X"]?.last
        if let override, !override.isEmpty {
            return override
        }
        if transfer.effectiveOptions["--head"] != nil || transfer.effectiveOptions["-I"] != nil {
            return "HEAD"
        }
        return fallback
    }

    private func metadata(
        for transfer: CurlCommandTransferPlan,
        originalCommand: String,
        diagnostics: [CurlDiagnostic],
        transferCount: Int
    ) -> CurlExecutionMetadata {
        CurlExecutionMetadata(
            originalCommand: originalCommand,
            transferIndex: transfer.index,
            transferCount: max(transferCount, 1),
            effectiveOptions: transfer.effectiveOptions,
            diagnostics: diagnostics.map(\.asExecutionDiagnostic)
        )
    }
}
