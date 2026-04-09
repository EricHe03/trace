//
//  PacketTunnelProvider+NetworkSetup.swift
//  TraceVPN
//
//  Created by Justin on 2026/03/06.
//

import Darwin
import Foundation
import Network
import NetworkExtension
import OSLog
import TraceCore
import TraceProxy
import TraceSecurity

extension PacketTunnelProvider {
    func configureNetworkSettings(using config: CaptureConfiguration) async throws {
        let modeLabel = captureModeLogLabel(config.captureMode)
        VPNLog.config.debug("event=vpn.network_settings_begin mode=\(modeLabel, privacy: .public)")
        await runtimeState.appendEventLog(
            type: "network_settings",
            msg: "begin mode=\(modeLabel) dns_servers=\(config.fullTunnelDNSServers.count) ipv6=\(config.fullTunnelIPv6Enabled)"
        )

        let networkSettings = buildNetworkSettings(using: config)
        if config.captureMode.usesPacketTunnelRouting {
            await runtimeState.appendEventLog(
                type: "dns_config",
                msg: "mode=\(modeLabel) servers=\(config.fullTunnelDNSServers.count) search_domains=\(config.fullTunnelSearchDomains.count)"
            )
        } else {
            await runtimeState.appendEventLog(type: "dns_config", msg: "mode=system_default")
        }

        VPNLog.config.info(
            "event=vpn.network_settings_configured mode=\(modeLabel, privacy: .public) proxy_enabled=\(config.captureMode.usesSystemHTTPProxy)"
        )
        await runtimeState.appendEventLog(
            type: "network_settings",
            msg: "configured mode=\(modeLabel) proxy_enabled=\(config.captureMode.usesSystemHTTPProxy)"
        )

        VPNLog.config.debug("event=vpn.network_settings_apply mode=\(modeLabel, privacy: .public)")
        await runtimeState.appendEventLog(
            type: "network_settings",
            msg: "apply mode=\(modeLabel)"
        )

        do {
            try await applyTunnelNetworkSettings(networkSettings)
            await runtimeState.appendEventLog(
                type: "network_settings",
                msg: "outcome=success mode=\(modeLabel)"
            )
        } catch {
            await runtimeState.appendEventLog(
                type: "network_settings",
                msg: "outcome=failure mode=\(modeLabel) error=\(error.localizedDescription)"
            )
            throw PacketTunnelProviderError.networkSettingsFailed(underlying: error)
        }
    }

    func captureModeLogLabel(_ mode: CaptureMode) -> String {
        switch mode {
        case .proxyOnly:
            "proxy_only"
        case .fullTunnel:
            "full_tunnel"
        case .fullTunnelDualMITM:
            "full_tunnel_dual_mitm"
        }
    }

