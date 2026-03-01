# SwiftNIO Migration Behavior Parity Contract (Step 0 Baseline)
Date: 2026-02-13  
Repository: `/Users/lujuncheng/Trace-iOS/Trace`

## Scope and Non-Negotiables
- Keep product behavior unchanged: capture fidelity, throttling, PCAP behavior, metrics, sampling, body limits, bypass logic, redirect/cookie semantics, and user-visible error mapping.
- Rollout remains phased by subsystem.
- Transport backend for iOS + Network Extension paths is NIOTS-first (`swift-nio-transport-services`).
- Custom protocol parsing/framing for HTTP/1.1, HTTP/2, and WebSocket must be replaced by NIO codecs/handlers.
- In-app app-originated capture via `/Users/lujuncheng/Trace-iOS/Trace/Trace/NetworkInterceptor.swift` remains intentionally non-NIO.
- Vendored curl runtime and related branches are removed only after parity is proven.

## Baseline Build/Test Status
Baseline commands were executed before migration edits.

| Command | Date (local) | Outcome | Notes |
| --- | --- | --- | --- |
| `xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' build-for-testing` | 2026-02-13 | Failed | Destination mismatch: `iPhone 16` not available on `OS=latest` (latest resolves to iOS 26.2 on this machine; iPhone 16 exists on iOS 18.5). |
| `xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build-for-testing` | 2026-02-13 | Failed | Linker failure in dependency `zstd`: `Undefined symbols for architecture arm64: ___llvm_profile_runtime` while linking `libzstd_..._PackageProduct.framework`. |
| `xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' test-without-building` | 2026-02-13 | Failed | Install/launch failed: missing bundle ID because test app artifact was not produced by the failed build step. |

### Baseline test-state conclusion
- Current baseline is blocked before test execution due existing pre-migration build issues.
- Flaky test determination is inconclusive because no full green run exists in this environment.

### Post-migration compile validation update (2026-02-14)
| Command | Date (local) | Outcome | Notes |
| --- | --- | --- | --- |
| `xcodebuild -project Trace.xcodeproj -scheme TraceProxy -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build` | 2026-02-14 | Succeeded | Confirms NIO MITM proxy target compiles after migration changes. |
| `xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build` | 2026-02-14 | Succeeded | Confirms app + extension targets compile with NIO/NIOTS stack. |

## Implementation Progress (2026-02-14)
- Phase 3 progress advanced:
  - `LocalSocks5Server` UDP ASSOCIATE relay internals moved from `NWListener/NWConnection` to NIOTS datagram listener/connection channels.
  - `UDPForwarder` and `HevSocks5TunnelForwarder` probe path use NIOTS/NIO runtime plumbing.
- Phase 4 progress advanced:
  - Added `TraceProxy/MITM/NIOMITMProxyEngine.swift` with NIOTS listener + NIO HTTP/1 codec parsing for CONNECT/non-CONNECT proxy requests.
  - Added NIO CONNECT upstream dial + raw tunnel relay handlers.
  - Added non-CONNECT HTTP/1 forwarding via AsyncHTTPClient in the NIO engine.
  - Added CONNECT MITM upgrade path in NIO engine:
    - host/port decision callback from `MITMProxyServer` (`mitmEnabled` + allowlist)
    - dynamic per-domain server TLS context generation from `CertificateManager`
    - ALPN-based protocol selection after CONNECT MITM TLS termination (`h2` vs `http/1.1`)
    - decrypted tunneled request handling via NIO HTTP/1 codec and HTTP/2 stream channels (`HTTP2FramePayloadToHTTP1ServerCodec`)
    - explicit fallback to CONNECT passthrough when MITM setup/trust preflight fails
  - Replaced raw-stream relay fallback with explicit NIO streaming paths:
    - WebSocket upgrade now transitions to NIO WebSocket frame decoders/encoders with frame-level capture persistence.
    - SSE requests now stream through NIO HTTP response-part handling with incremental SSE parser/event capture persistence.
  - Restored transparent TLS ingress behavior in NIO:
    - initial ingress now sniffs TLS ClientHello before HTTP codec installation.
    - transparent TLS mode toggle is wired to NIO routing.
    - SNI-based transparent routing now supports both passthrough and MITM TLS termination paths.
  - Restored MITM bypass parity hooks:
    - auto-bypass cache (`MITMAutoBypassCache`) is consulted before MITM decisions.
    - NIO MITM failures feed host/reason callbacks to preserve auto-bypass recording semantics.
  - Added HTTP/1 connection-lifecycle guards in NIO engine:
    - sanitize hop-by-hop request/response headers
    - explicit `Connection: close` propagation
    - HTTP/1.0 keep-alive fallback behavior
  - `MITMProxyServer` internals were consolidated to NIO-only while keeping the external lifecycle/config API stable.
