//
//  SecurityLog.swift
//  TraceSecurity
//
//  Created by Justin on 2026/01/11.
//

import OSLog
import TraceCore

// MARK: - Security Module Logging

/// Defines Security module loggers that follow Trace Logging Standard v1.0.
///
/// **Subsystem:** `com.trace.TraceSecurity`
///
/// ## Categories
/// | Logger | Category | Use Case |
/// |--------|----------|----------|
/// | `tls` | Security.TLS | TLS handshake and connection |
/// | `keychain` | Security.Keychain | Keychain read/write operations |
/// | `crypto` | Security.Crypto | Cryptographic operations |
/// | `certificate` | Security.Certificate | Certificate generation/validation |
///
/// ## Usage
/// ```swift
/// // TLS handshake
/// SecurityLog.tls.info("event=tls.handshake_complete outcome=success host=\(host, privacy: .private(mask: .hash))")
/// SecurityLog.tls.debug("event=tls.cipher_selected cipher=\(cipher, privacy: .public)")
///
/// // Certificate operations
/// SecurityLog.certificate.info("event=cert.generate outcome=success cn=\(cn, privacy: .private(mask: .hash))")
/// SecurityLog.certificate.debug("event=cert.cache_hit host=\(host, privacy: .private(mask: .hash))")
/// ```
///
/// ## Privacy Guidelines
/// - **MUST NOT LOG**: Private keys, raw certificates, tokens, passwords, key material
/// - Certificate fingerprints: `.private(mask: .hash)`
/// - Hostnames: `.private(mask: .hash)` for correlation
/// - Cipher suites, TLS versions: `.public`
/// - Error types/codes: `.public`
/// - Key sizes, algorithm names: `.public`
///
/// ## Console Filtering
/// ```
/// subsystem:com.trace.TraceSecurity category:Security.TLS
/// ```
public enum SecurityLog {
    /// Provides TLS handshake and connection logging.
    ///
    /// Log levels:
    /// - `.info`: Handshake complete, connection established
    /// - `.warning`: Certificate validation issues, fallback behavior
    /// - `.error`: Handshake failed, connection error
    /// - `.debug`: Cipher negotiation, protocol details
    /// - `.fault`: Security boundary violation (must not happen)
    public static let tls = TraceLog.make(
        module: .security,
        category: .securityTLS
    )

    /// Provides keychain read/write logging.
    ///
    /// Log levels:
    /// - `.info`: Item saved/retrieved successfully
    /// - `.error`: Keychain access failed
    /// - `.debug`: Query details (never log actual values)
    public static let keychain = TraceLog.make(
        module: .security,
        category: .securityKeychain
    )

    /// Provides cryptographic operation logging.
    ///
    /// Log levels:
    /// - `.info`: Operation complete
    /// - `.error`: Crypto operation failed
    /// - `.debug`: Algorithm selection, key sizes
    public static let crypto = TraceLog.make(
        module: .security,
        category: .securityCrypto
    )

    /// Provides certificate generation and validation logging.
    ///
    /// Log levels:
    /// - `.info`: Certificate generated/validated
    /// - `.warning`: Certificate expired, untrusted chain
    /// - `.error`: Generation failed, invalid certificate
    /// - `.debug`: Cache operations, certificate details
    public static let certificate = TraceLog.make(
        module: .security,
        category: .securityCertificate
    )
}

// MARK: - TLS Debug Gating

/// Gates verbose TLS debug logs behind a runtime toggle to reduce hot-path noise.
public enum TLSLog {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var verboseEnabled = false
    }

    private static let state = State()

    public static var verboseEnabled: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.verboseEnabled
    }

    public static func setVerboseEnabled(_ enabled: Bool) {
        state.lock.lock()
        state.verboseEnabled = enabled
        state.lock.unlock()
    }

    @inlinable
    public static func debug(_ message: String) {
        guard verboseEnabled else { return }
        SecurityLog.tls.debug("\(message, privacy: .public)")
    }

    @inlinable
    public static func debug(_ event: LogEvent) {
        guard verboseEnabled else { return }
        SecurityLog.tls.debug(event)
    }
}

// MARK: - Security Event Domains

/// Defines event builders for common security operations.
public extension LogEvent {
    /// Creates a TLS event.
    /// - Parameter action: The action, such as "handshake_start", "handshake_complete", or "close".
    static func tls(_ action: String) -> LogEvent {
        LogEvent(domain: "tls", action: action)
    }

    /// Creates a keychain event.
    /// - Parameter action: The action, such as "save", "retrieve", or "delete".
    static func keychain(_ action: String) -> LogEvent {
        LogEvent(domain: "keychain", action: action)
    }

    /// Creates a crypto event.
    /// - Parameter action: The action, such as "encrypt", "decrypt", "sign", or "verify".
    static func crypto(_ action: String) -> LogEvent {
        LogEvent(domain: "crypto", action: action)
    }

    /// Creates a certificate event.
    /// - Parameter action: The action, such as "generate", "validate", or "cache_lookup".
    static func cert(_ action: String) -> LogEvent {
        LogEvent(domain: "cert", action: action)
    }
}
