//
//  DomainFiltersView.swift
//  Trace
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI
import TraceCore
import TraceUI

struct DomainFiltersView: View {
    @State private var config: CaptureConfiguration = .default
    @State private var toastMessage: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("Filter Mode") {
                Picker("Mode", selection: $config.filterMode) {
                    Text("All").tag(FilterMode.all)
                    Text("Whitelist").tag(FilterMode.whitelist)
                    Text("Blacklist").tag(FilterMode.blacklist)
                }
                .pickerStyle(.segmented)
            }

            DomainListEditor(
                title: "Domains",
                items: $config.domainFilters,
                addLabel: "Add Domain",
                placeholder: "example.com",
                emptyText: "No domains added",
                validate: validateDomainPattern
            )

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    config.filterMode = .all
                    config.domainFilters = []
                    saveConfiguration()
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle("Domain Filters")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadConfiguration)
        .onChangeCompat(of: config.filterMode) { saveConfiguration() }
        .onChangeCompat(of: config.domainFilters) { saveConfiguration() }
        .toast(message: $toastMessage)
    }

    private func loadConfiguration() {
        config = AppGroupStorage.shared.loadConfiguration()
    }

    private func saveConfiguration() {
        guard !isSaving else { return }
        isSaving = true
        do {
            try AppGroupStorage.shared.saveConfiguration(config)
        } catch {
            toastMessage = "Failed to save domain filters: \(error.localizedDescription)"
            isSaving = false
            return
        }
        isSaving = false
    }

    private func validateDomainPattern(_ value: String) -> String? {
        Validation.isValidDomainPattern(value) ? nil : "Invalid domain pattern"
    }
}
