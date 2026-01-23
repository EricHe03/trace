//
//  XMLViewerView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI

/// Presents XML content with formatting, syntax highlighting, and a tree view.
public struct XMLViewerView: View {
    public let xmlString: String

    public init(xmlString: String) {
        self.xmlString = xmlString
    }

    @State private var viewMode: ViewMode = .formatted
    @State private var parsedXML: XMLNode?
    @State private var parseError: String?
    @State private var expandedNodes: Set<String> = []

    enum ViewMode: String, CaseIterable {
        case formatted = "Formatted"
        case tree = "Tree"
        case raw = "Raw"
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("View Mode", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            ScrollView {
                Group {
                    switch viewMode {
                    case .formatted:
                        formattedView
                    case .tree:
                        treeView
                    case .raw:
                        rawView
                    }
                }
                .padding()
            }
        }
        .onAppear {
            parseXML()
        }
    }

    // MARK: - Formatted View

    private var formattedView: some View {
        Text(attributedXMLString())
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - Tree View

    private var treeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root = parsedXML {
                treeNode(root, level: 0)
            } else if let error = parseError {
                errorView(error: error)
            } else {
                Text("Parsing...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func treeNode(_ node: XMLNode, level: Int) -> AnyView {
        let nodeId = "\(node.name)_\(level)_\(node.children.count)_\(node.attributes.count)"
        let isExpanded = expandedNodes.contains(nodeId)

        return AnyView(
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Button {
                    withAnimation {
                        if isExpanded {
                            expandedNodes.remove(nodeId)
                        } else {
                            expandedNodes.insert(nodeId)
                        }
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.smPlus) {
                        Color.clear
                            .frame(width: CGFloat(level) * DesignSystem.Spacing.indent)

                        if !node.children.isEmpty || node.text != nil {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: DesignSystem.Spacing.md)
                        } else {
                            Color.clear
                                .frame(width: DesignSystem.Spacing.md)
                        }

                        Image(systemName: "tag")
                            .font(.caption)
                            .foregroundStyle(DesignSystem.Colors.accent)

                        Text(node.name)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)

                        if !node.attributes.isEmpty {
                            Text(attributesString(node.attributes))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(DesignSystem.Colors.warning)
                        }

                        Spacer()

                        if let text = node.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(isExpanded ? DesignSystem.Colors.surfaceMuted.opacity(0.3) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))

                if isExpanded {
                    if let text = node.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: DesignSystem.Spacing.smPlus) {
                            Color.clear
                                .frame(width: CGFloat(level + 1) * DesignSystem.Spacing.indent + (DesignSystem.Spacing.indent - DesignSystem.Spacing.xxs))

                            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            Spacer()
                        }
                        .padding(.vertical, DesignSystem.Spacing.xs)
                    }

                    ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                        treeNode(child, level: level + 1)
                    }
                }
            }
        )
    }

    // MARK: - Raw View

    private var rawView: some View {
        Text(xmlString)
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

    // MARK: - XML Parsing

    private func parseXML() {
        let parser = XMLParserHelper(xmlString: xmlString)
        do {
            parsedXML = try parser.parse()
            parseError = nil

            // Rationale: Expand the root node so the tree view is immediately visible.
            if let root = parsedXML {
                expandedNodes.insert("\(root.name)_0_\(root.children.count)_\(root.attributes.count)")
            }
        } catch {
            parseError = error.localizedDescription
            parsedXML = nil
        }
    }

    // MARK: - Syntax Highlighting

    private func attributedXMLString() -> AttributedString {
        var result = AttributedString(formatXML(xmlString))

        if let regex = try? NSRegularExpression(pattern: "</?([\\w:]+)", options: []) {
            let nsRange = NSRange(result.startIndex ..< result.endIndex, in: result)
            let matches = regex.matches(in: String(result.characters), options: [], range: nsRange)

            for match in matches {
                if let range = Range(match.range, in: result) {
                    result[range].foregroundColor = DesignSystem.Colors.accent
                    result[range].font = .system(.caption, design: .monospaced).weight(.bold)
                }
            }
        }

        if let regex = try? NSRegularExpression(pattern: "(\\w+)=\"([^\"]+)\"", options: []) {
            let nsRange = NSRange(result.startIndex ..< result.endIndex, in: result)
            let matches = regex.matches(in: String(result.characters), options: [], range: nsRange)

            for match in matches {
                if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: result) {
                    result[range].foregroundColor = DesignSystem.Colors.warning
                }
                if match.numberOfRanges > 2, let range = Range(match.range(at: 2), in: result) {
                    result[range].foregroundColor = DesignSystem.Colors.success
                }
            }
        }

        if let regex = try? NSRegularExpression(pattern: "<!--[\\s\\S]*?-->", options: []) {
            let nsRange = NSRange(result.startIndex ..< result.endIndex, in: result)
            let matches = regex.matches(in: String(result.characters), options: [], range: nsRange)

            for match in matches {
                if let range = Range(match.range, in: result) {
                    result[range].foregroundColor = DesignSystem.Colors.muted
                    result[range].font = .system(.caption, design: .monospaced).italic()
                }
            }
        }

        return result
    }

    // MARK: - XML Formatting

    private func formatXML(_ xml: String) -> String {
        var formatted = ""
        var indent = 0
        var inTag = false
        var tagContent = ""

        for char in xml {
            if char == "<" {
                if !tagContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    formatted += tagContent
                }
                tagContent = ""
                inTag = true
                formatted += String(repeating: "  ", count: indent)
            }

            if inTag {
                tagContent += String(char)
            }

            if char == ">" {
                inTag = false

                if tagContent.hasPrefix("</") {
                    indent = max(0, indent - 1)
                    formatted = formatted.trimmingCharacters(in: .whitespaces)
                }

                formatted += tagContent + "\n"

                if !tagContent.hasPrefix("</") && !tagContent.hasSuffix("/>") && !tagContent.hasPrefix("<?") && !tagContent.hasPrefix("<!") {
                    indent += 1
                }

                tagContent = ""
            } else if !inTag && char != "\n" && char != "\r" {
                tagContent += String(char)
            }
        }

        return formatted
    }

    private func attributesString(_ attributes: [String: String]) -> String {
        attributes.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ")
    }
}

