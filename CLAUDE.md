# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

- Xcode 26.2 (Swift 6 toolchain), iOS 16.0+ deployment target
- Open `Trace.xcodeproj` and run on a **physical device** — packet tunnel is unavailable in Simulator
- Submodules must be initialized: `git submodule update --init --recursive`
- Build QUIC library (only needed when updating the quiche submodule): `Tools/QUIC/build_quiche_apple.sh` (requires Rust/Cargo)

## Tests

Run full suite from CLI:
```bash
xcodebuild test \
  -project Trace.xcodeproj \
  -scheme Trace \
  -testPlan Trace \
  -destination 'platform=iOS Simulator,name=<Your Simulator Name>'
```

Run a specific test class or method:
```bash
xcodebuild test \
  -project Trace.xcodeproj \
  -scheme Trace \
  -testPlan Trace \
  -destination 'platform=iOS Simulator,name=<Your Simulator Name>' \
  -only-testing:TraceTests/<TestClassName>/<testMethodName>
```

VPN/packet-tunnel end-to-end tests require a physical device.

## Lint & Format

```bash
# Format check (CI enforced)
swiftformat --lint . --config .swiftformat

# Format fix
swiftformat --fix . --config .swiftformat

# Lint (CI enforced, strict mode)
swiftlint lint --strict --config .swiftlint.yml
```

## Commit Style

Conventional Commits titles: `feat(vpn): ...`, `fix(ui): ...`, `refactor(proxy): ...`

## Architecture

The project uses Swift Package Manager with four dependency layers:

### Layer 1 — Foundation
- **TraceCore**: models, GRDB-backed SQLite storage (app group shared), NIO runtime lifecycle, throttling, configuration, logging
- **TraceCompression**: Brotli/Deflate/Zstd decompression

### Layer 2 — Infrastructure
- **TraceSecurity**: X.509 cert generation, TLS, root CA for MITM
- **TraceNetworking**: DNS parsing, network diagnostics
- **TracePacket**: IP/TCP/UDP packet parsing and TCP/UDP flow reassembly
- **TraceQUIC**: QUIC/HTTP3 via quiche FFI bindings (`CQuicheFFI` target), MITM abstractions
- **HevSocks5Tunnel**: C submodule for full-tunnel tun2socks forwarding (`ThirdParty/hev-socks5-tunnel/`)

### Layer 3 — Features
- **TraceProxy**: NIO-based MITM proxy engine (`NIOMITMProxyEngine.swift`), HTTP/1.1 + HTTP/2 + WebSocket interception, PCAP/NDJSON logging
- **TraceFeatures**: 18+ sub-modules — VPN management, request execution, rewrite rules, breakpoints, request maps, HAR/cURL export, scripting, profiles, widgets, notifications, data cleanup
- **TraceUI**: shared SwiftUI components

### Layer 4 — Targets
- **Trace** (main app): ViewModels, Repositories, SwiftUI views. App-originated traffic captured via `Trace/NetworkInterceptor.swift` (URLProtocol-based — intentional exception to the NIO path)
- **TraceVPN** (Network Extension): `PacketTunnelProvider.swift` entry point, SOCKS5 server, UDP forwarding, QUIC flow routing
- **TraceWidget** (WidgetKit): live activities and quick stats

### Networking Architecture
- **Shared runtime**: `TraceCore/Networking/NIORuntime.swift` — NIOTSEventLoopGroup + AsyncHTTPClient lifecycle
- **Request execution**: `TraceFeatures/Request/RequestExecutor.swift` uses AsyncHTTPClient
- **MITM proxy**: `TraceProxy/MITM/MITMProxyServer.swift` → `NIOMITMProxyEngine.swift` (NIOSSL TLS)
- **VPN path**: `TraceVPN/Providers/LocalSocks5Server.swift`, `UDPForwarder.swift`, `HevSocks5TunnelForwarder.swift`

## Bundle IDs & App Group

| Item | Default |
|---|---|
| App | `com.justin.trace` |
| VPN extension | `com.justin.trace.vpn` — must match `providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift` |
| Widget | `com.justin.trace.tracewidget` |
| App Group | `group.com.justin.trace` — shared across app, VPN extension, and widget |
| Keychain group | `$(AppIdentifierPrefix)com.justin.trace` |

## Key Technical Context

- **Swift 6 strict concurrency**: all types crossing actor boundaries must be `Sendable`; avoid introducing data races
- **Multi-target storage**: GRDB SQLite in the app group container is read/written by all three targets
- **QUIC submodule**: `ThirdParty/quiche/` is a Rust library; `CQuicheFFI` wraps the compiled `.xcframework` in `build/quiche/`
- **Docs**: `Docs/SwiftNIO-Behavior-Parity-Contract.md` documents the NIO runtime contract; read before changing `NIORuntime.swift`
