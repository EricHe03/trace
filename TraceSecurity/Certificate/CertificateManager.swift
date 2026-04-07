//
//  CertificateManager.swift
//  TraceSecurity
//
//  Created by Justin on 2026/01/10.
//

import CryptoKit
import Foundation
import Security
import X509

/// Manages Root CA generation and dynamic certificate signing for MITM.
public class CertificateManager {
    public nonisolated(unsafe) static let shared = CertificateManager()

    private let keychainService = "com.trace.certificates"
    private let rootCALabel = "Trace Root CA"
    private let rootCACommonName = "Trace Network Debugger Root CA"
    private let rootCAOrganization = "Trace Network Debugger"
    private let rootCACountry = "US"

    /// Provides the Root CA Distinguished Name for subject and issuer use.
    private var rootCADistinguishedName: DistinguishedName {
        DistinguishedName(
            commonName: rootCACommonName,
            organization: rootCAOrganization,
            country: rootCACountry
        )
    }

    /// Stores the UserDefaults key for the known Root CA fingerprint.
    private let knownFingerprintKey = "com.trace.rootCA.knownFingerprint"
    private let rootCACacheLock = NSLock()
    private var cachedRootCA: (certificate: SecCertificate, privateKey: SecKey)?

    /// Posts when the Root CA fingerprint changes.
    public static let rootCAMismatchNotification = Notification.Name("TraceRootCAMismatchNotification")
    private static let keychainAccessGroupLogLock = NSLock()
    private nonisolated(unsafe) static var didLogKeychainAccessGroup = false
    private static let runtimeCacheInvalidatorLock = NSLock()
    private nonisolated(unsafe) static var runtimeCacheInvalidators: [@Sendable () -> Void] = []

    // MARK: - Keychain identifiers (per-domain leafs)

    struct DomainKeychainIdentifiers: Sendable {
        let keyApplicationTag: Data
        let certificateLabel: String
        let legacyKeyApplicationTag: Data
        let legacyCertificateLabel: String
    }

    private static let domainKeyTagPrefix = "com.trace.domain."
    private static let domainCertLabelPrefix = "Trace - "

    private static func canonicalDomainKey(_ domain: String) -> String {
        var value = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func keychainIdentifiers(forDomain domain: String) -> DomainKeychainIdentifiers {
        let canonical = canonicalDomainKey(domain)
        let hash = sha256Hex(canonical)
        let idPrefix = String(hash.prefix(16))

        let display: String = {
            guard !canonical.isEmpty else { return "<empty>" }
            if canonical.count <= 120 { return canonical }
            let head = canonical.prefix(72)
            let tail = canonical.suffix(24)
            return "\(head)…\(tail)"
        }()

        let label = "\(domainCertLabelPrefix)\(display) (\(idPrefix))"

        return DomainKeychainIdentifiers(
            keyApplicationTag: Data("\(domainKeyTagPrefix)\(hash)".utf8),
            certificateLabel: label,
            legacyKeyApplicationTag: Data("\(domainKeyTagPrefix)\(domain)".utf8),
            legacyCertificateLabel: "\(domainCertLabelPrefix)\(domain)"
        )
    }

    /// Provides the shared keychain access group used by the app and VPN extension.
    public static let keychainAccessGroup: String? = {
        // Prefer explicit configuration for forks and CI signing setups.
        if let configured = Bundle.main.object(forInfoDictionaryKey: "TraceKeychainAccessGroup") as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("$("), !trimmed.contains("${") {
                SecurityLog.keychain.info("event=keychain.access_group_resolved outcome=success source=info_plist")
                return trimmed
            }
        }

        // Rationale: App and VPN extension must share keychain items to avoid divergent Root CAs.
        #if os(macOS)
        // Rationale: macOS can read entitlements directly.
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let groupsAny = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
        ) else { return nil }
        let groups = groupsAny as? [String]
        // Rule: Prefer the Trace app group when multiple groups are present.
        return groups?.first(where: { $0.hasSuffix(".com.justin.trace") }) ?? groups?.first
        #else
        // Rationale: iOS SDK constraints require inferring the Team ID prefix from keychain metadata.
        func inferTeamPrefix() -> String? {
            let service = "com.trace.keychain.teamPrefixProbe"
            let account = UUID().uuidString
            let value = Data([0x00])

            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: value,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecReturnAttributes as String: true
            ]

            var result: CFTypeRef?
            var status = SecItemAdd(addQuery as CFDictionary, &result)
            if status == errSecDuplicateItem {
                SecItemDelete(addQuery as CFDictionary)
                result = nil
                status = SecItemAdd(addQuery as CFDictionary, &result)
            }
            defer { SecItemDelete(addQuery as CFDictionary) }

            guard status == errSecSuccess,
                  let attrs = result as? [String: Any],
                  let accessGroup = attrs[kSecAttrAccessGroup as String] as? String,
                  let dot = accessGroup.firstIndex(of: ".") else {
                SecurityLog.keychain.warning("event=keychain.team_prefix_inference outcome=failure status=\(status) reason=keychain_sharing_may_not_work")
                return nil
            }

