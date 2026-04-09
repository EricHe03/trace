//
//  NetworkViewActions.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UIKit

struct NetworkViewActions {
    let viewModel: CaptureViewModel
    let toastMessage: Binding<String?>
    private static let localNetworkRetryDelayNanoseconds: UInt64 = 600_000_000

    func toggleFavorite(_ request: NetworkRequest) {
        DesignSystem.Haptics.medium()
        FavoritesManager.shared.toggleFavorite(requestId: request.id)
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage.wrappedValue = FavoritesManager.shared.isFavorited(requestId: request.id) ? "Added to favorites" : "Removed from favorites"
        }
    }

    func deleteRequest(_ request: NetworkRequest) {
        DesignSystem.Haptics.warning()
        viewModel.deleteRequest(request)
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage.wrappedValue = "Request deleted"
        }
    }

    func shareRequest(_ request: NetworkRequest) {
        DesignSystem.Haptics.light()
        let items = [
            ShareHelper.formatRequestForSharing(request),
            CurlCommandGenerator.generate(from: request)
        ]
        presentShareSheet(
            items: items,
            applicationActivities: ActivityHelper.customActivitiesForRequest()
        )
    }

    func shareResponseBody(_ request: NetworkRequest) {
        DesignSystem.Haptics.light()
        let items = ShareHelper.shareItemsForResponseBody(from: request)
        presentShareSheet(items: items)
    }

    func shareRequestBody(_ request: NetworkRequest) {
        DesignSystem.Haptics.light()
        let items = ShareHelper.shareItemsForRequestBody(from: request)
        presentShareSheet(items: items)
    }

    private func presentShareSheet(
        items: [Any],
        applicationActivities: [UIActivity]? = nil
    ) {
        Task { @MainActor in
            ShareHelper.presentShareSheet(
                items: items,
                applicationActivities: applicationActivities
            )
        }
    }

    func copyURL(_ request: NetworkRequest) {
        DesignSystem.Haptics.light()
        UIPasteboard.general.string = request.url
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage.wrappedValue = "URL copied to clipboard"
        }
    }

    func copyAsCurl(_ request: NetworkRequest) {
        DesignSystem.Haptics.light()
        let curl = CurlCommandGenerator.generate(from: request)
        UIPasteboard.general.string = curl
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage.wrappedValue = "cURL copied to clipboard"
        }
    }

    func replayRequest(_ request: NetworkRequest) {
        DesignSystem.Haptics.medium()
        Task {
            let executor = RequestExecutor()
            do {
                let response = try await executor.replay(request)
                // Save the replayed request response to storage
                try AppGroupStorage.shared.saveRequest(response)
                await viewModel.reloadRequests()
                await MainActor.run {
                    DesignSystem.Haptics.success()
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage.wrappedValue = "Request replayed successfully"
                    }
                }
            } catch {
                await MainActor.run {
                    DesignSystem.Haptics.error()
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage.wrappedValue = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func shareItems(for request: NetworkRequest) -> [Any] {
        let curl = CurlCommandGenerator.generate(from: request)
        return [curl]
    }

    @MainActor
    func importCurlCommand(_ command: String) async -> CurlImportView.ImportOutcome {
        let result = await executeCurlImportResult(command)
        let successful = Self.successfulRequests(from: result)

        do {
            for request in successful {
                try AppGroupStorage.shared.saveRequest(request)
            }
            await viewModel.reloadRequests()

            if let selected = successful.last {
                viewModel.selectedRequestId = selected.id
            }

            if successful.isEmpty {
                DesignSystem.Haptics.error()
                if Self.isLikelyPermissionIssue(in: result) {
                    return .permissionRequired(message: Self.permissionRequiredMessage)
                }
                return .failure(message: Self.importFailureMessage(from: result))
            }

            DesignSystem.Haptics.success()
            return .success(message: Self.importSuccessMessage(from: result))
        } catch {
            DesignSystem.Haptics.error()
            return .failure(message: "Imported responses could not be saved: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func executeCurlImportResult(_ command: String) async -> CurlExecutionResult {
        let executor = CurlCommandExecutor()
        let firstResult = await executor.execute(command)
        guard Self.shouldRetryAfterPermissionPrompt(in: firstResult) else {
            return firstResult
        }

        // Retry once after the system permission prompt resolves (Allow/Don't Allow).
        do {
            try await Task.sleep(nanoseconds: Self.localNetworkRetryDelayNanoseconds)
        } catch {
            return firstResult
        }
        guard !Task.isCancelled else { return firstResult }
        return await executor.execute(command)
    }

    static func successfulRequests(from result: CurlExecutionResult) -> [NetworkRequest] {
        result.transfers
            .filter(\.succeeded)
            .compactMap(\.request)
    }

    static let permissionRequiredMessage = "Network access is required to import this cURL command. Allow access in the system prompt, or enable it later in Settings."

    static func importSuccessMessage(from result: CurlExecutionResult) -> String {
        if result.failedCount == 0 {
            return "Imported \(result.succeededCount) transfer(s)"
        }
        return "Imported \(result.succeededCount) transfer(s); \(result.failedCount) could not be completed"
    }

    static func importFailureMessage(from result: CurlExecutionResult) -> String {
        let firstError = result.transfers.compactMap(\.errorMessage).first
            ?? result.allDiagnostics.first?.message
            ?? "No transfer was executed."
        return "Couldn't import cURL command. \(firstError)"
    }

    static func isLikelyPermissionIssue(in result: CurlExecutionResult) -> Bool {
        let messages = (result.transfers.compactMap(\.errorMessage) + result.allDiagnostics.map(\.message))
        let urls = result.plan.transfers.flatMap(\.urls)
        return NetworkPermissionHeuristics.isLikelyPermissionIssue(messages: messages, urls: urls)
    }

    static func shouldRetryAfterPermissionPrompt(in result: CurlExecutionResult) -> Bool {
        guard result.succeededCount == 0 else { return false }
        return isLikelyPermissionIssue(in: result)
    }

    static func targetsLocalNetwork(_ transfers: [CurlCommandTransferPlan]) -> Bool {
        NetworkPermissionHeuristics.targetsLocalNetwork(transfers.flatMap(\.urls))
    }

    static func isLocalNetworkURL(_ rawURL: String) -> Bool {
        NetworkPermissionHeuristics.isLocalNetworkURL(rawURL)
    }

    static func isPrivateIPv4Address(_ host: String) -> Bool {
        NetworkPermissionHeuristics.isPrivateIPv4Address(host)
    }

    static func isPrivateIPv6Address(_ host: String) -> Bool {
        NetworkPermissionHeuristics.isPrivateIPv6Address(host)
    }

    func clearAllData(
        webSocketViewModel: WebSocketViewModel,
        sseViewModel: SSEViewModel
    ) {
        DesignSystem.Haptics.warning()
        viewModel.clearRequests()
        viewModel.clearTransportRequests()
        webSocketViewModel.clearAllConnections()
        sseViewModel.clearAllConnections()

        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage.wrappedValue = "All network activity cleared"
        }
    }
}
