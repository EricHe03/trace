# Trace

[![Swift](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS-blue)](#)
[![Xcode](https://img.shields.io/badge/Xcode-26.2-blue)](#)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Release](https://img.shields.io/github/v/release/6639835/Trace)](https://github.com/6639835/Trace/releases)
[![Downloads](https://img.shields.io/github/downloads/6639835/Trace/total)](https://github.com/6639835/Trace/releases)

Trace is an iOS network debugger that captures HTTP(S), WebSocket, and SSE traffic via a Network Extension packet tunnel with **full-tunnel** and **proxy-only** modes. Full-tunnel routes device traffic through the tunnel, while proxy-only relies on the VPN-provided system proxy settings. It performs on-device TLS MITM with a generated root CA, shares capture data with the main app using an App Group, and includes powerful tooling for inspection, modification, replay, and export.

## Table of Contents

- [Features](#features)
- [Project Structure](#project-structure)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Configuration](#configuration)
- [Limitations](#limitations)
- [Contributing](#contributing)
- [Authors](#authors)
- [License](#license)

## Features

- Capture via a Packet Tunnel provider in **full-tunnel** or **proxy-only (system proxy)** mode with on-device TLS MITM and an in-app root CA trust flow.
- Unified Network view for HTTP(S), WebSockets, and SSE with search, filters, presets, grouping, and sorting.
- Deep inspection: headers/body viewers (JSON, XML, images, SVG, multipart), timings, TLS chain details, HTTP/2 stream info + HPACK tables.
- Traffic modification: rewrite rules, request maps, host overrides, breakpoints, JavaScript scripts, and network condition profiles.
- Replay and tooling: request builder, cURL import/export, HAR import/export, and quick actions.
- Built-in utilities: Base64, URL encode/decode, JSON formatter, hash generator, timestamp converter, and more.
- Widgets: WidgetKit bundle with a widget, control widget, and Live Activity.
- Diagnostics: optional NDJSON event logging and PCAP export of captured HTTP frames.
- Config portability: import/export for rewrite rules, request maps, scripts, and hosts.
- Capture sessions: organize requests into named sessions and switch between them quickly.

## Project Structure

- `Trace`: iOS app target (UI, capture management, tooling).
- `TraceVPN`: Packet Tunnel network extension target.
- `TraceWidgetExtension`: WidgetKit + Live Activity extension target (sources in `TraceWidget`).
- `TraceWidget`: Widget sources and Live Activity views.
- SwiftPM libraries: `TraceCore`, `TraceNetworking`, `TraceSecurity`, `TraceProxy`, `TraceCompression`, `TracePacket`, `TraceFeatures`, `TraceUI`, `HevSocks5Tunnel`.
- `ThirdParty/hev-socks5-tunnel`: Vendored SOCKS5 tunnel used by `TraceVPN`.
- Tests: `TraceTests`, `TraceUITests`.

## Quick Start

Prerequisites:

- macOS with Xcode 26.2 (SwiftPM uses `swift-tools-version: 6.0`).
- iOS 16.0 deployment target (matches Xcode project and SwiftPM settings).
- Apple Developer Team with Network Extension entitlements.
- Physical iOS device for end-to-end capture (packet tunnel is unavailable in the simulator).

Steps:

1. Clone and open the project:

```bash
open Trace.xcodeproj
```

2. Update signing for all targets (App, `TraceVPN`, `TraceWidgetExtension`).
3. Set `APP_GROUP_IDENTIFIER` in Build Settings so the app, VPN extension, and widget share storage.
4. Update bundle identifiers and entitlements for App, `TraceVPN`, and `TraceWidgetExtension`.
5. If you change the extension bundle ID, update `protocolConfiguration.providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift`.
6. Build and run on a device. The app generates its own root CA in the keychain.

Optional SwiftPM workflow:

- Open `Package.swift` in Xcode 26.2 to work without the `.xcodeproj`.
- Update `bundleIdentifier` (and optionally `teamIdentifier`) in the `.iOSApplication` declaration.
- Keep using Xcode for entitlements and signing; SwiftPM does not produce the VPN/widget `.appex` bundles.

## Usage

Start a capture session:

```text
1. Launch Trace and complete onboarding (root CA install + VPN permission).
2. Go to Settings → Capture and tap Start Capture (or use the Start Capture button in Network).
3. Browse requests in the Network tab.
```

Replay a request from cURL:

```bash
curl -X POST https://api.example.com/items \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"Trace"}'
```

Import and export HAR:

```text
Settings → Data → Import/Export HAR
```

## Configuration

- App Group: set `APP_GROUP_IDENTIFIER` (the Info.plist `AppGroupIdentifier` keys in `TraceVPN` and `TraceWidgetExtension` use it). If unset, the app falls back to `group.<bundleIdentifier>`.
- Bundle IDs and entitlements: align App, `TraceVPN`, and `TraceWidgetExtension` identifiers with your team.
- Deployment target: update `Package.swift` and `Trace.xcodeproj` if you need a lower target.
- Keychain access group: keep `$(AppIdentifierPrefix)com.justin.trace` aligned if you change bundle IDs.
- VPN extension bundle ID: keep `protocolConfiguration.providerBundleIdentifier` in sync with `TraceVPN`.
- Full-tunnel mode: configure a SOCKS5 host and port in Capture settings before starting a full-tunnel session.

## Limitations

- Proxy-only mode: Trace relies on the system proxy settings from the VPN configuration, so apps that ignore proxy settings will not be captured. Use full-tunnel mode for complete traffic coverage.
- QUIC/HTTP3: Traffic is not decrypted. Depending on capture settings, it may be forwarded, blocked, or appear only as packet-level data.

## Contributing

Contributions are welcome. Please open an issue to discuss changes or send a PR with a clear description and screenshots when UI is affected.

## Authors

Justin

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
