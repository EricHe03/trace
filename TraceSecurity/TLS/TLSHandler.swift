//
//  TLSHandler.swift
//  TraceSecurity
//
//  Created by Justin on 2026/01/10.
//

import CommonCrypto
import Darwin
import Foundation
import Network
import Security
@preconcurrency import TraceCore

/// Manages TLS handshakes and encryption for HTTPS interception.
public class TLSHandler {
    private static let lastErrorQueue = DispatchQueue(label: "com.trace.tls.lasterror", attributes: .concurrent)
    // Rule: Diagnostics are best-effort; callers must handle nil when no failure detail is available.
    private nonisolated(unsafe) static var _lastServerTLSOptionsError: String?
    private static let debugSampler = LogSampler()
    private static let warningThrottle = LogThrottle()

    private static func debugSampled(
        _ key: String,
        first: Int = 3,
        every: Int = 200,
        _ message: () -> String
    ) {
        if debugSampler.shouldLog(key: key, first: first, every: every) {
            TLSLog.debug(message())
        }
    }

    private static func debugSampled(
        _ key: String,
        first: Int = 3,
        every: Int = 200,
        _ event: () -> LogEvent
    ) {
        if debugSampler.shouldLog(key: key, first: first, every: every) {
            TLSLog.debug(event())
        }
    }

    private static func sampledDebug(
        key: String,
        event: LogEvent,
        first: Int = 2,
        every: Int = 50
    ) {
        if debugSampler.shouldLog(key: key, first: first, every: every) {
            TLSLog.debug(event)
        }
    }

    private static func describeOSStatus(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(status) (\(message))"
    }

    /// Returns the most recent server-side TLS options error (best-effort).
    /// Useful to surface a concrete reason when TLS options creation fails.
    public static func lastServerTLSOptionsError() -> String? {
        lastErrorQueue.sync { _lastServerTLSOptionsError }
    }

    private static func setLastServerTLSOptionsError(_ message: String?) {
        // Rule: Updates must be synchronous so callers can include details in failure paths.
        lastErrorQueue.sync(flags: .barrier) {
            _lastServerTLSOptionsError = message
        }
    }

    /// Defines the ALPN protocols offered during negotiation.
    public static let supportedALPNProtocols: [String] = ["h2", "http/1.1"]

    private nonisolated(unsafe) static var certificateCache: [String: CachedCertificate] = [:]
    private struct LeafTrustPreflight: Sendable {
        let ok: Bool
        let detail: String?
        let expiresAt: Date
    }

    // Rationale: Leaf trust evaluation can be moderately expensive; cache results briefly to avoid
    // repeating evaluations during bursts of CONNECTs to the same host.
    private nonisolated(unsafe) static var leafTrustPreflightCache: [String: LeafTrustPreflight] = [:]
    private static let leafTrustPreflightTTL: TimeInterval = 10 * 60
    private static let cacheQueue = DispatchQueue(label: "com.trace.tls.cache", attributes: .concurrent)
    public static let certificateLifetime: TimeInterval = 3600

    // MARK: - TLS Server (for client connections)

    /// Preflights whether we should bypass MITM for a domain based on local leaf trust evaluation.
    ///
    /// Discussion:
    /// Some domains (notably those with system-level pinning requirements) will never accept a
    /// user-installed Root CA. When we detect that our generated leaf fails trust evaluation,
    /// we should bypass MITM early (before performing expensive upstream TLS handshakes) and
    /// fall back to a passthrough tunnel.
    ///
    /// - Returns: A failure detail string (e.g. `leaf_trust_failed:...`) when MITM should be bypassed.
    ///            Returns `nil` when MITM can proceed.
    public static func preflightServerLeafTrust(for domain: String) -> String? {
        guard !domain.isEmpty else { return "leaf_trust_empty_domain" }

        if let cached = getLeafTrustPreflight(for: domain) {
            if cached.ok {
                setLastServerTLSOptionsError(nil)
                return nil
            }
            let detail = cached.detail ?? "leaf_trust_failed:unknown"
            setLastServerTLSOptionsError(detail)
            return detail
        }

        setLastServerTLSOptionsError(nil)

        if let cached = getCachedCertificate(for: domain), !cached.isExpired {
            if debugValidateLeafCertificate(certificate: cached.certificate, domain: domain) {
                setLeafTrustPreflight(ok: true, detail: nil, for: domain)
                return nil
            }
            let detail = lastServerTLSOptionsError() ?? "leaf_trust_failed:unknown"
            setLeafTrustPreflight(ok: false, detail: detail, for: domain)
            return detail
        }

        do {
            let (certificate, privateKey) = try CertificateManager.shared.generateCertificateForDomain(domain)
            let ok = debugValidateLeafCertificate(certificate: certificate, domain: domain)
            if ok {
                cacheCertificate(certificate: certificate, privateKey: privateKey, for: domain)
                setLeafTrustPreflight(ok: true, detail: nil, for: domain)
                return nil
            }
            let detail = lastServerTLSOptionsError() ?? "leaf_trust_failed:unknown"
            setLeafTrustPreflight(ok: false, detail: detail, for: domain)
            return detail
        } catch {
            let message = "leaf_trust_failed:certificate_generate_failed:\(String(describing: error))"
            setLastServerTLSOptionsError(message)
            setLeafTrustPreflight(ok: false, detail: message, for: domain)
            return message
        }
    }

