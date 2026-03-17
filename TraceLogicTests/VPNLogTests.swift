//
//  VPNLogTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

#if targetEnvironment(simulator)
import XCTest

final class VPNLogTests: XCTestCase {
    func testVPNLogTestsSkippedOnSimulator() throws {
        throw XCTSkip("VPNLog lives in the TraceVPN app extension, which is not linked into simulator unit tests.")
    }
}
#else
import XCTest
import OSLog
@testable import TraceVPNKit
@testable import TraceCore

final class VPNLogTests: XCTestCase {

    // MARK: - Logger Instance Tests

    func testTunnelLoggerExists() {
        XCTAssertNotNil(VPNLog.tunnel)
    }

    func testProxyLoggerExists() {
        XCTAssertNotNil(VPNLog.proxy)
    }

    func testCertificateLoggerExists() {
        XCTAssertNotNil(VPNLog.certificate)
    }

    func testConfigLoggerExists() {
        XCTAssertNotNil(VPNLog.config)
    }

    // MARK: - LogEvent Factory Method Tests

    func testVPNTunnelEventFactory() {
        let event = LogEvent.vpnTunnel("start")
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.tunnel_start"), "Event should contain domain.action pattern")
        XCTAssertTrue(formatted.contains("event=vpn.tunnel_start"))
    }

    func testVPNProxyEventFactory() {
        let event = LogEvent.vpnProxy("start")
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.proxy_start"))
        XCTAssertTrue(formatted.contains("event=vpn.proxy_start"))
    }

    func testVPNCertificateEventFactory() {
        let event = LogEvent.vpnCertificate("load")
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.ca_load"))
        XCTAssertTrue(formatted.contains("event=vpn.ca_load"))
    }

    func testVPNConfigEventFactory() {
        let event = LogEvent.vpnConfig("apply")
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.network_apply"))
        XCTAssertTrue(formatted.contains("event=vpn.network_apply"))
    }

    // MARK: - Event Builder Chain Tests

    func testTunnelStartEventWithSuccess() {
        let event = LogEvent.vpnTunnel("start")
            .success()
        let formatted = event.description

        XCTAssertTrue(formatted.contains("outcome=success"))
    }

    func testTunnelStopEventWithFailure() {
        let event = LogEvent.vpnTunnel("stop")
            .failure()
        let formatted = event.description

        XCTAssertTrue(formatted.contains("outcome=failure"))
    }

