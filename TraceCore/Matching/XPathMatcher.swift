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

        let sanitized = xpath
            .replacingOccurrences(of: "//", with: "")
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return false }
        return xml.contains("<\(sanitized)") || xml.contains("</\(sanitized)")
    }
}
