//
//  NetworkSectionHeaders.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct SessionSectionHeader: View {
    let group: SessionGroup

    var body: some View {
        Group {
            if group.session.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    headerContent(durationText: group.session.durationString(relativeTo: context.date))
                }
            } else {
                headerContent(durationText: group.session.durationString)
            }
        }
    }

    private func headerContent(durationText: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Image(systemName: group.session.isActive ? "record.circle.fill" : "checkmark.circle")
                    .foregroundStyle(group.session.isActive ? DesignSystem.Colors.danger : DesignSystem.Colors.success)
                Text(group.session.displayName)
                    .font(.headline)
            }
            HStack(spacing: 12) {
                Label("\(group.requestCount) requests", systemImage: "list.number")
                Label(durationText, systemImage: "clock")
                Label(group.totalSizeString, systemImage: "arrow.down.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.session.displayName), \(group.session.isActive ? "Active" : "Completed") session, \(group.requestCount) requests, \(durationText), \(group.totalSizeString)")
        .accessibilityAddTraits(.isHeader)
    }
}

struct DomainSectionHeader: View {
    let group: DomainGroup

    var body: some View {
        HStack {
            Image(systemName: "globe")
            Text(group.domain)
                .font(.headline)
            Spacer()
            Text("\(group.requestCount) requests")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(group.totalSizeString)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.domain), \(group.requestCount) requests, \(group.totalSizeString)")
        .accessibilityAddTraits(.isHeader)
    }
}

struct DomainGroupLabel: View {
    let group: DomainGroup

    var body: some View {
        HStack {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text(group.domain)
            Spacer()
            Text("\(group.requestCount)")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                .padding(.vertical, DesignSystem.Badge.verticalPadding)
                .background(Capsule().fill(DesignSystem.Colors.accent))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.domain), \(group.requestCount) requests")
    }
}

// MARK: - Previews

#Preview("SessionSectionHeader") {
    let session = CaptureSession(name: "Session 1", startTime: Date().addingTimeInterval(-120))
    let request = NetworkRequest(
        url: "https://api.example.com/users",
        method: .get,
        statusCode: 200,
        timestamp: Date(),
        duration: 0.15
    )
    let group = SessionGroup(session: session, requests: [request], domainGroups: [])
    List {
        SessionSectionHeader(group: group)
    }
}

#Preview("DomainSectionHeader") {
    let request = NetworkRequest(
        url: "https://api.example.com/users",
        method: .get,
        statusCode: 200,
        timestamp: Date(),
        duration: 0.15
    )
    let group = DomainGroup(domain: "api.example.com", requests: [request])
    List {
        DomainSectionHeader(group: group)
    }
}

#Preview("DomainGroupLabel") {
    let request = NetworkRequest(
        url: "https://api.example.com/users",
        method: .get,
        statusCode: 200,
        timestamp: Date(),
        duration: 0.15
    )
    let group = DomainGroup(domain: "api.example.com", requests: [request])
    List {
        DomainGroupLabel(group: group)
    }
}