    /// Creates TLS options for accepting client connections.
    /// Uses our generated certificate for the target domain (with caching).
    /// - Important: Returns `nil` when MITM should be bypassed (e.g., leaf fails local trust).
    public static func createServerTLSOptions(for domain: String, alpnProtocols: [String]? = nil) -> NWProtocolTLS.Options? {
        do {
            setLastServerTLSOptionsError(nil)
            sampledDebug(
                key: "tls.server_options.\(domain)",
                event: LogEvent.tls("server_options")
                    .outcome(.pending)
                    .with("domain", value: domain, privacy: .hash)
            )
            let alpn = alpnProtocols ?? supportedALPNProtocols

            if let cached = getCachedCertificate(for: domain), !cached.isExpired {
                let cacheAge = Date().timeIntervalSince(cached.createdAt)
                sampledDebug(
                    key: "tls.cache_hit.\(domain)",
                    event: LogEvent.tls("cache_hit")
                        .success()
                        .with("domain", value: domain, privacy: .hash)
                        .with("age_s", value: String(format: "%.1f", cacheAge))
                )

                // Rationale: Root CA trust can change, so revalidate cached leafs before reuse.
                // Optimization: Use a short-lived preflight cache to avoid repeating trust evaluation during bursts.
                let leafTrustOK: Bool
                if let preflight = getLeafTrustPreflight(for: domain) {
                    if preflight.ok {
                        leafTrustOK = true
                    } else {
                        let detail = preflight.detail ?? "leaf_trust_failed:unknown"
                        setLastServerTLSOptionsError(detail)
                        leafTrustOK = false
                    }
                } else {
                    let ok = debugValidateLeafCertificate(certificate: cached.certificate, domain: domain)
                    if ok {
                        setLeafTrustPreflight(ok: true, detail: nil, for: domain)
                    } else {
                        let detail = lastServerTLSOptionsError() ?? "leaf_trust_failed:unknown"
                        setLeafTrustPreflight(ok: false, detail: detail, for: domain)
                    }
                    leafTrustOK = ok
                }
                if !leafTrustOK {
                    if warningThrottle.shouldLog(key: "tls.leaf_trust.failure.\(domain)", minInterval: 30) {
                        SecurityLog.tls.warning(
                            LogEvent.tls("leaf_trust")
                                .failure()
                                .with("domain", value: domain, privacy: .hash)
                                .with("action", value: "bypass_mitm")
                        )
                    }
                    return nil
                }

                return createTLSOptions(
                    certificate: cached.certificate,
                    privateKey: cached.privateKey,
                    domain: domain,
                    replaceExistingIdentity: false,
                    alpnProtocols: alpn
                )
            }

            sampledDebug(
                key: "tls.cache_miss.\(domain)",
                event: LogEvent.tls("cache_miss")
                    .outcome(.pending)
                    .with("domain", value: domain, privacy: .hash)
            )

            sampledDebug(
                key: "tls.cert_generate.\(domain)",
                event: LogEvent.tls("cert_generate")
                    .outcome(.pending)
                    .with("domain", value: domain, privacy: .hash)
            )
            let (certificate, privateKey) = try CertificateManager.shared.generateCertificateForDomain(domain)

            let certSummary = SecCertificateCopySubjectSummary(certificate) as String? ?? "unknown"
            sampledDebug(
                key: "tls.cert_generate.\(domain)",
                event: LogEvent.tls("cert_generate")
                    .success()
                    .with("subject", value: certSummary, privacy: .hash)
            )

            // Rationale: Validate the generated leaf against system trust to detect CA or cert issues.
            let leafTrustOK = debugValidateLeafCertificate(certificate: certificate, domain: domain)
            if !leafTrustOK {
                // Rationale: Returning nil forces passthrough when the system rejects the leaf.
                if warningThrottle.shouldLog(key: "tls.leaf_trust.failure.\(domain)", minInterval: 30) {
                    SecurityLog.tls.warning(
                        LogEvent.tls("leaf_trust")
                            .failure()
                            .with("domain", value: domain, privacy: .hash)
                            .with("action", value: "bypass_mitm")
                    )
                }
                let detail = lastServerTLSOptionsError() ?? "leaf_trust_failed:unknown"
                setLeafTrustPreflight(ok: false, detail: detail, for: domain)
                return nil
            }

            cacheCertificate(certificate: certificate, privateKey: privateKey, for: domain)
            setLeafTrustPreflight(ok: true, detail: nil, for: domain)
            sampledDebug(
                key: "tls.cache_store.\(domain)",
                event: LogEvent.tls("cache_store")
                    .success()
                    .with("domain", value: domain, privacy: .hash)
                    .with("lifetime_s", value: certificateLifetime)
            )

            let options = createTLSOptions(
                certificate: certificate,
                privateKey: privateKey,
                domain: domain,
                replaceExistingIdentity: true,
                alpnProtocols: alpn
            )

            if options != nil {
                sampledDebug(
                    key: "tls.server_options.\(domain)",
                    event: LogEvent.tls("server_options")
                        .success()
                        .with("domain", value: domain, privacy: .hash)
                )
            } else {
                SecurityLog.tls.warning(
                    LogEvent.tls("server_options")
                        .failure()
                        .with("domain", value: domain, privacy: .hash)
                )
            }

            return options

        } catch {
            setLastServerTLSOptionsError("certificate_generate_failed:\(String(describing: error))")
            SecurityLog.tls.error(
                LogEvent.tls("server_options")
                    .failure()
                    .with("domain", value: domain, privacy: .hash)
                    .error(error)
            )
            return nil
        }
    }

