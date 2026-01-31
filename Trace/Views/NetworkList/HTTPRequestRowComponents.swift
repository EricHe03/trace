//
//  HTTPRequestRowComponents.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

/// Reusable components for displaying HTTP request rows in lists
public enum HTTPRequestRowComponents {
    // MARK: - Main Row Builder

    @ViewBuilder
    public static func httpRequestRow(
        for request: NetworkRequest,
        isSimulator: Bool,
        onToggleFavorite: @escaping (NetworkRequest) -> Void,
        onDeleteRequest: @escaping (NetworkRequest) -> Void,
        onShareRequest: @escaping (NetworkRequest) -> Void,
        contextMenuContent: @escaping (NetworkRequest) -> some View
    ) -> some View {
        let linkContent = requestRowContent(
            for: request
        )
        let linkView = NavigationLink(destination: DetailView(request: request)) {
            linkContent
        }

        let withLeadingSwipe = linkView.swipeActions(edge: .leading, allowsFullSwipe: false) {
            favoriteButton(for: request, onToggleFavorite: onToggleFavorite)
        }

        let withTrailingSwipe = withLeadingSwipe.swipeActions(edge: .trailing, allowsFullSwipe: false) {
            deleteButton(for: request, onDeleteRequest: onDeleteRequest)
            shareButton(for: request, onShareRequest: onShareRequest)
        }

        if isSimulator {
            withTrailingSwipe
        } else {
            withTrailingSwipe.contextMenu {
                contextMenuContent(request)
            }
        }
    }

    // MARK: - Row Content

    private static func requestRowContent(
        for request: NetworkRequest
    ) -> some View {
        RequestListRow(
            request: request,
            isFavorited: FavoritesManager.shared.isFavorited(requestId: request.id)
        )
    }

    // MARK: - Swipe Action Buttons

    private static func favoriteButton(
        for request: NetworkRequest,
        onToggleFavorite: @escaping (NetworkRequest) -> Void
    ) -> some View {
        Button {
            onToggleFavorite(request)
        } label: {
            Label("Favorite", systemImage: "star.fill")
        }
        .tint(DesignSystem.Colors.favorite)
    }

    private static func deleteButton(
        for request: NetworkRequest,
        onDeleteRequest: @escaping (NetworkRequest) -> Void
    ) -> some View {
        Button(role: .destructive) {
            onDeleteRequest(request)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private static func shareButton(
        for request: NetworkRequest,
        onShareRequest: @escaping (NetworkRequest) -> Void
    ) -> some View {
        Button {
            onShareRequest(request)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .tint(DesignSystem.Colors.accent)
    }
}
