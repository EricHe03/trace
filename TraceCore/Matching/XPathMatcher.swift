//
//  XPathMatcher.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

#if canImport(FoundationXML) && !os(iOS) && !os(tvOS) && !os(watchOS)
import FoundationXML
#endif

public enum XPathMatcher {
    public static func matches(xpath: String, in xml: String) -> Bool {
        #if canImport(FoundationXML) && !os(iOS) && !os(tvOS) && !os(watchOS)
        if let data = xml.data(using: .utf8),
           let document = try? XMLDocument(data: data, options: .documentTidyXML),
           let nodes = try? document.nodes(forXPath: xpath) {
            return !nodes.isEmpty
        }
        #endif

        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Fallback matcher for platforms without FoundationXML.
        // We support simple XPath shapes used in tests:
        // - "//tag"
        // - "/a/b" (match leaf tag)
        // - "tag"
        let leaf = trimmed
            .split(separator: "/")
            .last(where: { !$0.isEmpty })
            .map(String.init) ?? ""

        let tag = leaf.split(separator: "[", maxSplits: 1).first.map(String.init) ?? ""
        guard !tag.isEmpty else { return false }

        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\\/?\(escapedTag)(\\s|>|/)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(xml.startIndex..., in: xml)
        return regex.firstMatch(in: xml, options: [], range: range) != nil
    }
}
