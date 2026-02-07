# CLAUDE.md

This file provides guidance to Claude ​Code (claude.ai/code) when working with code in this repository.

## Project Overview

Trace is an iOS network debugger for capturing and inspecting HTTP(S), WebSocket, and SSE traffic. It's built as a local Network Extension packet tunnel with on-device TLS MITM via a self-generated root CA. All captured data stays on-device.

**Key characteristics:**
- Swift 6 toolchain with strict concurrency enabled
- iOS 16.0+ deployment target
- Requires Xcode 26.2 or newer
- Must be tested on a physical iOS device (VPN Network Extensions don't work in simulator)

## Development Commands

### Building
```bash
# Open the project
open Trace.xcodeproj

# Build via xcodebuild (use Trace scheme)
xcodebuild build -project Trace.xcodeproj -scheme "Trace (Trace)" -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

### Testing
```bash
# Run all tests via Xcode
# Cmd+U in Xcode

# Run tests via command line
xcodebuild test \
  -project Trace.xcodeproj \
  -scheme Trace \
  -testPlan Trace \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# Run a single test
xcodebuild test \
  -project Trace.xcodeproj \
  -scheme Trace \
  -only-testing:TraceTests/SSEHandlerTests/testParseBasicEvent \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

### Code Quality
```bash
# Format code with SwiftFormat
swiftformat .

# Lint code with SwiftLint
swiftlint lint

# Auto-fix SwiftLint issues
swiftlint --fix
```

## Architecture

### Module Layering

The codebase follows a strict layered architecture defined in `Package.swift`:

**Foundation Layer** (no dependencies):
- `TraceCore`: Shared models, storage (`AppGroupStorage`), logging, and core utilities
- `TraceCompression`: Compression/decompression (Brotli, Deflate, Zstd)

**Infrastructure Layer**:
- `TraceSecurity`: Certificate management and TLS handling
- `TraceNetworking`: Protocol parsers (HTTP, HTTP/2, WebSocket, SSE)
- `TracePacket`: IP/TCP parsing and packet reassembly
- `HevSocks5Tunnel`: C tunnel over SOCKS5 (external git submodule in `ThirdParty/`)

**Feature Layer**:
- `TraceProxy`: MITM proxy server and connection management
- `TraceFeatures`: Application features (VPN lifecycle, export, scripting, cleanup, breakpoints, etc.)
- `TraceUI`: Reusable SwiftUI components

**App Targets**:
- `Trace`: Main iOS app
- `TraceVPN`: Packet Tunnel Network Extension (runs in separate process)
- `TraceWidget`: Widget Extension source

### Critical Architecture Concepts

#### 1. App Group Storage (`TraceCore/Storage/AppGroupStorage.swift`)

The main app and VPN extension run in **separate processes** and share data via an **App Group container**. The App Group identifier is:
- Default: `group.com.justin.trace`
- Configurable via `Info.plist` key `AppGroupIdentifier`
- Must match across main app, VPN extension, and Widget entitlements

**Inter-process communication:**
- Network requests, WebSocket connections, SSE connections are saved as JSON files in the shared container
- Configuration (capture rules, MITM allowlist, throttling state) is stored in shared `UserDefaults` suite
- Darwin notifications (`CFNotificationCenter`) notify the main app when new data is available

#### 2. VPN Lifecycle (`TraceFeatures/VPN/VPNManager.swift`)

**VPN Manager** controls the VPN connection lifecycle:
- `initializeIfNeeded()`: Loads existing VPN configuration without prompting user
- `requestVPNPermission()`: Creates VPN configuration and triggers iOS permission prompt
- `start()`: Starts the VPN tunnel (calls `PacketTunnelProvider.startTunnel()`)
- `stop()`: Stops the VPN tunnel

**IMPORTANT:** The VPN extension bundle ID must match `providerBundleIdentifier` in `VPNManager.swift` (line 169):
```swift
protocolConfiguration.providerBundleIdentifier = "com.justin.trace.vpn"
```

#### 3. Packet Tunnel Provider (`TraceVPN/Providers/PacketTunnelProvider.swift`)

The VPN extension runs in a separate process and implements `NEPacketTunnelProvider`. It has two capture modes:

**Proxy-only mode** (default):
- Routes HTTP/HTTPS traffic through local MITM proxy (port 8888)
- Non-HTTP traffic is not captured
- Uses VPN proxy settings (`NEProxySettings`)

**Full-tunnel mode**:
- Routes all TCP/UDP traffic through the tunnel
- Uses `hev-socks5-tunnel` (C library) for tun2socks forwarding
- Supports custom DNS, IPv6, and SOCKS5 upstream proxy

**IPC between main app and VPN extension:**
- Main app sends messages via `NETunnelProviderSession.sendProviderMessage()`
- VPN extension handles messages in `handleAppMessage(_:completionHandler:)`
- Commands include: update config, update throttling state, clear requests

#### 4. MITM Proxy (`TraceProxy/MITM/MITMProxyServer.swift`)

The MITM proxy server:
- Listens on `127.0.0.1:8888`
- Intercepts HTTP/HTTPS traffic and performs TLS MITM
- Uses a self-generated root CA stored in iOS Keychain
- Saves captured requests to `AppGroupStorage`
- Supports WebSocket and SSE protocol upgrades

#### 5. Protocol Parsing

- **HTTP/HTTP2**: `TraceNetworking` contains parsers for HTTP/1.1 and HTTP/2 frames
- **WebSocket**: Handled by `TraceNetworking/WebSocket/`
- **SSE**: Handled by `TraceNetworking/SSE/SSEHandler.swift`

### Testing Considerations

- VPN functionality cannot be tested in iOS Simulator (use physical device only)
- Unit tests run in simulator and use fallback storage (not real App Group)
- Tests are excluded from SwiftFormat and SwiftLint (see `.swiftformat` and `.swiftlint.yml`)

## Configuration Files

### Bundle IDs and Identifiers

| Component | Default Bundle ID | Configuration |
|-----------|------------------|---------------|
| Main app | `com.justin.trace` | Xcode target settings |
| VPN extension | `com.justin.trace.vpn` | Must match `providerBundleIdentifier` in `VPNManager.swift` |
| Widget | `com.justin.trace.tracewidget` | `TraceWidgetExtension` target |
| App Group | `group.com.justin.trace` | Shared storage across app/extension/widget |
| Keychain group | `$(AppIdentifierPrefix)com.justin.trace` | App and VPN entitlements |

### Signing Requirements

All three targets (`Trace`, `TraceVPN`, `TraceWidgetExtension`) must:
- Use the same App Group identifier in entitlements
- Use the same Team ID
- Have Network Extension capability enabled (for VPN target)

## Git Submodules

The project includes one git submodule:
```bash
# Initialize submodules after cloning
git submodule update --init --recursive
```

Submodule location: `ThirdParty/hev-socks5-tunnel/`

## Code Style

- **Swift 6 language mode** with strict concurrency checking
- **SwiftFormat** configuration in `.swiftformat`
- **SwiftLint** configuration in `.swiftlint.yml`
- Disabled rules: `line_length`, `function_body_length`, `type_body_length` (SwiftUI views can be long)
- Opt-in rules include: `force_unwrapping`, `implicitly_unwrapped_optional`

## Common Development Pitfalls

1. **App Group misconfiguration**: If the app can't save/load requests, verify App Group entitlements match across all targets
2. **VPN bundle ID mismatch**: If VPN won't start, verify `providerBundleIdentifier` in `VPNManager.swift` matches the VPN extension's bundle ID
3. **Simulator limitations**: VPN Network Extensions don't work in simulator - test on real device
4. **Concurrent modifications**: When modifying VPN configuration while connected, use `applyProtocolRoutingDefaults()` pattern to avoid reassert cycles
5. **Swift 6 concurrency**: All types crossing concurrency boundaries must be `Sendable`. Use actors or `@unchecked Sendable` with manual synchronization.
