//
//  PCAPFileRow.swift
//  Trace
//
//  Created by Justin on 2026/03/06.
//

import SwiftUI
import TraceUI

struct PCAPFileRow: View {
    let file: PCAPExportView.PCAPFileInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: DesignSystem.Spacing.md) {
                    Text(file.sizeFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(file.dateFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name), \(file.sizeFormatted), \(file.dateFormatted)")
        .accessibilityHint("Swipe to share or delete")
    }
}
