//
//  HTMLViewerView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/14.
//

import SwiftUI
import WebKit

/// Presents HTML content with syntax highlighting and a web preview.
public struct HTMLViewerView: View {
    public let htmlString: String

    public init(htmlString: String) {
        self.htmlString = htmlString
    }

    @State private var viewMode: ViewMode = .formatted

    public enum ViewMode: String, CaseIterable {
        case formatted = "Formatted"
        case preview = "Preview"
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

            Group {
                switch viewMode {
                case .formatted:
                    ScrollView {
                        formattedView
                            .padding()
                    }
                case .preview:
                    HTMLWebPreview(html: htmlString)
                        .accessibilityLabel("HTML preview")
                        .accessibilityHint("Renders the HTML content for visual inspection.")
                case .raw:
                    ScrollView {
                        rawView
                            .padding()
                    }
                }
            }
        }
    }

    // MARK: - Formatted View with Syntax Highlighting

    private var formattedView: some View {
        Text(attributedHTMLString())
            .font(DesignSystem.Typography.monospacedFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - Raw View

    private var rawView: some View {
        Text(htmlString)
            .font(DesignSystem.Typography.monospacedFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - Syntax Highlighting

    private func attributedHTMLString() -> AttributedString {
        let formatted = formatHTML(htmlString)
        var result = AttributedString(formatted)

        highlightPattern(&result, pattern: "<!DOCTYPE[^>]*>", color: DesignSystem.Colors.muted, italic: true)

        highlightPattern(&result, pattern: "<!--[\\s\\S]*?-->", color: DesignSystem.Colors.muted, italic: true)

        highlightPattern(&result, pattern: "</?([a-zA-Z][a-zA-Z0-9]*)", color: DesignSystem.Colors.accent, bold: true)

        highlightPattern(&result, pattern: "\\s([a-zA-Z][a-zA-Z0-9-]*)(?==)", color: DesignSystem.Colors.warning)

        highlightPattern(&result, pattern: "\"[^\"]*\"", color: DesignSystem.Colors.success)
        highlightPattern(&result, pattern: "'[^']*'", color: DesignSystem.Colors.success)

        highlightPattern(&result, pattern: "/>", color: DesignSystem.Colors.accent)

        highlightPattern(&result, pattern: ">", color: DesignSystem.Colors.accent)

        return result
    }

    private func highlightPattern(
        _ text: inout AttributedString,
        pattern: String,
        color: Color,
        bold: Bool = false,
        italic: Bool = false
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = regex.matches(in: String(text.characters), options: [], range: nsRange)

        for match in matches {
            if let range = Range(match.range, in: text) {
                text[range].foregroundColor = color
                if bold {
                    text[range].font = .system(.callout, design: .monospaced).weight(.bold)
                }
                if italic {
                    text[range].font = .system(.callout, design: .monospaced).italic()
                }
            }
        }
    }

    // MARK: - HTML Formatting

    private func formatHTML(_ html: String) -> String {
        var formatted = ""
        var indent = 0
        var inTag = false
        var inScript = false
        var inStyle = false
        var tagContent = ""
        var textContent = ""

        let selfClosingTags = Set([
            "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr"
        ])

        for char in html {
            if char == "<" {
                let trimmed = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    formatted += String(repeating: "  ", count: indent)
                    formatted += trimmed + "\n"
                }
                textContent = ""
                inTag = true
                tagContent = "<"
            } else if char == ">" && inTag {
                tagContent += ">"
                inTag = false

                let isClosing = tagContent.hasPrefix("</")
                let isSelfClosing = tagContent.hasSuffix("/>")
                let isComment = tagContent.hasPrefix("<!--")
                let isDoctype = tagContent.uppercased().hasPrefix("<!DOCTYPE")

                var tagName = ""
                if let match = tagContent.range(of: "</?([a-zA-Z][a-zA-Z0-9]*)", options: .regularExpression) {
                    tagName = String(tagContent[match]).replacingOccurrences(of: "<", with: "").replacingOccurrences(of: "/", with: "").lowercased()
                }

                let isSelfClosingTag = selfClosingTags.contains(tagName)

                if tagName == "script" && !isClosing {
                    inScript = true
                } else if tagName == "script" && isClosing {
                    inScript = false
                } else if tagName == "style" && !isClosing {
                    inStyle = true
                } else if tagName == "style" && isClosing {
                    inStyle = false
                }

                if isClosing {
                    indent = max(0, indent - 1)
                }

                formatted += String(repeating: "  ", count: indent)
                formatted += tagContent + "\n"

                if !isClosing && !isSelfClosing && !isSelfClosingTag && !isComment && !isDoctype {
                    indent += 1
                }

                tagContent = ""
            } else if inTag {
                tagContent += String(char)
            } else if !inScript && !inStyle {
                textContent += String(char)
            } else {
                // Rule: Preserve script and style content without formatting.
                textContent += String(char)
            }
        }

        let trimmed = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            formatted += String(repeating: "  ", count: indent)
            formatted += trimmed + "\n"
        }

        return formatted
    }
}

// MARK: - HTML Web Preview

struct HTMLWebPreview: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.bounces = true
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Rule: Wrap fragments in a minimal document for consistent preview styling.
        let wrappedHTML: String = if html.lowercased().contains("<html") {
            html
        } else {
            """
            <!DOCTYPE html>
            <html>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        padding: 16px;
                        margin: 0;
                        color: \(UITraitCollection.current.userInterfaceStyle == .dark ? "#fff" : "#000");
                        background: \(UITraitCollection.current.userInterfaceStyle == .dark ? "#1c1c1e" : "#fff");
                    }
                    img { max-width: 100%; height: auto; }
                    pre, code { overflow-x: auto; }
                </style>
            </head>
            <body>
                \(html)
            </body>
            </html>
            """
        }
        uiView.loadHTMLString(wrappedHTML, baseURL: nil)
    }
}

#Preview {
    HTMLViewerView(htmlString: """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Sample Page</title>
        <link rel="stylesheet" href="styles.css">
    </head>
    <body>
        <header>
            <h1>Welcome to My Website</h1>
            <nav>
                <ul>
                    <li><a href="#home">Home</a></li>
                    <li><a href="#about">About</a></li>
                </ul>
            </nav>
        </header>
        <main>
            <section id="content">
                <p>This is a paragraph with <strong>bold</strong> and <em>italic</em> text.</p>
                <img src="image.jpg" alt="Sample Image" />
            </section>
        </main>
        <!-- This is a comment -->
        <footer>
            <p>&copy; 2024 My Website</p>
        </footer>
    </body>
    </html>
    """)
}
