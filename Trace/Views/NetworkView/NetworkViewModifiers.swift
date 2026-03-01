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
        let step1 = content.onChangeCompat(of: viewModel.requestsChangeToken) {
            scheduleRebuild()
        }
        let step2 = step1.onChangeCompat(of: viewModel.transportRequestsChangeToken) {
            scheduleRebuild()
        }
        let step3 = step2.onChangeCompat(of: webSocketViewModel.connectionsChangeToken) {
            scheduleRebuild()
        }
        let step4 = step3.onChangeCompat(of: sseViewModel.connectionsChangeToken) {
            scheduleRebuild()
        }
        let step5 = step4.onChangeCompat(of: viewModel.eventRebuildFilterToken) {
            scheduleRebuild()
        }
        return step5.onChangeCompat(of: viewModel.groupingMode) {
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
