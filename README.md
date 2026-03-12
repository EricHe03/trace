# Trace

An iOS network debugger for capturing and inspecting HTTP(S), HTTP/2, WebSocket, SSE, DNS, UDP, and QUIC/HTTP3 traffic directly on-device.

![Swift](https://img.shields.io/badge/Swift-6%20toolchain-orange)
![Platform](https://img.shields.io/badge/platform-iOS%2016.0%2B-blue)
![Xcode](https://img.shields.io/badge/Xcode-26.x-blue)
![License](https://img.shields.io/badge/license-MIT-blue)
[Latest Release](https://github.com/Trace-iOS/Trace/releases/latest) | [Releases](https://github.com/Trace-iOS/Trace/releases)

Trace combines a local MITM proxy with a Network Extension packet tunnel and a self-generated root CA for HTTPS inspection. Captured data stays on-device unless you choose to export or share it. The app supports proxy-only, full-tunnel, and dual-MITM capture, and includes replay, rewriting, diagnostics, packet capture, and widget/live activity controls.

The repository includes both `Trace.xcodeproj` and `Package.swift`. Use the Xcode project to build and run the app and extensions. The package manifest mirrors the module graph for package-aware tooling and module-level development.

## Features

- Proxy-only, full-tunnel, and dual-MITM capture modes
- Unified capture for HTTP(S), HTTP/2, WebSocket, SSE, DNS, TCP/UDP transport events, and QUIC/HTTP3
- Request inspection for headers, bodies, timings, TLS chain, and decrypted payloads when MITM is possible
- Request replay, manual request builder, copy-as-cURL, and cURL import
- Rewrite rules, request maps, breakpoints, scripts, hosts overrides, and favorites
- Capture rules for domain filtering, body capture controls, and storage limits
- Full-tunnel controls for custom DNS, IPv6, SOCKS5 forwarding, hybrid TCP MITM, and UDP forwarding mode
- Network throttling profiles for Wi-Fi, cellular, offline, and custom conditions
- Connection, UDP-flow, and DNS diagnostics plus full-tunnel self-check tooling
- HAR import/export, PCAP capture/export, and VPN NDJSON log export
- Certificate setup wizard, MITM allowlist, notification controls, and QUIC blocking/security settings
- Home Screen widgets, Live Activity, Control Widget actions, and quick actions
- Built-in utilities for Base64, URL encoding, JSON formatting, hashes, and timestamps

## Networking Architecture

- Runtime foundation: shared NIOTS event-loop and AsyncHTTPClient lifecycle via `TraceCore/Networking/NIORuntime.swift`
- App-originated capture: `Trace/NetworkInterceptor.swift` remains URLProtocol-based for requests initiated by Trace itself
- Request execution path: `TraceFeatures/Request/RequestExecutor.swift` uses the shared AsyncHTTPClient transport abstraction
- Proxy/MITM path: `TraceProxy/MITM/MITMProxyServer.swift` delegates to `TraceProxy/MITM/NIOMITMProxyEngine.swift` for HTTP/1.1, HTTP/2, and NIOSSL-backed MITM TLS handling
- QUIC/HTTP3 path: `TraceQUIC` provides the HTTP/3 client and MITM orchestration, backed by `ThirdParty/CQuicheFFI` plus `build/quiche` artifacts produced by `Tools/QUIC`
- VPN/full-tunnel path: `TraceVPN` handles packet-tunnel routing, local SOCKS5 forwarding, UDP forwarding, PCAP capture, and NDJSON event logging

## Requirements

- macOS with Xcode 26.2 or newer
- iOS deployment target 16.0+
- Apple Developer signing with the Network Extension capability
- A physical iOS device for packet-tunnel and full-tunnel validation
- Rust is only required when rebuilding quiche artifacts in `Tools/QUIC/`

## Installation

1. Clone the repo and initialize submodules:

```bash
git clone https://github.com/Trace-iOS/Trace.git
cd Trace
git submodule update --init --recursive
```

2. Open the project:

```bash
open Trace.xcodeproj
```

3. Configure signing for `Trace`, `TraceVPN`, and `TraceWidgetExtension`.
4. Ensure all targets use the same App Group via `APP_GROUP_IDENTIFIER`.
5. If you change bundle identifiers, update the related entitlements and `providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift`.
6. Build and run on a physical device.

## Quick Start

1. Complete onboarding and allow Trace to install the VPN configuration.
2. Install and trust the Trace root CA if you want HTTPS decryption.
3. Choose a capture mode in `Settings -> Capture Mode`.
4. Start capture from the `Network` tab or the widget/control widget.
5. Generate traffic from other apps, then inspect requests, DNS activity, WebSocket/SSE events, and connection diagnostics inside Trace.

## App Surface

- `Network` tab: captured requests and network events, filters, favorites, replay, manual request builder, and cURL import
- `Tools` tab: rewrite rules, request maps, scripts, hosts overrides, breakpoints, and utility tools
- `Settings` tab: capture rules and modes, network conditions, connections, certificate and MITM settings, HAR import/export, packet captures, full-tunnel self-check, notifications, and storage cleanup

## Configuration Reference

| Item | Default | Notes |
|---|---|---|
| App bundle ID | `com.justin.trace` | Main app target |
| VPN bundle ID | `com.justin.trace.vpn` | Must match `providerBundleIdentifier` in `VPNManager` |
| Widget bundle ID | `com.justin.trace.tracewidget` | `TraceWidgetExtension` target |
| App Group | `group.com.justin.trace` | Shared storage across app, VPN extension, and widget |
| Keychain group | `$(AppIdentifierPrefix)com.justin.trace` | App and VPN entitlements |

## Project Structure

```text
Trace/
├── Trace.xcodeproj/              # Xcode project used for app + extension builds
├── Package.swift                 # SwiftPM manifest that mirrors the module graph
├── Docs/                         # Architecture notes and capture test plans
├── Trace/                        # Main iOS app target
├── TraceVPN/                     # Packet Tunnel extension source
├── TraceWidget/                  # Widget source used by TraceWidgetExtension
├── TraceCore/                    # Models, storage, logging, shared utilities
├── TraceCompression/             # Brotli, Deflate, and Zstd decoding
├── TraceNetworking/              # DNS parsing and shared networking diagnostics
├── TraceSecurity/                # Certificate and TLS handling
├── TraceQUIC/                    # QUIC/HTTP3 client and MITM pipeline
├── TraceProxy/                   # MITM proxy and capture pipeline
├── TracePacket/                  # Packet parsing and TCP/UDP reassembly
├── TraceFeatures/                # Feature modules (VPN, export, scripting, cleanup, etc.)
├── TraceUI/                      # Shared SwiftUI components and design system
├── TraceTests/                   # Unit tests
├── TraceUITests/                 # UI tests
├── ThirdParty/CQuicheFFI/        # C shim layer over quiche APIs
├── ThirdParty/quiche/            # Git submodule: QUIC/HTTP3 implementation
├── ThirdParty/hev-socks5-tunnel/ # Git submodule: full-tunnel SOCKS5 forwarding
└── Tools/QUIC/                   # quiche build and verification scripts
```

Generated QUIC build artifacts live under `build/quiche/` after running the scripts in `Tools/QUIC/`.

## Documentation

- [Docs/StreamInterceptionV2.md](Docs/StreamInterceptionV2.md) describes the stream interception design
- [Docs/SwiftNIO-Behavior-Parity-Contract.md](Docs/SwiftNIO-Behavior-Parity-Contract.md) documents the expected NIO behavior contract
- [Docs/SwiftNIO-E2E-Capture-Test-Plan.md](Docs/SwiftNIO-E2E-Capture-Test-Plan.md) outlines end-to-end capture validation

## Testing

Run the same base checks that CI runs:

```bash
xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' build-for-testing

xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' test-without-building

swiftformat --lint . --config .swiftformat
swiftlint lint --strict --config .swiftlint.yml
```

For QUIC toolchain changes, also run:

```bash
./Tools/QUIC/build_quiche_apple.sh
./Tools/QUIC/verify_quiche_symbols.sh build/quiche/quiche.xcframework
```

CI also sets an explicit `DerivedData` path, disables simulator code signing, and writes an `.xcresult` bundle for uploads.

## Limitations

- Apps that ignore system proxy settings generally require full-tunnel mode
- Certificate pinning or custom trust validation prevents HTTPS MITM decryption
- QUIC/HTTP3 decryption requires the relevant MITM path plus a trusted root CA and may still fail under pinning or ECH constraints
- Packet-tunnel behavior cannot be fully validated in the iOS Simulator

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and PR guidance, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for participation standards. Commit messages follow Conventional Commits (`type(scope): summary`).

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting guidance.

## Authors

Justin ([Trace-iOS](https://github.com/Trace-iOS))

## License

MIT. See [LICENSE](LICENSE).

[Report Issues](https://github.com/Trace-iOS/Trace/issues) | [Request Features](https://github.com/Trace-iOS/Trace/issues/new)
