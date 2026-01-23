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
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
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
