//
//  NetworkTypeFilters.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct NetworkTypeFilters: View {
    let viewModel: CaptureViewModel
    let eventCountByType: [NetworkEventType: Int]
    let onToggleType: (NetworkEventType) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ForEach(NetworkEventType.allCases) { type in
                    typeFilterChip(for: type)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sectionHorizontal)
            .padding(.vertical, DesignSystem.Spacing.md)
        }
        .background(DesignSystem.Colors.groupedBackground)
    }

    private func typeFilterChip(for type: NetworkEventType) -> some View {
        let isEnabled = viewModel.filterNetworkEventTypes.contains(type)
        let count = eventCountByType[type] ?? 0

        return FilterChip(
            title: type.displayName,
            icon: type.icon,
            isSelected: isEnabled,
            count: count,
            selectedColor: DesignSystem.Colors.eventTypeColor(for: type)
        ) {
            onToggleType(type)
        }
    }
}

// MARK: - NetworkEventType Extension

extension NetworkEventType {
    var displayName: String {
        switch self {
        case .http: "HTTP"
        case .webSocket: "WebSocket"
        case .sse: "SSE"
        }
    }
}
