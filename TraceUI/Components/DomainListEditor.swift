//
//  DomainListEditor.swift
//  TraceUI
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI

public struct DomainListEditor: View {
    public let title: String
    public let addLabel: String
    public let placeholder: String
    public let helperText: String?
    public let emptyText: String?
    public var validate: ((String) -> String?)?
    public var normalize: ((String) -> String)?
    @Binding public var items: [String]

    @State private var newItem: String = ""
    @State private var errorMessage: String?

    public init(
        title: String,
        items: Binding<[String]>,
        addLabel: String = "Add",
        placeholder: String = "example.com",
        helperText: String? = nil,
        emptyText: String? = nil,
        validate: ((String) -> String?)? = nil,
        normalize: ((String) -> String)? = nil
    ) {
        self.title = title
        self._items = items
        self.addLabel = addLabel
        self.placeholder = placeholder
        self.helperText = helperText
        self.emptyText = emptyText
        self.validate = validate
        self.normalize = normalize
    }

    public var body: some View {
        Section {
            if items.isEmpty {
                Text(emptyText ?? "No entries yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack {
                        Text(item)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                                items.removeAll { $0 == item }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item)")
                    }
                }
            }

            HStack {
                TextField(placeholder, text: $newItem)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("\(title) entry")
                    .accessibilityHint(helperText ?? "Enter a domain pattern, then tap Add")

                Button(addLabel) {
                    addItem()
                }
                .buttonStyle(.bordered)
                .disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(addLabel)
                .accessibilityHint("Adds the entered item")
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let helperText {
                    Text(helperText)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(DesignSystem.Colors.danger)
                        .accessibilityLabel("Error")
                        .accessibilityValue(errorMessage)
                }
            }
        }
    }

    private func addItem() {
        let raw = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let normalized = normalize?(raw) ?? raw.lowercased()
        if let error = validate?(normalized) {
            errorMessage = error
            return
        }

        guard !items.contains(normalized) else {
            errorMessage = "Already added"
            return
        }

        errorMessage = nil
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            items.append(normalized)
        }
        newItem = ""
    }
}
