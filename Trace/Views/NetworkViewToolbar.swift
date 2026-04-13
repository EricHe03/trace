//
//  NetworkViewToolbar.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct NetworkViewToolbar: ToolbarContent {
    @ObservedObject var viewModel: CaptureViewModel
    let allEventsIsEmpty: Bool
    let onToggleFilters: () -> Void
    let onShowFavorites: () -> Void
    let onShowCurlImport: () -> Void
    let onClearAll: () -> Void

    var body: some ToolbarContent {
        // Grouping menu (HTTP only)
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Grouping", selection: Binding(
                    get: { viewModel.groupingMode },
                    set: { viewModel.setGroupingMode($0) }
                )) {
                    ForEach(RequestGroupingMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Group", systemImage: viewModel.groupingMode == .none ? "square.grid.2x2" : "square.grid.2x2.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(viewModel.groupingMode != .none ? DesignSystem.Colors.accent : .primary)
            }
            .accessibilityLabel("Grouping options")
            .accessibilityHint("Double tap to change request grouping mode")
        }

        // Filter button
        ToolbarItem(placement: .topBarLeading) {
            Button {
                onToggleFilters()
            } label: {
                Label("Filter", systemImage: viewModel.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(viewModel.hasActiveFilters ? DesignSystem.Colors.accent : .primary)
                    .overlay(alignment: .topTrailing) {
                        if viewModel.activeFilterCount > 0 {
                            Text("\(viewModel.activeFilterCount)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Circle().fill(DesignSystem.Colors.danger))
                                .offset(x: 6, y: -6)
                        }
                    }
            }
            .accessibilityLabel(viewModel.hasActiveFilters ? "Filters, \(viewModel.activeFilterCount) active" : "Filters")
            .accessibilityHint("Double tap to configure request filters")
        }

        // More menu
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    onShowFavorites()
                } label: {
                    Label("Favorites", systemImage: "star")
                }

                Button {
                    onShowCurlImport()
                } label: {
                    Label("Import cURL", systemImage: "square.and.arrow.down")
                }

                Divider()

                Button(role: .destructive) {
                    onClearAll()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(allEventsIsEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("More options")
            .accessibilityHint("Double tap to view favorites, import cURL, or clear all requests")
        }
    }
}