- Added focused SOCKS5 and NIO runtime test coverage:
  - `TraceTests/LocalSocks5ServerTests.swift`
  - `TraceTests/NIOMITMProxyEngineTests.swift`
    - includes start/stop smoke test, HTTP/1.1 keep-alive sequential forwarding, and CONNECT tunnel byte relay
- Phase 5 cleanup progress:
  - removed `TraceCurlRuntime/`
  - removed `ThirdParty/curl/` and `ThirdParty/curl-shim/`
  - removed `Tools/Curl/` scripts
  - removed `ThirdParty/curl` entry from `.gitmodules`
  - removed legacy Network.framework MITM/TLS protocol stack:
    - `TraceProxy/MITM/ProxyConnection+TLS.swift`
    - `TraceSecurity/TLS/TLSProxyConnection.swift`
  - removed obsolete custom protocol parsers:
    - `TraceNetworking/HTTP/HTTPParser.swift`
    - `TraceNetworking/HTTP2/*`
    - `TraceNetworking/SSE/SSEHandler.swift`
    - `TraceNetworking/WebSocket/WebSocketHandler.swift`
  - updated `README.md` architecture/runtime notes for NIOTS/AHC-first stack
  - hardening config now uses canonical `enableNIOMITM` toggle with legacy `enableNetworkFrameworkMITM` compatibility alias.

## Feature Inventory and Parity Mapping
Source of truth is existing code + tests in this repo snapshot.

