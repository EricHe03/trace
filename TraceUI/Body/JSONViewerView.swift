//
//  JSONViewerView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/14.
//

import SwiftUI

/// Presents JSON content with syntax highlighting and a tree view.
public struct JSONViewerView: View {
    public let jsonString: String

    public init(jsonString: String) {
        self.jsonString = jsonString
    }

    @State private var viewMode: ViewMode = .formatted
    @State private var parsedJSON: JSONValue?
    @State private var parseError: String?
    @State private var expandedPaths: Set<String> = []
    @State private var expandAll = true

    public enum ViewMode: String, CaseIterable {
        case formatted = "Formatted"
        case tree = "Tree"
        case raw = "Raw"
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View Mode", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Spacer()

                if viewMode == .tree {
                    Button {
                        if expandAll {
                            expandedPaths.removeAll()
                        } else {
                            expandAllNodes()
                        }
                        expandAll.toggle()
                    } label: {
                        Image(systemName: expandAll ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()

            Divider()

            switch viewMode {
            case .formatted:
                ScrollView([.horizontal, .vertical]) {
                    formattedView
                        .padding()
                }
            case .tree:
                ScrollView([.horizontal, .vertical]) {
                    treeView
                        .padding()
                }
            case .raw:
                ScrollView([.horizontal]) {
                    rawView
                        .padding()
                }
            }
        }
        .onAppear {
            parseJSON()
            expandAllNodes()
        }
    }

    // MARK: - Formatted View

    private var formattedView: some View {
        Text(attributedJSONString())
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - Tree View

    private var treeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root = parsedJSON {
                jsonNode(root, key: nil, path: "root", level: 0)
            } else if let error = parseError {
                errorView(error: error)
            } else {
                Text("Parsing...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Rationale: Use `AnyView` to avoid recursive `some View` type inference.
    private func jsonNode(_ value: JSONValue, key: String?, path: String, level: Int) -> AnyView {
        let isExpanded = expandedPaths.contains(path)
        let hasChildren = value.hasChildren

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedPaths.remove(path)
                        } else {
                            expandedPaths.insert(path)
                        }
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        if level > 0 {
                            Color.clear
                                .frame(width: CGFloat(level) * DesignSystem.Spacing.indent)
                        }

                        if hasChildren {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        } else {
                            Color.clear.frame(width: 12)
                        }

                        if let key {
                            Text("\"\(key)\"")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(DesignSystem.Colors.accent)
                            Text(":")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        valuePreview(value, expanded: isExpanded)

                        Spacer()

                        if hasChildren {
                            Text(value.countDescription)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
                .background(isExpanded && hasChildren ? DesignSystem.Colors.surfaceMuted.opacity(0.3) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))

                if isExpanded && hasChildren {
                    childrenView(value, parentPath: path, level: level)
                }
            }
        )
    }

    @ViewBuilder
    private func valuePreview(_ value: JSONValue, expanded: Bool) -> some View {
        switch value {
        case .null:
            Text("null")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.muted)

        case let .bool(b):
            Text(b ? "true" : "false")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.warning)

        case let .number(n):
            Text(formatNumber(n))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.warning)

        case let .string(s):
            if s.count > 50 && !expanded {
                Text("\"\(s.prefix(50))...\"")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.success)
            } else {
                Text("\"\(s)\"")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.success)
                    .textSelection(.enabled)
            }

