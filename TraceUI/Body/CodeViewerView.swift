//
//  CodeViewerView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/14.
//

import SwiftUI

/// Defines supported code languages for syntax highlighting.
public enum CodeLanguage: String, CaseIterable {
    case javascript = "JavaScript"
    case css = "CSS"
    case plainText = "Plain Text"

    var fileExtension: String {
        switch self {
        case .javascript: "js"
        case .css: "css"
        case .plainText: "txt"
        }
    }
}

/// Presents a code viewer with syntax highlighting for supported languages.
public struct CodeViewerView: View {
    public let code: String
    public let language: CodeLanguage

    public init(code: String, language: CodeLanguage) {
        self.code = code
        self.language = language
    }

    @State private var showLineNumbers = true
    @State private var viewMode: ViewMode = .formatted
    private let maxHighlightedLines = 2_000

    public enum ViewMode: String, CaseIterable {
        case formatted = "Formatted"
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

                Toggle(isOn: $showLineNumbers) {
                    Image(systemName: "number")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Divider()

            if estimatedLineCount > 1_000 {
                Label("Large content detected. Rendering may be slower.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, DesignSystem.Spacing.xs)
            }

            ScrollView([.horizontal, .vertical]) {
                Group {
                    switch viewMode {
                    case .formatted:
                        formattedView
                    case .raw:
                        rawView
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Formatted View

    private var formattedView: some View {
        let lines = code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let lineNumberWidth = "\(lines.count)".count

        return Group {
            if lines.count > maxHighlightedLines {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Too many lines to syntax highlight. Showing raw text.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    rawLinesView(lines: lines, lineNumberWidth: lineNumberWidth)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                            if showLineNumbers {
                                Text("\(index + 1)")
                                    .font(DesignSystem.Typography.monospacedCaption2Font)
                                    .foregroundStyle(.secondary)
                                    .frame(width: CGFloat(lineNumberWidth) * 8 + 8, alignment: .trailing)
                                    .accessibilityHidden(true)
                            }

                            Text(highlightLine(line))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Raw View

    private var rawView: some View {
        let lines = code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let lineNumberWidth = "\(lines.count)".count

        return rawLinesView(lines: lines, lineNumberWidth: lineNumberWidth)
    }

    // MARK: - Syntax Highlighting

    private func highlightLine(_ line: String) -> AttributedString {
        var result = AttributedString(line)

        switch language {
        case .javascript:
            highlightJavaScript(&result)
        case .css:
            highlightCSS(&result)
        case .plainText:
            break
        }

        return result
    }

    // MARK: - JavaScript Highlighting

    private func highlightJavaScript(_ text: inout AttributedString) {
        highlightPattern(&text, pattern: "//.*$", color: DesignSystem.Colors.muted, italic: true)

        // Edge case: Multi-line comments are matched only within a single line.
        highlightPattern(&text, pattern: "/\\*.*?\\*/", color: DesignSystem.Colors.muted, italic: true)

        highlightPattern(&text, pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", color: DesignSystem.Colors.success)

        highlightPattern(&text, pattern: "'(?:[^'\\\\]|\\\\.)*'", color: DesignSystem.Colors.success)

        highlightPattern(&text, pattern: "`(?:[^`\\\\]|\\\\.)*`", color: DesignSystem.Colors.success)

        let keywords = [
            "async", "await", "break", "case", "catch", "class", "const",
            "continue", "debugger", "default", "delete", "do", "else",
            "export", "extends", "finally", "for", "function", "if",
            "import", "in", "instanceof", "let", "new", "return", "static",
            "super", "switch", "this", "throw", "try", "typeof", "var",
            "void", "while", "with", "yield", "from", "of"
        ]
        for keyword in keywords {
            highlightPattern(&text, pattern: "\\b\(keyword)\\b", color: DesignSystem.Colors.accentAlt, bold: true)
        }

        let builtins = ["true", "false", "null", "undefined", "NaN", "Infinity", "console", "window", "document", "Array", "Object", "String", "Number", "Boolean", "Promise", "Math", "Date", "JSON", "Error"]
        for builtin in builtins {
            highlightPattern(&text, pattern: "\\b\(builtin)\\b", color: DesignSystem.Colors.info)
        }

        highlightPattern(&text, pattern: "\\b\\d+(\\.\\d+)?\\b", color: DesignSystem.Colors.warning)

        highlightPattern(&text, pattern: "\\b([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*\\(", color: DesignSystem.Colors.accent)

        highlightPattern(&text, pattern: "=>", color: DesignSystem.Colors.accentAlt, bold: true)

        highlightPattern(&text, pattern: "[+\\-*/%=<>!&|^~?:]+", color: DesignSystem.Colors.muted)
    }

    // MARK: - CSS Highlighting

    private func highlightCSS(_ text: inout AttributedString) {
        highlightPattern(&text, pattern: "/\\*.*?\\*/", color: DesignSystem.Colors.muted, italic: true)

        highlightPattern(&text, pattern: "^\\s*[.#]?[a-zA-Z][a-zA-Z0-9_-]*(?=[\\s,{:])", color: DesignSystem.Colors.accent, bold: true)

        highlightPattern(&text, pattern: ":[a-zA-Z-]+", color: DesignSystem.Colors.accentAlt)

        highlightPattern(&text, pattern: "\\b([a-z-]+)\\s*:", color: DesignSystem.Colors.info)

        highlightPattern(&text, pattern: "\"[^\"]*\"", color: DesignSystem.Colors.success)
        highlightPattern(&text, pattern: "'[^']*'", color: DesignSystem.Colors.success)

        highlightPattern(&text, pattern: "\\b\\d+(\\.\\d+)?(px|em|rem|%|vh|vw|deg|s|ms)?\\b", color: DesignSystem.Colors.warning)

        highlightPattern(&text, pattern: "#[0-9a-fA-F]{3,8}\\b", color: DesignSystem.Colors.warning)

        highlightPattern(&text, pattern: "\\b(url|rgb|rgba|hsl|hsla|calc|var|linear-gradient|radial-gradient|rotate|scale|translate|translateX|translateY|translateZ)\\s*\\(", color: DesignSystem.Colors.accent)

        highlightPattern(&text, pattern: "!important", color: DesignSystem.Colors.danger, bold: true)

        highlightPattern(&text, pattern: "@[a-zA-Z-]+", color: DesignSystem.Colors.accentAlt, bold: true)

        highlightPattern(&text, pattern: "[{}]", color: DesignSystem.Colors.muted)
    }

    // MARK: - Helper

    private func highlightPattern(
        _ text: inout AttributedString,
        pattern: String,
        color: Color,
        bold: Bool = false,
        italic: Bool = false
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = regex.matches(in: String(text.characters), options: [], range: nsRange)

        for match in matches {
            if let range = Range(match.range, in: text) {
                text[range].foregroundColor = color
                if bold || italic {
                    var font: Font = .system(.callout, design: .monospaced)
                    if bold {
                        font = font.weight(.bold)
                    }
                    if italic {
                        font = font.italic()
                    }
                    text[range].font = font
                }
            }
        }
    }

    private func rawLinesView(lines: [String], lineNumberWidth: Int) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    if showLineNumbers {
                        Text("\(index + 1)")
                            .font(DesignSystem.Typography.monospacedCaption2Font)
                            .foregroundStyle(.secondary)
                            .frame(width: CGFloat(lineNumberWidth) * 8 + 8, alignment: .trailing)
                            .accessibilityHidden(true)
                    }

                    Text(line)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var estimatedLineCount: Int {
        code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }
}

// MARK: - Convenience Views

/// Presents a JavaScript-specific code viewer.
public struct JavaScriptViewerView: View {
    public let code: String

    public init(code: String) {
        self.code = code
    }

    public var body: some View {
        CodeViewerView(code: code, language: .javascript)
    }
}

/// Presents a CSS-specific code viewer.
public struct CSSViewerView: View {
    public let code: String

    public init(code: String) {
        self.code = code
    }

    public var body: some View {
        CodeViewerView(code: code, language: .css)
    }
}

#Preview("JavaScript") {
    JavaScriptViewerView(code: """
    // Sample JavaScript code
    const greeting = "Hello, World!";
    let count = 42;

    async function fetchData(url) {
        try {
            const response = await fetch(url);
            const data = await response.json();
            return data;
        } catch (error) {
            console.error('Error:', error);
            throw error;
        }
    }

    class User {
        constructor(name, age) {
            this.name = name;
            this.age = age;
        }

        greet() {
            return `Hello, I'm ${this.name}`;
        }
    }

    const users = [1, 2, 3].map(id => new User(`User ${id}`, id * 10));
    console.log(users);
    """)
}

#Preview("CSS") {
    CSSViewerView(code: """
    /* Main styles */
    :root {
        --primary-color: #007bff;
        --font-size: 16px;
    }

    body {
        font-family: -apple-system, sans-serif;
        font-size: var(--font-size);
        margin: 0;
        padding: 20px;
    }

    .container {
        max-width: 1200px;
        margin: 0 auto;
    }

    #header {
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        padding: 2rem;
        border-radius: 8px;
    }

    .button:hover {
        transform: scale(1.05);
        transition: transform 0.3s ease;
    }

    @media (max-width: 768px) {
        .container {
            padding: 10px !important;
        }
    }
    """)
}