    func testProxyStartWithDuration() {
        let start = Date()
        let event = LogEvent.vpnProxy("start")
            .success()
            .duration(since: start)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("outcome=success"))
        XCTAssertTrue(formatted.contains("duration_ms="))
    }

    func testCertificateLoadWithMetadata() {
        let event = LogEvent.vpnCertificate("load")
            .success()
            .with("fingerprint", value: "abc123", privacy: .hash)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("outcome=success"))
        XCTAssertTrue(formatted.contains("fingerprint="))
    }

    func testConfigUpdateWithMultipleFields() {
        let event = LogEvent.vpnConfig("update")
            .success()
            .with("quic_blocking", value: true, privacy: .public)
            .with("mitm_enabled", value: false, privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("quic_blocking=true"))
        XCTAssertTrue(formatted.contains("mitm_enabled=false"))
    }

    // MARK: - Event Action Name Tests

    func testTunnelActionNames() {
        let actions = ["start", "stop", "heartbeat", "state_change"]

        for action in actions {
            let event = LogEvent.vpnTunnel(action)
            let formatted = event.description
            XCTAssertTrue(formatted.contains("vpn.tunnel_\(action)"), "Should create correct action: tunnel_\(action)")
        }
    }

    func testProxyActionNames() {
        let actions = ["start", "stop", "config_update"]

        for action in actions {
            let event = LogEvent.vpnProxy(action)
            let formatted = event.description
            XCTAssertTrue(formatted.contains("vpn.proxy_\(action)"), "Should create correct action: proxy_\(action)")
        }
    }

    func testCertificateActionNames() {
        let actions = ["load", "trust_check", "cleanup"]

        for action in actions {
            let event = LogEvent.vpnCertificate(action)
            let formatted = event.description
            XCTAssertTrue(formatted.contains("vpn.ca_\(action)"), "Should create correct action: ca_\(action)")
        }
    }

    func testConfigActionNames() {
        let actions = ["apply", "configure", "update"]

        for action in actions {
            let event = LogEvent.vpnConfig(action)
            let formatted = event.description
            XCTAssertTrue(formatted.contains("vpn.network_\(action)"), "Should create correct action: network_\(action)")
        }
    }

    // MARK: - Complex Event Scenarios

    func testTunnelStartWithInvocationID() {
        let invocationID = UUID().uuidString
        let event = LogEvent.vpnTunnel("start")
            .success()
            .with("id", value: invocationID, privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("id=\(invocationID)"))
        XCTAssertTrue(formatted.contains("outcome=success"))
    }

    func testProxyStartWithHostAndPort() {
        let event = LogEvent.vpnProxy("start")
            .success()
            .with("host", value: "127.0.0.1", privacy: .public)
            .with("port", value: 8888, privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("host=127.0.0.1"))
        XCTAssertTrue(formatted.contains("port=8888"))
    }

    func testCertificateLoadFailureWithError() {
        let error = NSError(domain: "TestDomain", code: 1, userInfo: nil)
        let event = LogEvent.vpnCertificate("load")
            .failure()
            .with("error", value: error.localizedDescription, privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("outcome=failure"))
        XCTAssertTrue(formatted.contains("error="))
    }

    func testConfigApplyWithNetworkSettings() {
        let event = LogEvent.vpnConfig("apply")
            .success()
            .with("dns_servers", value: "8.8.8.8,8.8.4.4", privacy: .public)
            .with("proxy_enabled", value: true, privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("dns_servers="))
        XCTAssertTrue(formatted.contains("proxy_enabled=true"))
    }

    // MARK: - Privacy Annotation Tests

    func testPublicPrivacyAnnotation() {
        let event = LogEvent.vpnTunnel("start")
            .with("id", value: "test-123", privacy: .public)
        let formatted = event.description

        // Public values should be visible in logs
        XCTAssertTrue(formatted.contains("id=test-123"))
    }

    func testPrivateHashAnnotation() {
        let event = LogEvent.vpnCertificate("load")
            .with("fingerprint", value: "secret-fingerprint", privacy: .hash)
        let formatted = event.description

        // Should have fingerprint field (exact value depends on privacy handling)
        XCTAssertTrue(formatted.contains("fingerprint="))
    }

    // MARK: - Error Handling Tests

    func testEventWithEmptyAction() {
        let event = LogEvent.vpnTunnel("")
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.tunnel_"))
    }

    func testEventWithSpecialCharactersInAction() {
        let event = LogEvent.vpnProxy("start-with-hyphen")
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.proxy_start-with-hyphen"))
    }

    // MARK: - Real-World Usage Scenarios

    func testTunnelHeartbeatEvent() {
        let event = LogEvent.vpnTunnel("heartbeat")
            .with("active_connections", value: 42, privacy: .public)
            .with("memory_mb", value: 128, privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.tunnel_heartbeat"))
        XCTAssertTrue(formatted.contains("active_connections=42"))
        XCTAssertTrue(formatted.contains("memory_mb=128"))
    }

    func testProxyConfigUpdateEvent() {
        let event = LogEvent.vpnProxy("config_update")
            .success()
            .with("mitm_domains", value: "example.com", privacy: .public)
            .with("capture_enabled", value: true, privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.proxy_config_update"))
        XCTAssertTrue(formatted.contains("outcome=success"))
    }

    func testCertificateTrustCheckEvent() {
        let event = LogEvent.vpnCertificate("trust_check")
            .success()
            .with("trusted", value: true, privacy: .public)
            .with("mitm_enabled", value: true, privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.ca_trust_check"))
        XCTAssertTrue(formatted.contains("trusted=true"))
        XCTAssertTrue(formatted.contains("mitm_enabled=true"))
    }

    func testNetworkSettingsApplyEvent() {
        let start = Date()
        let event = LogEvent.vpnConfig("apply")
            .success()
            .duration(since: start)
            .with("mode", value: "proxy-only", privacy: .public)
        let formatted = event.description

        XCTAssertTrue(formatted.contains("vpn.network_apply"))
        XCTAssertTrue(formatted.contains("outcome=success"))
        XCTAssertTrue(formatted.contains("mode=proxy-only"))
    }
}
#endif
