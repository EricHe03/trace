//
//  CurlCommandExecutor.swift
//  TraceFeatures
//
//  Created by Justin on 2026/02/07.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
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

    public init(
        analyzer: CurlCommandAnalyzer = CurlCommandAnalyzer(),
        requestExecutorFactory: @escaping () -> any CurlTransferRequestExecuting = { RequestExecutor() }
    ) {
        self.analyzer = analyzer
        self.requestExecutorFactory = requestExecutorFactory
    }

    public func analyze(_ command: String) -> CurlCommandPlan {
        analyzer.analyze(command)
    }

    public func execute(_ command: String) async -> CurlExecutionResult {
        let startedAt = Date()
        let plan = analyze(command)

        guard !plan.hasBlockingDiagnostics else {
            return CurlExecutionResult(plan: plan, transfers: [], startedAt: startedAt, finishedAt: Date())
        }

        return await executeViaParsedPath(plan: plan, startedAt: startedAt)
    }

    private func executeViaParsedPath(plan: CurlCommandPlan, startedAt: Date) async -> CurlExecutionResult {
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