            // Rule: Preserve the trailing dot in the Team ID prefix, e.g. "ABCDE12345.".
            return String(accessGroup[..<accessGroup.index(after: dot)])
        }

        if let prefix = inferTeamPrefix() {
            let group = "\(prefix)com.justin.trace"
            SecurityLog.keychain.info("event=keychain.access_group_resolved outcome=success group=\(group, privacy: .private)")
            return group
        }

        // Rationale: Fall back to bundle identifiers when keychain probing fails in extensions.
        if let bundleId = Bundle.main.bundleIdentifier {
            // Rationale: VPN extensions use a different bundle ID but share the same keychain group.
            let mainAppBundleId = bundleId.components(separatedBy: ".").prefix(3).joined(separator: ".")
            if mainAppBundleId == "com.justin.trace" {
                SecurityLog.keychain.warning("event=keychain.access_group_inference outcome=failure reason=will_try_without_explicit_group")
            }
        }

        return nil
        #endif
    }()

    /// Logs the current keychain access group for diagnostics.
    public static func logKeychainAccessGroup(force: Bool = false) {
        keychainAccessGroupLogLock.lock()
        let shouldLog = force || !didLogKeychainAccessGroup
        if shouldLog {
            didLogKeychainAccessGroup = true
        }
        keychainAccessGroupLogLock.unlock()

        guard shouldLog else { return }
        if let group = keychainAccessGroup {
            SecurityLog.keychain.info("event=keychain.access_group outcome=success group=\(group, privacy: .private)")
        } else {
            SecurityLog.keychain.warning("event=keychain.access_group outcome=failure reason=no_group_available")
        }
    }

    private init() {}

    private func loadCachedRootCA() -> (certificate: SecCertificate, privateKey: SecKey)? {
        rootCACacheLock.lock()
        defer { rootCACacheLock.unlock() }
        return cachedRootCA
    }

    private func storeCachedRootCA(_ rootCA: (certificate: SecCertificate, privateKey: SecKey)) {
        rootCACacheLock.lock()
        cachedRootCA = rootCA
        rootCACacheLock.unlock()
    }

    private func clearCachedRootCA() {
        rootCACacheLock.lock()
        cachedRootCA = nil
        rootCACacheLock.unlock()
    }

    public static func registerRuntimeCacheInvalidator(_ invalidator: @escaping @Sendable () -> Void) {
        runtimeCacheInvalidatorLock.lock()
        runtimeCacheInvalidators.append(invalidator)
        runtimeCacheInvalidatorLock.unlock()
    }

    func clearRuntimeCaches() {
        SecurityLog.certificate.debug("event=ca.runtime_cache_clear outcome=pending")
        clearCachedRootCA()
        TLSHandler.clearCertificateCache()

        Self.runtimeCacheInvalidatorLock.lock()
        let invalidators = Self.runtimeCacheInvalidators
        Self.runtimeCacheInvalidatorLock.unlock()

        for invalidator in invalidators {
            invalidator()
        }
    }

    // MARK: - Root CA Management

    /// Returns the shared keychain access group or throws if unavailable.
    /// - Important: This prevents the app and VPN extension from silently using different roots.
    private func requireKeychainAccessGroup() throws -> String {
        guard let group = Self.keychainAccessGroup, !group.isEmpty else {
            SecurityLog.keychain.error("event=keychain.access_group_required outcome=failure reason=missing_shared_group")
            throw CertificateError.keychainAccessGroupUnavailable
        }
        return group
    }

    /// Generates or retrieves the Root CA certificate and private key.
    public func getRootCA(allowCreate: Bool = true) throws -> (certificate: SecCertificate, privateKey: SecKey) {
        if let cachedRootCA = loadCachedRootCA() {
            return cachedRootCA
        }

        SecurityLog.certificate.debug("event=ca.get_root outcome=pending action=retrieve")

        Self.logKeychainAccessGroup()

        do {
            SecurityLog.certificate.debug("event=ca.keychain_check outcome=pending")
            let existing = try loadRootCAFromKeychain()
            let summary = SecCertificateCopySubjectSummary(existing.certificate) as String? ?? "unknown"
            storeCachedRootCA(existing)
            SecurityLog.certificate.info("event=ca.load outcome=success subject=\(summary, privacy: .private(mask: .hash))")
            return existing
        } catch {
            SecurityLog.certificate.debug("event=ca.load outcome=failure error=\(error.localizedDescription)")

            // Rule: Only auto-generate when the Root CA is truly absent.
            // Rationale: Regenerating on partial keychain failure causes trust mismatches.
            if allowCreate {
                if let certError = error as? CertificateError {
                    switch certError {
                    case .rootCANotFound:
                        break
                    default:
                        throw error
                    }
                }
            } else {
                throw error
            }
        }

        guard allowCreate else {
            throw CertificateError.rootCANotFound
        }

        SecurityLog.certificate.info("event=ca.generate outcome=pending")
        let result = try generateRootCA()
        let summary = SecCertificateCopySubjectSummary(result.certificate) as String? ?? "unknown"
        storeCachedRootCA(result)
        SecurityLog.certificate.info("event=ca.generate outcome=success subject=\(summary, privacy: .private(mask: .hash))")
        return result
    }

    /// Generates a new Root CA certificate and private key.
    private func generateRootCA() throws -> (certificate: SecCertificate, privateKey: SecKey) {
        SecurityLog.certificate.debug("event=ca.generate_rsa outcome=pending key_size=2048")

        let accessGroup = try requireKeychainAccessGroup()
        SecurityLog.keychain.debug("event=keychain.access_group outcome=success group=\(accessGroup, privacy: .private)")

        var keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data("com.trace.rootca.private".utf8),
                kSecAttrLabel as String: rootCALabel,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var privateAttrs = keyAttributes[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
        privateAttrs[kSecAttrAccessGroup as String] = accessGroup
        keyAttributes[kSecPrivateKeyAttrs as String] = privateAttrs

        SecurityLog.crypto.debug("event=crypto.rsa_keygen outcome=pending")
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            SecurityLog.crypto.error("event=crypto.rsa_keygen outcome=failure error=\(errorDesc)")
            throw CertificateError.keyGenerationFailed(error?.takeRetainedValue())
        }
        SecurityLog.crypto.debug("event=crypto.rsa_keygen outcome=success")

        SecurityLog.certificate.debug("event=cert.create_self_signed outcome=pending cn=\(self.rootCACommonName, privacy: .private(mask: .hash))")
        let certificate = try createSelfSignedCertificate(
            commonName: rootCACommonName,
            privateKey: privateKey,
            isCA: true
        )
        SecurityLog.certificate.debug("event=cert.create_self_signed outcome=success")

        SecurityLog.keychain.debug("event=keychain.store_cert outcome=pending label=\(self.rootCALabel, privacy: .private(mask: .hash))")
        try storeCertificateInKeychain(certificate, label: rootCALabel)
        SecurityLog.keychain.debug("event=keychain.store_cert outcome=success")

        return (certificate, privateKey)
    }

    /// Loads the Root CA from the keychain.
    private func loadRootCAFromKeychain() throws -> (certificate: SecCertificate, privateKey: SecKey) {
        let accessGroup = try requireKeychainAccessGroup()
        SecurityLog.keychain.debug("event=keychain.load_ca outcome=pending access_group=\(accessGroup, privacy: .private)")

        // Rule: Root CA certificate must live in the shared access group.
        var certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: rootCALabel,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnRef as String: true
        ]

        var certificate: SecCertificate?
        let certStatus = withUnsafeMutablePointer(to: &certificate) { pointer in
            pointer.withMemoryRebound(to: CFTypeRef?.self, capacity: 1) {
                SecItemCopyMatching(certQuery as CFDictionary, $0)
            }
        }

        // Rule: Root CA private key must live in the shared access group.
        var keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data("com.trace.rootca.private".utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnRef as String: true
        ]

        var privateKey: SecKey?
        let keyStatus = withUnsafeMutablePointer(to: &privateKey) { pointer in
            pointer.withMemoryRebound(to: CFTypeRef?.self, capacity: 1) {
                SecItemCopyMatching(keyQuery as CFDictionary, $0)
            }
        }

        SecurityLog.keychain.debug("event=keychain.ca_lookup cert_status=\(certStatus) key_status=\(keyStatus)")

        // Rule: Do not auto-repair mismatched keychain entries; require an explicit reset.
        if (certStatus == errSecSuccess) != (keyStatus == errSecSuccess) {
            SecurityLog.keychain.error("event=keychain.ca_inconsistent outcome=failure cert_status=\(certStatus) key_status=\(keyStatus)")
            throw CertificateError.rootCAIncompleteInKeychain
        }

        guard certStatus == errSecSuccess, let certificate else {
            SecurityLog.keychain.warning("event=keychain.ca_cert_not_found outcome=failure status=\(certStatus)")
            throw CertificateError.rootCANotFound
        }

        guard keyStatus == errSecSuccess, let privateKey else {
            SecurityLog.keychain.warning("event=keychain.ca_key_not_found outcome=failure status=\(keyStatus)")
            throw CertificateError.privateKeyNotFound
        }

        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "unknown"
        SecurityLog.keychain.debug("event=keychain.ca_loaded outcome=success subject=\(summary, privacy: .private(mask: .hash))")
        return (certificate, privateKey)
    }

    // MARK: - Dynamic Certificate Generation

    /// Generates a certificate for a specific domain signed by the Root CA.
    public func generateCertificateForDomain(_ domain: String) throws -> (certificate: SecCertificate, privateKey: SecKey) {
        SecurityLog.certificate.debug("event=cert.generate_domain outcome=pending domain=\(domain, privacy: .private(mask: .hash))")

        do {
            let cached = try loadCertificateForDomain(domain)
            SecurityLog.certificate.debug("event=cert.cache_hit outcome=success domain=\(domain, privacy: .private(mask: .hash))")
            return cached
        } catch let error as CertificateError {
            switch error {
            case .certificateNotFound, .privateKeyNotFound:
                // Rationale: Partial keychain state can happen after crashes or failed writes; clean up to avoid permanent errSecDuplicateItem failures.
                try? deleteKeychainMaterialForDomain(domain)
            default:
                throw error
            }
        } catch {
            throw error
        }
        SecurityLog.certificate.debug("event=cert.cache_miss outcome=pending domain=\(domain, privacy: .private(mask: .hash))")

        SecurityLog.certificate.debug("event=cert.get_root_ca outcome=pending")
        let (_, rootPrivateKey) = try getRootCA()
        SecurityLog.certificate.debug("event=cert.get_root_ca outcome=success")

        let accessGroup = try requireKeychainAccessGroup()
        let identifiers = Self.keychainIdentifiers(forDomain: domain)
        var keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: identifiers.keyApplicationTag,
                kSecAttrLabel as String: identifiers.certificateLabel,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var privateAttrs = keyAttributes[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
        privateAttrs[kSecAttrAccessGroup as String] = accessGroup
        keyAttributes[kSecPrivateKeyAttrs as String] = privateAttrs

        SecurityLog.crypto.debug("event=crypto.rsa_keygen outcome=pending domain=\(domain, privacy: .private(mask: .hash))")
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            SecurityLog.crypto.error("event=crypto.rsa_keygen outcome=failure domain=\(domain, privacy: .private(mask: .hash)) error=\(errorDesc)")
            throw CertificateError.keyGenerationFailed(error?.takeRetainedValue())
        }
        SecurityLog.crypto.debug("event=crypto.rsa_keygen outcome=success domain=\(domain, privacy: .private(mask: .hash))")

        SecurityLog.certificate.debug("event=cert.sign outcome=pending domain=\(domain, privacy: .private(mask: .hash))")
        let certificate = try createSignedCertificate(
            commonName: domain,
            subjectPrivateKey: privateKey,
            signingKey: rootPrivateKey,
            isCA: false
        )
        SecurityLog.certificate.debug("event=cert.sign outcome=success domain=\(domain, privacy: .private(mask: .hash))")

        SecurityLog.keychain.debug("event=keychain.store_cert outcome=pending domain=\(domain, privacy: .private(mask: .hash))")
        try storeCertificateInKeychain(certificate, label: identifiers.certificateLabel)
        SecurityLog.keychain.debug("event=keychain.store_cert outcome=success domain=\(domain, privacy: .private(mask: .hash))")

        return (certificate, privateKey)
    }

    /// Deletes per-domain certificate/key material for a single domain (both current and legacy keychain identifiers).
    private func deleteKeychainMaterialForDomain(_ domain: String) throws {
        let accessGroup = try requireKeychainAccessGroup()
        let identifiers = Self.keychainIdentifiers(forDomain: domain)

        let variants: [(label: String, tag: Data)] = [
            (identifiers.certificateLabel, identifiers.keyApplicationTag),
            (identifiers.legacyCertificateLabel, identifiers.legacyKeyApplicationTag)
        ]

        for variant in variants {
            var keyDelete: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: variant.tag,
                kSecAttrAccessGroup as String: accessGroup
            ]
            SecItemDelete(keyDelete as CFDictionary)

            var certDelete: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: variant.label,
                kSecAttrAccessGroup as String: accessGroup
            ]
            SecItemDelete(certDelete as CFDictionary)

            var identityDelete: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecAttrLabel as String: variant.label,
                kSecAttrAccessGroup as String: accessGroup
            ]
            SecItemDelete(identityDelete as CFDictionary)
        }
    }

    /// Loads a cached certificate for a domain.
    private func loadCertificateForDomain(_ domain: String) throws -> (certificate: SecCertificate, privateKey: SecKey) {
        let accessGroup = try requireKeychainAccessGroup()
        let identifiers = Self.keychainIdentifiers(forDomain: domain)

        func loadCertificate(label: String) -> (certificate: SecCertificate?, status: OSStatus) {
            let certQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
                kSecAttrAccessGroup as String: accessGroup,
                kSecReturnRef as String: true
            ]

            var certificate: SecCertificate?
            let certStatus = withUnsafeMutablePointer(to: &certificate) { pointer in
                pointer.withMemoryRebound(to: CFTypeRef?.self, capacity: 1) {
                    SecItemCopyMatching(certQuery as CFDictionary, $0)
                }
            }

            guard certStatus == errSecSuccess else { return (nil, certStatus) }
            return (certificate, certStatus)
        }

        func loadKey(tag: Data) -> (key: SecKey?, status: OSStatus) {
            let keyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrAccessGroup as String: accessGroup,
                kSecReturnRef as String: true
            ]

            var privateKey: SecKey?
            let keyStatus = withUnsafeMutablePointer(to: &privateKey) { pointer in
                pointer.withMemoryRebound(to: CFTypeRef?.self, capacity: 1) {
                    SecItemCopyMatching(keyQuery as CFDictionary, $0)
                }
            }

            guard keyStatus == errSecSuccess else { return (nil, keyStatus) }
            return (privateKey, keyStatus)
        }

        let variants: [(label: String, tag: Data)] = [
            (identifiers.certificateLabel, identifiers.keyApplicationTag),
            (identifiers.legacyCertificateLabel, identifiers.legacyKeyApplicationTag)
        ]

        for variant in variants {
            let cert = loadCertificate(label: variant.label)
            let key = loadKey(tag: variant.tag)

            if cert.status == errSecItemNotFound, key.status == errSecItemNotFound {
                continue
            }

            if cert.status == errSecSuccess, let certificate = cert.certificate,
               key.status == errSecSuccess, let privateKey = key.key {
                return (certificate, privateKey)
            }

            if cert.status != errSecSuccess, cert.status != errSecItemNotFound {
                throw CertificateError.keychainStorageFailed(cert.status)
            }
            if key.status != errSecSuccess, key.status != errSecItemNotFound {
                throw CertificateError.keychainStorageFailed(key.status)
            }

            // Rule: Treat partial presence as an error so callers can clean up and regenerate.
            if cert.status == errSecItemNotFound {
                throw CertificateError.certificateNotFound
            }
            throw CertificateError.privateKeyNotFound
        }

        throw CertificateError.certificateNotFound
    }

    // MARK: - Certificate Creation Helpers

    /// Creates a self-signed Root CA certificate.
    /// - Important: Uses a complete Distinguished Name for browser compatibility.
    private func createSelfSignedCertificate(
        commonName: String,
        privateKey: SecKey,
        isCA: Bool
    ) throws -> SecCertificate {
        // Rationale: Use apple/swift-certificates for standards-compliant X.509 generation.

        let subjectDN = rootCADistinguishedName

        return try buildX509Certificate(
            subject: subjectDN,
            // Rule: Self-signed certificates must use the same subject and issuer.
            issuer: subjectDN,
            subjectPrivateKey: privateKey,
            signingKey: privateKey,
            isCA: isCA,
            validityDays: 3650
        )
    }

    /// Creates a certificate signed by the Root CA.
    /// - Important: Leaf certificates use a simple subject DN but must use the Root CA DN as issuer.
    private func createSignedCertificate(
        commonName: String,
        subjectPrivateKey: SecKey,
        signingKey: SecKey,
        isCA: Bool
    ) throws -> SecCertificate {
        // Rule: Leaf certificates use the domain name as the subject DN.
        let subjectDN = DistinguishedName.simple(commonName)

        // Rule: Issuer DN must match the Root CA subject DN for chain validation.
        let issuerDN = rootCADistinguishedName

        return try buildX509Certificate(
            subject: subjectDN,
            issuer: issuerDN,
            subjectPrivateKey: subjectPrivateKey,
            signingKey: signingKey,
            isCA: isCA,
            validityDays: 365
        )
    }

    /// Builds an X.509 certificate using apple/swift-certificates.
    private func buildX509Certificate(
        subject: DistinguishedName,
        issuer: DistinguishedName,
        subjectPrivateKey: SecKey,
        signingKey: SecKey,
        isCA: Bool,
        validityDays: Int
    ) throws -> SecCertificate {
        let now = Date()
        // Backdate validity slightly so trust evaluation is resilient to small clock skew.
        let notBefore = now.addingTimeInterval(-300)
        guard let notAfter = Calendar.current.date(byAdding: .day, value: validityDays, to: now) else {
            throw CertificateError.validityDateCalculationFailed
        }

        return try X509CertificateBuilder.buildCertificate(
            subject: subject,
            issuer: issuer,
            subjectPrivateKey: subjectPrivateKey,
            signingKey: signingKey,
            notBefore: notBefore,
            notAfter: notAfter,
            isCA: isCA
        )
    }

    // MARK: - Keychain Storage

    /// Stores a certificate in the keychain.
    private func storeCertificateInKeychain(_ certificate: SecCertificate, label: String) throws {
        SecurityLog.keychain.debug("event=keychain.store outcome=pending label=\(label, privacy: .private(mask: .hash))")

        let accessGroup = try requireKeychainAccessGroup()
        var existingQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnRef as String: true
        ]

        var existingRef: CFTypeRef?
        let existingStatus = SecItemCopyMatching(existingQuery as CFDictionary, &existingRef)
        if existingStatus == errSecSuccess {
            SecurityLog.keychain.debug("event=keychain.store outcome=exists label=\(label, privacy: .private(mask: .hash))")
            return
        } else if existingStatus != errSecItemNotFound {
            let message = SecCopyErrorMessageString(existingStatus, nil) as String? ?? "unknown"
            SecurityLog.keychain.error("event=keychain.store outcome=failure status=\(existingStatus) error=\(message)")
            throw CertificateError.keychainStorageFailed(existingStatus)
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        addQuery[kSecAttrAccessGroup as String] = accessGroup

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            SecurityLog.keychain.debug("event=keychain.store outcome=success label=\(label, privacy: .private(mask: .hash))")
        } else if status == errSecDuplicateItem {
            SecurityLog.keychain.debug("event=keychain.store outcome=duplicate label=\(label, privacy: .private(mask: .hash))")
        } else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            SecurityLog.keychain.error("event=keychain.store outcome=failure status=\(status) error=\(message)")
            throw CertificateError.keychainStorageFailed(status)
        }
    }

    // MARK: - Certificate Export

    /// Exports the Root CA certificate as DER data for installation.
    public func exportRootCertificate() throws -> Data {
        let (certificate, _) = try getRootCA()
        return SecCertificateCopyData(certificate) as Data
    }

    /// Checks whether the Root CA certificate is installed and trusted by the system.
    /// - Important: Do not trust-evaluate the Root CA directly; validate a leaf certificate instead.
    public func isRootCATrusted() -> Bool {
        SecurityLog.certificate.debug("event=ca.trust_check outcome=pending method=leaf_validation")
        do {
            // Rationale: Validate trust using a leaf certificate to mirror real client behavior.
            let testHost = "example.com"

            let (rootCert, rootPrivateKey) = try getRootCA()

            let rootFingerprint = computeFingerprint(for: rootCert)
            SecurityLog.certificate.debug(
                "event=ca.trust_check fingerprint=\(rootFingerprint.prefix(16), privacy: .private)..."
            )

            // Rationale: Use an ephemeral leaf key to keep the trust check side-effect free.
            let keyAttributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: false
                ]
            ]
            var keyError: Unmanaged<CFError>?
            guard let leafPrivateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &keyError) else {
                let errorDesc = keyError?.takeRetainedValue().localizedDescription ?? "unknown"
                SecurityLog.crypto.debug("event=crypto.ephemeral_keygen outcome=failure error=\(errorDesc)")
                return false
            }
            let leafCert = try createSignedCertificate(
                commonName: testHost,
                subjectPrivateKey: leafPrivateKey,
                signingKey: rootPrivateKey,
                isCA: false
            )

            // Safety: Do not provide the Root CA as a custom anchor; it can yield false positives.
            let sslPolicy = SecPolicyCreateSSL(true, testHost as CFString)
            var trust: SecTrust?
            let status = SecTrustCreateWithCertificates(leafCert, sslPolicy, &trust)
            guard status == errSecSuccess, let trust else {
                SecurityLog.certificate.debug("event=ca.trust_create outcome=failure status=\(status)")
                return false
            }

            // Rule: Avoid network fetch during trust evaluation.
            SecTrustSetNetworkFetchAllowed(trust, false)

            var error: CFError?
            let ok = SecTrustEvaluateWithError(trust, &error)
            if ok {
                SecurityLog.certificate.debug("event=ca.trust_evaluate outcome=success")
            } else {
                let errorDesc = (error as Error?)?.localizedDescription ?? "unknown"
                SecurityLog.certificate.debug("event=ca.trust_evaluate outcome=failure error=\(errorDesc)")
                // Rationale: Log detailed trust properties to diagnose installation issues.
                if let properties = SecTrustCopyProperties(trust) as? [[String: Any]] {
                    for prop in properties {
                        if let title = prop[kSecPropertyTypeTitle as String] as? String,
                           let errorMsg = prop[kSecPropertyTypeError as String] as? String {
                            SecurityLog.certificate.log(level: .debug, "event=ca.trust_property title=\(title) error=\(errorMsg)")
                        }
                    }
                }
            }
            return ok
        } catch {
            SecurityLog.certificate.debug("event=ca.trust_check outcome=failure error=\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Root CA Fingerprint & Mismatch Detection

    /// Computes the SHA-256 fingerprint of the current Root CA certificate.
    /// - Returns: A hex-encoded string or nil when the Root CA does not exist.
    public func getRootCAFingerprint() -> String? {
        do {
            let (certificate, _) = try getRootCA()
            return computeFingerprint(for: certificate)
        } catch {
            return nil
        }
    }

    /// Computes the SHA-256 fingerprint for a certificate.
    private func computeFingerprint(for certificate: SecCertificate) -> String {
        let derData = SecCertificateCopyData(certificate) as Data
        let hash = SHA256.hash(data: derData)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the fingerprint formatted for display with colon-separated pairs.
    public func getRootCAFingerprintFormatted() -> String? {
        guard let fingerprint = getRootCAFingerprint() else { return nil }
        return formatFingerprint(fingerprint)
    }

    /// Formats a fingerprint string with colons for readability.
    private func formatFingerprint(_ fingerprint: String) -> String {
        var result = ""
        for (index, char) in fingerprint.enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }
        return result.uppercased()
    }

    /// Returns the creation date of the Root CA from its notBefore field.
    public func getRootCACreationDate() -> Date? {
        do {
            let (certificate, _) = try getRootCA()
            return extractNotBeforeDate(from: certificate)
        } catch {
            return nil
        }
    }

    /// Extracts the notBefore date using SecCertificateCopyValues when available.
    private func extractNotBeforeDate(from certificate: SecCertificate) -> Date? {
        // Prefer swift-certificates parsing on all platforms.
        if let parsed = try? Certificate(certificate) {
            return parsed.notValidBefore
        }

        #if os(macOS)
        // Rationale: macOS exposes SecCertificateCopyValues for structured access.
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate, nil, &error) as? [String: Any] else {
            return nil
        }

        // Rationale: The validity period is exposed under the notBefore OID.
        // Rationale: "2.5.4.24" is a common OID for X509v1 notBefore values.
        let validityOIDs = [
            "2.5.4.24",
            kSecOIDX509V1ValidityNotBefore as String
        ]

        for oid in validityOIDs {
            if let validityDict = values[oid] as? [String: Any],
               let dateValue = validityDict[kSecPropertyKeyValue as String] as? Date {
                return dateValue
            }
        }

        // Edge case: Fall back to searching for any notBefore-like value.
        for (_, value) in values {
            if let dict = value as? [String: Any],
               let label = dict[kSecPropertyKeyLabel as String] as? String,
               label.lowercased().contains("not before") || label.lowercased().contains("notbefore"),
               let dateValue = dict[kSecPropertyKeyValue as String] as? Date {
                return dateValue
            }
        }

        return nil
        #else
        // Rationale: iOS lacks SecCertificateCopyValues, so parse DER directly.
        let derData = SecCertificateCopyData(certificate) as Data
        return parseNotBeforeDateFromDER(derData)
        #endif
    }

    /// Parses the notBefore date from DER-encoded certificate data.
    /// - Note: Minimal ASN.1 parser that assumes a standard TBSCertificate layout.
    private func parseNotBeforeDateFromDER(_ data: Data) -> Date? {
        // Rationale: Parse only the TBSCertificate validity fields to keep this minimal.

        guard data.count > 10 else { return nil }

        var offset = 0

        func readTagAndLength() -> (tag: UInt8, length: Int, headerSize: Int)? {
            guard offset < data.count else { return nil }
            let tag = data[offset]
            offset += 1

            guard offset < data.count else { return nil }
            var length = Int(data[offset])
            var headerSize = 2
            offset += 1

            if length > 127 {
                let numBytes = length & 0x7F
                length = 0
                for _ in 0 ..< numBytes {
                    guard offset < data.count else { return nil }
                    length = (length << 8) | Int(data[offset])
                    offset += 1
                    headerSize += 1
                }
            }

            return (tag, length, headerSize)
        }

        guard let outer = readTagAndLength(), outer.tag == 0x30 else { return nil }

        guard let tbs = readTagAndLength(), tbs.tag == 0x30 else { return nil }
        // Rationale: Only the tag matters; the TBSCertificate length is not needed.
        _ = tbs

        if offset < data.count, data[offset] == 0xA0 {
            guard let ver = readTagAndLength() else { return nil }
            offset += ver.length
        }

        guard let serial = readTagAndLength(), serial.tag == 0x02 else { return nil }
        offset += serial.length

        guard let sig = readTagAndLength(), sig.tag == 0x30 else { return nil }
        offset += sig.length

        guard let issuer = readTagAndLength(), issuer.tag == 0x30 else { return nil }
        offset += issuer.length

        guard let validity = readTagAndLength(), validity.tag == 0x30 else { return nil }

        guard let notBefore = readTagAndLength(),
              notBefore.tag == 0x17 || notBefore.tag == 0x18 else { return nil }

        let timeData = data.subdata(in: offset ..< offset + notBefore.length)
        guard let timeString = String(data: timeData, encoding: .ascii) else { return nil }

        return parseASN1Time(timeString, isGeneralized: notBefore.tag == 0x18)
    }

    /// Parses ASN.1 UTCTime or GeneralizedTime values.
    private func parseASN1Time(_ string: String, isGeneralized: Bool) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")

        var timeString = string
        if timeString.hasSuffix("Z") {
            timeString = String(timeString.dropLast())
        }

        if isGeneralized {
            formatter.dateFormat = "yyyyMMddHHmmss"
        } else {
            formatter.dateFormat = "yyMMddHHmmss"
        }

        return formatter.date(from: timeString)
    }

    /// Stores the current Root CA fingerprint as the known trusted fingerprint.
    /// - Important: Call this after the user installs and trusts the certificate.
    public func saveKnownFingerprint() {
        guard let fingerprint = getRootCAFingerprint() else { return }
        UserDefaults.standard.set(fingerprint, forKey: knownFingerprintKey)
        SecurityLog.certificate.info("event=ca.fingerprint_saved outcome=success fingerprint=\(fingerprint.prefix(16), privacy: .private)...")
    }

    /// Returns the stored known fingerprint or nil if none was saved.
    public func getKnownFingerprint() -> String? {
        UserDefaults.standard.string(forKey: knownFingerprintKey)
    }

    /// Clears the stored known fingerprint.
    /// - Important: Call this when the Root CA is regenerated.
    public func clearKnownFingerprint() {
        UserDefaults.standard.removeObject(forKey: knownFingerprintKey)
        SecurityLog.certificate.info("event=ca.fingerprint_cleared outcome=success")
    }

    /// Checks whether the current Root CA matches the known fingerprint.
    /// - Returns: A status value suitable for UI display.
    public func checkRootCAStatus() -> RootCAStatus {
        guard let currentFingerprint = getRootCAFingerprint() else {
            return .notGenerated
        }

        guard let knownFingerprint = getKnownFingerprint() else {
            // Rationale: Re-seed when a trusted Root exists but the known fingerprint is missing.
            if isRootCATrusted() {
                UserDefaults.standard.set(currentFingerprint, forKey: knownFingerprintKey)
                SecurityLog.certificate.info("event=ca.fingerprint_reseeded outcome=success fingerprint=\(currentFingerprint.prefix(16), privacy: .private)...")
                return .trustedAndMatching(fingerprint: currentFingerprint)
            }
            return .notInstalled(currentFingerprint: currentFingerprint)
        }

        if currentFingerprint == knownFingerprint {
            let trusted = isRootCATrusted()
            if trusted {
                return .trustedAndMatching(fingerprint: currentFingerprint)
            } else {
                return .matchingButNotTrusted(fingerprint: currentFingerprint)
            }
        } else {
            return .mismatch(
                currentFingerprint: currentFingerprint,
                installedFingerprint: knownFingerprint
            )
        }
    }

    /// Posts a notification when a Root CA mismatch is detected.
    /// - Note: Call this on app launch or before starting the MITM proxy.
    public func checkAndNotifyMismatch() {
        let status = checkRootCAStatus()
        if case .mismatch = status {
            NotificationCenter.default.post(
                name: Self.rootCAMismatchNotification,
                object: nil,
                userInfo: ["status": status]
            )
            SecurityLog.certificate.warning("event=ca.mismatch_detected outcome=failure action=reinstall_required")
        }
    }

    /// Deletes the existing Root CA and private key so a fresh one can be generated.
    /// - Important: Use this when HTTPS MITM keeps failing after installation and trust.
    public func resetRootCA() throws {
        SecurityLog.certificate.info("event=ca.reset outcome=pending")

        SecurityLog.certificate.debug("event=ca.reset_cache outcome=pending")
        clearRuntimeCaches()

        SecurityLog.certificate.debug("event=ca.reset_domain_certs outcome=pending")
        let accessGroup = try requireKeychainAccessGroup()
        deletePerDomainCertificates(accessGroup: accessGroup)

        SecurityLog.keychain.debug("event=keychain.access_group outcome=success group=\(accessGroup, privacy: .private)")

        SecurityLog.keychain.debug("event=keychain.delete_ca_cert outcome=pending")
        var certDelete: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: rootCALabel,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let certStatus = SecItemDelete(certDelete as CFDictionary)
        SecurityLog.keychain.debug("event=keychain.delete_ca_cert status=\(certStatus)")

        SecurityLog.keychain.debug("event=keychain.delete_ca_key outcome=pending")
        var keyDelete: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data("com.trace.rootca.private".utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let keyStatus = SecItemDelete(keyDelete as CFDictionary)
        SecurityLog.keychain.debug("event=keychain.delete_ca_key status=\(keyStatus)")

        SecurityLog.certificate.debug("event=ca.clear_fingerprint outcome=pending")
        clearKnownFingerprint()

        SecurityLog.certificate.info("event=ca.reset outcome=success")
    }

    /// Exports the Root CA certificate as a PEM string.
    public func exportRootCertificatePEM() throws -> String {
        let derData = try exportRootCertificate()
        let base64 = derData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----"
    }

    /// Saves the Root CA certificate to a file URL for sharing.
    public func saveRootCertificateToFile() throws -> URL {
        let derData = try exportRootCertificate()

        // Rationale: Use the Documents directory for better share sheet compatibility.
        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CertificateError.fileSystemError("Documents directory not available")
        }
        let fileURL = documentsDir.appendingPathComponent("TraceRootCA.cer")

        try? FileManager.default.removeItem(at: fileURL)

        // Rule: Use a protection level compatible with share sheet access after first unlock.
        try derData.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path
        )

        // Safety: Verify the file exists and is readable before returning it.
        guard FileManager.default.fileExists(atPath: fileURL.path),
              FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw CertificateError.fileSystemError("Certificate file not accessible after creation")
        }

        SecurityLog.certificate.info("event=cert.save_file outcome=success path=\(fileURL.path, privacy: .private(mask: .hash))")
        return fileURL
    }

    private func deletePerDomainCertificates(accessGroup: String) {
        // Rule: Only delete items created by Trace to avoid collateral keychain removal.
        var certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        certQuery[kSecAttrAccessGroup as String] = accessGroup

        var certResult: CFTypeRef?
        if SecItemCopyMatching(certQuery as CFDictionary, &certResult) == errSecSuccess,
           let certs = certResult as? [[String: Any]] {
            for cert in certs {
                guard let label = cert[kSecAttrLabel as String] as? String,
                      label.hasPrefix("Trace - ") else {
                    continue
                }
                var deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassCertificate,
                    kSecAttrLabel as String: label,
                    kSecAttrAccessGroup as String: accessGroup
                ]
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }

        var keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        keyQuery[kSecAttrAccessGroup as String] = accessGroup

        var keyResult: CFTypeRef?
        if SecItemCopyMatching(keyQuery as CFDictionary, &keyResult) == errSecSuccess,
           let keys = keyResult as? [[String: Any]] {
            for key in keys {
                guard let tagData = key[kSecAttrApplicationTag as String] as? Data,
                      let tag = String(data: tagData, encoding: .utf8),
                      tag.hasPrefix("com.trace.domain.") else {
                    continue
                }
                var deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassKey,
                    kSecAttrApplicationTag as String: tagData,
                    kSecAttrAccessGroup as String: accessGroup
                ]
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }
    }
}

