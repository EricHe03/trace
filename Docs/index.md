# Trace Documentation

Trace is an on-device iOS network debugger. It captures HTTP(S), HTTP/2, WebSocket, SSE, DNS, UDP, and QUIC/HTTP3 traffic without routing traffic off the device.

## Start here

- [Quickstart](quickstart.md) — install the root CA and make your first capture in under five minutes

## Guides — task-focused how-tos

| Guide | What it covers |
|---|---|
| [Capture HTTPS traffic](guides/capture-https.md) | Install the root CA and configure HTTPS MITM |
| [Use rewrite rules](guides/rewrite-rules.md) | Modify requests and responses on the fly |
| [Use breakpoints](guides/breakpoints.md) | Pause and edit requests or responses mid-flight |
| [Export traffic](guides/export-traffic.md) | Export as HAR, PCAP, or cURL |
| [Full-tunnel mode](guides/full-tunnel-mode.md) | Capture apps that ignore system proxy settings |

## Reference — exact facts

| Reference | What it covers |
|---|---|
| [Capture modes](reference/capture-modes.md) | Proxy-only, full-tunnel, and dual-MITM comparison |
| [Configuration](reference/configuration.md) | Bundle IDs, app group, entitlements, build flags |

## Explanation — concepts and design

| Explanation | What it covers |
|---|---|
| [Capture architecture](explanation/capture-architecture.md) | How the three capture paths work and interact |
| [MITM certificate model](explanation/mitm-certificate.md) | How the root CA and per-host certificates are generated |

## Architecture and design records

| Document | What it covers |
|---|---|
| [Stream interception design](StreamInterceptionV2.md) | V2 stream interception design and invariants |
| [SwiftNIO behavior contract](SwiftNIO-Behavior-Parity-Contract.md) | Required NIO runtime behavior; read before touching `NIORuntime.swift` |
| [E2E capture test plan](SwiftNIO-E2E-Capture-Test-Plan.md) | End-to-end capture validation procedure |

## Troubleshooting

- [Troubleshooting](troubleshooting.md) — known issues, common failures, and debugging paths
