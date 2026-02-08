//
//  CurlOptionMetadata.swift
//  TraceFeatures
//
//  Auto-generated from manpage.html.
//  Do not edit manually.
//

import Foundation

public enum CurlOptionArity: String, Codable, Sendable {
    case flag
    case requiredValue
    case optionalValue
}

public enum CurlOptionCategory: String, Codable, Sendable {
    case global
    case transfer
}

public struct CurlOptionMetadata: Codable, Equatable, Sendable {
    public let option: String
    public let arity: CurlOptionArity
    public let category: CurlOptionCategory

    public init(option: String, arity: CurlOptionArity, category: CurlOptionCategory) {
        self.option = option
        self.arity = arity
        self.category = category
    }
}

public enum CurlOptionMetadataRegistry {
    static let globalOptions: Set<String> = [
        "-#",
        "--fail-early",
        "--libcurl",
        "--parallel",
        "--parallel-immediate",
        "--parallel-max",
        "--parallel-max-host",
        "--progress-bar",
        "--rate",
        "--show-error",
        "--stderr",
        "--styled-output",
        "--trace",
        "--trace-ascii",
        "--trace-config",
        "--trace-ids",
        "--trace-time",
        "--verbose",
        "-S",
        "-Z",
        "-v",
    ]

    public static func metadata(for option: String) -> CurlOptionMetadata? {
        guard CurlOptionRegistry.isKnown(option) else { return nil }

        let arity: CurlOptionArity
        if CurlOptionRegistry.hasOptionalValue(option) {
            arity = .optionalValue
        } else if CurlOptionRegistry.requiresValue(option) {
            arity = .requiredValue
        } else {
            arity = .flag
        }

        let category: CurlOptionCategory = globalOptions.contains(option) ? .global : .transfer
        return CurlOptionMetadata(option: option, arity: arity, category: category)
    }

    public static var all: [String: CurlOptionMetadata] {
        var result: [String: CurlOptionMetadata] = [:]
        for option in CurlOptionRegistry.allOptions {
            if let metadata = metadata(for: option) {
                result[option] = metadata
            }
        }
        return result
    }
}