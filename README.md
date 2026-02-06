# Trace

An iOS network debugger for capturing and inspecting HTTP(S), WebSocket, and SSE traffic.

![Swift](https://img.shields.io/badge/Swift-6%20toolchain-orange)
![Platform](https://img.shields.io/badge/platform-iOS%2016.0%2B-blue)
![Xcode](https://img.shields.io/badge/Xcode-26.2-blue)
![License](https://img.shields.io/badge/license-MIT-blue)
![Release](https://img.shields.io/github/v/release/Trace-iOS/Trace)
![Downloads](https://img.shields.io/github/downloads/Trace-iOS/Trace/total)

Trace is built as a local Network Extension packet tunnel with on-device TLS MITM (via a self-generated root CA). Captured data stays on-device, and you can inspect requests, replay traffic, apply rewrite rules, and export diagnostics without routing through a remote proxy.

## Features

- Proxy-only and full-tunnel capture modes
- HTTP(S), WebSocket, and SSE capture in one network timeline
- Request inspection for headers, body, timings, TLS chain, and HTTP/2 metadata
- Request replay and manual request builder
- cURL import, HAR import/export, and copy-as-cURL
- Rewrite rules, request maps, breakpoints, scripts, and hosts overrides
- Capture rules for domain filtering, body capture controls, and size limits
- Full-tunnel controls for custom DNS, IPv6, SOCKS5 forwarding, and UDP forwarding mode
- Connections and UDP flow diagnostics
- PCAP capture/export and VPN NDJSON log export
- Certificate setup wizard, MITM allowlist, and QUIC blocking controls
- Quick actions, notification actions, and Widget/Live Activity integration
- Built-in utilities (Base64, URL encode/decode, JSON formatter, hash, timestamp)

## Requirements

- macOS with Xcode 26.2 or newer
- iOS deployment target 16.0+
- Apple Developer signing with Network Extension capability
- Physical iOS device for packet-tunnel capture (simulator does not support packet tunnels)

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

3. Configure signing for targets `Trace`, `TraceVPN`, and `TraceWidgetExtension`.
4. Ensure all targets use the same App Group (`APP_GROUP_IDENTIFIER`).
5. If you change the VPN extension bundle ID, also update `providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift`.
6. Build and run on a physical device.

## Quick Start

1. Complete onboarding:
   - Optional: enable notifications.
   - Install and trust the Trace root CA in iOS Settings.
   - Allow Trace to add VPN configurations.
2. Open the Network tab and tap **Start Capture**.
3. Generate traffic from other apps and inspect requests in Trace.
4. Adjust capture behavior in Settings:
   - `Capture Rules` for domain/body capture behavior.
   - `Capture Mode` for proxy-only vs full-tunnel routing.
   - `MITM & Security` for allowlist and QUIC blocking.

## Common Workflows

- Inspect request details: Network tab -> tap a request.
- Replay a request: request row/context menu -> `Replay`.
- Build a manual request: tap `New Request` in the Network view.
- Import cURL: Network toolbar (`...`) -> `Import cURL`.
- Export HAR: Settings -> `Export HAR`.
- Import HAR: Settings -> `Import HAR`.
- Export packet captures and VPN logs: Settings -> `Packet Captures`.

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
├── Trace/                  # Main iOS app target
├── TraceVPN/               # Packet Tunnel extension source
├── TraceWidget/            # Widget source (used by TraceWidgetExtension target)
├── TraceCore/              # Models, storage, logging, shared utilities
├── TraceCompression/       # Brotli, Deflate, Zstd decoding
├── TraceNetworking/        # HTTP/HTTP2/WebSocket/SSE parsing
├── TraceSecurity/          # Certificate and TLS handling
├── TraceProxy/             # MITM proxy and capture pipeline
├── TracePacket/            # Packet parsing and TCP/UDP reassembly
├── TraceFeatures/          # Feature modules (VPN, export, scripting, cleanup, etc.)
├── TraceUI/                # Shared UI components/utilities
├── TraceTests/             # Unit tests
├── TraceUITests/           # UI tests
└── ThirdParty/hev-socks5-tunnel/  # Git submodule used by full-tunnel forwarding
```

## Testing

- Xcode: run the `Trace` scheme tests (`Cmd+U`).
- CLI example:

```bash
xcodebuild test \
  -project Trace.xcodeproj \
  -scheme Trace \
  -testPlan Trace \
  -destination 'platform=iOS Simulator,name=<Your Simulator Name>'
```

## Limitations

- Apps that ignore system proxy settings require full-tunnel mode.
- Certificate pinning/custom trust validation prevents HTTPS MITM decryption.
- QUIC/HTTP3 is not decrypted; optional QUIC blocking can force HTTP/2 in many cases.
- Packet-tunnel behavior cannot be fully validated in iOS Simulator.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and PR guidance, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for participation standards.

## Authors

Justin ([Trace-iOS](https://github.com/Trace-iOS))

## License

MIT. See [LICENSE](LICENSE).

[Report Issues](https://github.com/Trace-iOS/Trace/issues) | [Request Features](https://github.com/Trace-iOS/Trace/issues/new)