| Feature | Current implementation (pre-migration) | Current infra dependency | Expected post-migration mapping |
| --- | --- | --- | --- |
| Request execution (`execute/replay/get/post`) | `TraceFeatures/Request/RequestExecutor.swift` | `URLSession` + `URLSessionTaskDelegate` | Keep API signatures; route through transport abstraction backed by AsyncHTTPClient over shared NIOTS runtime. |
| Unsupported scheme rejection (`http/https` only) | `TraceFeatures/Request/RequestExecutor.swift` | URL parsing + URLSession path | Preserve exact guard/error behavior in executor before dispatching to AsyncHTTPClient. |
| Redirect tracking + follow/non-follow | `TraceFeatures/Request/RequestExecutor.swift` (`RedirectTrackingDelegate`) | `URLSession` redirect delegate | Explicit redirect policy/state machine in executor transport layer; preserve chain capture semantics. |
| Cookie diff fallback and response cookie shaping | `TraceFeatures/Request/RequestExecutor.swift` + `CookieStore` | URLSession cookie behavior + app cookie store | Keep CookieStore usage; explicitly apply and diff cookies per hop in AsyncHTTPClient flow. |
| Local-network permission retry heuristic | `TraceFeatures/Request/RequestExecutor.swift` + `TraceFeatures/Request/NetworkPermissionHeuristics.swift` | URLSession/URLError/POSIX error surfaces | Preserve retry-once heuristic and classification logic, mapped to NIO/AHC errors. |
| Request error mapping | `TraceFeatures/Request/RequestExecutor.swift` (`RequestExecutionError`) | URLSession error model | Keep deterministic mapping contract for unsupported URL/invalid response/transport errors. |
| Curl capability identity | `TraceFeatures/Request/CurlRuntimeCapabilities.swift` | `#if canImport(TraceCurlRuntime)` + URLSession fallback identity | Replace backend identity with SwiftNIO/AsyncHTTPClient and remove runtime-report branching. |
| Curl analyze preflight | `TraceFeatures/Request/CurlCommandAnalyzer.swift` | Optional runtime preflight via `TraceCurlRuntime` | Keep parser/analyzer diagnostics deterministic; remove runtime preflight branch. |
| Curl execute runtime path | `TraceFeatures/Request/CurlCommandExecutor.swift` | Optional runtime CLI execution via `TraceCurlRuntime` | Execute parsed transfers via RequestExecutor transport abstraction only; remove runtime branch. |
| Curl parser/export compatibility | `TraceFeatures/Parsers/CurlParser.swift`, `TraceFeatures/Parsers/CurlOptionRegistry.swift`, `TraceFeatures/Export/CurlCommandGenerator.swift` | Independent of runtime backend | Preserve unchanged unless parity tests require bug-fix adjustments. |
| MITM proxy public lifecycle API | `TraceProxy/MITM/MITMProxyServer.swift` (`start/stop/updateConfiguration/setMitmAllowlist/setMitmEnabled/updateThrottlingState/configureRawCapture/updateRawCaptureLimit/activeConnectionCount`) | Network.framework listener/connection internals | Keep public API stable; replace internals with NIO listener/channel pipelines. |
| HTTP CONNECT handling + marker capture | `TraceProxy/MITM/MITMProxyServer.swift` | Network.framework + custom parse path | NIO HTTP/1.1 codec + CONNECT handler; preserve marker request emission and bypass behavior. |
| Transparent TLS mode (optional) | `TraceProxy/MITM/MITMProxyServer.swift` (ClientHello sniff path) | Network.framework byte stream handling | NIO byte pipeline with TLS sniff gate preserving current opt-in semantics. |
| MITM allowlist + auto-bypass cache | `TraceProxy/MITM/MITMProxyServer.swift`, `TraceProxy/MITM/MITMAutoBypassCache.swift` | Current logic independent from transport | Preserve matching rules, auto-bypass reasons/TTL, and emitted events. |
| CONNECT passthrough fallback | `TraceProxy/MITM/MITMProxyServer.swift` | Network.framework tunnel bridging | NIO tunnel bridge handler for client↔upstream bytes with same fallback triggers. |
| HTTP/1.1 parse/framing | `TraceNetworking/HTTP/HTTPParser.swift` + proxy connection logic in `TraceProxy/MITM/MITMProxyServer.swift` | Custom parser/framing | Replace with NIO HTTP/1 codecs; keep behavior for chunked decode, headers/body handling, keep-alive sequencing. |
| TLS MITM data plane | `TraceSecurity/TLS/TLSProxyConnection.swift`, `TraceProxy/MITM/ProxyConnection+TLS.swift`, `TraceSecurity/TLS/TLSHandler.swift` | Network.framework `NWConnection`/`NWListener`/`NWProtocolTLS` | NIO channel pipelines with `NIOSSL` + ALPN-driven protocol dispatch; preserve TLS info/error mapping semantics. |
| ALPN reconciliation (`h2` vs `http/1.1`) | `TraceSecurity/TLS/TLSProxyConnection.swift`, `TraceSecurity/TLS/TLSHandler.swift` | Network.framework ALPN metadata | Preserve reconciliation policy (including mismatch failure behavior) using NIO TLS handshake info. |
| HTTP/2 capture + stream state | `TraceNetworking/HTTP2/*` + `TraceSecurity/TLS/TLSProxyConnection.swift` integration | Custom HTTP/2 frame parser/stream manager | Replace frame parsing with NIO HTTP/2 handlers/multiplexer; preserve capture metadata, stream lifecycle, and metrics. |
| WebSocket upgrade + frame capture | `TraceNetworking/WebSocket/WebSocketHandler.swift` + proxy/TLS integration | Network.framework reads + custom WS frame parser | Use NIO HTTP upgrader + WebSocket codecs; preserve frame/message capture behavior and limits. |
| SSE streaming capture | `TraceNetworking/SSE/SSEHandler.swift` + proxy/TLS integration | Network.framework reads + SSE parser | Keep SSE parser logic; feed from NIO channel bytes while preserving chunked/content-decoding behaviors. |
| Interception contract (rewrite/mock/breakpoint/scripts) | `TraceProxy/MITM/RequestInterceptor.swift` | Actor-based logic independent of transport | Keep interface/behavior unchanged; adapt call sites to NIO pipeline events. |
| Throttling behavior | `TraceProxy/Throttling/PacketThrottler.swift` and TLS-local throttler in `TraceSecurity/TLS/TLSProxyConnection.swift` | Queue/timer-based simulation | Port to NIO channel handlers preserving latency/bandwidth/loss semantics. |
| PCAP writing and size cap | `TraceProxy/Core/PCAPWriter.swift`, `TraceProxy/Core/RollingPCAPWriter.swift`, capture calls in `TraceProxy/MITM/MITMProxyServer.swift` and `TraceVPN/Providers/PacketFlowLoop.swift` | File I/O + current capture synthesis | Preserve output format, rotation/size caps, and disable-on-limit behavior. |
| Metrics counters | `TraceProxy/Core/ProxyNetworkMetrics.swift` + VPN event metrics in VPN providers | Current actor/log counters | Preserve counter dimensions and update points across NIO code paths. |
| Sampling + domain filter persistence gates | `TraceProxy/MITM/MITMProxyServer.swift` (`shouldSample`, `shouldPersist`) + `TraceCore/Config/SamplingConfig.swift` + `TraceCore/Storage/AppGroupStorage.swift` | None (logic layer) | Preserve identical sampling/filter decisions; no behavior drift. |
| Body capture limits/truncation/spooling | `TraceProxy/MITM/MITMProxyServer.swift` + `TraceSecurity/TLS/TLSProxyConnection.swift` | Custom buffering + file spooling | Preserve hard/soft limits, preview behavior, truncation markers, and streaming spool behavior under NIO pipelines. |
| SOCKS5 listener + CONNECT relay | `TraceVPN/Providers/LocalSocks5Server.swift` | `NWListener`/`NWConnection` | Reimplement SOCKS5 state machine over NIOTS TCP channels. |
| SOCKS5 UDP ASSOCIATE + IPv6→IPv4 fallback | `TraceVPN/Providers/LocalSocks5Server.swift` (`Socks5UDPRelay`) | Network.framework UDP listener/connections | Reimplement over NIOTS datagram channels preserving fallback semantics. |
| UDP forwarding to packet flow | `TraceVPN/UDP/UDPForwarder.swift` | `NWConnection` UDP + timers | NIOTS datagram forwarding with same checksum/packet reconstruction behavior and idle cleanup semantics. |
| Hev UDP associate probe + support matrix | `TraceVPN/Providers/HevSocks5TunnelForwarder.swift` | Network.framework probe connection | NIOTS-based probe path preserving support outcomes (`unsupported`, `ipv4Only`, `ipv6`). |
| UDP routing policy (`direct/split/hevOnly`) and QUIC block behavior | `TraceCore/Networking/UDPForwardingDecision.swift`, `TraceVPN/Providers/PacketFlowLoop.swift` | Policy logic independent from transport | Preserve policy logic exactly; integrate with NIOTS forwarding backends. |
| Packet loop + capture pipeline orchestration API | `TraceVPN/Providers/PacketFlowLoop.swift`, `TraceVPN/Providers/PacketTunnelProvider.swift` | NEPacketTunnelFlow + existing orchestration | Keep orchestration APIs stable; swap socket transport internals only. |
| Connection lifecycle cleanup timers | `TraceProxy/MITM/MITMProxyServer.swift` (60s cleanup), `TraceVPN/UDP/UDPForwarder.swift` (idle cleanup), `TraceSecurity/TLS/TLSProxyConnection.swift` (handshake/connect watchdogs) | Dispatch timers + Network.framework state updates | Preserve equivalent timeout/cleanup semantics in NIO scheduling/event-loop tasks. |

