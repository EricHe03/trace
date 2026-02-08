#!/usr/bin/env swift

import Foundation

struct GeneratorConfig {
    let manpagePath: String
    let registryOutputPath: String
    let metadataOutputPath: String
}

struct ParsedOptionDefinitions {
    var options: Set<String> = []
    var required: Set<String> = []
    var optional: Set<String> = []
    var aliasesByOption: [String: Set<String>] = [:]
}

enum GeneratorError: Error {
    case invalidArgs
    case cannotRead(String)
}

func parseArgs() throws -> GeneratorConfig {
    let args = CommandLine.arguments
    var manpage: String?
    var registry: String?
    var metadata: String?

    var index = 1
    while index < args.count {
        let arg = args[index]
        let valueIndex = index + 1
        guard valueIndex < args.count else {
            throw GeneratorError.invalidArgs
        }

        switch arg {
        case "--manpage":
            manpage = args[valueIndex]
        case "--output-registry":
            registry = args[valueIndex]
        case "--output-metadata":
            metadata = args[valueIndex]
        default:
            throw GeneratorError.invalidArgs
        }

        index += 2
    }

    guard let manpage, let registry, let metadata else {
        throw GeneratorError.invalidArgs
    }

    return GeneratorConfig(manpagePath: manpage, registryOutputPath: registry, metadataOutputPath: metadata)
}

func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // swiftlint:disable-next-line force_try
    try! NSRegularExpression(pattern: pattern, options: options)
}

func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
    regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
}

func capture(_ result: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
    guard let range = Range(result.range(at: index), in: text) else { return nil }
    return String(text[range])
}

func htmlDecoded(_ value: String) -> String {
    var output = value.replacingOccurrences(of: "&amp;", with: "&")
    output = output.replacingOccurrences(of: "&lt;", with: "<")
    output = output.replacingOccurrences(of: "&gt;", with: ">")
    output = output.replacingOccurrences(of: "&quot;", with: "\"")
    output = output.replacingOccurrences(of: "&#39;", with: "'")
    let numericEntityRegex = regex("&#([0-9]+);")
    while let match = numericEntityRegex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
          let fullRange = Range(match.range(at: 0), in: output),
          let codeRange = Range(match.range(at: 1), in: output),
          let scalarValue = UInt32(output[codeRange]),
          let scalar = UnicodeScalar(scalarValue) {
        output.replaceSubrange(fullRange, with: String(scalar))
    }
    return output
}

func parseOptionDefinitions(from manpage: String) -> ParsedOptionDefinitions {
    let definitionRegex = regex(#"<p class=\"level0\">(?:<a name=\"[^\"]+\"></a>)+<span class=\"nroffip\">([^<]*)</span>"#)
    let optionRegex = regex(#"(?<!\w)(--[A-Za-z0-9][A-Za-z0-9.:-]*|-[A-Za-z0-9:#])"#)
    let requiredRegex = regex(#"<[^>]+>"#)
    let optionalRegex = regex(#"\[[^\]]+\]"#)

    var parsed = ParsedOptionDefinitions()

    for definition in matches(definitionRegex, in: manpage) {
        guard let rawSpec = capture(definition, 1, in: manpage) else { continue }
        let spec = htmlDecoded(rawSpec)

        let options = matches(optionRegex, in: spec).compactMap {
            capture($0, 1, in: spec)
        }
        guard !options.isEmpty else { continue }
        let optionSet = Set(options)

        for option in optionSet {
            parsed.options.insert(option)
            parsed.aliasesByOption[option, default: []].formUnion(optionSet)
        }

        let hasRequiredValue = requiredRegex.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)) != nil
        let hasOptionalValue = optionalRegex.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)) != nil

        if hasRequiredValue {
            for option in optionSet {
                parsed.required.insert(option)
            }
        }

        if hasOptionalValue {
            for option in optionSet {
                parsed.optional.insert(option)
            }
        }
    }

    return parsed
}

func parseGlobalOptions(from manpage: String, aliasesByOption: [String: Set<String>]) -> Set<String> {
    let globalRegex = regex(#"The following options are global:(.*?)</p>"#, options: [.dotMatchesLineSeparators])
    guard let match = matches(globalRegex, in: manpage).first,
          let section = capture(match, 1, in: manpage)
    else {
        return []
    }

    let optionRegex = regex("href=\\\"#([^\\\"]+)\\\"")
    var globals = Set<String>()
    for optionMatch in matches(optionRegex, in: section) {
        if let token = capture(optionMatch, 1, in: section), token.hasPrefix("-") {
            globals.insert(token)
        }
    }

    var expandedGlobals = globals
    for option in globals {
        expandedGlobals.formUnion(aliasesByOption[option] ?? [])
    }
    return expandedGlobals
}

func optionListLiteral(_ options: [String]) -> String {
    options.map { "        \"\($0)\"," }.joined(separator: "\n")
}

func writeRegistry(
    path: String,
    allOptions: [String],
    required: [String],
    optional: [String]
) throws {
    let content = """
    //
    //  CurlOptionRegistry.swift
    //  TraceFeatures
    //
    //  Auto-generated from manpage.html.
    //  Do not edit manually.
    //

    import Foundation

    enum CurlOptionRegistry {
        static let allOptions: Set<String> = [
    \(optionListLiteral(allOptions))
        ]

        static let optionsRequiringValue: Set<String> = [
    \(optionListLiteral(required))
        ]

        static let optionsWithOptionalValue: Set<String> = [
    \(optionListLiteral(optional))
        ]

        static func isKnown(_ option: String) -> Bool {
            allOptions.contains(option)
        }

        static func requiresValue(_ option: String) -> Bool {
            optionsRequiringValue.contains(option)
        }

        static func hasOptionalValue(_ option: String) -> Bool {
            optionsWithOptionalValue.contains(option)
        }
    }
    """

    try content.write(toFile: path, atomically: true, encoding: .utf8)
}

func writeMetadata(path: String, globalOptions: [String]) throws {
    let content = """
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
    \(optionListLiteral(globalOptions))
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
    """

    try content.write(toFile: path, atomically: true, encoding: .utf8)
}

func main() throws {
    let config = try parseArgs()
    guard let manpage = try? String(contentsOfFile: config.manpagePath, encoding: .utf8) else {
        throw GeneratorError.cannotRead(config.manpagePath)
    }

    let parsed = parseOptionDefinitions(from: manpage)
    let globals = parseGlobalOptions(from: manpage, aliasesByOption: parsed.aliasesByOption).sorted()

    try writeRegistry(
        path: config.registryOutputPath,
        allOptions: parsed.options.sorted(),
        required: parsed.required.sorted(),
        optional: parsed.optional.sorted()
    )
    try writeMetadata(path: config.metadataOutputPath, globalOptions: globals)
}

do {
    try main()
} catch {
    fputs("curl option generation failed: \(error)\n", stderr)
    exit(1)
}
