//
//  HTTPHeaderNormalizer.swift
//  TraceCore
//
//  Created by Justin on 2026/01/23.
//

import Foundation

/// Normalizes HTTP headers captured from Foundation APIs.
public enum HTTPHeaderNormalizer {
    /// Flattens header dictionaries into repeated key/value pairs.
    public static func flatten(_ headers: [AnyHashable: Any]) -> [TraceHTTPHeader] {
        var flattened: [TraceHTTPHeader] = []
        for (key, value) in headers {
            let keyString = "\(key)"
            if let array = value as? [Any] {
                for item in array {
                    flattened.append(TraceHTTPHeader(key: keyString, value: "\(item)"))
                }
            } else if let array = value as? NSArray {
                for item in array {
                    flattened.append(TraceHTTPHeader(key: keyString, value: "\(item)"))
                }
            } else {
                flattened.append(TraceHTTPHeader(key: keyString, value: "\(value)"))
            }
        }
        return flattened
    }
}
