//
//  ContentSafety.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public enum ContentSafety {
    public static func isBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // Fast-path for common binary signatures where the heuristic ratio can misclassify
        // small headers as text-like (e.g. PNG).
        if data.count >= 8 {
            let prefix8 = [UInt8](data.prefix(8))
            if prefix8 == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { // PNG
                return true
            }
        }
        if data.contains(0) { return true }
        let sample = data.prefix(4096)
        let nonText = sample.filter { byte in
            !(byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte < 127))
        }
        let ratio = Double(nonText.count) / Double(sample.count)
        return ratio > 0.3
    }

    public static func shouldSkipTextOperation(_ data: Data, contentType: String?) -> Bool {
        if let contentType = contentType?.lowercased() {
            if contentType.contains("image") || contentType.contains("video") || contentType.contains("audio") {
                return true
            }
        }
        return isBinary(data)
    }
}
