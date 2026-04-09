//
//  RewriteAdvancedViews.swift
//  Trace
//
//  Created by Justin on 2026/01/21.
//

import SwiftUI

struct RuleWizardView: View {
    var body: some View {
        Form {
            Section("Step 1") {
                Text("Choose use case")
            }
            Section("Step 2") {
                Text("Define matching criteria")
            }
            Section("Step 3") {
                Text("Configure actions")
            }
            Section("Step 4") {
                Text("Preview and save")
            }
        }
        .navigationTitle("Rule Wizard")
    }
}

struct VisualRuleEditorView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Visual Rule Editor")
                .font(.headline)
            Text("Drag actions and preview diffs.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Visual Editor")
    }
}

struct RequestComposerView: View {
    var body: some View {
        Form {
            Section("Request") {
                Text("Compose a custom request")
            }
            Section("Send") {
                Text("Send and view response")
            }
        }
        .navigationTitle("Request Composer")
    }
}

struct RuleTestingView: View {
    var body: some View {
        Form {
            Section("Rule") {
                Text("Select rule")
            }
            Section("Request") {
                Text("Select captured request")
            }
            Section("Preview") {
                Text("Preview changes")
            }
        }
        .navigationTitle("Rule Testing")
    }
}

struct ImportProxymanView: View {
    var body: some View {
        Text("Import Proxyman Rules")
            .navigationTitle("Import Proxyman")
            .padding()
    }
}

struct ImportCharlesView: View {
    var body: some View {
        Text("Import Charles Rules")
            .navigationTitle("Import Charles")
            .padding()
    }
}

struct ImportFiddlerView: View {
    var body: some View {
        Text("Import Fiddler Rules")
            .navigationTitle("Import Fiddler")
            .padding()
    }
}

struct ImportHARView: View {
    var body: some View {
        Text("Import HAR as Rules")
            .navigationTitle("Import HAR")
            .padding()
    }
}

#Preview("RuleWizardView") {
    NavigationStack { RuleWizardView() }
}

#Preview("VisualRuleEditorView") {
    NavigationStack { VisualRuleEditorView() }
}

#Preview("RequestComposerView") {
    NavigationStack { RequestComposerView() }
}

#Preview("RuleTestingView") {
    NavigationStack { RuleTestingView() }
}

#Preview("ImportProxymanView") {
    NavigationStack { ImportProxymanView() }
}

#Preview("ImportCharlesView") {
    NavigationStack { ImportCharlesView() }
}

#Preview("ImportFiddlerView") {
    NavigationStack { ImportFiddlerView() }
}

#Preview("ImportHARView") {
    NavigationStack { ImportHARView() }
}