// MARK: - XML Data Structures

/// Represents a parsed XML element with attributes, text, and children.
public struct XMLNode {
    public let name: String
    public var attributes: [String: String]
    public var text: String?
    public var children: [XMLNode]

    public init(name: String, attributes: [String: String] = [:], text: String? = nil, children: [XMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }
}

// MARK: - XML Parser

/// Parses XML strings into an `XMLNode` tree.
public class XMLParserHelper: NSObject, XMLParserDelegate {
    private let xmlString: String
    private var root: XMLNode?
    private var stack: [XMLNode] = []
    private var currentText = ""
    private var parseError: Error?

    public init(xmlString: String) {
        self.xmlString = xmlString
        super.init()
    }

    public func parse() throws -> XMLNode? {
        guard let data = xmlString.data(using: .utf8) else {
            throw NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 string"])
        }

        let parser = XMLParser(data: data)
        parser.delegate = self

        if parser.parse() {
            return root
        } else if let error = parseError {
            throw error
        } else {
            throw NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown parsing error"])
        }
    }

    // MARK: - XMLParserDelegate

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        stack.append(node)
        currentText = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard var node = stack.popLast() else { return }

        // Rule: Ignore whitespace-only text nodes.
        let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            node.text = trimmedText
        }
        currentText = ""

        // Rule: When the stack is empty, the node becomes the root.
        if !stack.isEmpty {
            stack[stack.count - 1].children.append(node)
        } else {
            root = node
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

#Preview {
    XMLViewerView(xmlString: """
    <?xml version="1.0" encoding="UTF-8"?>
    <root>
        <person id="1">
            <name>John Doe</name>
            <age>30</age>
            <address>
                <street>123 Main St</street>
                <city>Springfield</city>
            </address>
        </person>
        <person id="2">
            <name>Jane Smith</name>
            <age>25</age>
        </person>
    </root>
    """)
}