        case let .array(arr):
            if expanded {
                Text("[")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("[\(arr.count) items]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

        case let .object(obj):
            if expanded {
                Text("{")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("{\(obj.count) keys}")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func childrenView(_ value: JSONValue, parentPath: String, level: Int) -> some View {
        switch value {
        case let .array(arr):
            ForEach(Array(arr.enumerated()), id: \.offset) { index, item in
                jsonNode(item, key: "[\(index)]", path: "\(parentPath).\(index)", level: level + 1)
            }
            closingBracket("]", level: level)

        case let .object(obj):
            let sortedKeys = obj.keys.sorted()
            ForEach(Array(sortedKeys.enumerated()), id: \.offset) { _, key in
                if let val = obj[key] {
                    jsonNode(val, key: key, path: "\(parentPath).\(key)", level: level + 1)
                }
            }
            closingBracket("}", level: level)

        default:
            EmptyView()
        }
    }

    private func closingBracket(_ bracket: String, level: Int) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if level > 0 {
                Color.clear
                    .frame(width: CGFloat(level) * DesignSystem.Spacing.indent)
            }
            Color.clear.frame(width: 12)
            Text(bracket)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Raw View

    private var rawView: some View {
        Text(jsonString)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - Error View

    private func errorView(error: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(DesignSystem.Colors.warning)

            Text("Parse Error")
                .font(.headline)

            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - JSON Parsing

    private func parseJSON() {
        guard let data = jsonString.data(using: .utf8) else {
            parseError = "Invalid UTF-8 string"
            return
        }

        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            parsedJSON = JSONValue.from(jsonObject)
            parseError = nil
        } catch {
            parseError = error.localizedDescription
            parsedJSON = nil
        }
    }

    private func expandAllNodes() {
        guard let root = parsedJSON else { return }
        expandedPaths.insert("root")
        collectPaths(root, path: "root")
    }

    private func collectPaths(_ value: JSONValue, path: String) {
        switch value {
        case let .array(arr):
            expandedPaths.insert(path)
            for (index, item) in arr.enumerated() {
                collectPaths(item, path: "\(path).\(index)")
            }
        case let .object(obj):
            expandedPaths.insert(path)
            for (key, val) in obj {
                collectPaths(val, path: "\(path).\(key)")
            }
        default:
            break
        }
    }

    // MARK: - Syntax Highlighting

    private func attributedJSONString() -> AttributedString {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let formattedString = String(data: formatted, encoding: .utf8)
        else {
            return AttributedString(jsonString)
        }

        var result = AttributedString(formattedString)

        highlightPattern(&result, pattern: "\"[^\"]+\"\\s*:", color: DesignSystem.Colors.accent)

        highlightPattern(&result, pattern: ":\\s*\"[^\"]*\"", color: DesignSystem.Colors.success)

        highlightPattern(&result, pattern: ":\\s*-?\\d+(\\.\\d+)?([eE][+-]?\\d+)?", color: DesignSystem.Colors.warning)

        highlightPattern(&result, pattern: ":\\s*(true|false)", color: DesignSystem.Colors.warning)

        highlightPattern(&result, pattern: ":\\s*null", color: DesignSystem.Colors.muted)

        highlightPattern(&result, pattern: "[\\[\\]{}]", color: .secondary)

        return result
    }

    private func highlightPattern(_ text: inout AttributedString, pattern: String, color: Color) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = regex.matches(in: String(text.characters), options: [], range: nsRange)

        for match in matches {
            if let range = Range(match.range, in: text) {
                text[range].foregroundColor = color
            }
        }
    }

    // MARK: - Helpers

    private func formatNumber(_ n: NSNumber) -> String {
        if n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < Double(Int64.max) {
            return String(format: "%.0f", n.doubleValue)
        }
        return n.stringValue
    }
}

// MARK: - JSON Value Type

enum JSONValue {
    case null
    case bool(Bool)
    case number(NSNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var hasChildren: Bool {
        switch self {
        case let .array(arr): !arr.isEmpty
        case let .object(obj): !obj.isEmpty
        default: false
        }
    }

    var countDescription: String {
        switch self {
        case let .array(arr): "\(arr.count) items"
        case let .object(obj): "\(obj.count) keys"
        default: ""
        }
    }

    static func from(_ any: Any) -> JSONValue {
        if any is NSNull {
            return .null
        }
        if let bool = any as? Bool {
            return .bool(bool)
        }
        if let number = any as? NSNumber {
            return .number(number)
        }
        if let string = any as? String {
            return .string(string)
        }
        if let array = any as? [Any] {
            return .array(array.map { from($0) })
        }
        if let dict = any as? [String: Any] {
            return .object(dict.mapValues { from($0) })
        }
        return .null
    }
}

#Preview {
    JSONViewerView(jsonString: """
    {
        "id": 12345,
        "name": "John Doe",
        "email": "john.doe@example.com",
        "active": true,
        "balance": 1234.56,
        "tags": ["developer", "swift", "ios"],
        "metadata": null,
        "address": {
            "street": "123 Main St",
            "city": "San Francisco",
            "state": "CA",
            "zip": "94102",
            "coordinates": {
                "lat": 37.7749,
                "lng": -122.4194
            }
        },
        "orders": [
            {"id": 1, "product": "Widget", "quantity": 5},
            {"id": 2, "product": "Gadget", "quantity": 3}
        ]
    }
    """)
}
