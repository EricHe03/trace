# Full-Tunnel Mode

Full-tunnel mode routes all device traffic through a local packet tunnel (iOS Network Extension). Use this when an app ignores the system HTTP proxy, or when you need to capture non-HTTP traffic like DNS, raw UDP, or QUIC.

## When to use full-tunnel mode

| Situation | Recommended mode |
|---|---|
| App respects system proxy | Proxy mode is sufficient |
| App bypasses system proxy | Full tunnel required |
| You need raw DNS capture | Full tunnel required |
| You need UDP flow data | Full tunnel required |
| You want both proxy and tunnel | Dual MITM |

## Enable full-tunnel mode

1. Open **Settings → Capture Mode**.
2. Select **Full Tunnel**.
3. Start a capture session from the **Network** tab.

iOS will show the VPN status indicator (the VPN icon in the status bar) while the tunnel is active.

## Full-tunnel settings

All settings below are in **Settings → Full Tunnel**.

### DNS

| Setting | Description |
|---|---|
| Custom DNS | Override the DNS server used by the tunnel (e.g. `1.1.1.1`) |
| DNS capture | Log DNS queries and responses in the Network tab |

### IPv6

| Setting | Description |
|---|---|
| IPv6 | Enable or disable IPv6 routing through the tunnel |

### SOCKS5 upstream

You can forward tunnel traffic through an external SOCKS5 proxy:

| Setting | Description |
|---|---|
| SOCKS5 host | Upstream SOCKS5 server hostname or IP |
| SOCKS5 port | Port (default 1080) |
| Authentication | Optional username/password |

### TCP MITM (hybrid mode)

When the tunnel is active, TCP flows can also be intercepted by the local MITM proxy engine:

| Setting | Description |
|---|---|
| Hybrid TCP MITM | Forward tunneled TCP flows to the local proxy for HTTP/HTTPS interception |

### QUIC

| Setting | Description |
|---|---|
| Block QUIC | Drop UDP packets on port 443 to force apps to fall back from HTTP/3 to HTTP/2 over TLS |

Blocking QUIC is useful when you want Trace to MITM traffic from apps that prefer HTTP/3, since HTTP/3 runs over QUIC (UDP) and bypasses the TLS interception path Trace uses for HTTP/2.

### UDP forwarding

| Setting | Description |
|---|---|
| UDP forwarding mode | `direct` sends UDP packets to the real destination; `socks5` wraps them through the upstream SOCKS5 proxy |

## Limitations

- The packet tunnel requires a physical iOS device. It cannot run in the iOS Simulator.
- App Store apps with aggressive certificate pinning still resist HTTPS MITM even through the tunnel.
- Full-tunnel mode increases battery consumption because the Network Extension runs persistently.
- Some apps detect the VPN status indicator and alter their behavior.
