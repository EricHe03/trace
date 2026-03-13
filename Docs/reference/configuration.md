# Configuration Reference

This page lists every configurable identifier, entitlement, and build setting that wires the three targets together.

## Bundle identifiers

| Target | Default bundle ID | Xcode target name |
|---|---|---|
| Main app | `com.justin.trace` | `Trace` |
| VPN extension | `com.justin.trace.vpn` | `TraceVPN` |
| Widget extension | `com.justin.trace.tracewidget` | `TraceWidgetExtension` |

If you change any bundle ID, update:

1. The corresponding `.entitlements` file for that target.
2. `providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift` — this must match the VPN extension bundle ID exactly. A mismatch causes the VPN configuration to fail at runtime.
3. The App Group identifier in all three targets (see below).

## App Group

| Item | Default value |
|---|---|
| App Group ID | `group.com.justin.trace` |
| Build setting | `APP_GROUP_IDENTIFIER` |

All three targets must share the same App Group. The GRDB SQLite database lives in the App Group container and is read and written by the main app, the VPN extension, and the widget extension.

To change the App Group:

1. Update `APP_GROUP_IDENTIFIER` in the Xcode project build settings.
2. Update the `com.apple.security.application-groups` array in each target's `.entitlements` file.
3. Provision the new App Group in the Apple Developer portal and re-download provisioning profiles.

## Keychain group

| Item | Default value |
|---|---|
| Keychain group | `$(AppIdentifierPrefix)com.justin.trace` |

Used in the `keychain-access-groups` entitlement for the app and VPN extension. The `$(AppIdentifierPrefix)` prefix expands to your Team ID at build time.

## Entitlements summary

| Entitlement | App | VPN | Widget |
|---|---|---|---|
| `com.apple.security.application-groups` | Yes | Yes | Yes |
| `keychain-access-groups` | Yes | Yes | No |
| `com.apple.developer.networking.networkextension` | No | `packet-tunnel-provider` | No |

The Network Extension entitlement requires an explicit capability in the Apple Developer portal. It cannot be added with a wildcard provisioning profile.

## SwiftPM modules

The `Package.swift` manifest mirrors the internal module graph. Modules and their roles:

| Module | Layer | Role |
|---|---|---|
| `TraceCore` | Foundation | Models, GRDB storage, NIO runtime, logging |
| `TraceCompression` | Foundation | Brotli, Deflate, Zstd decompression |
| `TraceSecurity` | Infrastructure | X.509 cert generation, TLS, root CA |
| `TraceNetworking` | Infrastructure | DNS parsing, network diagnostics |
| `TracePacket` | Infrastructure | IP/TCP/UDP packet parsing and flow reassembly |
| `TraceQUIC` | Infrastructure | QUIC/HTTP3 via quiche FFI, MITM abstractions |
| `TraceProxy` | Features | NIO MITM proxy engine, HTTP/1.1+HTTP/2+WebSocket interception |
| `TraceFeatures` | Features | VPN management, rewrite rules, export, scripting, etc. |
| `TraceUI` | Features | Shared SwiftUI components |
| `CQuicheFFI` | Third-party | C shim over quiche QUIC/HTTP3 APIs |

## QUIC build artifacts

The quiche library is a Rust project compiled separately. Artifacts live at `build/quiche/` and are committed to the repository.

To regenerate (only needed when updating the `ThirdParty/quiche/` submodule):

```bash
./Tools/QUIC/build_quiche_apple.sh
./Tools/QUIC/verify_quiche_symbols.sh build/quiche/quiche.xcframework
```

Requires Rust and Cargo. The script cross-compiles for `arm64-apple-ios` and `arm64-apple-ios-simulator`.

## Storage locations

| Data | Location |
|---|---|
| SQLite database | App Group container (`group.com.justin.trace`), managed by GRDB |
| Root CA private key | Keychain, shared group `$(AppIdentifierPrefix)com.justin.trace` |
| Generated leaf certs | In-memory cache within `TraceSecurity`; not persisted |
| PCAP files | App Group container, managed by `TraceVPN` |
| NDJSON event log | App Group container, managed by `TraceVPN` |

## CI environment variables

GitHub Actions workflows in `.github/workflows/` use these variables:

| Variable | Value | Purpose |
|---|---|---|
| `CODE_SIGNING_ALLOWED` | `NO` | Disables signing in Simulator builds |
| `DERIVED_DATA_PATH` | `DerivedData` | Explicit DerivedData location for artifact upload |

See `.github/workflows/build-and-test.yml` for the full workflow definition.
