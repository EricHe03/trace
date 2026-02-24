# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Trace is a modular Swift 6 iOS network debugger. It implements a local Network Extension packet tunnel with on-device TLS MITM (via a self-generated root CA) to capture and inspect HTTP(S), WebSocket, SSE, and QUIC/HTTP3 traffic.

## Build & Test Commands

```bash
# After cloning — pull submodules
git submodule update --init --recursive

# Open for local development
open Trace.xcodeproj

# CI-aligned simulator build
xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  build-for-testing

# Run tests (from built artifacts)
xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  test-without-building

# Run via Xcode: Cmd+U

# Formatting check
swiftformat --lint . --config .swiftformat

# Lint check (strict)
swiftlint lint --strict --config .swiftlint.yml

# Build quiche XCFramework (requires Rust toolchain)
./Tools/QUIC/build_quiche_apple.sh
./Tools/QUIC/verify_quiche_symbols.sh build/quiche/quiche.xcframework
```

**Note:** Packet-tunnel behavior cannot be fully validated in iOS Simulator — physical device required for VPN extension testing.

## Architecture

### Module Layers (SPM)

Dependencies flow strictly from bottom to top:

1. **Foundation** (no external deps beyond NIO): `TraceCore` (models, storage, logging), `TraceCompression`
2. **Infrastructure**: `TraceSecurity` (TLS/certs), `TraceNetworking` (DNS), `TracePacket` (TCP/UDP parsing), `TraceQUIC` (HTTP/3 MITM), `HevSocks5Tunnel` (C submodule)
3. **Feature**: `TraceProxy` (MITM engine), `TraceFeatures` (VPN, export, scripting, rewrite, etc.), `TraceUI` (shared SwiftUI components)
4. **App Targets**: `Trace` (main app), `TraceVPN` (packet tunnel extension), `TraceWidget` (widget extension)

### Key Architectural Components

**Shared NIO Runtime** (`TraceCore/Networking/NIORuntime.swift`): Single shared NIOTS `EventLoopGroup` + `AsyncHTTPClient` instance. Context-aware lifecycle (app vs. network extension vs. tests) with reference counting. All network operations share this runtime.

**MITM Proxy** (`TraceProxy/MITM/`): `MITMProxyServer` delegates to `NIOMITMProxyEngine` (NIO-based, HTTP/1.1 codec + HTTP/2 streams + NIOSSL TLS). Default ingress is explicit CONNECT; transparent TLS ClientHello ingress is behind a runtime config flag. App-originated traffic uses `Trace/NetworkInterceptor.swift` (URLProtocol-based — intentional exception).

**App Group Storage** (`TraceCore/Storage/AppGroupStorage.swift`): Shared file container (`group.com.justin.trace`) between app and VPN extension. Stores captured requests, WS/SSE connections, sessions, flows, config. Falls back to local container in simulator/tests.

**VPN Extension** (`TraceVPN/`): `PacketTunnelProvider` → `LocalSocks5Server` (full-tunnel SOCKS5) + `QUICFlowRouter` (UDP/QUIC detection) + `HevSocks5TunnelForwarder` (tun2socks C submodule). Three capture modes: proxy-only, full-tunnel, full-tunnel dual MITM.

**HTTP/3 QUIC** (`TraceQUIC/`): Quiche (Rust, Cloudflare) compiled to `quiche.xcframework`. `CQuicheFFI/` (C shim) isolates ABI. Swift wrappers: `HTTP3MitmPipeline`, `QUICMitmSession`, `HTTP3Bridge` (HTTP/3 ↔ HTTP/1.1 translation for inspection).

**Main App** (`Trace/`): SwiftUI + `@Observable`/`ObservableObject` ViewModels. Repository pattern for data access (`ConfigurationRepository`, `NetworkRequestRepository`, etc.). Entry point is `TraceApp.swift`.

### Bundle IDs & App Group

| Target | Bundle ID |
|---|---|
| Main app | `com.justin.trace` |
| VPN extension | `com.justin.trace.vpn` |
| Widget | `com.justin.trace.tracewidget` |
| App Group | `group.com.justin.trace` |

If the VPN extension bundle ID changes, update `providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift`. Keep `APP_GROUP_IDENTIFIER` consistent across all targets.

## Code Style

- Swift 6 language mode; 4-space indentation (`.swiftformat` enforced)
- `UpperCamelCase` for types/protocols, `lowerCamelCase` for methods/properties
- SwiftUI views use `...View` suffix; test files use `*Tests.swift`
- Test methods: `test<Scenario>_<ExpectedResult>()` convention
- Commits follow Conventional Commits: `feat(module): ...`, `fix(module): ...`, `refactor(module)!: ...`
