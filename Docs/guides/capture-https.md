# Capture HTTPS Traffic

This guide walks through installing the Trace root CA, verifying the trust chain, and understanding what Trace can and cannot decrypt.

## How HTTPS MITM works in Trace

Trace intercepts HTTPS by acting as a local TLS terminator. For each domain it has permission to inspect, Trace generates a per-host certificate signed by a locally-created root CA. Your device trusts this root CA, so iOS accepts the Trace-issued leaf certificates without warnings.

For a deeper explanation see [MITM certificate model](../explanation/mitm-certificate.md).

## Install the root CA

1. In Trace, open **Settings → Certificate Setup**.
2. Tap **Install Certificate** and follow the prompt — iOS opens the Settings app and asks you to install a configuration profile.
3. Tap **Install** in the profile installer.

## Trust the root CA

Installing a profile is not enough. iOS requires explicit trust for custom root CAs.

1. Open iOS **Settings → General → VPN & Device Management**.
2. Tap the Trace profile and tap **Trust**.
3. Open iOS **Settings → General → About → Certificate Trust Settings**.
4. Find the Trace CA entry and toggle it on.

Until you complete step 3, Trace cannot decrypt HTTPS — you will see requests logged but bodies will show as encrypted.

## Verify decryption is working

1. Start a capture session.
2. Open Safari and visit any HTTPS site.
3. Tap the request in Trace.
4. The **Response** tab should show the decoded body (HTML, JSON, etc.), not binary ciphertext.
5. The **TLS** tab shows the certificate chain Trace presented to the client.

## Allowlist and blocklist

Trace respects per-domain MITM settings under **Settings → MITM Allowlist**. You can:

- Enable MITM for all domains (default when the root CA is trusted).
- Add specific domains to the blocklist to leave them end-to-end encrypted.

Blocked domains are still captured as opaque TCP flows — you see connection timing and byte counts but not decrypted content.

## Limitations

The following scenarios prevent HTTPS decryption even with the CA installed:

| Scenario | Reason |
|---|---|
| Certificate pinning | The app validates the leaf certificate fingerprint or public key, which Trace's generated cert does not match |
| Custom trust evaluation | The app calls `SecTrust` APIs directly and rejects non-built-in roots |
| Encrypted Client Hello (ECH) | The server-name indication is encrypted before Trace can intercept the handshake |
| QUIC/HTTP3 under pinning or ECH | Same constraints apply on the QUIC path |

For pinned apps, try full-tunnel mode with QUIC blocking enabled (**Settings → Full Tunnel → Block QUIC**), which forces a fallback to TCP/TLS where Trace can attempt MITM.
