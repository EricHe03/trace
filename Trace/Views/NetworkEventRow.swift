//
//  NetworkEventRow.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct NetworkEventRow<ContextMenu: View>: View {
    let event: NetworkEvent
    let webSocketViewModel: WebSocketViewModel
    let sseViewModel: SSEViewModel
    let isSimulator: Bool
    let onToggleFavorite: (NetworkRequest) -> Void
    let onDeleteRequest: (NetworkRequest) -> Void
    let onShareRequest: (NetworkRequest) -> Void
    let contextMenuContent: (NetworkRequest) -> ContextMenu

    var body: some View {
        switch event {
        case let .httpRequest(request):
            httpRequestRow(for: request)

        case let .webSocket(connection):
            NavigationLink(destination: WebSocketDetailView(connection: connection)) {
                WebSocketConnectionRow(connection: connection)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    webSocketViewModel.deleteConnection(connection)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

        case let .sse(connection):
            NavigationLink(destination: LiveSSEDetailView(connectionID: connection.id, fallbackConnection: connection, viewModel: sseViewModel)) {
                SSEConnectionRow(connection: connection)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    sseViewModel.deleteConnection(connection)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

        case let .transportRequest(request):
            NavigationLink(destination: TransportDetailView(request: request)) {
                TransportEventRow(request: request)
            }
        }
    }

    private func httpRequestRow(for request: NetworkRequest) -> some View {
        HTTPRequestRowComponents.httpRequestRow(
            for: request,
            isSimulator: isSimulator,
            onToggleFavorite: onToggleFavorite,
            onDeleteRequest: onDeleteRequest,
            onShareRequest: onShareRequest,
            contextMenuContent: contextMenuContent
        )
    }
}
