//
//  CurlCommandAnalyzerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/08.
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
        let analyzer = CurlCommandAnalyzer(capabilities: .nioAsyncHTTPClient)

        let plan = analyzer.analyze("curl --parallel https://example.com")

        XCTAssertTrue(plan.hasBlockingDiagnostics)
        XCTAssertTrue(plan.diagnostics.contains { $0.option == "--parallel" })
    }

    func testAnalyzeFailsFastForUnsupportedProtocolOnDefaultBackend() {
        let analyzer = CurlCommandAnalyzer(capabilities: .nioAsyncHTTPClient)

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

    func testAnalyzeMultilineCommandWithLineContinuationAfterQuotedValues() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)
        let command = """
        curl -X POST -H 'Content-Type: application/json' \
             -d '{"hello":"world"}' \
             https://httpbin.org/post
        """

        let plan = analyzer.analyze(command)

        XCTAssertEqual(plan.transfers.count, 1)
        XCTAssertFalse(plan.hasBlockingDiagnostics)
        XCTAssertEqual(
            plan.transfers[0].argv,
            [
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "-d", "{\"hello\":\"world\"}",
                "https://httpbin.org/post",
            ]
        )
        XCTAssertFalse(plan.transfers[0].argv.contains(""))
    }

    func testAnalyzeEmitsFeatureDiagnosticsWhenRuntimeFlagsAreDisabled() {
        let analyzer = CurlCommandAnalyzer(capabilities: makeFeatureLimitedRuntimeCapabilities())

        let http2Plan = analyzer.analyze("curl --http2 https://example.com")
        XCTAssertTrue(http2Plan.hasBlockingDiagnostics)
        XCTAssertTrue(http2Plan.diagnostics.contains { $0.option == "--http2" && $0.message.contains("HTTP/2") })

        let http3Plan = analyzer.analyze("curl --http3 https://example.com")
        XCTAssertTrue(http3Plan.hasBlockingDiagnostics)
        XCTAssertTrue(http3Plan.diagnostics.contains { $0.option == "--http3" && $0.message.contains("HTTP/3") })

        let http3OnlyPlan = analyzer.analyze("curl --http3-only https://example.com")
        XCTAssertTrue(http3OnlyPlan.hasBlockingDiagnostics)
        XCTAssertTrue(http3OnlyPlan.diagnostics.contains { $0.option == "--http3-only" && $0.message.contains("HTTP/3") })

        let compressedPlan = analyzer.analyze("curl --compressed https://example.com")
        XCTAssertTrue(compressedPlan.hasBlockingDiagnostics)
        XCTAssertTrue(compressedPlan.diagnostics.contains { $0.option == "--compressed" && $0.message.contains("Compressed response decoding") })

        let ntlmPlan = analyzer.analyze("curl --ntlm --user user:pass https://example.com")
        XCTAssertTrue(ntlmPlan.hasBlockingDiagnostics)
        XCTAssertTrue(ntlmPlan.diagnostics.contains { $0.option == "--ntlm" && $0.message.contains("NTLM authentication") })
    }

    func testAnalyzeWarnsForNativeCAWhenUnsupported() {
        let analyzer = CurlCommandAnalyzer(capabilities: makeFeatureLimitedRuntimeCapabilities())

        let plan = analyzer.analyze("curl --ca-native https://example.com")

        XCTAssertFalse(plan.hasBlockingDiagnostics)
        XCTAssertTrue(
            plan.diagnostics.contains {
                $0.severity == .warning &&
                    $0.option == "--ca-native" &&
                    $0.message.contains("Native CA store")
            }
        )
    }

    func testAnalyzeAllowsHTTP2AndCompressedWhenRuntimeFlagsAreEnabled() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let http2Plan = analyzer.analyze("curl --http2 https://example.com")
        XCTAssertFalse(http2Plan.hasBlockingDiagnostics)
        XCTAssertFalse(http2Plan.diagnostics.contains { $0.option == "--http2" && $0.severity == .error })

        let compressedPlan = analyzer.analyze("curl --compressed https://example.com")
        XCTAssertFalse(compressedPlan.hasBlockingDiagnostics)
        XCTAssertFalse(compressedPlan.diagnostics.contains { $0.option == "--compressed" && $0.severity == .error })

        let http3Plan = analyzer.analyze("curl --http3-only https://example.com")
        XCTAssertFalse(http3Plan.hasBlockingDiagnostics)
        XCTAssertFalse(http3Plan.diagnostics.contains { $0.option == "--http3-only" && $0.severity == .error })
    }

    func testAnalyzeRejectsHTTP3OnlyForNonHTTPSURLs() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl --http3-only http://example.com")

        XCTAssertTrue(plan.hasBlockingDiagnostics)
        XCTAssertTrue(
            plan.diagnostics.contains {
                $0.option == "--http3-only" &&
                    $0.message.contains("requires an https:// URL")
            }
        )
    }

    func testAnalyzeRejectsHTTP3ForNonHTTPSURLs() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl --http3 http://example.com")

        XCTAssertTrue(plan.hasBlockingDiagnostics)
        XCTAssertTrue(
            plan.diagnostics.contains {
                $0.option == "--http3" &&
                    $0.message.contains("requires an https:// URL")
            }
        )
    }

    func testAnalyzeRejectsHTTP3OnlyWithOtherVersionFlags() {
        let analyzer = CurlCommandAnalyzer(capabilities: .parityValidation)

        let plan = analyzer.analyze("curl --http3-only --http2 https://example.com")

        XCTAssertTrue(plan.hasBlockingDiagnostics)
        XCTAssertTrue(
            plan.diagnostics.contains {
                $0.option == "--http3-only" &&
                    $0.message.contains("cannot be combined")
            }
        )
    }

    func testAnalyzeRejectsExplicitlyUnsupportedRuntimeProtocols() {
        let analyzer = CurlCommandAnalyzer(capabilities: makeFeatureLimitedRuntimeCapabilities())

        for scheme in ["ldap", "ldaps", "scp", "sftp"] {
            let plan = analyzer.analyze("curl \(scheme)://example.com/resource")
            XCTAssertTrue(plan.hasBlockingDiagnostics, "Expected blocking diagnostics for \(scheme)")
            XCTAssertTrue(
                plan.diagnostics.contains { $0.message.contains("Protocol '\(scheme)'") },
                "Expected protocol diagnostic for \(scheme)"
            )
        }
    }
}

private extension CurlCommandAnalyzerTests {
    func makeFeatureLimitedRuntimeCapabilities() -> CurlRuntimeCapabilities {
        CurlRuntimeCapabilities(
            backendName: "TestRuntime",
            supportedProtocols: ["http", "https"],
            supportedOptions: CurlOptionRegistry.allOptions,
            supportsHTTP2: false,
            supportsHTTP3: false,
            supportsContentDecoding: false,
            supportsNativeCA: false,
            supportsNTLM: false
        )
    }

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
