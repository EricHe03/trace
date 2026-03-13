# Quickstart

Get Trace capturing and decrypting HTTPS traffic in under five minutes.

## Prerequisites

- Xcode 26.2 or newer
- An Apple Developer account with the **Network Extension** capability
- A physical iOS device running iOS 16.0 or newer (the packet tunnel cannot run in Simulator)

## Step 1 — Clone and build

```bash
git clone https://github.com/Trace-iOS/Trace.git
cd Trace
git submodule update --init --recursive
open Trace.xcodeproj
```

In Xcode:

1. Select your development team for the `Trace`, `TraceVPN`, and `TraceWidgetExtension` targets.
2. Confirm all three targets share the same App Group (`group.com.justin.trace` by default).
3. Connect your device and press **Run**.

## Step 2 — Allow the VPN configuration

On first launch, Trace presents an onboarding screen that requests permission to install a VPN configuration. Tap **Allow** and authenticate with Face ID / Touch ID when iOS prompts you.

The VPN configuration is used only to route traffic through the local packet tunnel. No traffic leaves the device.

## Step 3 — Install and trust the root CA

To decrypt HTTPS traffic, Trace needs a trusted root certificate authority on the device.

1. Open the **Settings** tab in Trace and tap **Certificate Setup**.
2. Follow the wizard to install the Trace root CA profile.
3. In iOS **Settings → General → VPN & Device Management**, locate the Trace profile and tap **Trust**.
4. In iOS **Settings → General → About → Certificate Trust Settings**, enable full trust for the Trace root CA.

The root CA is generated locally on your device and never leaves it.

## Step 4 — Choose a capture mode

Open **Settings → Capture Mode** and select one of:

| Mode | Best for |
|---|---|
| **Proxy** | Apps that respect the system HTTP proxy |
| **Full Tunnel** | Apps that bypass the system proxy |
| **Dual MITM** | Both proxy and VPN paths simultaneously |

For most cases, start with **Proxy**. See [Capture modes](reference/capture-modes.md) for a detailed comparison.

## Step 5 — Start capturing

1. Go to the **Network** tab.
2. Tap the **Start** button (or use the Control Widget / Home Screen widget).
3. Open another app and generate some network traffic.
4. Return to Trace — requests appear in the list in real time.

Tap any request to inspect headers, body, TLS chain, timing breakdown, and (for HTTPS) the decrypted payload.

## Next steps

- [Capture HTTPS traffic](guides/capture-https.md) — deeper MITM setup and certificate pinning notes
- [Full-tunnel mode](guides/full-tunnel-mode.md) — capture apps that ignore the system proxy
- [Export traffic](guides/export-traffic.md) — share a HAR file or PCAP with teammates