    /// Runs a local trust evaluation for the generated leaf certificate.
    /// - Important: A failure means iOS clients will reject the MITM certificate.
    @discardableResult
    private static func debugValidateLeafCertificate(certificate: SecCertificate, domain: String) -> Bool {
        let certInfo = extractCertificateInfo(from: certificate)
        let fingerprintPrefix = certInfo?.fingerprint.prefix(16) ?? "unknown"
        sampledDebug(
            key: "tls.leaf_cert_info.\(domain)",
            event: LogEvent.tls("leaf_cert_info")
                .with("domain", value: domain, privacy: .hash)
                .with("fingerprint_prefix", value: fingerprintPrefix, privacy: .hash)
        )

        let policy = SecPolicyCreateSSL(true, domain as CFString)
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, policy, &trust)
        guard status == errSecSuccess, let trust else {
            SecurityLog.tls.error(
                LogEvent.tls("trust_create")
                    .failure()
                    .with("domain", value: domain, privacy: .hash)
                    .with("status", value: status)
            )
            setLastServerTLSOptionsError("leaf_trust_create_failed:\(status)")
            return false
        }
        SecTrustSetNetworkFetchAllowed(trust, false)

        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        if ok {
            sampledDebug(
                key: "tls.leaf_trust.\(domain)",
                event: LogEvent.tls("leaf_trust")
                    .success()
                    .with("domain", value: domain, privacy: .hash)
            )
            return true
        } else {
            let errorDesc = (error as Error?)?.localizedDescription ?? "unknown"
            SecurityLog.tls.error(
                LogEvent.tls("leaf_trust")
                    .failure()
                    .with("domain", value: domain, privacy: .hash)
                    .with("error", value: errorDesc)
            )
            setLastServerTLSOptionsError("leaf_trust_failed:\(errorDesc)")
            if let properties = SecTrustCopyProperties(trust) as? [[String: Any]] {
                for prop in properties {
                    if let title = prop[kSecPropertyTypeTitle as String] as? String,
                       let errorVal = prop[kSecPropertyTypeError as String] as? String {
                        sampledDebug(
                            key: "tls.trust_property.\(domain)",
                            event: LogEvent.tls("trust_property")
                                .with("title", value: title, privacy: .hash)
                                .with("error", value: errorVal, privacy: .hash)
                        )
                    }
                }
            }
            return false
        }
    }

    /// Creates TLS options from a certificate and private key.
    /// - Important: Includes the leaf and Root CA chain for validation.
    private static func createTLSOptions(
        certificate: SecCertificate,
        privateKey: SecKey,
        domain: String,
        replaceExistingIdentity: Bool,
        alpnProtocols: [String]
    ) -> NWProtocolTLS.Options? {
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.create_options outcome=pending domain=\(domain, privacy: .private(mask: .hash)) replace_identity=\(replaceExistingIdentity)"
            )
        }

        let options = NWProtocolTLS.Options()

        // Rationale: Network.framework requires a sec_identity_t, so build one via keychain import.
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.create_identity outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
            )
        }
        guard let identity = createIdentityFromCertificateAndKey(
            certificate: certificate,
            privateKey: privateKey,
            domain: domain,
            replaceExisting: replaceExistingIdentity
        ) else {
            setLastServerTLSOptionsError("identity_create_failed")
            SecurityLog.tls.error("event=tls.create_identity outcome=failure domain=\(domain, privacy: .private(mask: .hash))")
            return nil
        }
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.create_identity outcome=success domain=\(domain, privacy: .private(mask: .hash))"
            )
        }

        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.build_chain outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
            )
        }
        if let identityWithChain = createIdentityWithCertificateChain(
            baseIdentity: identity,
            leafCertificate: certificate
        ) {
            if TLSLog.verboseEnabled {
                SecurityLog.tls.debug(
                    "event=tls.build_chain outcome=success domain=\(domain, privacy: .private(mask: .hash))"
                )
            }
            sec_protocol_options_set_local_identity(
                options.securityProtocolOptions,
                identityWithChain
            )
        } else {
            // Rationale: Fall back to the base identity when the chain cannot be built.
            if TLSLog.verboseEnabled {
                SecurityLog.tls.debug(
                    "event=tls.build_chain outcome=fallback domain=\(domain, privacy: .private(mask: .hash))"
                )
            }
            sec_protocol_options_set_local_identity(
                options.securityProtocolOptions,
                identity
            )
        }

        sec_protocol_options_set_peer_authentication_required(
            options.securityProtocolOptions,
            false
        )
        TLSLog.debug("event=tls.config peer_auth=disabled mode=server")

        // Rule: Require TLS 1.2 or newer.
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv12
        )

        sec_protocol_options_set_max_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv13
        )
        TLSLog.debug("event=tls.config tls_min=1.2 tls_max=1.3")

        if alpnProtocols.isEmpty {
            TLSLog.debug("event=tls.alpn_config protocols=none")
        } else {
            for proto in alpnProtocols {
                proto.withCString { ptr in
                    sec_protocol_options_add_tls_application_protocol(
                        options.securityProtocolOptions,
                        ptr
                    )
                }
            }
            TLSLog.debug("event=tls.alpn_config protocols=\(alpnProtocols.joined(separator: ","))")
        }

        return options
    }

    /// Creates a sec_identity_t with the leaf and Root CA certificate chain.
    private static func createIdentityWithCertificateChain(
        baseIdentity: sec_identity_t,
        leafCertificate: SecCertificate
    ) -> sec_identity_t? {
        TLSLog.debug("event=tls.chain_build outcome=pending")

        guard let (rootCACert, _) = try? CertificateManager.shared.getRootCA() else {
            SecurityLog.tls.warning("event=tls.chain_build outcome=failure reason=no_root_ca")
            return nil
        }

        let rootCASummary = SecCertificateCopySubjectSummary(rootCACert) as String? ?? "unknown"
        let leafSummary = SecCertificateCopySubjectSummary(leafCertificate) as String? ?? "unknown"
        TLSLog.debug("event=tls.chain_build root_ca=\(rootCASummary) leaf=\(leafSummary)")

        guard let secIdentity = sec_identity_copy_ref(baseIdentity)?.takeRetainedValue() else {
            SecurityLog.tls.warning("event=tls.identity_extract outcome=failure")
            return nil
        }
        TLSLog.debug("event=tls.identity_extract outcome=success")

        // Rationale: The leaf certificate is already part of the identity; append the Root CA only.
        let certificateChain = [rootCACert] as CFArray
        TLSLog.debug("event=tls.chain_array outcome=success chain_count=1")

        guard let identityWithChain = sec_identity_create_with_certificates(secIdentity, certificateChain) else {
            SecurityLog.tls.warning("event=tls.identity_with_chain outcome=failure")
            return nil
        }

        TLSLog.debug("event=tls.identity_with_chain outcome=success")
        return identityWithChain
    }

    // MARK: - Certificate Caching

    private static func getCachedCertificate(for domain: String) -> CachedCertificate? {
        cacheQueue.sync {
            certificateCache[domain]
        }
    }

    private static func getLeafTrustPreflight(for domain: String) -> LeafTrustPreflight? {
        let key = domain.lowercased()
        let now = Date()
        return cacheQueue.sync {
            guard let entry = leafTrustPreflightCache[key] else { return nil }
            guard entry.expiresAt > now else { return nil }
            return entry
        }
    }

    private static func setLeafTrustPreflight(ok: Bool, detail: String?, for domain: String) {
        let key = domain.lowercased()
        let entry = LeafTrustPreflight(
            ok: ok,
            detail: detail,
            expiresAt: Date().addingTimeInterval(leafTrustPreflightTTL)
        )
        cacheQueue.async(flags: .barrier) {
            leafTrustPreflightCache[key] = entry
        }
    }

    private static func cacheCertificate(certificate: SecCertificate, privateKey: SecKey, for domain: String) {
        cacheQueue.async(flags: .barrier) {
            certificateCache[domain] = CachedCertificate(
                certificate: certificate,
                privateKey: privateKey,
                createdAt: Date()
            )
        }
    }

    /// Clears expired certificates from the cache.
    public static func clearExpiredCertificates() {
        cacheQueue.async(flags: .barrier) {
            let expiredDomains = certificateCache.filter { _, cached in
                cached.isExpired
            }.map(\.key)

            for domain in expiredDomains {
                deleteKeychainIdentity(for: domain)
            }

            certificateCache = certificateCache.filter { _, cached in
                !cached.isExpired
            }
            TLSLog.debug("event=tls.cache_clear_expired outcome=success count=\(expiredDomains.count)")
        }
    }

    /// Clears all cached certificates.
    public static func clearCertificateCache() {
        cacheQueue.async(flags: .barrier) {
            let domains = certificateCache.keys
            for domain in domains {
                deleteKeychainIdentity(for: domain)
            }
            certificateCache.removeAll()
            TLSLog.debug("event=tls.cache_clear_all outcome=success")
        }
    }

    // MARK: - TLS Client (for server connections)

    /// Creates TLS options for connecting to upstream servers.
    /// - Important: Uses system trust evaluation without pinning.
    public static func createClientTLSOptions(
        for domain: String,
        alpnProtocols: [String]? = nil,
        onTrustFailure: (@Sendable (_ domain: String, _ errorDescription: String, _ errorCode: Int) -> Void)? = nil
    ) -> NWProtocolTLS.Options {
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.client_options outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
            )
        }

        let options = NWProtocolTLS.Options()
        let alpn = alpnProtocols ?? supportedALPNProtocols

        if !domain.isEmpty {
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, domain)
            if TLSLog.verboseEnabled {
                SecurityLog.tls.debug(
                    "event=tls.sni_set domain=\(domain, privacy: .private(mask: .hash))"
                )
            }
        }

        // Rule: Use system trust evaluation; do not accept all certificates.
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, trust, complete in
                let queue = DispatchQueue.global(qos: .default)
                queue.async {
                    if TLSLog.verboseEnabled {
                        SecurityLog.tls.debug(
                            "event=tls.verify_server outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
                        )
                    }

                    var error: CFError?
                    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

                    let certCount = SecTrustGetCertificateCount(secTrust)
                    TLSLog.debug("event=tls.cert_chain chain_length=\(certCount)")

                    if certCount > 0, let serverCert = SecTrustGetCertificateAtIndex(secTrust, 0) {
                        let summary = SecCertificateCopySubjectSummary(serverCert) as String? ?? "unknown"
                        TLSLog.debug("event=tls.server_cert subject=\(summary)")
                    }

                    if !domain.isEmpty {
                        let policy = SecPolicyCreateSSL(true, domain as CFString)
                        SecTrustSetPolicies(secTrust, policy)
                        if TLSLog.verboseEnabled {
                            SecurityLog.tls.debug(
                                "event=tls.ssl_policy domain=\(domain, privacy: .private(mask: .hash))"
                            )
                        }
                    }

                    let trustResult = SecTrustEvaluateWithError(secTrust, &error)

                    if trustResult {
                        if TLSLog.verboseEnabled {
                            SecurityLog.tls.debug(
                                "event=tls.verify_server outcome=success domain=\(domain, privacy: .private(mask: .hash))"
                            )
                        }
                        complete(true)
                    } else {
                        let errorDesc = (error as Error?)?.localizedDescription ?? "unknown error"
                        let errorCode = (error as Error?)?._code ?? -1
                        onTrustFailure?(domain, errorDesc, errorCode)
                        if warningThrottle.shouldLog(key: "tls.verify_server.failure.\(domain)", minInterval: 30) {
                            SecurityLog.tls.warning("event=tls.verify_server outcome=failure domain=\(domain, privacy: .private(mask: .hash)) error=\(errorDesc) code=\(errorCode)")
                            SecurityLog.tls.error("event=tls.verify_server action=reject domain=\(domain, privacy: .private(mask: .hash))")
                        }
                        complete(false)
                    }
                }
            },
            DispatchQueue.global(qos: .default)
        )

        // Rule: Require TLS 1.2 or newer for upstream connections.
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv12
        )
        TLSLog.debug("event=tls.config tls_min=1.2")

        if alpn.isEmpty {
            TLSLog.debug("event=tls.alpn_request protocols=none")
        } else {
            for proto in alpn {
                proto.withCString { ptr in
                    sec_protocol_options_add_tls_application_protocol(
                        options.securityProtocolOptions,
                        ptr
                    )
                }
            }
            TLSLog.debug("event=tls.alpn_request protocols=\(alpn.joined(separator: ","))")
        }

        return options
    }

    // MARK: - Helper Methods

    // swiftlint:disable cyclomatic_complexity
    /// Creates a sec_identity_t from a certificate and private key.
    /// - Important: Uses the keychain to construct a valid identity.
    private static func createIdentityFromCertificateAndKey(
        certificate: SecCertificate,
        privateKey: SecKey,
        domain: String,
        replaceExisting: Bool
    ) -> sec_identity_t? {
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.identity_create outcome=pending domain=\(domain, privacy: .private(mask: .hash)) replace=\(replaceExisting)"
            )
        }

        // Rule: Key and certificate identifiers must match CertificateManager for identity lookup on iOS.
        let identifiers = CertificateManager.keychainIdentifiers(forDomain: domain)
        let currentKeyTagData = identifiers.keyApplicationTag
        let legacyKeyTagData = identifiers.legacyKeyApplicationTag
        let currentCertLabel = identifiers.certificateLabel
        let legacyCertLabel = identifiers.legacyCertificateLabel
        var effectiveCertLabel = currentCertLabel
        let accessGroup = CertificateManager.keychainAccessGroup
        TLSLog.debug("event=tls.keychain_group group=\(accessGroup ?? "default")")

        if replaceExisting {
            if TLSLog.verboseEnabled {
                SecurityLog.tls.debug(
                    "event=tls.identity_cleanup outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
                )
            }
            deleteKeychainIdentity(for: domain)
        }

        // Rule: Add the private key to the keychain if it is missing.
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.key_lookup outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
            )
        }
        func queryKey(tag: Data) -> OSStatus {
            var keyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecReturnRef as String: true
            ]
            if let accessGroup {
                keyQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            return SecItemCopyMatching(keyQuery as CFDictionary, &keyRef)
        }

        var keyRef: CFTypeRef?
        var status = queryKey(tag: currentKeyTagData)
        TLSLog.debug("event=tls.key_lookup status=\(describeOSStatus(status))")

        if status == errSecItemNotFound {
            status = queryKey(tag: legacyKeyTagData)
            if status == errSecSuccess {
                TLSLog.debug("event=tls.key_lookup outcome=legacy_hit")
            }
        }

        if status == errSecItemNotFound {
            if TLSLog.verboseEnabled {
                SecurityLog.tls.debug(
                    "event=tls.key_add outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
                )
            }
            var keyAttrs: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: currentKeyTagData,
                kSecAttrLabel as String: currentCertLabel,
                kSecValueRef as String: privateKey,
                kSecAttrIsPermanent as String: true,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecReturnPersistentRef as String: true
            ]
            if let accessGroup {
                keyAttrs[kSecAttrAccessGroup as String] = accessGroup
            }
            status = SecItemAdd(keyAttrs as CFDictionary, &keyRef)
            TLSLog.debug("event=tls.key_add status=\(describeOSStatus(status))")
        } else if status == errSecSuccess {
            if TLSLog.verboseEnabled {
                SecurityLog.tls.debug(
                    "event=tls.key_lookup outcome=exists domain=\(domain, privacy: .private(mask: .hash))"
                )
            }
        }

        guard status == errSecSuccess || status == errSecDuplicateItem else {
            setLastServerTLSOptionsError("private_key_store_failed:\(describeOSStatus(status))")
            SecurityLog.tls.error("event=tls.key_store outcome=failure domain=\(domain, privacy: .private(mask: .hash)) status=\(describeOSStatus(status))")
            return nil
        }
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.key_ready outcome=success domain=\(domain, privacy: .private(mask: .hash))"
            )
        }

        // Rule: Add the certificate to the keychain if it is missing.
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.cert_lookup outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
            )
        }
        func queryCert(label: String) -> OSStatus {
            var certQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
                kSecReturnRef as String: true
            ]
            if let accessGroup {
                certQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            return SecItemCopyMatching(certQuery as CFDictionary, &certRef)
        }

        var certRef: CFTypeRef?
        var certStatus = queryCert(label: currentCertLabel)
        TLSLog.debug("event=tls.cert_lookup status=\(describeOSStatus(certStatus))")

        if certStatus == errSecItemNotFound {
            certStatus = queryCert(label: legacyCertLabel)
            if certStatus == errSecSuccess {
                effectiveCertLabel = legacyCertLabel
                TLSLog.debug("event=tls.cert_lookup outcome=legacy_hit")
            }
        }

        if certStatus == errSecItemNotFound {
            if TLSLog.verboseEnabled {
                SecurityLog.tls.debug(
                    "event=tls.cert_add outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
                )
            }
            var certAttrs: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrLabel as String: currentCertLabel,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            if let accessGroup {
                certAttrs[kSecAttrAccessGroup as String] = accessGroup
            }
            certStatus = SecItemAdd(certAttrs as CFDictionary, &certRef)
            TLSLog.debug("event=tls.cert_add status=\(describeOSStatus(certStatus))")
        } else if certStatus == errSecSuccess {
            if TLSLog.verboseEnabled {
                SecurityLog.tls.debug(
                    "event=tls.cert_lookup outcome=exists domain=\(domain, privacy: .private(mask: .hash))"
                )
            }
        }

        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            setLastServerTLSOptionsError("certificate_store_failed:\(describeOSStatus(certStatus))")
            SecurityLog.tls.error("event=tls.cert_store outcome=failure domain=\(domain, privacy: .private(mask: .hash)) status=\(describeOSStatus(certStatus))")
            return nil
        }
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.cert_ready outcome=success domain=\(domain, privacy: .private(mask: .hash))"
            )
        }

        // Rationale: Use SecItemCopyMatching because some SDKs omit SecIdentityCreateWithCertificate.
        var identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: effectiveCertLabel,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            identityQuery[kSecAttrAccessGroup as String] = accessGroup
        }

        var identityRef: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)
        if lookupStatus == errSecSuccess, let identityRef, CFGetTypeID(identityRef) == SecIdentityGetTypeID() {
            let identity = unsafeBitCast(identityRef, to: SecIdentity.self)
            return sec_identity_create(identity)
        }

        // Rationale: Fall back to certificate reference lookup when label-based identity is unavailable.
        var matchQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecMatchItemList as String: [certificate] as CFArray
        ]
        if let accessGroup {
            matchQuery[kSecAttrAccessGroup as String] = accessGroup
        }

        var matchRef: CFTypeRef?
        let matchStatus = SecItemCopyMatching(matchQuery as CFDictionary, &matchRef)
        TLSLog.debug("event=tls.identity_certref_lookup status=\(describeOSStatus(matchStatus))")

        guard matchStatus == errSecSuccess, let matchRef, CFGetTypeID(matchRef) == SecIdentityGetTypeID() else {
            let statusToReport = (lookupStatus != errSecSuccess) ? lookupStatus : matchStatus
            setLastServerTLSOptionsError("identity_lookup_failed:\(describeOSStatus(statusToReport))")
            SecurityLog.tls.error("event=tls.identity_fetch outcome=failure domain=\(domain, privacy: .private(mask: .hash)) label_status=\(describeOSStatus(lookupStatus)) certref_status=\(describeOSStatus(matchStatus))")
            return nil
        }
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.identity_fetch outcome=success domain=\(domain, privacy: .private(mask: .hash))"
            )
        }
        let identity = unsafeBitCast(matchRef, to: SecIdentity.self)
        return sec_identity_create(identity)
    }

    // swiftlint:enable cyclomatic_complexity

    private static func deleteKeychainIdentity(for domain: String) {
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.keychain_delete outcome=pending domain=\(domain, privacy: .private(mask: .hash))"
            )
        }

        let identifiers = CertificateManager.keychainIdentifiers(forDomain: domain)
        let accessGroup = CertificateManager.keychainAccessGroup

        let variants: [(label: String, tag: Data)] = [
            (identifiers.certificateLabel, identifiers.keyApplicationTag),
            (identifiers.legacyCertificateLabel, identifiers.legacyKeyApplicationTag)
        ]

        for variant in variants {
            var keyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: variant.tag
            ]
            if let accessGroup {
                keyQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            let keyStatus = SecItemDelete(keyQuery as CFDictionary)
            TLSLog.debug("event=tls.key_delete status=\(describeOSStatus(keyStatus))")

            var certQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: variant.label
            ]
            if let accessGroup {
                certQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            let certStatus = SecItemDelete(certQuery as CFDictionary)
            TLSLog.debug("event=tls.cert_delete status=\(describeOSStatus(certStatus))")

            var identityQuery: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecAttrLabel as String: variant.label
            ]
            if let accessGroup {
                identityQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            let identityStatus = SecItemDelete(identityQuery as CFDictionary)
            TLSLog.debug("event=tls.identity_delete status=\(describeOSStatus(identityStatus))")
        }
    }

    /// Extracts SNI (Server Name Indication) from a TLS ClientHello.
    /// - Important: Best-effort parse. Supports ClientHello spanning multiple TLS records, but requires enough bytes.
    public static func extractSNI(from data: Data) -> String? {
        debugSampled("tls.sni_parse.pending", first: 5, every: 500) {
            "event=tls.sni_parse outcome=pending data_size=\(data.count)"
        }

        guard let extensions = extractClientHelloExtensions(from: data) else {
            debugSampled("tls.sni_parse.short", first: 5, every: 500) {
                "event=tls.sni_parse outcome=failure reason=client_hello_incomplete size=\(data.count)"
            }
            return nil
        }

        var offset = extensions.startIndex
        while offset + 4 <= extensions.endIndex {
            let extensionType = Int(extensions[offset]) << 8 | Int(extensions[offset + 1])
            let extensionLength = Int(extensions[offset + 2]) << 8 | Int(extensions[offset + 3])
            offset += 4

            guard offset + extensionLength <= extensions.endIndex else { break }

            if extensionType == 0x0000 {
                let end = offset + extensionLength
                guard offset + 2 <= end else { break }

                let serverNameListLength = Int(extensions[offset]) << 8 | Int(extensions[offset + 1])
                offset += 2

                guard offset + serverNameListLength <= end else { break }

                var listOffset = offset
                let listEnd = offset + serverNameListLength
                while listOffset + 3 <= listEnd {
                    let nameType = extensions[listOffset]
                    listOffset += 1
                    let nameLength = Int(extensions[listOffset]) << 8 | Int(extensions[listOffset + 1])
                    listOffset += 2
                    guard listOffset + nameLength <= listEnd else { break }

                    if nameType == 0x00,
                       let serverName = String(
                           data: extensions[listOffset ..< (listOffset + nameLength)],
                           encoding: .ascii
                       ) {
                        debugSampled("tls.sni_parse.success.\(serverName)", first: 5, every: 500) {
                            LogEvent.tls("sni_parse")
                                .success()
                                .with("sni", value: serverName, privacy: .hash)
                        }
                        return serverName
                    }
                    listOffset += nameLength
                }

                break
            }

            offset += extensionLength
        }

        debugSampled("tls.sni_parse.no_sni", first: 5, every: 500) {
            "event=tls.sni_parse outcome=failure reason=no_sni_extension"
        }
        return nil
    }

    /// Extracts ALPN (Application-Layer Protocol Negotiation) extension from a TLS ClientHello.
    /// - Important: Best-effort parse. Supports ClientHello spanning multiple TLS records, but requires enough bytes.
    public static func extractALPN(from data: Data) -> [String]? {
        guard let extensions = extractClientHelloExtensions(from: data) else { return nil }

        var offset = extensions.startIndex
        while offset + 4 <= extensions.endIndex {
            let extensionType = Int(extensions[offset]) << 8 | Int(extensions[offset + 1])
            let extensionLength = Int(extensions[offset + 2]) << 8 | Int(extensions[offset + 3])
            offset += 4

            guard offset + extensionLength <= extensions.endIndex else { break }

            if extensionType == 0x0010 {
                let end = offset + extensionLength
                guard offset + 2 <= end else { break }

                let alpnListLength = Int(extensions[offset]) << 8 | Int(extensions[offset + 1])
                var alpnOffset = offset + 2

                guard alpnOffset + alpnListLength <= end else { break }

                var protocols: [String] = []
                let alpnEnd = alpnOffset + alpnListLength
                while alpnOffset < alpnEnd {
                    let protocolLength = Int(extensions[alpnOffset])
                    alpnOffset += 1
                    guard alpnOffset + protocolLength <= alpnEnd else { break }

                    if let protocolName = String(
                        data: extensions[alpnOffset ..< (alpnOffset + protocolLength)],
                        encoding: .ascii
                    ) {
                        protocols.append(protocolName)
                    }
                    alpnOffset += protocolLength
                }

                debugSampled("tls.alpn_parse.success", first: 5, every: 500) {
                    LogEvent.tls("alpn_parse")
                        .success()
                        .with("protocols", value: protocols.joined(separator: ","), privacy: .public)
                }
                return protocols.isEmpty ? nil : protocols
            }

            offset += extensionLength
        }

        debugSampled("tls.alpn_parse.none", first: 5, every: 500) {
            "event=tls.alpn_parse outcome=failure reason=no_alpn_extension"
        }
        return nil
    }

    // MARK: - ClientHello parsing (best-effort)

    /// Extracts the raw extensions block from a TLS ClientHello message.
    /// - Important: Returns nil when the ClientHello is incomplete or not present in `data`.
    private static func extractClientHelloExtensions(from data: Data) -> Data? {
        guard let clientHello = extractClientHelloHandshake(from: data) else { return nil }
        guard clientHello.count >= 4 else { return nil }

        let body = clientHello.dropFirst(4)
        guard body.count >= 2 + 32 + 1 else { return nil }

        var offset = body.startIndex

        // client_version (2)
        offset = body.index(offset, offsetBy: 2)

        // random (32)
        offset = body.index(offset, offsetBy: 32)

        // session_id
        guard offset < body.endIndex else { return nil }
        let sessionIDLength = Int(body[offset])
        offset = body.index(offset, offsetBy: 1)
        guard offset + sessionIDLength <= body.endIndex else { return nil }
        offset = body.index(offset, offsetBy: sessionIDLength)

        // cipher_suites
        guard offset + 2 <= body.endIndex else { return nil }
        let cipherSuitesLength = Int(body[offset]) << 8 | Int(body[offset + 1])
        offset = body.index(offset, offsetBy: 2)
        guard offset + cipherSuitesLength <= body.endIndex else { return nil }
        offset = body.index(offset, offsetBy: cipherSuitesLength)

        // compression_methods
        guard offset < body.endIndex else { return nil }
        let compressionMethodsLength = Int(body[offset])
        offset = body.index(offset, offsetBy: 1)
        guard offset + compressionMethodsLength <= body.endIndex else { return nil }
        offset = body.index(offset, offsetBy: compressionMethodsLength)

        // extensions (optional)
        guard offset + 2 <= body.endIndex else { return Data() }
        let extensionsLength = Int(body[offset]) << 8 | Int(body[offset + 1])
        offset = body.index(offset, offsetBy: 2)
        guard offset + extensionsLength <= body.endIndex else { return nil }

        return Data(body[offset ..< (offset + extensionsLength)])
    }

    /// Extracts the first ClientHello handshake message from a TLS byte stream.
    /// Accepts either a full TLS record stream (starting with content type 0x16) or a raw handshake message (starting with 0x01).
    private static func extractClientHelloHandshake(from data: Data, maxBytes: Int = 256 * 1024) -> Data? {
        guard !data.isEmpty else { return nil }

        func expectedHandshakeTotal(_ handshake: Data) -> Int? {
            guard handshake.count >= 4 else { return nil }
            guard handshake[handshake.startIndex] == 0x01 else { return -1 }
            let start = handshake.startIndex
            let length =
                (Int(handshake[start + 1]) << 16)
                    | (Int(handshake[start + 2]) << 8)
                    | Int(handshake[start + 3])
            return 4 + length
        }

        // Raw handshake message path.
        if data.first == 0x01 {
            guard let total = expectedHandshakeTotal(data) else { return nil }
            guard total >= 0, total <= maxBytes else { return nil }
            guard data.count >= total else { return nil }
            return Data(data.prefix(total))
        }

        var offset = 0
        var handshakeBytes = Data()
        var expectedTotal: Int?

        while offset + 5 <= data.count {
            let contentType = data[offset]
            let recordLength = (Int(data[offset + 3]) << 8) | Int(data[offset + 4])
            let recordStart = offset + 5
            let recordEnd = recordStart + recordLength
            guard recordEnd <= data.count else { return nil }

            if contentType == 0x16 {
                handshakeBytes.append(contentsOf: data[recordStart ..< recordEnd])
                if handshakeBytes.count > maxBytes { return nil }

                if expectedTotal == nil, let total = expectedHandshakeTotal(handshakeBytes) {
                    if total < 0 { return nil }
                    if total > maxBytes { return nil }
                    expectedTotal = total
                }

                if let expectedTotal, handshakeBytes.count >= expectedTotal {
                    return Data(handshakeBytes.prefix(expectedTotal))
                }
            }

            offset = recordEnd
        }

        return nil
    }

    /// Returns the negotiated ALPN protocol from a TLS connection.
    public static func getNegotiatedALPN(from connection: NWConnection) -> String? {
        var negotiatedProtocol: String?

        connection.metadata(definition: NWProtocolTLS.definition).map { metadata in
            guard let tlsMetadata = metadata as? NWProtocolTLS.Metadata else {
                debugSampled("tls.alpn_get.no_metadata") {
                    "event=tls.alpn_get outcome=failure reason=no_metadata"
                }
                return
            }

            if let protocolPtr = sec_protocol_metadata_get_negotiated_protocol(tlsMetadata.securityProtocolMetadata) {
                negotiatedProtocol = String(cString: protocolPtr)
                debugSampled("tls.alpn_get.success") {
                    LogEvent.tls("alpn_get")
                        .success()
                        .with("protocol", value: negotiatedProtocol ?? "none", privacy: .public)
                }
            } else {
                debugSampled("tls.alpn_get.no_protocol") {
                    "event=tls.alpn_get outcome=failure reason=no_protocol"
                }
            }
        }

        return negotiatedProtocol
    }

    /// Gets TLS connection information from a NWConnection.
    /// - Note: Certificate chain and trust are best-effort; metadata APIs can omit details.
    public static func getTLSInfo(from connection: NWConnection) -> TLSConnectionInfo? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            debugSampled("tls.info_get.no_metadata") {
                "event=tls.info_get outcome=failure reason=no_metadata"
            }
            return nil
        }

        let secMetadata = metadata.securityProtocolMetadata
        debugSampled("tls.info_extract.pending") {
            "event=tls.info_extract outcome=pending"
        }

        let tlsVersionRaw = sec_protocol_metadata_get_negotiated_tls_protocol_version(secMetadata)
        let tlsVersion = switch tlsVersionRaw {
        case .TLSv10: "TLSv1.0"
        case .TLSv11: "TLSv1.1"
        case .TLSv12: "TLSv1.2"
        case .TLSv13: "TLSv1.3"
        case .DTLSv10: "DTLSv1.0"
        case .DTLSv12: "DTLSv1.2"
        default: "Unknown"
        }
        debugSampled("tls.version_negotiated") {
            LogEvent.tls("version_negotiated")
                .with("version", value: tlsVersion, privacy: .public)
        }

        let cipherSuiteRaw = sec_protocol_metadata_get_negotiated_tls_ciphersuite(secMetadata)
        let cipherSuite = cipherSuiteToString(cipherSuiteRaw)
        debugSampled("tls.cipher_negotiated") {
            LogEvent.tls("cipher_negotiated")
                .with("cipher", value: cipherSuite, privacy: .public)
        }

        var certificateTrusted = false
        var certificateChain: [CertificateInfo]? = nil

        if let secTrust = copySecTrust(from: secMetadata) {
            var trustError: CFError?
            certificateTrusted = SecTrustEvaluateWithError(secTrust, &trustError)

            let certCount = SecTrustGetCertificateCount(secTrust)
            if certCount > 0 {
                var chain: [CertificateInfo] = []
                chain.reserveCapacity(certCount)
                for idx in 0 ..< certCount {
                    if let cert = SecTrustGetCertificateAtIndex(secTrust, idx),
                       let info = extractCertificateInfo(from: cert) {
                        chain.append(info)
                    }
                }
                certificateChain = chain.isEmpty ? nil : chain
            }
        }

        let alpnProtocol: String? = {
            if let protocolPtr = sec_protocol_metadata_get_negotiated_protocol(secMetadata) {
                return String(cString: protocolPtr)
            }
            return nil
        }()

        let alpnOffered = supportedALPNProtocols
        let alpnAvailable: [String]? = alpnProtocol.map { [$0] }

        return TLSConnectionInfo(
            protocolVersion: tlsVersion,
            cipherSuite: cipherSuite,
            certificateChain: certificateChain,
            certificatePinningEnabled: false,
            certificateTrusted: certificateTrusted,
            alpnProtocol: alpnProtocol,
            alpnOffered: alpnOffered,
            alpnAvailable: alpnAvailable
        )
    }

    // Rationale: `sec_protocol_metadata_copy_sec_trust` is weak-linked; use dlsym to avoid a hard dependency.
    private static func copySecTrust(from metadata: sec_protocol_metadata_t) -> SecTrust? {
        let symbolName = "sec_protocol_metadata_copy_sec_trust"
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), symbolName) else {
            return nil
        }
        // Important: `copy_*` follows the Create Rule (returns a +1 retained object).
        // When calling via `dlsym`, we must model ownership explicitly to avoid ARC mismatches.
        typealias CopyFunc = @convention(c) (sec_protocol_metadata_t) -> Unmanaged<SecTrust>?
        let function = unsafeBitCast(symbol, to: CopyFunc.self)
        return function(metadata)?.takeRetainedValue()
    }

    /// Converts a cipher suite value into a readable string.
    private static func cipherSuiteToString(_ suite: tls_ciphersuite_t) -> String {
        // Rationale: Map common suites and fall back to hex for unknown values.
        let suiteValue = suite.rawValue
        switch suiteValue {
        case 0x1301: return "TLS_AES_128_GCM_SHA256"
        case 0x1302: return "TLS_AES_256_GCM_SHA384"
        case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
        case 0xC02B: return "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
        case 0xC02C: return "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
        case 0xC02F: return "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
        case 0xC030: return "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
        default: return String(format: "0x%04X", suiteValue)
        }
    }

    /// Extracts certificate information from a SecCertificate.
    private static func extractCertificateInfo(from certificate: SecCertificate) -> CertificateInfo? {
        guard let subject = SecCertificateCopySubjectSummary(certificate) as String? else {
            return nil
        }

        let issuer = "Unknown"
        let notBefore = Date.distantPast
        let notAfter = Date.distantFuture
        let serialNumber: String? = nil

        let fingerprint: String
        if let certData = SecCertificateCopyData(certificate) as Data? {
            let hash = SHA256Hash(data: certData)
            fingerprint = hash.map { String(format: "%02x", $0) }.joined()
        } else {
            fingerprint = "N/A"
        }

        var publicKeyAlgorithm = "Unknown"
        if let publicKey = SecCertificateCopyKey(certificate) {
            let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any]
            if let keyType = attributes?[kSecAttrKeyType as String] as? String,
               let keySize = attributes?[kSecAttrKeySizeInBits as String] as? Int {
                publicKeyAlgorithm = "\(keyType) \(keySize)"
            }
        }

        return CertificateInfo(
            subject: subject,
            issuer: issuer,
            validFrom: notBefore,
            validUntil: notAfter,
            fingerprint: fingerprint,
            publicKeyAlgorithm: publicKeyAlgorithm,
            serialNumber: serialNumber
        )
    }

    /// Computes a SHA-256 digest for the provided data.
    private static func SHA256Hash(data: Data) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash
    }
}

// MARK: - Cached Certificate

/// Represents a cached certificate with expiration tracking.
public struct CachedCertificate {
    public let certificate: SecCertificate
    public let privateKey: SecKey
    public let createdAt: Date

    public var isExpired: Bool {
        let lifetime = TLSHandler.certificateLifetime
        return Date().timeIntervalSince(createdAt) > lifetime
    }
}
