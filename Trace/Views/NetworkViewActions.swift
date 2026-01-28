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

    func shareRequest(_ request: NetworkRequest, selectedRequest: Binding<NetworkRequest?>) {
        selectedRequest.wrappedValue = request
    }

    func shareRequest(_ request: NetworkRequest) {
        DesignSystem.Haptics.light()
        let items = [
            ShareHelper.formatRequestForSharing(request),
            CurlCommandGenerator.generate(from: request)
        ]
        presentShareSheet(items: items)
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

    /// Presents the iOS Share Sheet following best practices.
    ///
    /// ## Implementation Notes:
    /// - Validates items array (prevents blank white screen from empty items)
    /// - Presents on main thread using Task @MainActor
    /// - Finds topmost view controller (prevents "not in window hierarchy" error)
    /// - Configures iPad popover anchor (required for iPad, prevents blank screen)
    /// - Uses centered popover with no arrow (standard iOS pattern)
    ///
    /// ## Note:
    /// This is a UIKit-based approach used for non-View contexts.
    /// For SwiftUI views, prefer using the `ShareSheet` wrapper with `.sheet` modifier.
    ///
    private func presentShareSheet(items: [Any]) {
        // Prevent blank screen: ensure items array is never empty.
        let safeItems = items.isEmpty ? [ShareHelper.fallbackShareMessage] : items

        Task { @MainActor in
            // Find the window and root view controller.
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first,
                  let rootViewController = window.rootViewController else {
                return
            }

            // Find topmost presented view controller (prevents "not in window hierarchy" error).
            var presenter = rootViewController
            while let presented = presenter.presentedViewController {
                presenter = presented
            }

            // Create UIActivityViewController with custom activities.
            let activityVC = UIActivityViewController(
                activityItems: safeItems,
                applicationActivities: ActivityHelper.customActivitiesForRequest()
            )
            activityVC.excludedActivityTypes = ActivityHelper.defaultExcludedActivityTypes()

            // Required on iPad: Set popover anchor to prevent blank screen or crash.
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = window
                // Center the popover with no arrow (common iOS pattern for centered modals)
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            // Present on main thread.
            DispatchQueue.main.async {
                presenter.present(activityVC, animated: true)
            }
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

    func importCurlRequest(_ request: NetworkRequest) {
        Task {
            do {
                let executor = RequestExecutor()
                let response = try await executor.replay(request)
                try AppGroupStorage.shared.saveRequest(response)
                await viewModel.reloadRequests()
                await MainActor.run {
                    DesignSystem.Haptics.success()
                    viewModel.selectedRequestId = response.id
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        toastMessage.wrappedValue = "Imported and sent cURL request"
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
