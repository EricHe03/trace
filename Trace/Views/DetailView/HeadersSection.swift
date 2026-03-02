//
//  HeadersSection.swift
//  Trace
//
//  Created by Justin on 2026/01/14.
//

import SwiftUI
import TraceCore
import TraceUI

struct HeadersSection: View {
    let headers: [TraceHTTPHeader]

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            if !headers.isEmpty {
                SectionCard(title: "Headers") {
                    ForEach(Array(headers.enumerated()), id: \.element.id) { index, header in
                        if index > 0 {
                            Divider()
                        }
                        InfoRow(label: header.key, value: header.value)
                    }
                }
            } else {
                TraceContentUnavailableView(
                    "No Headers",
                    systemImage: "list.bullet.rectangle",
                    description: Text("This request has no headers")
                )
            }
        }
    }
}
