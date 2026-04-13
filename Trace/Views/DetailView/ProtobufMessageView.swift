//
//  ProtobufMessageView.swift
//  Trace
//

import SwiftUI
import TraceCore
import TraceUI

// MARK: - ProtobufMessageView

struct ProtobufMessageView: View {
    let fields: [ProtobufDecoder.Field]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ForEach(fields) { field in
                ProtobufFieldRow(field: field, depth: depth)
                if field.id != fields.last?.id {
                    Divider()
                        .padding(.leading, CGFloat(depth) * 12)
                }
            }
        }
    }
}

// MARK: - ProtobufFieldRow

private struct ProtobufFieldRow: View {
    let field: ProtobufDecoder.Field
    let depth: Int

    @State private var isExpanded = false

    var body: some View {
        switch field.value {
        case let .submessage(nestedFields):
            submessageRow(nestedFields)

        case let .repeated(values):
            repeatedRow(values)

        default:
            scalarRow
        }
    }

    @ViewBuilder
    private var scalarRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            fieldLabel
            Spacer(minLength: DesignSystem.Spacing.sm)
            Text(field.value.previewText)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(4)
        }
        .padding(.leading, CGFloat(depth) * 12)
    }

    @ViewBuilder
    private func submessageRow(_ nestedFields: [ProtobufDecoder.Field]) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ProtobufMessageView(fields: nestedFields, depth: depth + 1)
                .padding(.top, DesignSystem.Spacing.xs)
        } label: {
            HStack {
                fieldLabel
                Spacer()
                Text("{\(nestedFields.count) field\(nestedFields.count == 1 ? "" : "s")}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
    }

    @ViewBuilder
    private func repeatedRow(_ values: [ProtobufDecoder.Value]) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(alignment: .top) {
                        Text("[\(index)]")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, alignment: .leading)
                        Text(value.previewText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, DesignSystem.Spacing.xs)
            .padding(.leading, CGFloat(depth + 1) * 12)
        } label: {
            HStack {
                fieldLabel
                Spacer()
                Text("[\(values.count)]")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
    }

    private var fieldLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            Text(field.value.typeLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Proto Import Sheet

struct ProtobufSchemaImportSheet: View {
    @Binding var isPresented: Bool
    let onImport: (String) -> Void

    @State private var protoText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Paste your .proto file content below. Field names will replace field numbers in the decoded view.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $protoText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 200)
                    .padding(DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(DesignSystem.Colors.danger)
                }
            }
            .padding()
            .navigationTitle("Import .proto Schema")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do {
                            _ = try ProtobufSchema.parse(protoText: protoText)
                            errorMessage = nil
                            onImport(protoText)
                            isPresented = false
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(protoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
