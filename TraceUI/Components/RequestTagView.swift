//
//  RequestTagView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore

public struct RequestTagView: View {
    public let tag: TagType

    public var body: some View {
        Text(tag.displayText)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tag.color)
            .cornerRadius(4)
            .accessibilityLabel(tag.tooltip)
    }
}

public struct DuplicateCounterView: View {
    public let count: Int

    public var body: some View {
        Text("×\(count)")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(3)
            .accessibilityLabel("\(count) duplicate requests")
    }
}

public struct OverflowTagView: View {
    public let count: Int
    public let allTags: [TagType]
    @State private var showAllTags = false

    public var body: some View {
        Text("+\(count)")
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(4)
            .accessibilityLabel("\(count) more tags")
            .onTapGesture {
                showAllTags = true
            }
            .popover(isPresented: $showAllTags) {
                AllTagsPopover(tags: allTags)
            }
    }
}

public struct AllTagsPopover: View {
    public let tags: [TagType]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All Tags")
                .font(.headline)
                .padding(.bottom, 4)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 80), spacing: 8)
            ], spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    RequestTagView(tag: tag)
                }
            }
        }
        .padding()
        .frame(maxWidth: 300)
    }
}
