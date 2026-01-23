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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: group.session.isActive ? "record.circle" : "checkmark.circle")
                    .foregroundStyle(group.session.isActive ? .red : .green)
                Text(group.session.displayName)
                    .font(.headline)
            }
            HStack(spacing: 12) {
                Label("\(group.requestCount) requests", systemImage: "number")
                Label(group.session.durationString, systemImage: "clock")
                Label(group.totalSizeString, systemImage: "arrow.down.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.session.displayName), \(group.session.isActive ? "Active" : "Completed") session, \(group.requestCount) requests, \(group.session.durationString), \(group.totalSizeString)")
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
        .padding(.vertical, 4)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(DesignSystem.Colors.accent))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.domain), \(group.requestCount) requests")
    }
}