    func buildNetworkSettings(using config: CaptureConfiguration) -> NEPacketTunnelNetworkSettings {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

        switch config.captureMode {
        case .proxyOnly:
            networkSettings.dnsSettings = nil
            VPNLog.config.debug("event=vpn.dns_config mode=system_default")

            let ipv4Settings = NEIPv4Settings(
                addresses: [tunnelLocalAddress],
                subnetMasks: [tunnelSubnetMask]
            )
            ipv4Settings.includedRoutes = []
            ipv4Settings.excludedRoutes = []
            networkSettings.ipv4Settings = ipv4Settings
            networkSettings.ipv6Settings = nil

        case .fullTunnel, .fullTunnelDualMITM:
            if let dnsSettings = buildDNSSettings(using: config) {
                networkSettings.dnsSettings = dnsSettings
                VPNLog.config.debug(
                    "event=vpn.dns_config mode=\(self.captureModeLogLabel(config.captureMode), privacy: .public) servers=\(dnsSettings.servers.count)"
                )
            } else {
                networkSettings.dnsSettings = nil
                VPNLog.config.debug(
                    "event=vpn.dns_config mode=\(self.captureModeLogLabel(config.captureMode), privacy: .public) servers=none"
                )
            }

            let ipv4Settings = NEIPv4Settings(
                addresses: [tunnelLocalAddress],
                subnetMasks: [tunnelSubnetMask]
            )
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
            let excluded = buildExcludedRoutes(using: config)
            if !excluded.ipv4.isEmpty {
                ipv4Settings.excludedRoutes = excluded.ipv4
            }
            networkSettings.ipv4Settings = ipv4Settings

            if config.fullTunnelIPv6Enabled {
                let ipv6Settings = NEIPv6Settings(
                    addresses: ["fc00::1"],
                    networkPrefixLengths: [64]
                )
                ipv6Settings.includedRoutes = [NEIPv6Route.default()]
                if !excluded.ipv6.isEmpty {
                    ipv6Settings.excludedRoutes = excluded.ipv6
                }
                networkSettings.ipv6Settings = ipv6Settings
            } else {
                VPNLog.config.warning("event=vpn.ipv6_route_config outcome=skipped reason=disabled")
                networkSettings.ipv6Settings = nil
            }
        }

        if config.captureMode.usesSystemHTTPProxy {
            let proxy = NEProxySettings()
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            proxy.httpServer = NEProxyServer(address: proxyHost, port: Int(proxyPort))
            proxy.httpsServer = NEProxyServer(address: proxyHost, port: Int(proxyPort))
            proxy.excludeSimpleHostnames = false
            proxy.matchDomains = [""]
            proxy.exceptionList = [
                "localhost",
                "*.local",
                "127.0.0.1",
                "10.*",
                "172.16.*", "172.17.*", "172.18.*", "172.19.*",
                "172.20.*", "172.21.*", "172.22.*", "172.23.*",
                "172.24.*", "172.25.*", "172.26.*", "172.27.*",
                "172.28.*", "172.29.*", "172.30.*", "172.31.*",
                "192.168.*"
            ]
            networkSettings.proxySettings = proxy
        } else {
            networkSettings.proxySettings = nil
        }

        if config.captureMode.usesPacketTunnelRouting {
            networkSettings.mtu = NSNumber(value: fullTunnelMTU)
        }

        return networkSettings
    }

    func buildDNSSettings(using config: CaptureConfiguration) -> NEDNSSettings? {
        guard !config.fullTunnelDNSServers.isEmpty else { return nil }
        let dns = NEDNSSettings(servers: config.fullTunnelDNSServers)
        if !config.fullTunnelSearchDomains.isEmpty {
            dns.searchDomains = config.fullTunnelSearchDomains
        }
        return dns
    }

