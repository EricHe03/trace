//
//  JSONXMLConverter.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public enum JSONXMLConverter {
    public static func jsonToXML(data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        let xml = buildXML(from: object, rootName: "root")
        return xml.data(using: .utf8)
    }

    public static func xmlToJSON(data: Data) -> Data? {
        let parser = XMLParser(data: data)
        let delegate = SimpleXMLToJSONParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        guard let result = delegate.result else { return nil }
        return try? JSONSerialization.data(withJSONObject: result, options: [])
    }

    public static func jsonPathSet(data: Data, path: String, rawValue: String) -> Data? {
        let evaluator = JSONPathEvaluator()
        let value = parseJSONValue(rawValue)
        return try? evaluator.set(json: data, path: path, value: value)
    }

    public static func jsonPathDelete(data: Data, path: String) -> Data? {
        let evaluator = JSONPathEvaluator()
        return try? evaluator.delete(json: data, path: path)
    }

    private static func buildXML(from value: Any, rootName: String) -> String {
        var xml = "<\(rootName)>"
        switch value {
        case let dict as [String: Any]:
            for (key, val) in dict {
                xml += buildXML(from: val, rootName: sanitize(key))
            }
        case let array as [Any]:
            for item in array {
                xml += buildXML(from: item, rootName: "item")
            }
        case let string as String:
            xml += escapeXML(string)
        case let number as NSNumber:
            xml += number.stringValue
        case _ as NSNull:
            xml += ""
        default:
            xml += "\(value)"
        }
        xml += "</\(rootName)>"
        return xml
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func parseJSONValue(_ raw: String) -> Any {
        if let data = raw.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: []) {
            return value
        }
        if let intValue = Int(raw) { return intValue }
        if let doubleValue = Double(raw) { return doubleValue }
        if raw.lowercased() == "true" { return true }
        if raw.lowercased() == "false" { return false }
        if raw.lowercased() == "null" { return NSNull() }
        return raw
    }
}

private final class SimpleXMLToJSONParser: NSObject, XMLParserDelegate {
    private var stack: [[String: Any]] = []
    private var textBuffer: String = ""
    private(set) var result: [String: Any]?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        var node: [String: Any] = attributeDict
        stack.append(node)
        textBuffer = ""
        if stack.count == 1 {
            result = [elementName: node]
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            stack[stack.count - 1]["_text"] = text
        }

        let node = stack.removeLast()
        if !stack.isEmpty {
            var parent = stack.removeLast()
            if let existing = parent[elementName] {
                if var array = existing as? [Any] {
                    array.append(node)
                    parent[elementName] = array
                } else {
                    parent[elementName] = [existing, node]
                }
            } else {
                parent[elementName] = node
            }
            stack.append(parent)
        } else {
            result = [elementName: node]
        }
        textBuffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }
}
