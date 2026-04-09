# CLAUDE.md

This file provides guidance to Claude ​Code (claude.ai/code) when working with code in this repository.

## Build & Run

Use `Trace.xcodeproj` for all app/extension builds. `Package.swift` mirrors the module graph and is used for indexing and focused module work only.

```bash
# Open project
open Trace.xcodeproj

# Build for simulator testing (no signing required)
xcodebuild \
  -project Trace.xcodeproj \
  -scheme Trace \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath DerivedData \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="-" \
  build-for-testing | xcpretty

# Run tests
xcodebuild \
  -project Trace.xcodeproj \
  -scheme Trace \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath DerivedData \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="-" \
  test-without-building | xcpretty

# Format and lint
swiftformat --lint . --config .swiftformat
swiftlint lint --strict --config .swiftlint.yml
swiftformat . --config .swiftformat  # auto-fix
```

**Physical device required** for: VPN/packet tunnel, full-tunnel capture, Network Extension validation.

**Submodules** must be initialized: `git submodule update --init --recursive`

## Architecture

4-layer Swift Package Manager architecture. All layers are local packages in `Package.swift`; `Trace.xcodeproj` is the canonical app build.

### Layer 1 — Foundation
- **TraceCore**: models, GRDB SQLite storage (App Group shared), NIO runtime, logging, throttling, config
- **TraceCompression**: streaming Brotli/Deflate/Zstd decoders

### Layer 2 — Infrastructure
- **TraceSecurity**: X.509 cert generation, TLS, root CA for MITM
- **TraceNetworking**: DNS parsing, network diagnostics
- **TracePacket**: IP/TCP/UDP parsing + TCP reassembly
- **TraceQUIC**: QUIC/HTTP3 via quiche Rust FFI (`ThirdParty/CQuicheFFI` + `build/quiche/`)
- **HevSocks5Tunnel**: C TUN-to-SOCKS5 submodule (`ThirdParty/hev-socks5-tunnel/`)

### Layer 3 — Features
- **TraceProxy**: NIO MITM engine for HTTP/1.1, HTTP/2, WebSocket, SSE
- **TraceFeatures**: 17+ submodules — VPN, rewrite rules, breakpoints, scripts, export, hosts, favorites, etc.
- **TraceUI**: Shared SwiftUI components and design system tokens

### Layer 4 — Targets
- **Trace**: Main iOS app, MVVM + Repositories pattern
- **TraceVPN**: `NEPacketTunnelProvider` + local SOCKS5 server + PCAP capture
- **TraceWidget**: WidgetKit, Live Activity, Control Widget

## Capture Pipeline

Three capture paths all write to shared GRDB SQLite in the App Group container:

1. **System Proxy**: `MITMProxyServer` → `NIOMITMProxyEngine` (NIO pipeline)
2. **Full-Tunnel**: TUN device → hev-socks5-tunnel → `LocalSocks5Server` → NIO forwarding
3. **URLProtocol**: `NetworkInterceptor.swift` — intentional exception for app-originated traffic only

Key NIO handler chain in `TraceProxy/MITM/`:
- `NIOMITMInitialIngressHandler` — accepts connections, performs TLS probing
- `NIOMITMHTTPConnectHandler+Forwarding.swift` — relay/interception dispatch (largest file, ~78KB)
- `RequestInterceptor.swift` — applies rewrite rules, breakpoints, scripts

Stream interception V2 (SSE/WebSocket) lives in `TraceProxy/MITM/Streams/` behind the `hardening.enableStreamInterceptionV2` feature flag. Legacy path remains active when false.

## Key Files

| File | Purpose |
|---|---|
| `TraceCore/Networking/NIORuntime.swift` | Shared `NIOTSEventLoopGroup` + `AsyncHTTPClient` lifecycle |
| `TraceCore/Networking/DualMITMCircuitBreaker.swift` | Policy: proxy vs. MITM routing decisions |
| `TraceCore/Storage/AppGroupStorage.swift` | All cross-target data APIs (~110KB, main storage layer) |
| `TraceProxy/MITM/MITMProxyServer.swift` | Proxy entry point |
| `TraceProxy/MITM/NIOMITMProxyEngine.swift` | NIO handler orchestration |
| `TraceProxy/MITM/RequestInterceptor.swift` | Rules/breakpoints/scripts engine |
| `TraceVPN/Providers/PacketTunnelProvider.swift` | `NEPacketTunnelProvider` entry |
| `TraceVPN/Providers/LocalSocks5Server.swift` | SOCKS5 server (~41KB) |
| `TraceFeatures/VPN/VPNManager.swift` | VPN lifecycle + IPC; contains `providerBundleIdentifier` |
| `Trace/NetworkInterceptor.swift` | URLProtocol for app-originated traffic |

## Concurrency & Patterns

- **Swift 6 strict concurrency** throughout: `Sendable`, actors, no data races
- **Actors** for stateful components: `TunnelLifecycle`, `PacketTunnelRuntimeState`
- **Protocol abstractions**: `RequestExecutorTransport`, `CircuitBreakerController`, `InterceptionProviding`
- **NIO handlers** (`ChannelInboundHandler`/`ChannelOutboundHandler`) for stateful stream processing — state machines, not callbacks
- **Immutable config snapshots** taken before critical operations to avoid TOCTOU races
- **Dual MITM mode**: system proxy + full tunnel can run simultaneously; policy is coordinated via `DualMITMCircuitBreaker`
- Custom `LogCategory` protocol with per-module loggers (not `print` or `NSLog`)

## Storage

All persistent state goes through `AppGroupStorage` (GRDB SQLite in App Group `group.com.justin.trace`). Key tables: `requests`, `stream_sessions`, `stream_events`, `breakpoints`, `rewrite_rules`. Stream event journal (v2) is append-only.

## Bundle IDs & Entitlements

| Target | Bundle ID |
|---|---|
| App | `com.justin.trace` |
| VPN | `com.justin.trace.vpn` |
| Widget | `com.justin.trace.tracewidget` |
| App Group | `group.com.justin.trace` |
| Keychain | `$(AppIdentifierPrefix)com.justin.trace` |

If bundle IDs change, update entitlements for all three targets **and** `providerBundleIdentifier` in `VPNManager.swift`.

## QUIC / quiche

`build/quiche/` artifacts are **not tracked in git**. iOS builds need them; macOS package indexing does not.

```bash
./Tools/QUIC/build_quiche_apple.sh
./Tools/QUIC/verify_quiche_symbols.sh build/quiche/quiche.xcframework
```

Requires Rust with targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`.

## Tests

Unit tests: `TraceTests/` (236 files). UI tests: `TraceUITests/`. Logic-only tests: `TraceLogicTests/`.

SwiftLint excludes `TraceTests` and `TraceUITests`. Packet-tunnel and full-tunnel tests require a physical device.

## Commit Convention

Conventional Commits: `type(scope): summary` — e.g. `feat(vpn): ...`, `fix(proxy): ...`, `refactor(storage): ...`.

## Documentation

- `Docs/StreamInterceptionV2.md` — stream interception design and storage model
- `Docs/SwiftNIO-Behavior-Parity-Contract.md` — expected NIO behavior contract
- `Docs/SwiftNIO-E2E-Capture-Test-Plan.md` — end-to-end capture validation plan