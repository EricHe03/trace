//
//  ContentValidator.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public struct ValidationResult: Sendable {
    public var isValid: Bool
    public var errors: [String]
    public var canAutoFix: Bool

    public init(isValid: Bool, errors: [String] = [], canAutoFix: Bool = false) {
        self.isValid = isValid
        self.errors = errors
        self.canAutoFix = canAutoFix
    }
}

public struct ContentValidator {
    public init() {}

    public func validateJSON(_ data: Data) -> ValidationResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return ValidationResult(isValid: false, errors: ["Invalid UTF-8 data"], canAutoFix: false)
        }

        let sanitized = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        if sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ValidationResult(isValid: false, errors: ["Empty JSON"], canAutoFix: false)
        }

        if containsTrailingComma(in: sanitized) {
            return ValidationResult(isValid: false, errors: ["Trailing comma in JSON"], canAutoFix: false)
        }

        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return ValidationResult(isValid: true)
        } catch {
            return ValidationResult(isValid: false, errors: [error.localizedDescription], canAutoFix: false)
        }
    }

    public func validateXML(_ data: Data) -> ValidationResult {
        let parser = XMLParser(data: data)
        let delegate = XMLValidationDelegate()
        parser.delegate = delegate
        let success = parser.parse()
        if success {
            return ValidationResult(isValid: true)
        }
        let errorMessage = parser.parserError?.localizedDescription ?? "Invalid XML"
        return ValidationResult(isValid: false, errors: [errorMessage], canAutoFix: false)
    }
}

private final class XMLValidationDelegate: NSObject, XMLParserDelegate {}

private func containsTrailingComma(in text: String) -> Bool {
    let bytes = Array(text.utf8)
    var inString = false
    var isEscaped = false
    var index = 0

    func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    while index < bytes.count {
        let byte = bytes[index]
        if inString {
            if isEscaped {
                isEscaped = false
            } else if byte == 0x5C {
                isEscaped = true
            } else if byte == 0x22 {
                inString = false
            }
            index += 1
            continue
        }

        if byte == 0x22 {
            inString = true
            index += 1
            continue
        }

        if byte == 0x2C {
            var lookahead = index + 1
            while lookahead < bytes.count, isWhitespace(bytes[lookahead]) {
                lookahead += 1
            }
            if lookahead >= bytes.count {
                return true
            }
            let next = bytes[lookahead]
            if next == 0x7D || next == 0x5D {
                return true
            }
        }

        index += 1
    }
    return false
}