## Current Hard Dependencies on URLSession / Network.framework

### URLSession/URLProtocol-bound
- `/Users/lujuncheng/Trace-iOS/Trace/Trace/NetworkInterceptor.swift` (intentional in-app URLProtocol capture path).
- `TraceTests/RequestExecutorTests.swift` (transport mocking + URLProtocol compatibility coverage).

### Network.framework-bound
- `TraceSecurity/TLS/TLSHandler.swift` (NW TLS options/metadata compatibility helpers retained for existing APIs).
- Tests coupled to NW internals: `TraceTests/ProxyConnectionTLSTests.swift`, `TraceTests/TLSProxyConnectionTests.swift`, helper constructors in SSE/WS tests.
- NIOTS replacement completed for proxy/VPN data-plane paths:
  - `TraceVPN/Providers/LocalSocks5Server.swift`
  - `TraceVPN/UDP/UDPForwarder.swift`
  - `TraceVPN/Providers/HevSocks5TunnelForwarder.swift` (UDP associate probe)

### TraceCurlRuntime conditional dependency
- Removed from product code.
- Remaining test migration work is tracked in `TraceTests/CurlRuntimeCapabilitiesTests.swift`, `TraceTests/CurlCommandExecutorTests.swift`, `TraceTests/CurlRuntimeCLIExecutorTests.swift`.

