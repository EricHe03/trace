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

    func importCurlCommand(_ command: String) {
        Task {
            let result = await CurlCommandExecutor().execute(command)
            let successful = Self.successfulRequests(from: result)

            do {
                for request in successful {
                    try AppGroupStorage.shared.saveRequest(request)
                }
                await viewModel.reloadRequests()

                await MainActor.run {
                    if let selected = successful.last {
                        viewModel.selectedRequestId = selected.id
                    }

                    if successful.isEmpty {
                        DesignSystem.Haptics.error()
                        let firstError = result.transfers.compactMap(\.errorMessage).first
                            ?? result.allDiagnostics.first?.message
                            ?? "No transfer executed"
                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                            toastMessage.wrappedValue = "Import failed: \(firstError)"
                        }
                    } else {
                        DesignSystem.Haptics.success()
                        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                            toastMessage.wrappedValue = "Imported \(result.succeededCount) transfer(s), failed \(result.failedCount)"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    DesignSystem.Haptics.error()
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage.wrappedValue = "Import failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    static func successfulRequests(from result: CurlExecutionResult) -> [NetworkRequest] {
        result.transfers
            .filter(\.succeeded)
            .compactMap(\.request)
    }

    func clearAllData(
        webSocketViewModel: WebSocketViewModel,
        sseViewModel: SSEViewModel
    ) {
        DesignSystem.Haptics.warning()
        viewModel.clearRequests()
        webSocketViewModel.clearAllConnections()
        sseViewModel.clearAllConnections()

        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage.wrappedValue = "All network activity cleared"
        }
    }
}
