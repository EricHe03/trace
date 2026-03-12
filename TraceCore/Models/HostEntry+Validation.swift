//
//  HostEntry+Validation.swift
//  TraceCore
//
//  Created by Justin on 2026/03/06.
//

import Foundation

public extension HostEntry {
    func matches(_ url: String) -> Bool {
        guard enabled else { return false }

        let targetHostname: String = if let urlObj = URL(string: url), let host = urlObj.host {
            host
        } else {
            url
        }

        if hostname.caseInsensitiveCompare(targetHostname) == .orderedSame {
            return true
        }

        if hostname.contains("*") {
            let pattern = hostname
                .replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "*", with: ".*")
            return RegexMatcher.safeMatch(pattern: "^\(pattern)$", in: targetHostname, caseSensitive: false)
        }

        return false
    }

    var isValidHostname: Bool {
        guard !hostname.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let validCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*")
        let hostnameSet = CharacterSet(charactersIn: hostname)
        return hostnameSet.isSubset(of: validCharacterSet)
    }

    var isValidTargetIP: Bool {
        Validation.isValidIPAddress(targetIP)
    }

    var validationErrors: [String] {
        var errors: [String] = []

        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Name cannot be empty")
        }
        if !isValidHostname {
            errors.append("Invalid hostname pattern")
        }
        if !isValidTargetIP {
            errors.append("Invalid target IP address")
        }
        if let port = targetPort, port < 1 || port > 65535 {
            errors.append("Port must be between 1 and 65535")
        }

        return errors
    }

    var isValid: Bool {
        validationErrors.isEmpty
    }

    static var sample: HostEntry {
        HostEntry(
            name: "Local API Server",
            hostname: "api.example.com",
            targetIP: "192.168.1.100",
            targetPort: 8080
        )
    }

    static var samples: [HostEntry] {
        [
            HostEntry(
                name: "Local API Server",
                hostname: "api.example.com",
                targetIP: "192.168.1.100",
                targetPort: 8080
            ),
            HostEntry(
                name: "Development Server",
                hostname: "*.dev.example.com",
                targetIP: "10.0.0.50",
                targetPort: nil
            ),
            HostEntry(
                name: "Staging Environment",
                enabled: false,
                hostname: "staging.example.com",
                targetIP: "172.16.0.10",
                targetPort: 443
            )
        ]
    }
}
