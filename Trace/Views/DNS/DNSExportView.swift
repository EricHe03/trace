//
//  DNSExportView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import os
import SwiftUI
import TraceCore
import UniformTypeIdentifiers

struct DNSExportView: View {
    let viewModel: DNSViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportFormat: ExportFormat = .csv
    @State private var showingExporter = false
    @State private var exportData: Data?

    enum ExportFormat: String, CaseIterable {
        case csv = "CSV"
        case json = "JSON"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.accentColor)

                Text("Export DNS Data")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Export \(viewModel.messages.count) DNS messages")
                    .foregroundStyle(.secondary)

                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Export") {
                        performExport()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top)
            }
            .padding(40)
            .navigationTitle("Export DNS Data")
        }
        .frame(maxWidth: 400, maxHeight: 300)
        .fileExporter(
            isPresented: $showingExporter,
            document: ExportDocument(data: exportData ?? Data(), format: exportFormat),
            contentType: exportFormat == .csv ? .commaSeparatedText : .json,
            defaultFilename: "dns-export-\(Date().timeIntervalSince1970).\(exportFormat == .csv ? "csv" : "json")"
        ) { result in
            switch result {
            case .success:
                dismiss()
            case let .failure(error):
                CoreLog.storage.error(
                    "event=storage.dns_export outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func performExport() {
        switch exportFormat {
        case .csv:
            let csv = viewModel.exportToCSV()
            exportData = csv.data(using: .utf8)
        case .json:
            exportData = viewModel.exportToJSON()
        }

        showingExporter = true
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .json] }

    let data: Data
    let format: DNSExportView.ExportFormat

    init(data: Data, format: DNSExportView.ExportFormat) {
        self.data = data
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        format = .csv
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    DNSExportView(viewModel: DNSViewModel())
}
