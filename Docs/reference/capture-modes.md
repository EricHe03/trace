# Capture Modes

Trace supports three capture modes. Each targets a different traffic path.

## Overview

| Mode | Mechanism | Best for |
|---|---|---|
| **Proxy** | System HTTP/HTTPS proxy | Apps that respect iOS proxy settings |
| **Full Tunnel** | Network Extension packet tunnel | Apps that bypass the proxy; non-HTTP traffic |
| **Dual MITM** | Proxy + tunnel simultaneously | Complete visibility across both paths |

## Proxy mode

Trace registers itself as the system HTTP proxy. iOS routes HTTP and HTTPS connections from most apps through the proxy automatically.

**Captured traffic:**
- HTTP/1.1 and HTTP/2 (CONNECT tunnels)
- WebSocket and SSE (over the same proxy connection)
- HTTPS (decrypted when the root CA is trusted)

**Not captured:**
- Traffic from apps that set their own `URLSessionConfiguration.connectionProxyDictionary` to bypass the system proxy
- Raw TCP/UDP flows that do not use HTTP
- DNS queries
- QUIC/HTTP3 (unless the app falls back to HTTP/2 through the proxy)

**Implementation:** `Trace/NetworkInterceptor.swift` (URLProtocol) handles traffic from Trace's own process; `TraceProxy/MITM/MITMProxyServer.swift` → `NIOMITMProxyEngine.swift` handles external clients.

## Full-tunnel mode

Trace starts a Network Extension (packet tunnel provider) that captures all IP traffic at the TUN layer. An embedded hev-socks5-tunnel (`ThirdParty/hev-socks5-tunnel/`) forwards packets from the TUN device to a local SOCKS5 server (`TraceVPN/Providers/LocalSocks5Server.swift`), where flows are reassembled and optionally passed to the MITM proxy.

**Captured traffic:**
- All TCP flows (including non-HTTP)
- All UDP flows
- DNS queries and responses
- QUIC/HTTP3 (as UDP flows; decryption requires hybrid TCP MITM to be enabled and the root CA to be trusted)

**Not captured:**
- Traffic that the app routes over a secondary VPN or tunnel that takes precedence over Trace's tunnel

**Implementation:** `TraceVPN/Providers/PacketTunnelProvider.swift` is the Network Extension entry point. `UDPForwarder.swift` handles UDP. `HevSocks5TunnelForwarder.swift` bridges the TUN device to the SOCKS5 layer.

## Dual MITM mode

Both proxy and tunnel paths are active simultaneously. The proxy intercepts traffic from apps that use the system proxy; the tunnel catches everything else.

This mode provides the most complete capture coverage but also has the highest resource overhead (CPU, memory, battery).

Use dual MITM when you are not sure whether an app uses the system proxy, or when you want to correlate proxy-level HTTP data with packet-level flow data side by side.

## Switching modes

Go to **Settings → Capture Mode** and tap the desired mode. Switching modes while a capture session is active restarts the active tunnel/proxy components. In-progress requests may be lost.

## Mode capabilities matrix

| Capability | Proxy | Full Tunnel | Dual MITM |
|---|---|---|---|
| HTTP/1.1 | Yes | Yes (via MITM) | Yes |
| HTTP/2 | Yes | Yes (via MITM) | Yes |
| HTTPS decryption | Yes | Yes (hybrid MITM) | Yes |
| WebSocket | Yes | Yes (via MITM) | Yes |
| SSE | Yes | Yes (via MITM) | Yes |
| gRPC metadata | Yes | Yes (hybrid MITM) | Yes |
| QUIC/HTTP3 | Partial (fallback) | With QUIC MITM | With QUIC MITM |
| Raw TCP flows | No | Yes | Yes |
| UDP flows | No | Yes | Yes |
| DNS capture | No | Yes | Yes |
| PCAP export | No | Yes | Yes |
| Battery impact | Low | Medium | High |
