//
//  CurlCommandAnalyzerTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/08.
//

import XCTest
@testable import TraceFeatures

final class CurlCommandAnalyzerTests: XCTestCase {

    func testAnalyzeRecognizesEveryRegisteredOption() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        for option in CurlOptionRegistry.allOptions.sorted() {
            let plan = analyzer.analyze(makeCommand(for: option))

            let parseErrors = plan.diagnostics.filter {
                $0.severity == .error && (
                    $0.message.contains("Unsupported cURL option") ||
                    $0.message.contains("requires a value") ||
                    $0.message.contains("has no URL") ||
                    $0.message.contains("Missing URL")
                )
            }
            XCTAssertTrue(parseErrors.isEmpty, "Option \(option) was not parsed cleanly: \(parseErrors.map(\.message))")
        }
    }

    func testAnalyzeSplitsTransfersForNextAndDashColon() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let longNextPlan = analyzer.analyze("curl https://one.example --next https://two.example")
        XCTAssertEqual(longNextPlan.transfers.count, 2)
        XCTAssertEqual(longNextPlan.transfers[0].urls, ["https://one.example"])
        XCTAssertEqual(longNextPlan.transfers[1].urls, ["https://two.example"])

        let shortNextPlan = analyzer.analyze("curl https://one.example -: https://two.example")
        XCTAssertEqual(shortNextPlan.transfers.count, 2)
        XCTAssertEqual(shortNextPlan.transfers[0].urls, ["https://one.example"])
        XCTAssertEqual(shortNextPlan.transfers[1].urls, ["https://two.example"])
    }

    func testAnalyzeFailsFastForUnsupportedBackendOption() {
        let analyzer = CurlCommandAnalyzer(capabilities: .urlSession)

        let plan = analyzer.analyze("curl --parallel https://example.com")

        XCTAssertTrue(plan.hasBlockingDiagnostics)
        XCTAssertTrue(plan.diagnostics.contains { $0.option == "--parallel" })
    }

    func testAnalyzeFailsFastForUnsupportedProtocolOnDefaultBackend() {
        let analyzer = CurlCommandAnalyzer(capabilities: .urlSession)

        let plan = analyzer.analyze("curl ftp://example.com/file.txt")

        XCTAssertTrue(plan.hasBlockingDiagnostics)
        XCTAssertTrue(plan.diagnostics.contains { $0.message.contains("Protocol 'ftp'") })
    }

    func testAnalyzeValidatesConfigFilePath() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl --config /path/that/does/not/exist https://example.com")

        XCTAssertTrue(plan.hasBlockingDiagnostics)
        XCTAssertTrue(plan.diagnostics.contains { $0.option == "--config" && $0.message.contains("not readable") })
    }

    func testAnalyzeValidatesVariableFormat() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl --variable not-valid https://example.com")

        XCTAssertTrue(plan.hasBlockingDiagnostics)
        XCTAssertTrue(plan.diagnostics.contains { $0.option == "--variable" && $0.message.contains("Invalid variable") })
    }
}

private extension CurlCommandAnalyzerTests {
    func makeCommand(for option: String) -> String {
        if option == "--next" || option == "-:" {
            return "curl https://first.example \(option) https://second.example"
        }

        if CurlOptionRegistry.requiresValue(option) {
            return "curl \(option) \(placeholderValue(for: option)) https://example.com"
        }

        if CurlOptionRegistry.hasOptionalValue(option) {
            return "curl \(option) \(placeholderValue(for: option)) https://example.com"
        }

        return "curl \(option) https://example.com"
    }

    func placeholderValue(for option: String) -> String {
        switch option {
        case "--config", "-K":
            "-"
        case "--url":
            "https://option-value.example"
        case "--variable":
            "name=value"
        default:
            "value"
        }
    }
}
