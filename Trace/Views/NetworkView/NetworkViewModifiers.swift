//
//  NetworkViewModifiers.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

// MARK: - Request Selection Modifier

struct RequestSelectionModifier: ViewModifier {
    let viewModel: CaptureViewModel
    @Binding var requestToOpen: NetworkRequest?
    @Binding var toastMessage: String?

    func body(content: Content) -> some View {
        content.onChangeCompat(of: viewModel.selectedRequestId) { newValue in
            handleRequestSelection(newValue)
        }
    }

    private func handleRequestSelection(_ requestId: UUID?) {
        guard let requestId else { return }
        if let request = viewModel.requests.first(where: { $0.id == requestId }) {
            requestToOpen = request
        } else {
            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                toastMessage = "Request not found"
            }
        }
        viewModel.selectedRequestId = nil
    }
}

// MARK: - Event Rebuild Modifier

struct EventRebuildModifier: ViewModifier {
    let viewModel: CaptureViewModel
    let webSocketViewModel: WebSocketViewModel
    let sseViewModel: SSEViewModel
    let scheduleRebuild: () -> Void

    func body(content: Content) -> some View {
        let filteredRequestIds = viewModel.filteredRequests.map(\.id)
        let webSocketIds = webSocketViewModel.connections.map(\.id)
        let sseConnectionIds = sseViewModel.connections.map(\.id)

        let step1 = content.onChangeCompat(of: filteredRequestIds) {
            scheduleRebuild()
        }
        let step2 = step1.onChangeCompat(of: webSocketIds) {
            scheduleRebuild()
        }
        let step3 = step2.onChangeCompat(of: sseConnectionIds) {
            scheduleRebuild()
        }
        let step4 = step3.onChangeCompat(of: viewModel.searchText) {
            scheduleRebuild()
        }
        return step4.onChangeCompat(of: viewModel.filterNetworkEventTypes) {
            scheduleRebuild()
        }
    }
}

// MARK: - Grouping Indicator Row

struct GroupingIndicatorRow: View {
    let mode: RequestGroupingMode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: mode.icon)
                .foregroundStyle(DesignSystem.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grouping: \(mode.rawValue)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
