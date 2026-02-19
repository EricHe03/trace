//
//  HardeningConfigTests.swift
//  TraceTests
//
//  Created by Justin on 2026-02-01.
//

import XCTest
@testable import TraceProxy
@testable import TraceCore

@MainActor
final class HardeningConfigTests: XCTestCase {
    // MARK: - Properties

    var sut: HardeningConfig!

    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()
        sut = await HardeningConfig.shared
        await sut.resetToDefaults()
    }

    override func tearDown() async throws {
        await sut.resetToDefaults()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Default Configuration Tests

    func testDefaultRobustReassemblyEnabled() async {
        // Given / When
        let enabled = await sut.enableRobustReassembly

        // Then
        XCTAssertTrue(enabled)
    }

    func testDefaultMetricsEnabled() async {
        // Given / When
        let enabled = await sut.enableMetrics

        // Then
        XCTAssertTrue(enabled)
    }

    func testDefaultDebugLoggingDisabled() async {
        // Given / When
        let enabled = await sut.enableDebugLogging

        // Then
        XCTAssertFalse(enabled)
    }

    func testDefaultRolloutStageIsProduction() async {
        // Given / When
        let stage = await sut.rolloutStage

        // Then
        XCTAssertEqual(stage, .production)
    }

    func testDefaultRawCaptureDisabled() async {
        // Given / When
        let enabled = await sut.enableRawCapture

        // Then
        XCTAssertFalse(enabled)
    }

    func testDefaultMaxRawCaptureSizeIs10MB() async {
        // Given / When
        let size = await sut.maxRawCaptureSize

        // Then
        XCTAssertEqual(size, 10_485_760) // 10 MB
    }

    func testDefaultMitmAllowlistIsWildcard() async {
        // Given / When
        let allowlist = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(allowlist, ["*"])
    }

    func testDefaultQUICHandlingModeIsIntercept() async {
        // Given / When
        let mode = await sut.quicHandlingMode

        // Then
        XCTAssertEqual(mode, .intercept)
    }

    func testDefaultBlockQUICDisabled() async {
        // Given / When
        let enabled = await sut.blockQUIC

        // Then
        XCTAssertFalse(enabled)
    }

    func testDefaultNetworkFrameworkMITMEnabled() async {
        // Given / When
        let enabled = await sut.enableNetworkFrameworkMITM

        // Then
        XCTAssertTrue(enabled)
    }

    // MARK: - Robust Reassembly Configuration Tests

    func testSetEnableRobustReassembly() async {
        // Given
        let enabled = false

        // When
        await sut.setEnableRobustReassembly(enabled)
        let result = await sut.enableRobustReassembly

        // Then
        XCTAssertEqual(result, enabled)
    }

    func testSetEnableRobustReassemblyTrue() async {
        // Given
        let enabled = true

        // When
        await sut.setEnableRobustReassembly(enabled)
        let result = await sut.enableRobustReassembly

        // Then
        XCTAssertEqual(result, enabled)
    }

    // MARK: - Metrics Configuration Tests

    func testSetEnableMetrics() async {
        // Given
        let enabled = false

        // When
        await sut.setEnableMetrics(enabled)
        let result = await sut.enableMetrics

        // Then
        XCTAssertEqual(result, enabled)
    }

    func testSetEnableMetricsTrue() async {
        // Given
        let enabled = true

        // When
        await sut.setEnableMetrics(enabled)
        let result = await sut.enableMetrics

        // Then
        XCTAssertEqual(result, enabled)
    }

    // MARK: - Debug Logging Configuration Tests

    func testSetEnableDebugLogging() async {
        // Given
        let enabled = true

        // When
        await sut.setEnableDebugLogging(enabled)
        let result = await sut.enableDebugLogging

        // Then
        XCTAssertEqual(result, enabled)
    }

    func testSetEnableDebugLoggingFalse() async {
        // Given
        let enabled = false

        // When
        await sut.setEnableDebugLogging(enabled)
        let result = await sut.enableDebugLogging

        // Then
        XCTAssertEqual(result, enabled)
    }

    // MARK: - Rollout Stage Tests

    func testSetRolloutStageDisabled() async {
        // Given
        let stage = HardeningConfig.RolloutStage.disabled

        // When
        await sut.setRolloutStage(stage)
        let result = await sut.rolloutStage

        // Then
        XCTAssertEqual(result, stage)
    }

    func testSetRolloutStageInternal() async {
        // Given
        let stage = HardeningConfig.RolloutStage.internalStage

        // When
        await sut.setRolloutStage(stage)
        let result = await sut.rolloutStage

        // Then
        XCTAssertEqual(result, stage)
    }

    func testSetRolloutStageBeta() async {
        // Given
        let stage = HardeningConfig.RolloutStage.beta

        // When
        await sut.setRolloutStage(stage)
        let result = await sut.rolloutStage

        // Then
        XCTAssertEqual(result, stage)
    }

    func testSetRolloutStageProduction() async {
        // Given
        let stage = HardeningConfig.RolloutStage.production

        // When
        await sut.setRolloutStage(stage)
        let result = await sut.rolloutStage

        // Then
        XCTAssertEqual(result, stage)
    }

    // MARK: - Rollout Stage Enforcement Tests

    func testDisabledStageDisablesAllFeatures() async {
        // Given
        let stage = HardeningConfig.RolloutStage.disabled

        // When
        await sut.setRolloutStage(stage)

        // Then
        let reassembly = await sut.enableRobustReassembly
        let metrics = await sut.enableMetrics
        let debug = await sut.enableDebugLogging

        XCTAssertFalse(reassembly)
        XCTAssertFalse(metrics)
        XCTAssertFalse(debug)
    }

    func testBetaStageEnablesReassemblyAndMetrics() async {
        // Given
        let stage = HardeningConfig.RolloutStage.beta

        // When
        await sut.setRolloutStage(stage)

        // Then
        let reassembly = await sut.enableRobustReassembly
        let metrics = await sut.enableMetrics
        let debug = await sut.enableDebugLogging

        XCTAssertTrue(reassembly)
        XCTAssertTrue(metrics)
        XCTAssertFalse(debug)
    }

    func testProductionStageEnablesReassemblyAndMetrics() async {
        // Given
        let stage = HardeningConfig.RolloutStage.production

        // When
        await sut.setRolloutStage(stage)

        // Then
        let reassembly = await sut.enableRobustReassembly
        let metrics = await sut.enableMetrics
        let debug = await sut.enableDebugLogging

        XCTAssertTrue(reassembly)
        XCTAssertTrue(metrics)
        XCTAssertFalse(debug)
    }

    func testDisabledStageBlocksFeatureToggles() async {
        // Given
        await sut.setRolloutStage(.disabled)

        // When
        await sut.setEnableRobustReassembly(true)
        await sut.setEnableMetrics(true)
        await sut.setEnableDebugLogging(true)

        // Then
        let reassembly = await sut.enableRobustReassembly
        let metrics = await sut.enableMetrics
        let debug = await sut.enableDebugLogging

        XCTAssertFalse(reassembly)
        XCTAssertFalse(metrics)
        XCTAssertFalse(debug)
    }

    // MARK: - Raw Capture Configuration Tests

    func testSetEnableRawCapture() async {
        // Given
        let enabled = true

        // When
        await sut.setEnableRawCapture(enabled)
        let result = await sut.enableRawCapture

        // Then
        XCTAssertEqual(result, enabled)
    }

    func testSetEnableRawCaptureFalse() async {
        // Given
        let enabled = false

        // When
        await sut.setEnableRawCapture(enabled)
        let result = await sut.enableRawCapture

        // Then
        XCTAssertEqual(result, enabled)
    }

    func testSetMaxRawCaptureSize() async {
        // Given
        let size: UInt64 = 50_000_000 // 50 MB

        // When
        await sut.setMaxRawCaptureSize(size)
        let result = await sut.maxRawCaptureSize

        // Then
        XCTAssertEqual(result, size)
    }

    func testSetMaxRawCaptureSizeToZero() async {
        // Given
        let size: UInt64 = 0

        // When
        await sut.setMaxRawCaptureSize(size)
        let result = await sut.maxRawCaptureSize

        // Then
        XCTAssertEqual(result, size)
    }

    func testSetMaxRawCaptureSizeToLargeValue() async {
        // Given
        let size: UInt64 = 1_000_000_000 // 1 GB

        // When
        await sut.setMaxRawCaptureSize(size)
        let result = await sut.maxRawCaptureSize

        // Then
        XCTAssertEqual(result, size)
    }

    // MARK: - MITM Allowlist Configuration Tests

    func testSetMitmAllowlistEmpty() async {
        // Given
        let allowlist: [String] = []

        // When
        await sut.setMitmAllowlist(allowlist)
        let result = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(result, [])
    }

    func testSetMitmAllowlistSingleDomain() async {
        // Given
        let allowlist = ["example.com"]

        // When
        await sut.setMitmAllowlist(allowlist)
        let result = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(result, ["example.com"])
    }

    func testSetMitmAllowlistMultipleDomains() async {
        // Given
        let allowlist = ["example.com", "api.example.com", "cdn.example.com"]

        // When
        await sut.setMitmAllowlist(allowlist)
        let result = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(result, allowlist)
    }

    func testSetMitmAllowlistSanitizesWhitespace() async {
        // Given
        let allowlist = ["  example.com  ", "\tapi.example.com\t", " cdn.example.com "]

        // When
        await sut.setMitmAllowlist(allowlist)
        let result = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(result, ["example.com", "api.example.com", "cdn.example.com"])
    }

    func testSetMitmAllowlistConvertsToLowercase() async {
        // Given
        let allowlist = ["EXAMPLE.COM", "Api.Example.COM", "CDN.EXAMPLE.COM"]

        // When
        await sut.setMitmAllowlist(allowlist)
        let result = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(result, ["example.com", "api.example.com", "cdn.example.com"])
    }

    func testSetMitmAllowlistFiltersEmptyStrings() async {
        // Given
        let allowlist = ["example.com", "", "  ", "api.example.com", "\t\t"]

        // When
        await sut.setMitmAllowlist(allowlist)
        let result = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(result, ["example.com", "api.example.com"])
    }

    // MARK: - QUIC Configuration Tests

    func testSetBlockQUIC() async {
        // Given
        let enabled = false

        // When
        await sut.setBlockQUIC(enabled)
        let result = await sut.blockQUIC

        // Then
        XCTAssertEqual(result, enabled)
    }

    func testSetBlockQUICTrue() async {
        // Given
        let enabled = true

        // When
        await sut.setBlockQUIC(enabled)
        let result = await sut.blockQUIC

        // Then
        XCTAssertEqual(result, enabled)
    }

    func testSetQUICHandlingModeUpdatesLegacyBlockCompatibility() async {
        await sut.setQUICHandlingMode(.block)

        let blockMode = await sut.quicHandlingMode
        let blockFlag = await sut.blockQUIC
        XCTAssertEqual(blockMode, .block)
        XCTAssertTrue(blockFlag)

        await sut.setQUICHandlingMode(.intercept)

        let interceptMode = await sut.quicHandlingMode
        let interceptBlockFlag = await sut.blockQUIC
        XCTAssertEqual(interceptMode, .intercept)
        XCTAssertFalse(interceptBlockFlag)
    }

    // MARK: - Network Framework MITM Configuration Tests

    func testSetEnableNetworkFrameworkMITM() async {
        // Given
        let enabled = false

        // When
        await sut.setEnableNetworkFrameworkMITM(enabled)
        let result = await sut.enableNetworkFrameworkMITM

        // Then
        XCTAssertEqual(result, enabled)
    }

    func testSetEnableNetworkFrameworkMITMTrue() async {
        // Given
        let enabled = true

        // When
        await sut.setEnableNetworkFrameworkMITM(enabled)
        let result = await sut.enableNetworkFrameworkMITM

        // Then
        XCTAssertEqual(result, enabled)
    }

    // MARK: - Configuration Snapshot Tests

    func testGetCurrentConfigReturnsSnapshot() async {
        // Given / When
        let snapshot = await sut.getCurrentConfig()

        // Then
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot.rolloutStage, "production")
        XCTAssertEqual(snapshot.mitmAllowlist, ["*"])
        XCTAssertEqual(snapshot.quicHandlingMode, QUICHandlingMode.intercept.rawValue)
        XCTAssertFalse(snapshot.blockQUIC)
        XCTAssertTrue(snapshot.enableNetworkFrameworkMITM)
    }

    func testSnapshotReflectsCurrentConfiguration() async {
        // Given
        await sut.setRolloutStage(.beta)
        await sut.setEnableRawCapture(true)
        await sut.setMaxRawCaptureSize(50_000_000)
        await sut.setMitmAllowlist(["example.com"])
        await sut.setBlockQUIC(false)

        // When
        let snapshot = await sut.getCurrentConfig()

        // Then
        XCTAssertEqual(snapshot.rolloutStage, "beta")
        XCTAssertTrue(snapshot.enableRawCapture)
        XCTAssertEqual(snapshot.maxRawCaptureSize, 50_000_000)
        XCTAssertEqual(snapshot.mitmAllowlist, ["example.com"])
        XCTAssertFalse(snapshot.blockQUIC)
    }

    func testSnapshotToDictionary() async {
        // Given
        let snapshot = await sut.getCurrentConfig()

        // When
        let dict = snapshot.toDictionary()

        // Then
        XCTAssertNotNil(dict["enableRobustReassembly"])
        XCTAssertNotNil(dict["enableMetrics"])
        XCTAssertNotNil(dict["enableDebugLogging"])
        XCTAssertNotNil(dict["rolloutStage"])
        XCTAssertNotNil(dict["enableRawCapture"])
        XCTAssertNotNil(dict["maxRawCaptureSize"])
        XCTAssertNotNil(dict["mitmAllowlist"])
        XCTAssertNotNil(dict["quicHandlingMode"])
        XCTAssertNotNil(dict["blockQUIC"])
        XCTAssertNotNil(dict["enableNetworkFrameworkMITM"])
    }

    // MARK: - Reset to Defaults Tests

    func testResetToDefaultsRestoresConfiguration() async {
        // Given
        await sut.setRolloutStage(.disabled)
        await sut.setEnableRawCapture(true)
        await sut.setMaxRawCaptureSize(50_000_000)
        await sut.setMitmAllowlist(["test.com"])
        await sut.setBlockQUIC(false)
        await sut.setEnableNetworkFrameworkMITM(false)

        // When
        await sut.resetToDefaults()

        // Then
        let stage = await sut.rolloutStage
        let rawCapture = await sut.enableRawCapture
        let maxSize = await sut.maxRawCaptureSize
        let allowlist = await sut.mitmAllowlist
        let blockQUIC = await sut.blockQUIC
        let nwMITM = await sut.enableNetworkFrameworkMITM

        XCTAssertEqual(stage, .production)
        XCTAssertFalse(rawCapture)
        XCTAssertEqual(maxSize, 10_485_760)
        XCTAssertEqual(allowlist, ["*"])
        XCTAssertFalse(blockQUIC)
        XCTAssertTrue(nwMITM)
    }

    // MARK: - Rollout Stage Codable Tests

    func testRolloutStageRawValues() {
        // Given / When / Then
        XCTAssertEqual(HardeningConfig.RolloutStage.disabled.rawValue, "disabled")
        XCTAssertEqual(HardeningConfig.RolloutStage.internalStage.rawValue, "internal")
        XCTAssertEqual(HardeningConfig.RolloutStage.beta.rawValue, "beta")
        XCTAssertEqual(HardeningConfig.RolloutStage.production.rawValue, "production")
    }

    func testRolloutStageInitFromRawValue() {
        // Given / When / Then
        XCTAssertEqual(HardeningConfig.RolloutStage(rawValue: "disabled"), .disabled)
        XCTAssertEqual(HardeningConfig.RolloutStage(rawValue: "internal"), .internalStage)
        XCTAssertEqual(HardeningConfig.RolloutStage(rawValue: "beta"), .beta)
        XCTAssertEqual(HardeningConfig.RolloutStage(rawValue: "production"), .production)
        XCTAssertNil(HardeningConfig.RolloutStage(rawValue: "invalid"))
    }

    // MARK: - Edge Cases

    func testSetMitmAllowlistWithWildcard() async {
        // Given
        let allowlist = ["*"]

        // When
        await sut.setMitmAllowlist(allowlist)
        let result = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(result, ["*"])
    }

    func testSetMitmAllowlistWithUnicodeDomains() async {
        // Given
        let allowlist = ["例え.jp", "тест.рф"]

        // When
        await sut.setMitmAllowlist(allowlist)
        let result = await sut.mitmAllowlist

        // Then
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains("例え.jp"))
        XCTAssertTrue(result.contains("тест.рф"))
    }

    func testMultipleConfigurationChanges() async {
        // Given
        let configurations = [
            (stage: HardeningConfig.RolloutStage.beta, rawCapture: true, blockQUIC: false),
            (stage: HardeningConfig.RolloutStage.production, rawCapture: false, blockQUIC: true),
            (stage: HardeningConfig.RolloutStage.disabled, rawCapture: false, blockQUIC: false)
        ]

        for config in configurations {
            // When
            await sut.setRolloutStage(config.stage)
            await sut.setEnableRawCapture(config.rawCapture)
            await sut.setBlockQUIC(config.blockQUIC)

            // Then
            let stage = await sut.rolloutStage
            let rawCapture = await sut.enableRawCapture
            let blockQUIC = await sut.blockQUIC

            XCTAssertEqual(stage, config.stage)
            XCTAssertEqual(rawCapture, config.rawCapture)
            XCTAssertEqual(blockQUIC, config.blockQUIC)
        }
    }
}
