//
//  SVGPreviewView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import WebKit

/// Renders SVG data in a web view for display in SwiftUI.
public struct SVGPreviewView: UIViewRepresentable {
    public let svgData: Data
    public var isScrollable: Bool = false

    public init(svgData: Data, isScrollable: Bool = false) {
        self.svgData = svgData
        self.isScrollable = isScrollable
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = isScrollable
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.scrollView.isScrollEnabled = isScrollable
        let svgString = String(data: svgData, encoding: .utf8) ?? ""
        guard svgString != context.coordinator.lastLoaded else { return }
        context.coordinator.lastLoaded = svgString

        // Sanitize SVG to prevent XSS attacks
        let sanitizedSVG = SVGPreviewHelper.sanitize(svg: svgString)

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;">
            <style>
              html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: transparent; overflow: hidden; }
              svg { width: 100%; height: 100%; max-width: 100%; max-height: 100%; display: block; }
            </style>
          </head>
          <body>
            \(sanitizedSVG)
          </body>
        </html>
        """

        uiView.loadHTMLString(html, baseURL: nil)
    }

    public class Coordinator {
        var lastLoaded: String?
    }
}

/// Provides SVG detection and decoding helpers for preview rendering.
public enum SVGPreviewHelper {
    public static func isSVG(data: Data, contentType: String? = nil, filename: String? = nil) -> Bool {
        if let contentType, contentType.lowercased().contains("image/svg+xml") {
            return true
        }

        if let filename, filename.lowercased().hasSuffix(".svg") {
            return true
        }

        return dataHasSVGTag(data)
    }

    public static func svgData(from content: String, contentType: String? = nil) -> Data? {
        if let decoded = Data(base64Encoded: content), isSVG(data: decoded, contentType: contentType) {
            return decoded
        }

        guard let data = content.data(using: .utf8) else { return nil }
        return isSVG(data: data, contentType: contentType) ? data : nil
    }

    /// Sanitizes SVG content to prevent XSS attacks by removing dangerous elements and attributes.
    /// - Parameter svg: The raw SVG string to sanitize.
    /// - Returns: A sanitized SVG string safe for rendering.
    public static func sanitize(svg: String) -> String {
        var sanitized = svg

        // Remove script tags and their contents (case-insensitive)
        sanitized = sanitized.replacingOccurrences(
            of: "<script[^>]*>.*?</script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove standalone script tags
        sanitized = sanitized.replacingOccurrences(
            of: "<script[^>]*/>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove on* event handlers (onclick, onload, onerror, etc.)
        sanitized = sanitized.replacingOccurrences(
            of: "\\s+on\\w+\\s*=\\s*['\"][^'\"]*['\"]",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove javascript: URLs
        sanitized = sanitized.replacingOccurrences(
            of: "javascript:",
            with: "blocked:",
            options: [.caseInsensitive]
        )

        // Remove data: URLs that could contain scripts (except for images)
        sanitized = sanitized.replacingOccurrences(
            of: "data:text/html",
            with: "blocked:text/html",
            options: [.caseInsensitive]
        )

        // Remove foreignObject elements (can embed HTML/scripts)
        sanitized = sanitized.replacingOccurrences(
            of: "<foreignObject[^>]*>.*?</foreignObject>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove use elements with external references (potential security risk)
        sanitized = sanitized.replacingOccurrences(
            of: "xlink:href\\s*=\\s*['\"](?!#|data:image/)[^'\"]*['\"]",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove set and animate elements that could trigger scripts
        sanitized = sanitized.replacingOccurrences(
            of: "<set[^>]*onbegin[^>]*>",
            with: "<set>",
            options: [.regularExpression, .caseInsensitive]
        )
        sanitized = sanitized.replacingOccurrences(
            of: "<animate[^>]*onbegin[^>]*>",
            with: "<animate>",
            options: [.regularExpression, .caseInsensitive]
        )

        return sanitized
    }

    private static func dataHasSVGTag(_ data: Data) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return false }
        return string.range(of: "<svg", options: [.caseInsensitive]) != nil
    }
}
