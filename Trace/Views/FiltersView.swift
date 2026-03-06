//
//  FiltersView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct FiltersView: View {
    @ObservedObject var viewModel: CaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newDomain = ""
    @State private var showingAddDomain = false
    @State private var showingSavePreset = false
    @State private var presetName = ""
    @State private var showingAdvancedFilters = false

    var body: some View {
        NavigationStack {
            Form {
                // Saved Presets Section
                if !viewModel.savedFilterPresets.isEmpty {
                    Section {
                        ForEach(viewModel.savedFilterPresets) { preset in
                            Button(action: {
                                viewModel.applyPreset(preset)
                            }) {
                                HStack {
                                    Image(systemName: "slider.horizontal.3")
                                        .foregroundStyle(DesignSystem.Colors.accent)
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.deletePreset(preset)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Saved Presets")
                    }
                }

                // Quick Filters Section
                Section {
                    Toggle("Favorites Only", isOn: $viewModel.filterFavoritesOnly)
                        .tint(DesignSystem.Colors.favorite)
                        .accessibilityHint("Filter to show only favorited requests")

                    Toggle("Errors Only (4xx/5xx)", isOn: $viewModel.filterShowErrorsOnly)
                        .tint(DesignSystem.Colors.danger)
                        .accessibilityHint("Filter to show only error responses")

                    Toggle("Duplicates Only", isOn: $viewModel.filterShowDuplicatesOnly)
                        .tint(DesignSystem.Colors.warning)
                        .accessibilityHint("Filter to show only duplicate requests")
                } header: {
                    Text("Quick Filters")
                }

                // Domain Filtering Section
                Section {
                    ForEach(viewModel.filterDomains, id: \.self) { domain in
                        HStack {
                            Image(systemName: "globe")
                                .foregroundStyle(DesignSystem.Colors.accent)
                            Text(domain)
                            Spacer()
                            Button(action: {
                                viewModel.removeDomainFilter(domain)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button(action: {
                        showingAddDomain = true
                    }) {
                        Label("Add Domain Filter", systemImage: "plus.circle.fill")
                    }
                    .accessibilityHint("Double tap to add a new domain filter")
                } header: {
                    Text("Domain Filters")
                } footer: {
                    Text("Filter requests by domain. Use wildcards like *.example.com")
                }

                // HTTP Method Filter
                Section {
                    Picker("Method", selection: $viewModel.filterMethod) {
                        Text("All Methods").tag(nil as HTTPMethod?)
                        Divider()
                        ForEach(HTTPMethod.allCases, id: \.self) { method in
                            HStack {
                                Text(method.rawValue)
                                Spacer()
                                Circle()
                                    .fill(methodColor(for: method))
                                    .frame(width: 8, height: 8)
                            }
                            .tag(method as HTTPMethod?)
                        }
                    }
                    .accessibilityLabel("HTTP Method filter")
                } header: {
                    Text("HTTP Method")
                }

                // Status Code Filter
                Section {
                    Picker("Status Code", selection: $viewModel.filterStatusCode) {
                        Text("All Status Codes").tag(nil as Int?)
                        Divider()

                        Group {
                            Text("2xx - Success").tag(nil as Int?)
                                .font(.headline)
                            Text("200 - OK").tag(200 as Int?)
                            Text("201 - Created").tag(201 as Int?)
                            Text("204 - No Content").tag(204 as Int?)
                        }

                        Divider()

                        Group {
                            Text("3xx - Redirection").tag(nil as Int?)
                                .font(.headline)
                            Text("301 - Moved Permanently").tag(301 as Int?)
                            Text("302 - Found").tag(302 as Int?)
                            Text("304 - Not Modified").tag(304 as Int?)
                        }

                        Divider()

                        Group {
                            Text("4xx - Client Error").tag(nil as Int?)
                                .font(.headline)
                            Text("400 - Bad Request").tag(400 as Int?)
                            Text("401 - Unauthorized").tag(401 as Int?)
                            Text("403 - Forbidden").tag(403 as Int?)
                            Text("404 - Not Found").tag(404 as Int?)
                        }

                        Divider()

                        Group {
                            Text("5xx - Server Error").tag(nil as Int?)
                                .font(.headline)
                            Text("500 - Internal Server Error").tag(500 as Int?)
                            Text("502 - Bad Gateway").tag(502 as Int?)
                            Text("503 - Service Unavailable").tag(503 as Int?)
                        }
                    }
                    .accessibilityLabel("Status Code filter")
                } header: {
                    Text("Status Code")
                }

                // Content Type Filter
                Section {
                    ForEach(ContentTypeFilter.allCases, id: \.self) { type in
                        Toggle(type.rawValue, isOn: Binding(
                            get: { viewModel.filterContentTypes.contains(type) },
                            set: { isSelected in
                                if isSelected {
                                    viewModel.filterContentTypes.insert(type)
                                } else {
                                    viewModel.filterContentTypes.remove(type)
                                }
                            }
                        ))
                    }
                } header: {
                    Text("Content Type")
                } footer: {
                    Text("Filter by response content type")
                }

                // Network Type Filter
                Section {
                    ForEach(NetworkEventType.allCases) { type in
                        Toggle(isOn: Binding(
                            get: { viewModel.filterNetworkEventTypes.contains(type) },
                            set: { isSelected in
                                if isSelected {
                                    viewModel.filterNetworkEventTypes.insert(type)
                                } else {
                                    viewModel.filterNetworkEventTypes.remove(type)
                                }
                            }
                        )) {
                            HStack {
                                Image(systemName: type.icon)
                                    .foregroundStyle(DesignSystem.Colors.eventTypeColor(for: type))
                                    .frame(width: 24)
                                Text(type.displayName)
                            }
                        }
                    }
                } header: {
                    Text("Network Event Type")
                } footer: {
                    Text("Filter by network event type. TCP and UDP are hidden by default to keep Requests focused; enable them for packet-level debugging.")
                }

                // Response Time Filter
                Section {
                    HStack {
                        Text("Min (ms)")
                        Spacer()
                        TextField("0", value: $viewModel.minResponseTime, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 100)
                    }

                    HStack {
                        Text("Max (ms)")
                        Spacer()
                        TextField("∞", value: $viewModel.maxResponseTime, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 100)
                    }
                } header: {
                    Text("Response Time")
                } footer: {
                    Text("Filter by response time in milliseconds")
                }

                // Response Size Filter
                Section {
                    HStack {
                        Text("Min (KB)")
                        Spacer()
                        TextField("0", value: $viewModel.minResponseSize, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 100)
                    }

                    HStack {
                        Text("Max (KB)")
                        Spacer()
                        TextField("∞", value: $viewModel.maxResponseSize, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 100)
                    }
                } header: {
                    Text("Response Size")
                } footer: {
                    Text("Filter by response size in kilobytes")
                }

                // Duration Filter
                Section {
                    HStack {
                        Text("Min (s)")
                        Spacer()
                        TextField("0", value: $viewModel.minDuration, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(width: 100)
                    }

                    HStack {
                        Text("Max (s)")
                        Spacer()
                        TextField("∞", value: $viewModel.maxDuration, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(width: 100)
                    }
                } header: {
                    Text("Request Duration")
                } footer: {
                    Text("Filter by total request duration in seconds")
                }

                // Regex Filter
                Section {
                    TextField("Enter regex pattern", text: $viewModel.regexFilter)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    if !viewModel.regexFilter.isEmpty {
                        Button(role: .destructive) {
                            viewModel.regexFilter = ""
                        } label: {
                            Label("Clear Regex", systemImage: "xmark.circle")
                        }
                    }
                } header: {
                    Text("Advanced Regex Filter")
                } footer: {
                    Text("Filter URLs matching the regex pattern (e.g., api/v[0-9]+/users)")
                }

                // Filter Summary
                Section {
                    HStack {
                        Text("Active Filters")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(viewModel.activeFilterCount)")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(DesignSystem.Colors.accent.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    HStack {
                        Text("Matching Requests")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(viewModel.filteredRequests.count)")
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.hasActiveFilters {
                        Button(role: .destructive) {
                            viewModel.clearFilters()
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                Text("Clear All Filters")
                            }
                        }
                        .accessibilityLabel("Clear all filters")
                        .accessibilityHint("Double tap to remove all active filters")
                    }
                } header: {
                    Text("Summary")
                }
            }
            .dismissKeyboardOnTapAndScroll()
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                if viewModel.hasActiveFilters {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear All") {
                            viewModel.clearFilters()
                        }
                        .foregroundStyle(DesignSystem.Colors.danger)
                    }
                }
            }
            .sheet(isPresented: $showingAddDomain) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("example.com", text: $newDomain)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        } header: {
                            Text("Domain")
                        } footer: {
                            Text("Enter a domain to filter (e.g., api.example.com or *.example.com)")
                        }
                    }
                    .dismissKeyboardOnTapAndScroll()
                    .navigationTitle("Add Domain Filter")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                newDomain = ""
                                showingAddDomain = false
                            }
                        }

                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                if !newDomain.isEmpty {
                                    viewModel.addDomainFilter(newDomain)
                                    newDomain = ""
                                }
                                showingAddDomain = false
                            }
                            .disabled(newDomain.isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func methodColor(for method: HTTPMethod) -> Color {
        DesignSystem.Colors.methodColor(for: method)
    }
}

#Preview {
    FiltersView(viewModel: CaptureViewModel())
}
