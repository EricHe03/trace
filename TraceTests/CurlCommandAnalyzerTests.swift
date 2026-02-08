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

    func testAnalyzeSplitsMultipleURLsIntoSeparateTransfers() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl --header X-Test:1 https://one.example https://two.example")

        XCTAssertEqual(plan.transfers.count, 2)
        XCTAssertEqual(plan.transfers[0].urls, ["https://one.example"])
        XCTAssertEqual(plan.transfers[1].urls, ["https://two.example"])
        XCTAssertEqual(plan.transfers[0].effectiveOptions["--header"], ["X-Test:1"])
        XCTAssertEqual(plan.transfers[1].effectiveOptions["--header"], ["X-Test:1"])
        XCTAssertEqual(plan.transfers[0].argv, ["--header", "X-Test:1", "https://one.example"])
        XCTAssertEqual(plan.transfers[1].argv, ["--header", "X-Test:1", "https://two.example"])
    }

    func testAnalyzeCarriesGlobalOptionsAcrossNextPartitions() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl --verbose https://one.example --next https://two.example")

        XCTAssertEqual(plan.transfers.count, 2)
        XCTAssertEqual(plan.transfers[0].effectiveOptions["--verbose"], ["true"])
        XCTAssertEqual(plan.transfers[1].effectiveOptions["--verbose"], ["true"])
        XCTAssertTrue(plan.transfers[0].command.contains("--verbose"))
        XCTAssertTrue(plan.transfers[1].command.contains("--verbose"))
    }

    func testAnalyzeCarriesShortGlobalOptionsAcrossNextPartitions() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl -v https://one.example --next https://two.example")

        XCTAssertEqual(plan.transfers.count, 2)
        XCTAssertEqual(plan.transfers[0].effectiveOptions["-v"], ["true"])
        XCTAssertEqual(plan.transfers[1].effectiveOptions["-v"], ["true"])
        XCTAssertTrue(plan.transfers[0].command.contains("-v"))
        XCTAssertTrue(plan.transfers[1].command.contains("-v"))
    }

    func testAnalyzeIncludesOptionsAppearingAfterURL() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl https://one.example -H X-Trace:1")

        XCTAssertEqual(plan.transfers.count, 1)
        XCTAssertEqual(plan.transfers[0].urls, ["https://one.example"])
        XCTAssertEqual(plan.transfers[0].effectiveOptions["-H"], ["X-Trace:1"])
        XCTAssertTrue(plan.transfers[0].command.contains("-H"))
    }

    func testAnalyzeAssignsOutputOptionsPerURLInOrder() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl -o first.txt -o second.txt https://one.example https://two.example")

        XCTAssertEqual(plan.transfers.count, 2)
        XCTAssertEqual(plan.transfers[0].effectiveOptions["-o"], ["first.txt"])
        XCTAssertEqual(plan.transfers[1].effectiveOptions["-o"], ["second.txt"])
        XCTAssertTrue(plan.transfers[0].command.contains("first.txt"))
        XCTAssertTrue(plan.transfers[1].command.contains("second.txt"))
    }

    func testAnalyzeAssignsUploadOptionsPerURLInOrder() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl -T one.bin -T two.bin https://one.example https://two.example")

        XCTAssertEqual(plan.transfers.count, 2)
        XCTAssertEqual(plan.transfers[0].effectiveOptions["-T"], ["one.bin"])
        XCTAssertEqual(plan.transfers[1].effectiveOptions["-T"], ["two.bin"])
        XCTAssertTrue(plan.transfers[0].command.contains("one.bin"))
        XCTAssertTrue(plan.transfers[1].command.contains("two.bin"))
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

    func testAnalyzePreservesQuotedArgumentValuesInArgv() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl -H 'X Name: value with space' https://example.com")

        XCTAssertEqual(plan.transfers.count, 1)
        XCTAssertEqual(plan.transfers[0].argv, ["-H", "X Name: value with space", "https://example.com"])
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
