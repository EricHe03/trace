//
//  Validation.swift
//  TraceCore
//
//  Created by Justin on 2026/01/24.
//

import Darwin
import Foundation

public enum Validation {
    public static func isValidDomainPattern(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Reject obviously-invalid IPv4-like inputs (e.g. 999.999.999.999) which are frequently
        // user mistakes when entering a domain pattern.
        let dotParts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if dotParts.count == 4, dotParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return isValidIPv4(trimmed)
        }

        let validCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*")
        let valueSet = CharacterSet(charactersIn: trimmed)
        return valueSet.isSubset(of: validCharacters)
    }

    public static func isValidIPAddress(_ value: String) -> Bool {
        isValidIPv4(value) || isValidIPv6(value)
    }

    public static func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part), num >= 0, num <= 255 else { return false }
            return true
        }
    }

    public static func isValidIPv6(_ ip: String) -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var address = in6_addr()
        return trimmed.withCString { cString in
            inet_pton(AF_INET6, cString, &address) == 1
        }
    }
}
