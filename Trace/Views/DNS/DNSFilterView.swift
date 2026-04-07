//
//  DNSFilterView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore

struct DNSFilterView: View {
    @ObservedObject var viewModel: DNSViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Message Type") {
                    Toggle("Queries Only", isOn: $viewModel.showQueriesOnly)
                    Toggle("Responses Only", isOn: $viewModel.showResponsesOnly)
                    Toggle("Unanswered Only", isOn: $viewModel.showUnansweredOnly)
                    Toggle("Failed Only", isOn: $viewModel.showFailedOnly)
                }

                Section("Record Types") {
                    ForEach(DNSRecordType.common, id: \.self) { type in
                        Toggle(type.displayName, isOn: Binding(
                            get: { viewModel.selectedRecordTypes.contains(type) },
                            set: { _ in viewModel.toggleRecordType(type) }
                        ))
                    }
                }

                Section("Response Codes") {
                    Toggle("Success (NOERROR)", isOn: Binding(
                        get: { viewModel.selectedResponseCodes.contains(.noError) },
                        set: { _ in viewModel.toggleResponseCode(.noError) }
                    ))

                    Toggle("Name Error (NXDOMAIN)", isOn: Binding(
                        get: { viewModel.selectedResponseCodes.contains(.nameError) },
                        set: { _ in viewModel.toggleResponseCode(.nameError) }
                    ))

                    Toggle("Server Failure", isOn: Binding(
                        get: { viewModel.selectedResponseCodes.contains(.serverFailure) },
                        set: { _ in viewModel.toggleResponseCode(.serverFailure) }
                    ))

                    Toggle("Refused", isOn: Binding(
                        get: { viewModel.selectedResponseCodes.contains(.refused) },
                        set: { _ in viewModel.toggleResponseCode(.refused) }
                    ))
                }

                Section("Sort Order") {
                    Picker("Sort By", selection: $viewModel.sortOrder) {
                        ForEach(DNSViewModel.SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("DNS Filters")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear All", role: .destructive) {
                        viewModel.clearFilters()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(maxWidth: 400, maxHeight: 600)
    }
}

#Preview {
    DNSFilterView(viewModel: DNSViewModel())
}
