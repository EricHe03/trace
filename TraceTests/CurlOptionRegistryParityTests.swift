//
//  CurlOptionRegistryParityTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/07.
//

import Foundation
import XCTest
@testable import TraceFeatures

final class CurlOptionRegistryParityTests: XCTestCase {

    func testRegistryMatchesManpageOptions() throws {
        let manpage = try loadManpage()
        let parsed = parseOptionDefinitions(from: manpage)

        XCTAssertEqual(parsed.options, CurlOptionRegistry.allOptions)
    }

    func testMetadataArityConsistency() {
        for option in CurlOptionRegistry.allOptions {
            guard let metadata = CurlOptionMetadataRegistry.metadata(for: option) else {
                XCTFail("Missing metadata for \(option)")
                continue
            }

            if CurlOptionRegistry.hasOptionalValue(option) {
                XCTAssertEqual(metadata.arity, .optionalValue, "Optional arity mismatch for \(option)")
            } else if CurlOptionRegistry.requiresValue(option) {
                XCTAssertEqual(metadata.arity, .requiredValue, "Required arity mismatch for \(option)")
            } else {
                XCTAssertEqual(metadata.arity, .flag, "Flag arity mismatch for \(option)")
            }
        }
    }

    func testRegistryArityMatchesManpageDefinitions() throws {
        let manpage = try loadManpage()
        let parsed = parseOptionDefinitions(from: manpage)

        XCTAssertEqual(parsed.required, CurlOptionRegistry.optionsRequiringValue)
        XCTAssertEqual(parsed.optional, CurlOptionRegistry.optionsWithOptionalValue)
    }

    func testGlobalOptionMetadataMatchesManpageGlobalList() throws {
        let manpage = try loadManpage()
        let expectedGlobal = parseGlobalOptions(from: manpage)

        XCTAssertEqual(expectedGlobal, CurlOptionMetadataRegistry.globalOptions)
    }
}

private extension CurlOptionRegistryParityTests {
    struct ParsedOptionDefinitions {
        var options: Set<String> = []
        var required: Set<String> = []
        var optional: Set<String> = []
    }

    func loadManpage() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("manpage.html").path
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    func parseOptionDefinitions(from manpage: String) -> ParsedOptionDefinitions {
        let regex = try! NSRegularExpression( // swiftlint:disable:this force_try
            pattern: #"<p class=\"level0\">(?:<a name=\"[^\"]+\"></a>)+<span class=\"nroffip\">([^<]*)</span>"#
        )
        let optionRegex = try! NSRegularExpression( // swiftlint:disable:this force_try
            pattern: #"(?<!\w)(--[A-Za-z0-9][A-Za-z0-9.:-]*|-[A-Za-z0-9:#])"#
        )
        let requiredRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#) // swiftlint:disable:this force_try
        let optionalRegex = try! NSRegularExpression(pattern: #"\[[^\]]+\]"#) // swiftlint:disable:this force_try

        var parsed = ParsedOptionDefinitions()

        for match in regex.matches(in: manpage, range: NSRange(manpage.startIndex..., in: manpage)) {
            guard let range = Range(match.range(at: 1), in: manpage) else { continue }
            let spec = htmlDecoded(String(manpage[range]))
            let options = optionRegex.matches(in: spec, range: NSRange(spec.startIndex..., in: spec)).compactMap {
                Range($0.range(at: 1), in: spec).map { String(spec[$0]) }
            }

            guard !options.isEmpty else { continue }
            for option in options {
                parsed.options.insert(option)
            }

            let hasRequiredValue = requiredRegex.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)) != nil
            let hasOptionalValue = optionalRegex.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)) != nil

            if hasRequiredValue {
                for option in options {
                    parsed.required.insert(option)
                }
            }
            if hasOptionalValue {
                for option in options {
                    parsed.optional.insert(option)
                }
            }
        }

        return parsed
    }

    func parseGlobalOptions(from manpage: String) -> Set<String> {
        let pattern = #"The following options are global:(.*?)</p>"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) // swiftlint:disable:this force_try
        guard let match = regex.matches(in: manpage, range: NSRange(manpage.startIndex..., in: manpage)).first,
              let range = Range(match.range(at: 1), in: manpage)
        else {
            return []
        }

        let section = String(manpage[range])
        let hrefRegex = try! NSRegularExpression(pattern: "href=\\\"#([^\\\"]+)\\\"") // swiftlint:disable:this force_try
        let hrefMatches = hrefRegex.matches(in: section, range: NSRange(section.startIndex..., in: section))

        var options: Set<String> = []
        for href in hrefMatches {
            guard let hrefRange = Range(href.range(at: 1), in: section) else { continue }
            let token = String(section[hrefRange])
            guard token.hasPrefix("-") else { continue }
            options.insert(token)
        }

        return options
    }

    func htmlDecoded(_ string: String) -> String {
        var decoded = string
        decoded = decoded.replacingOccurrences(of: "&amp;", with: "&")
        decoded = decoded.replacingOccurrences(of: "&lt;", with: "<")
        decoded = decoded.replacingOccurrences(of: "&gt;", with: ">")
        decoded = decoded.replacingOccurrences(of: "&quot;", with: "\"")
        decoded = decoded.replacingOccurrences(of: "&#39;", with: "'")
        let numericEntityRegex = try! NSRegularExpression(pattern: "&#([0-9]+);") // swiftlint:disable:this force_try
        while let match = numericEntityRegex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
              let fullRange = Range(match.range(at: 0), in: decoded),
              let codeRange = Range(match.range(at: 1), in: decoded),
              let scalarValue = UInt32(decoded[codeRange]),
              let scalar = UnicodeScalar(scalarValue) {
            decoded.replaceSubrange(fullRange, with: String(scalar))
        }
        return decoded
    }
}