    func buildExcludedRoutes(using config: CaptureConfiguration) -> (ipv4: [NEIPv4Route], ipv6: [NEIPv6Route]) {
        var ipv4Targets = Set<String>()
        var ipv6Targets = Set<String>()

        if config.captureMode.supportsCustomSocksServer {
            let socksHost = config.fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
            if !socksHost.isEmpty {
                addExcludedHost(socksHost, ipv4: &ipv4Targets, ipv6: &ipv6Targets)
            }
        }

        for server in config.fullTunnelDNSServers {
            let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            addExcludedHost(trimmed, ipv4: &ipv4Targets, ipv6: &ipv6Targets)
        }

        let ipv4Routes = ipv4Targets.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
        let ipv6Routes = ipv6Targets.map { NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128) }
        if !ipv4Routes.isEmpty || !ipv6Routes.isEmpty {
            VPNLog.config.debug("event=vpn.route_exclusions_configured ipv4=\(ipv4Routes.count) ipv6=\(ipv6Routes.count)")
        }
        return (ipv4: ipv4Routes, ipv6: ipv6Routes)
    }

    func addExcludedHost(
        _ host: String,
        ipv4: inout Set<String>,
        ipv6: inout Set<String>
    ) {
        if IPv4Address(host) != nil {
            guard !isLoopbackIPv4(host) else { return }
            ipv4.insert(host)
            return
        }
        if IPv6Address(host) != nil {
            ipv6.insert(host)
            return
        }

        let resolved = resolveIPAddresses(for: host)
        ipv4.formUnion(resolved.ipv4.filter { !isLoopbackIPv4($0) })
        ipv6.formUnion(resolved.ipv6)
    }

    func isLoopbackIPv4(_ address: String) -> Bool {
        guard let ipv4 = IPv4Address(address) else { return false }
        return ipv4.rawValue.first == 127
    }

    func resolveIPAddresses(for host: String) -> (ipv4: [String], ipv6: [String]) {
        addressResolutionLock.lock()
        if let cached = addressResolutionCache[host] {
            addressResolutionLock.unlock()
            return cached
        }
        addressResolutionLock.unlock()

        let result = resolveIPAddressesWithTimeout(for: host, timeoutSeconds: 1.0)

        addressResolutionLock.lock()
        addressResolutionCache[host] = result
        addressResolutionLock.unlock()
        return result
    }

    func resolveIPAddressesWithTimeout(
        for host: String,
        timeoutSeconds: TimeInterval
    ) -> (ipv4: [String], ipv6: [String]) {
        final class Box: @unchecked Sendable {
            var value: (ipv4: [String], ipv6: [String]) = ([], [])
        }

        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        addressResolutionQueue.async {
            box.value = self.resolveIPAddressesBlocking(for: host)
            semaphore.signal()
        }

        let waited = semaphore.wait(timeout: .now() + timeoutSeconds)
        if waited == .timedOut {
            let hostHash = LogRedaction.hash(host)
            VPNLog.config.warning("event=vpn.host_resolution outcome=timeout host_hash=\(hostHash) timeout_s=\(timeoutSeconds)")
            return ([], [])
        }

        return box.value
    }

    func resolveIPAddressesBlocking(for host: String) -> (ipv4: [String], ipv6: [String]) {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            return (ipv4: [], ipv6: [])
        }
        defer { freeaddrinfo(first) }

        var ipv4 = Set<String>()
        var ipv6 = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            if info.pointee.ai_family == AF_INET {
                var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(buffer.count)) != nil {
                    ipv4.insert(String(cString: buffer))
                }
            } else if info.pointee.ai_family == AF_INET6 {
                var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr.sin6_addr, &buffer, socklen_t(buffer.count)) != nil {
                    ipv6.insert(String(cString: buffer))
                }
            }
            current = info.pointee.ai_next
        }

        return (ipv4: Array(ipv4), ipv6: Array(ipv6))
    }

    func applyTunnelNetworkSettings(_ settings: NEPacketTunnelNetworkSettings) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func startProxyServer(using runtimeConfiguration: TunnelProviderConfiguration) async throws {
        VPNLog.proxy.info("event=vpn.proxy_server_init_begin")

        let allowlist = runtimeConfiguration.hardening.mitmAllowlist
        let requestedMitmEnabled = runtimeConfiguration.hardening.enableNIOMITM
        let caTrusted = CertificateManager.shared.isRootCATrusted()

        VPNLog.proxy.info("event=vpn.proxy_server_config allowlist_count=\(allowlist.count) mitm_requested=\(requestedMitmEnabled) ca_trusted=\(caTrusted)")

        let mitmEnabled = requestedMitmEnabled && caTrusted

        VPNLog.proxy.info("event=vpn.proxy_server_mitm_decision effective_mitm_enabled=\(mitmEnabled)")

        if requestedMitmEnabled && !caTrusted {
            VPNLog.certificate.warning("event=vpn.ca_not_trusted_mitm_disabled reason=ca_not_trusted mitm_requested=\(requestedMitmEnabled)")
            await runtimeState.appendEventLog(
                type: "mitm_disabled",
                msg: "reason=ca_not_trusted"
            )
        }

        VPNLog.proxy.info("event=vpn.proxy_server_starting port=\(self.proxyPort) mitm_enabled=\(mitmEnabled)")

        do {
            try await runtimeState.startProxyServer(
                port: self.proxyPort,
                allowlist: allowlist,
                mitmEnabled: mitmEnabled
            )
            VPNLog.proxy.info("event=vpn.proxy_server_started outcome=success port=\(self.proxyPort)")
        } catch {
            VPNLog.proxy.error("event=vpn.proxy_server_start_failed outcome=failure port=\(self.proxyPort) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
