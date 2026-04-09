//
//  TunnelProviderConfigurationTests.swift
//  TraceTests
//
//  Created by Justin on 2026/03/17.
//

@testable import TraceCore
@testable import TraceProxy
@testable import TraceVPNKit
import XCTest

final class TunnelProviderConfigurationTests: XCTestCase {
    func testProxyOnlyRawCaptureStaysOnProxyPlane() {
        let configuration = makeConfiguration(
            captureMode: .proxyOnly,
            enableRawCapture: true
        )

        XCTAssertTrue(configuration.proxyRawCaptureEnabled)
        XCTAssertFalse(configuration.packetCaptureEnabled)
    }

    func testFullTunnelRawCaptureMovesToPacketPlane() {
        let configuration = makeConfiguration(
            captureMode: .fullTunnel,
            enableRawCapture: true
        )

        XCTAssertFalse(configuration.proxyRawCaptureEnabled)
        XCTAssertTrue(configuration.packetCaptureEnabled)
    }

    func testHybridFullTunnelEnablesTransparentTCPMITM() {
        let configuration = makeConfiguration(
            captureMode: .fullTunnel,
            enableRawCapture: false,
            fullTunnelHybridTCPMITMEnabled: true
        )

        XCTAssertTrue(configuration.transparentTCPMITMEnabled)
    }

    func testDualMITMMaintainsTransparentTCPMITMWithoutHybridFlag() {
        let configuration = makeConfiguration(
            captureMode: .fullTunnelDualMITM,
            enableRawCapture: false,
            fullTunnelHybridTCPMITMEnabled: false
        )

        XCTAssertTrue(configuration.transparentTCPMITMEnabled)
    }

    func testInvalidHardeningQUICModeFallsBackToLegacyBlockFlag() {
        let configuration = makeConfiguration(
            captureMode: .proxyOnly,
            enableRawCapture: false,
            quicHandlingMode: "not_a_mode",
            blockQUIC: true
        )

        XCTAssertEqual(configuration.hardening.quicHandlingMode, .block)
    }

    func testProxyIngressUsesCanonicalFlags() {
        let configuration = makeConfiguration(
            captureMode: .fullTunnelDualMITM,
            enableRawCapture: false,
            dualMITMPolicyEngineEnforcedProxy: true,
            dualMITMHttp2MITMEnabled: true,
            dualMITMStrictEnforcementHardFail: false
        )

        XCTAssertEqual(
            configuration.proxyIngress,
            TunnelProxyIngressConfiguration(
                transparentTLSModeEnabled: true,
                dualMITMPolicyEngineEnforcedProxy: true,
                dualMITMHttp2MITMEnabled: true,
                dualMITMStrictEnforcementHardFail: false
            )
        )
        XCTAssertEqual(
            configuration.proxyIngress.asDictionary()["transparentTLSModeEnabled"] as? Bool,
            true
        )
        XCTAssertNil(configuration.proxyIngress.asDictionary()["enableTransparentTLSMode"])
    }

    private func makeConfiguration(
        captureMode: CaptureMode,
        enableRawCapture: Bool,
        fullTunnelHybridTCPMITMEnabled: Bool = false,
        quicHandlingMode: String = QUICHandlingMode.intercept.rawValue,
        blockQUIC: Bool = false,
        dualMITMPolicyEngineEnforcedProxy: Bool = false,
        dualMITMHttp2MITMEnabled: Bool = false,
        dualMITMStrictEnforcementHardFail: Bool = true
    ) -> TunnelProviderConfiguration {
        var capture = CaptureConfiguration.default
        capture.captureMode = captureMode
        capture.fullTunnelHybridTCPMITMEnabled = fullTunnelHybridTCPMITMEnabled

        let hardeningSnapshot = HardeningConfigSnapshot(
            enableRobustReassembly: true,
            enableMetrics: true,
            enableDebugLogging: false,
            rolloutStage: "production",
            enableRawCapture: enableRawCapture,
            maxRawCaptureSize: 1024,
            mitmAllowlist: ["*"],
            quicHandlingMode: quicHandlingMode,
            blockQUIC: blockQUIC,
            enableNIOMITM: true,
            enableNetworkFrameworkMITM: true,
            dualMITMPolicyEngineShadow: false,
            dualMITMPolicyEngineEnforcedTCP: false,
            dualMITMPolicyEngineEnforcedProxy: dualMITMPolicyEngineEnforcedProxy,
            dualMITMPolicyEngineEnforcedQUIC: false,
            dualMITMHttp2MITMEnabled: dualMITMHttp2MITMEnabled,
            dualMITMStrictEnforcementHardFail: dualMITMStrictEnforcementHardFail,
            enableStreamInterceptionV2: false
        )

        return TunnelProviderConfiguration(
            capture: capture,
            hardeningSnapshot: hardeningSnapshot,
            environment: TunnelProviderEnvironment(
                proxy: .init(host: "127.0.0.1", port: 8888),
                localSocks: .init(host: "127.0.0.1", preferredPort: 0),
                fullTunnelMTU: 1400,
                transparentMITMPorts: [80, 443]
            )
        )
    }
}
