# Trace

**An iOS network debugger for capturing and inspecting HTTP(S), WebSocket, and SSE traffic**

![Swift](https://img.shields.io/badge/Swift-6.2-orange)
![Platform](https://img.shields.io/badge/platform-iOS%2016.0%2B-blue)
![Xcode](https://img.shields.io/badge/Xcode-26.2-blue)
![License](https://img.shields.io/badge/license-MIT-blue)
![Release](https://img.shields.io/github/v/release/Trace-iOS/Trace)
![Downloads](https://img.shields.io/github/downloads/Trace-iOS/Trace/total)

Trace is a powerful iOS network debugging tool that captures and inspects your device's HTTP(S), WebSocket, and SSE traffic in real-time. Built as a Network Extension packet tunnel, it performs on-device TLS MITM with a self-generated root CA, giving you complete visibility into network requests without routing traffic through external proxies.

Perfect for iOS developers debugging API calls, security researchers analyzing app behavior, or anyone who needs deep insight into mobile network traffic.

## Demo

![Demo](docs/assets/demo.gif)

*Placeholder: Add a GIF showing traffic capture, request inspection, and filtering*

![Network View](docs/assets/screenshot-network.png) ![Request Details](docs/assets/screenshot-details.png)

*Placeholder: Add screenshots of the Network view and Request details screen*

## Features

- **Flexible capture modes** – Full-tunnel or proxy-only mode with on-device TLS MITM
- **Unified network view** – HTTP(S), WebSocket, and SSE in one view with powerful search, filters, and grouping
- **Deep inspection** – Headers, body viewers (JSON, XML, images, multipart), timings, TLS chain, HTTP/2 streams + HPACK tables
- **Traffic modification** – Rewrite rules, request maps, host overrides, breakpoints, JavaScript scripts, and network condition profiles
- **Developer tools** – Request builder, cURL import/export, HAR import/export, and quick actions
- **Built-in utilities** – Base64, URL encode/decode, JSON formatter, hash generator, timestamp converter
- **Capture sessions** – Organize requests into named sessions and switch between them
- **Widgets & Live Activities** – WidgetKit integration for quick access
- **Export & diagnostics** – NDJSON event logging and PCAP export of captured frames

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Configuration](#configuration)
- [Project Structure](#project-structure)
- [Limitations](#limitations)
- [Contributing](#contributing)
- [License](#license)

## Installation

### Prerequisites

- macOS with Xcode 26.2 or later (Swift 6.2)
- iOS 16.0+ deployment target
- Apple Developer account with Network Extension entitlements
- Physical iOS device (packet tunnel unavailable in simulator)

### Build from Source

1. Clone the repository:

```bash
git clone https://github.com/Trace-iOS/Trace.git
cd Trace
```

2. Open the project:

```bash
open Trace.xcodeproj
```

3. Configure signing and bundle identifiers:
   - Update signing for all targets: `Trace`, `TraceVPN`, and `TraceWidgetExtension`
   - Set your team in Build Settings
   - Update bundle identifiers if needed

4. Configure App Group:
   - Set `APP_GROUP_IDENTIFIER` in Build Settings
   - Ensure all targets (App, VPN extension, Widget) use the same App Group

5. Sync VPN bundle identifier:
   - If you changed the VPN extension bundle ID, update `protocolConfiguration.providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift:69`

6. Build and run on your device

## Quick Start

### First Launch

1. **Install Root CA**
   Launch Trace and follow the onboarding flow to install the self-generated root certificate. You'll need to:
   - Save the certificate profile to Settings
   - Go to Settings → General → VPN & Device Management → Install profile
   - Go to Settings → General → About → Certificate Trust Settings → Enable trust

2. **Grant VPN Permission**
   Allow Trace to configure VPN when prompted

3. **Start Capturing**
   - Open the Network tab
   - Tap **Start Capture** (or go to Settings → Capture)
   - Browse other apps – their traffic will appear in real-time

### Capture Modes

**Proxy-only mode** (default)
Routes traffic through system proxy settings. Most apps will be captured, but some may ignore proxy settings.

**Full-tunnel mode**
Routes all device traffic through the tunnel for complete coverage. Requires configuring a SOCKS5 proxy in Settings → Capture.

## Usage

### Inspecting Requests

```text
1. Start a capture session
2. Navigate to the Network tab
3. Tap any request to see full details:
   - Headers, body, timings
   - TLS certificate chain
   - HTTP/2 stream information
```

### Replaying Requests

Replay any captured request:

```text
1. Long-press a request in Network view
2. Select "Replay"
3. Modify headers/body if needed
4. Send
```

### Import cURL Command

```bash
# Copy any cURL command
curl -X POST https://api.example.com/items \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Trace","version":"1.0"}'
```

```text
1. Go to Tools → Request Builder
2. Tap "Import from cURL"
3. Paste and execute
```

### Export as HAR

```text
1. Go to Settings → Data
2. Tap "Export HAR"
3. Select requests to export
4. Share the .har file
```

### Traffic Modification

**Rewrite Rules** – Pattern-based request/response modification
**Request Maps** – Map URLs to local or remote resources
**Breakpoints** – Pause requests to inspect and modify before sending
**Host Overrides** – Redirect specific hosts to custom IPs
**Scripts** – JavaScript-based request/response transformation

## Configuration

### Core Settings

| Setting | Location | Description |
|---------|----------|-------------|
| App Group | Build Settings → `APP_GROUP_IDENTIFIER` (or Info.plist `AppGroupIdentifier`) | Shared storage identifier (defaults to `group.<bundleIdentifier>`) |
| Bundle IDs | Target settings | Must align across App, VPN extension, and Widget |
| VPN Bundle ID | `TraceFeatures/VPN/VPNManager.swift:69` | Keep in sync with `TraceVPN` target |
| Keychain Group | Entitlements (or Info.plist `TraceKeychainAccessGroup`) | Default: `$(AppIdentifierPrefix)com.justin.trace` |

### Capture Settings

Configure in **Settings → Capture**:

- **Capture mode** – Proxy-only or Full-tunnel
- **SOCKS5 proxy** – Required for full-tunnel mode
- **MITM settings** – Enable/disable TLS interception
- **Network conditions** – Simulate slow connections, packet loss

### App Group Setup

The app, VPN extension, and widget communicate via App Groups:

```swift
// Automatically uses APP_GROUP_IDENTIFIER from Build Settings
// Falls back to: group.<bundleIdentifier>
```

If unset, ensure all targets share the same group identifier in their entitlements.

## Project Structure

```
Trace/
├── Trace/                          # Main iOS app target
├── TraceVPN/                       # Packet Tunnel network extension
├── TraceWidgetExtension/           # WidgetKit + Live Activity extension
├── TraceWidget/                    # Widget source files
└── SwiftPM Packages:
    ├── TraceCore/                  # Core models and utilities
    ├── TraceNetworking/            # HTTP client and network layer
    ├── TraceSecurity/              # Certificate management and MITM
    ├── TraceProxy/                 # Proxy server implementation
    ├── TraceCompression/           # Compression/decompression
    ├── TracePacket/                # Packet processing
    ├── TraceFeatures/              # App features (VPN, capture, etc.)
    ├── TraceUI/                    # Reusable UI components
    └── HevSocks5Tunnel/            # SOCKS5 tunnel (wraps C library)

ThirdParty/
└── hev-socks5-tunnel/              # Vendored SOCKS5 tunnel

Tests/
├── TraceTests/                     # Unit tests
└── TraceUITests/                   # UI tests
```

### Alternative: SwiftPM Workflow

Open `Package.swift` directly in Xcode to work without the `.xcodeproj`:

```bash
# Update bundleIdentifier in Package.swift
# Note: SwiftPM does not produce .appex bundles
# Use Xcode project for full builds
```

## Limitations

- **Proxy-only mode**: Apps that ignore system proxy settings will not be captured. Use full-tunnel mode for complete coverage.
- **Certificate pinning**: Apps using certificate pinning or custom TLS validation cannot be MITM'd – their HTTPS traffic remains encrypted.
- **QUIC/HTTP3**: Not decrypted. Traffic may be forwarded, blocked, or visible only at the packet level depending on settings.
- **Simulator**: Network Extension packet tunnels are unavailable in iOS Simulator. Use a physical device.

## Contributing

Contributions are welcome! Here's how to get started:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes with clear commit messages
4. Push to your fork: `git push origin feature/my-feature`
5. Open a Pull Request with:
   - Clear description of changes
   - Screenshots for UI changes
   - Test results

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

### Running Tests

```bash
# Unit tests
cmd+U in Xcode

# Specific test suite
xcodebuild test -scheme Trace -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Code of Conduct

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold this code.

## Authors

**Justin** – [@Trace-iOS](https://github.com/Trace-iOS)

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for more information.

---

**Built with Swift 6.2** | [Report Issues](https://github.com/Trace-iOS/Trace/issues) | [Request Features](https://github.com/Trace-iOS/Trace/issues/new)
