//
//  HostEditorView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI
import UIKit

struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hostsManager = HostsManager.shared

    let entry: HostEntry?

    @State private var name: String
    @State private var enabled: Bool
    @State private var hostname: String
    @State private var targetIP: String
    @State private var targetPortString: String
    @State private var showValidationErrors = false

    init(entry: HostEntry?) {
        self.entry = entry

        _name = State(initialValue: entry?.name ?? "")
        _enabled = State(initialValue: entry?.enabled ?? true)
        _hostname = State(initialValue: entry?.hostname ?? "")
        _targetIP = State(initialValue: entry?.targetIP ?? "")
        _targetPortString = State(initialValue: entry?.targetPort.map { String($0) } ?? "")
    }

    private var targetPort: Int? {
        if targetPortString.isEmpty {
            return nil
        }
        return Int(targetPortString)
    }

    private var validationErrors: [String] {
        var errors: [String] = []

        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Name cannot be empty")
        }

        if hostname.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Hostname cannot be empty")
        }

        if targetIP.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Target IP cannot be empty")
        }

        if !targetPortString.isEmpty {
            if let port = targetPort {
                if port < 1 || port > 65535 {
                    errors.append("Port must be between 1 and 65535")
                }
            } else {
                errors.append("Invalid port number")
            }
        }

        return errors
    }

    private var isValid: Bool {
        validationErrors.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Information") {
                    TextField("Entry Name", text: $name)
                        .autocapitalization(.words)
                        .accessibilityLabel("Entry name")

                    Toggle("Enabled", isOn: $enabled)
                        .accessibilityLabel("Enabled")
                }

                Section {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        TextField("Hostname", text: $hostname)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Hostname")

                        Text("e.g., api.example.com or *.example.com")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Match Hostname")
                } footer: {
                    Text("The hostname to match. Supports wildcards like *.example.com")
                }

                Section {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        TextField("Target IP", text: $targetIP)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityLabel("Target IP address")

                        Text("e.g., 192.168.1.100 or 10.0.0.50")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        TextField("Target Port (optional)", text: $targetPortString)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Target port")
                            .accessibilityHint("Optional. Leave empty to keep the original port.")

                        Text("Leave empty to use the original port")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Redirect Target")
                } footer: {
                    Text("The IP address and optional port to redirect to")
                }

                if !validationErrors.isEmpty {
                    Section {
                        ForEach(validationErrors, id: \.self) { error in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(DesignSystem.Colors.danger)
                                Text(error)
                                    .font(.subheadline)
                            }
                        }
                    } header: {
                        Text("Validation Errors")
                    }
                }

                Section {
                    exampleSection
                } header: {
                    Text("Example")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDismissToolbar()
            .navigationTitle(entry == nil ? "Add Host Entry" : "Edit Host Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEntry()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Example Section

    private var exampleSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("How it works:")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                exampleRow(
                    icon: "1.circle.fill",
                    text: "When a request is made to the hostname"
                )
                exampleRow(
                    icon: "2.circle.fill",
                    text: "It will be redirected to the target IP"
                )
                exampleRow(
                    icon: "3.circle.fill",
                    text: "Optionally override the port"
                )
            }

            Divider()
                .padding(.vertical, DesignSystem.Spacing.xs)

            Text("Examples:")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                exampleItem(
                    title: "Local Development",
                    hostname: "api.example.com",
                    target: "127.0.0.1:8080",
                    description: "Redirect API calls to local server"
                )

                exampleItem(
                    title: "Testing Environment",
                    hostname: "*.staging.com",
                    target: "192.168.1.50",
                    description: "Redirect all staging subdomains"
                )
            }
        }
    }

    private func exampleRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(DesignSystem.Colors.accent)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exampleItem(title: String, hostname: String, target: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)

            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(hostname)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(target)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    // MARK: - Save

    private func saveEntry() {
        // Show validation errors if invalid
        if !isValid {
            showValidationErrors = true
            if let first = validationErrors.first {
                UIAccessibility.post(notification: .announcement, argument: first)
            }
            return
        }

        let hostEntry: HostEntry

        if let existingEntry = entry {
            // Update existing entry
            hostEntry = HostEntry(
                id: existingEntry.id,
                name: name.trimmingCharacters(in: .whitespaces),
                enabled: enabled,
                hostname: hostname.trimmingCharacters(in: .whitespaces),
                targetIP: targetIP.trimmingCharacters(in: .whitespaces),
                targetPort: targetPort,
                createdAt: existingEntry.createdAt,
                modifiedAt: Date()
            )

            hostsManager.updateEntry(hostEntry)
        } else {
            // Create new entry
            hostEntry = HostEntry(
                name: name.trimmingCharacters(in: .whitespaces),
                enabled: enabled,
                hostname: hostname.trimmingCharacters(in: .whitespaces),
                targetIP: targetIP.trimmingCharacters(in: .whitespaces),
                targetPort: targetPort
            )

            hostsManager.addEntry(hostEntry)
        }

        dismiss()
    }
}

#Preview("Add Entry") {
    HostEditorView(entry: nil)
}

#Preview("Edit Entry") {
    HostEditorView(entry: HostEntry.sample)
}