// MARK: - Errors

public enum CertificateError: LocalizedError {
    case keyGenerationFailed(CFError?)
    case publicKeyExtractionFailed
    case keychainAccessGroupUnavailable
    case rootCAIncompleteInKeychain
    case rootCANotFound
    case privateKeyNotFound
    case certificateNotFound
    case keychainStorageFailed(OSStatus)
    case validityDateCalculationFailed
    case fileSystemError(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case let .keyGenerationFailed(error):
            "Failed to generate key: \(error?.localizedDescription ?? "unknown error")"
        case .publicKeyExtractionFailed:
            "Failed to extract public key"
        case .keychainAccessGroupUnavailable:
            "Shared keychain access group is unavailable. Ensure Keychain Sharing is enabled and the app + VPN extension both include the same access group (e.g. $(AppIdentifierPrefix)com.justin.trace)."
        case .rootCAIncompleteInKeychain:
            "Root CA keychain items are incomplete (certificate or private key missing). Use Reset CA and reinstall/trust the new certificate."
        case .rootCANotFound:
            "Root CA certificate not found in keychain"
        case .privateKeyNotFound:
            "Private key not found in keychain"
        case .certificateNotFound:
            "Certificate not found in keychain"
        case let .keychainStorageFailed(status):
            "Failed to store in keychain: \(status)"
        case .validityDateCalculationFailed:
            "Failed to calculate certificate validity dates"
        case let .fileSystemError(message):
            "File system error: \(message)"
        case let .notImplemented(message):
            "Not implemented: \(message)"
        }
    }
}

