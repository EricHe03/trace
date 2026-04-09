# Troubleshooting

## Setup and installation

### "VPN configuration failed to install"

**Symptom:** Trace shows an error when trying to install the VPN configuration during onboarding.

**Causes and fixes:**

- The VPN extension bundle ID in `TraceFeatures/VPN/VPNManager.swift` does not match the actual bundle ID of the `TraceVPN` target. Verify `providerBundleIdentifier` matches exactly.
- The provisioning profile for the `TraceVPN` target does not include the Network Extension entitlement. Check **Apple Developer → Certificates, IDs & Profiles → Identifiers** and confirm `com.apple.developer.networking.networkextension` is enabled for the VPN bundle ID.
- You are running in the iOS Simulator. Packet tunnel providers cannot run in Simulator.

### Root CA is installed but HTTPS is still not decrypted

**Symptom:** Requests appear in the Network tab but response bodies show as encrypted or empty.

**Checklist:**

1. Confirm full trust is enabled: iOS **Settings → General → About → Certificate Trust Settings** → Trace CA toggle must be **on**.
2. Confirm the profile is installed: iOS **Settings → General → VPN & Device Management** → Trace profile should appear.
3. Confirm the domain is not in the MITM blocklist: **Settings → MITM Allowlist**.
4. Restart the capture session after changing trust settings.

### App traffic is not appearing in the Network tab

**Symptom:** You start a capture session but the target app's traffic is not visible.

**Possible causes:**

| Cause | Fix |
|---|---|
| App bypasses system proxy | Switch to Full Tunnel mode |
| Capture mode is Proxy but app uses raw sockets | Switch to Full Tunnel mode |
| Capture session is not started | Tap **Start** on the Network tab or use the widget |
| Domain is filtered by capture rules | Check **Settings → Capture Rules → Domain Filter** |
| App is using a VPN of its own | Trace's tunnel may not take precedence |

---

## Full-tunnel mode

### Apps not captured in full-tunnel mode

Some apps install their own VPN or use a Network Extension of their own. iOS only supports one active packet tunnel at a time. If another VPN is active, Trace's tunnel may not take precedence.

Disconnect any other VPN before starting Trace in full-tunnel mode.

---

## QUIC and HTTP/3

### HTTP/3 traffic appears as opaque UDP

QUIC/HTTP3 decryption requires:

1. Full-tunnel mode (or Dual MITM).
2. Hybrid TCP MITM enabled (**Settings → Full Tunnel → Hybrid TCP MITM**).
3. The Trace root CA installed and trusted.
4. The app's QUIC implementation to not pin certificates.

If any condition is unmet, QUIC flows appear as raw UDP in the Network tab without decrypted content.

### App falls back to HTTP/2 unexpectedly

This is expected when **Block QUIC** is enabled. Trace drops UDP packets on port 443, and apps that support both HTTP/3 and HTTP/2 fall back automatically. Disable **Block QUIC** to allow HTTP/3 through.

---

## Performance and storage

### Capture slows down the device

- Dual MITM mode runs both the proxy and the packet tunnel simultaneously and has the highest CPU and memory cost. Use Proxy mode when full-tunnel is not needed.
- PCAP recording writes packet data for every flow. Disable PCAP if you do not need packet-level data: **Settings → Packet Capture → Stop**.
- Large captures fill the GRDB database. Run cleanup periodically: **Settings → Storage → Clean Up**.

### Database grows too large

Trace stores all captured requests, responses, and events in a GRDB SQLite database in the App Group container.

- Set storage limits: **Settings → Capture Rules → Storage Limit**.
- Delete old sessions: **Settings → Storage → Clean Up**.
- If the database is corrupted or abnormally large, deleting and reinstalling the app resets it. Exported HAR and PCAP files are preserved in the Files app.

---

## Build issues

### `TraceQUIC` build fails with missing quiche artifacts

The QUIC build artifacts under `build/quiche/` must exist before building for iOS. They are generated locally and are not committed to the repository. If they are missing:

```bash
git submodule update --init --recursive
./Tools/QUIC/build_quiche_apple.sh
```

Requires Rust and Cargo (`rustup` recommended).

### Swift 6 concurrency errors after modifying NIO code

Read `Docs/SwiftNIO-Behavior-Parity-Contract.md` before modifying `TraceCore/Networking/NIORuntime.swift` or any NIO channel handler. The concurrency model is intentional.

### Signing errors for `TraceVPN`

The Network Extension capability must be provisioned explicitly in the Apple Developer portal. Wildcard profiles do not support Network Extensions. Create an explicit App ID for the VPN bundle ID and enable the capability there.

---

## Getting more help

- [GitHub Issues](https://github.com/Trace-iOS/Trace/issues) — bug reports and feature requests
- [CONTRIBUTING.md](../CONTRIBUTING.md) — how to submit a PR
- [SECURITY.md](../SECURITY.md) — vulnerability reporting
