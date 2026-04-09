//
//  NetworkListContent.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct NetworkListContent<ContextMenu: View>: View {
    let viewModel: CaptureViewModel
    let filteredEvents: [NetworkEvent]
    let webSocketViewModel: WebSocketViewModel
    let sseViewModel: SSEViewModel
    let isSimulator: Bool
    let effectiveGroupingMode: RequestGroupingMode
    let onToggleFavorite: (NetworkRequest) -> Void
    let onDeleteRequest: (NetworkRequest) -> Void
    let onShareRequest: (NetworkRequest) -> Void
    let contextMenuContent: (NetworkRequest) -> ContextMenu

    var body: some View {
        switch effectiveGroupingMode {
        case .none:
            ForEach(filteredEvents) { event in
                NetworkEventRow(
                    event: event,
                    webSocketViewModel: webSocketViewModel,
                    sseViewModel: sseViewModel,
                    isSimulator: isSimulator,
                    onToggleFavorite: onToggleFavorite,
                    onDeleteRequest: onDeleteRequest,
                    onShareRequest: onShareRequest,
                    contextMenuContent: contextMenuContent
                )
            }
        case .byDomain:
            ForEach(viewModel.groupedRequests.domainGroups) { group in
                Section {
                    ForEach(group.requests) { request in
                        httpRequestRow(for: request)
                    }
                } header: {
                    DomainSectionHeader(group: group)
                }
            }
        case .bySession:
            ForEach(viewModel.groupedRequests.sessionGroups) { group in
                Section {
                    ForEach(group.requests) { request in
                        httpRequestRow(for: request)
                    }
                } header: {
                    SessionSectionHeader(group: group)
                }
                .id(group.session.id)
            }
        case .hierarchical:
            ForEach(viewModel.groupedRequests.sessionGroups) { group in
                Section {
                    ForEach(group.domainGroups) { domainGroup in
                        DisclosureGroup {
                            ForEach(domainGroup.requests) { request in
                                httpRequestRow(for: request)
                            }
                        } label: {
                            DomainGroupLabel(group: domainGroup)
                        }
                    }
                } header: {
                    SessionSectionHeader(group: group)
                }
                .id(group.session.id)
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

// MARK: - Previews

#Preview {
    Text("NetworkListContent renders inside a List managed by NetworkView.")
        .foregroundStyle(.secondary)
        .padding()
}