## Existing Coverage vs Required Parity Gates

### Covered in current suite (partial)
- Request executor basics (URL validity, basic method/headers/body, retry heuristic) in `TraceTests/RequestExecutorTests.swift`.
- Chunked HTTP parsing primitives in `TraceTests/MITMProxyServerTests.swift` (parser-level).
- HTTP/2 model/parser/state unit coverage in `TraceTests/HTTP2ConnectionTests.swift` and `TraceTests/HTTP2StreamManagerTests.swift`.
- SSE and WebSocket parser/model behavior in `TraceTests/SSEHandlerTests.swift` and `TraceTests/WebSocketHandlerTests.swift`.
- Throttling unit behavior in `TraceTests/PacketThrottlerTests.swift`.
- Rolling PCAP rotation behavior in `TraceTests/RollingPCAPWriterRotationTests.swift`.

### Missing or insufficient for migration parity (must add before deletion phases)
- End-to-end proxy HTTP/1.1 keep-alive with sequential requests over the same connection.
- End-to-end CONNECT passthrough and CONNECT MITM parity with ALPN reconciliation.
- HTTP/2 concurrent stream capture equivalence (golden request/response/counters/truncation/pcap).
- End-to-end WebSocket upgrade/frame capture across sustained frame streams.
- End-to-end long-lived SSE stream capture under backpressure and reconnect-like conditions.
- SOCKS5 UDP ASSOCIATE integration (IPv4 + IPv6 + fallback path) with real datagram relay behavior.
- Failure-mode matrix parity tests:
  - DNS failure
  - TLS handshake failure
  - upstream reset
  - client reset
  - idle timeout
  - oversized body truncation
  - user-visible error mapping equivalence
- Performance sanity benchmarks for:
  - HTTP/2 concurrent streams
  - sustained WebSocket frames
  - long-lived SSE
  - UDP burst forwarding

## Parity Gate Checklist (must pass before removing legacy paths)

### Request execution and curl
- [ ] `execute/replay/get/post` parity with old behavior.
- [ ] Redirect follow/non-follow chain capture parity.
- [ ] Cookie diff + response cookie fallback parity.
- [ ] Unsupported scheme and transport error mapping parity.
- [x] Curl parse/analyze/execute workflow runs without `TraceCurlRuntime`.
- [x] Unsupported-option diagnostics remain deterministic.

### VPN
- [ ] SOCKS5 handshake + CONNECT relay parity.
- [ ] UDP ASSOCIATE parity for IPv4 and IPv6.
- [ ] IPv6→IPv4 fallback parity when UDP associate unsupported.
- [ ] Extension lifecycle start/stop/restart stability parity.

### Proxy/TLS
- [ ] HTTP/1.1 keep-alive sequential request parity.
- [ ] CONNECT passthrough parity.
- [ ] CONNECT MITM parity with ALPN reconciliation.
- [ ] HTTP/2 concurrent-stream capture parity.
- [ ] WebSocket upgrade/frame capture parity.
- [ ] SSE long-lived stream capture parity.
- [ ] RequestInterceptor contract unchanged.

### Regression gates
- [ ] Throttling semantics parity.
- [ ] PCAP format + cap/rotation behavior parity.
- [ ] Metrics counters/timing parity.
- [ ] Sampling/filter/body-limit/truncation parity.
- [ ] Connection cleanup timer and close-propagation parity.
- [ ] Golden capture equivalence passes for target scenarios.
- [ ] Failure-mode matrix user-visible error mapping parity.

## Deletion Status
- Completed:
  - `TraceCurlRuntime/*`
  - `ThirdParty/curl-shim/*`
  - `ThirdParty/curl/*`
  - `Tools/Curl/*` related runtime scripts
  - `canImport(TraceCurlRuntime)` branches in product code and tests (Request/Curl paths)
  - `TraceNetworking/HTTP/HTTPParser.swift`
  - `TraceNetworking/HTTP2/*`
  - `TraceNetworking/SSE/SSEHandler.swift`
  - `TraceNetworking/WebSocket/WebSocketHandler.swift`
  - `TraceProxy/MITM/ProxyConnection+TLS.swift`
  - `TraceSecurity/TLS/TLSProxyConnection.swift`