// MARK: - Root CA Status

/// Represents the current status of the Root CA certificate.
public enum RootCAStatus: Equatable {
    /// Indicates no Root CA has been generated yet.
    case notGenerated

    /// Indicates the Root CA exists but the user has not completed installation.
    case notInstalled(currentFingerprint: String)

    /// Indicates the Root CA matches the installed certificate but is not trusted.
    case matchingButNotTrusted(fingerprint: String)

    /// Indicates the Root CA is installed, trusted, and fingerprints match.
    case trustedAndMatching(fingerprint: String)

    /// Indicates the current Root CA does not match the installed certificate.
    case mismatch(currentFingerprint: String, installedFingerprint: String)

    /// Provides a human-readable description for UI.
    public var description: String {
        switch self {
        case .notGenerated:
            "Root CA not generated"
        case .notInstalled:
            "Root CA not installed"
        case .matchingButNotTrusted:
            "Installed but not trusted"
        case .trustedAndMatching:
            "Trusted"
        case .mismatch:
            "Certificate mismatch"
        }
    }

    /// Indicates whether HTTPS decryption is available for this status.
    public var canDecryptHTTPS: Bool {
        if case .trustedAndMatching = self {
            return true
        }
        return false
    }

    /// Indicates whether user action is required.
    public var requiresUserAction: Bool {
        switch self {
        case .trustedAndMatching:
            false
        default:
            true
        }
    }

    /// Provides an action hint for the user.
    public var actionHint: String {
        switch self {
        case .notGenerated:
            "Generate and install the Root CA certificate"
        case .notInstalled:
            "Install and trust the Root CA certificate"
        case .matchingButNotTrusted:
            "Enable full trust in Settings → General → About → Certificate Trust Settings"
        case .trustedAndMatching:
            "HTTPS decryption is ready"
        case .mismatch:
            "Root CA was regenerated. Please reinstall the new certificate."
        }
    }
}

// MARK: - Certificate Info Extension

public extension SecCertificate {
    var commonName: String? {
        var commonName: CFString?
        SecCertificateCopyCommonName(self, &commonName)
        return commonName as String?
    }

    var summary: String {
        SecCertificateCopySubjectSummary(self) as String? ?? "Unknown"
    }
}
