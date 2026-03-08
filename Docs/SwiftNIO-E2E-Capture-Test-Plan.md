# SwiftNIO Full E2E Capture Test Plan (iOS WebKit, No Custom Scripts)
Date: 2026-02-16 (last updated: 2026-03-08)
Repository: `/Users/lujuncheng/Trace-iOS/Trace`

## 1) Goal
Validate that the SwiftNIO/NIOTS proxy path captures browser traffic correctly, end-to-end, on iOS:

- Request/response capture fidelity (method, URL, headers, status, body, protocol)
- HTTP protocol behavior (HTTP/2 available in normal flow, no forced HTTP/1.1 regressions)
- Stream path behavior (`stream_and_capture`) and interception path behavior (`buffer_and_intercept`)
- Special semantics (`304`, `204`, `HEAD` no-body behavior)
- WebSocket and SSE capture
- QUIC/HTTP3 flow routing and capture (block/passThrough/intercept modes)
- DualMITMPolicyEngine routing consistency
- Stability (no restart loops, no unexpected `502`/upstream failures)

---

## 2) iOS/WebKit Constraints (explicit)

This plan is designed for iPhone/iPad browsers (all WebKit-based) with **no custom JavaScript execution**:

1. Do not use DevTools console scripts.
2. Do not use bookmarklets/custom injected JS.
3. Allowed actions:
   - Normal navigation (open URL, refresh, back/forward)
   - Form submit/tap flows on normal web pages
   - Button-based interactions on browser-hosted tester pages

Note:
- Pure browser navigation naturally covers `GET`/form `POST` best.
- For `PUT`/`PATCH`/`DELETE`, use browser UI testers (no custom script input needed).
- `HEAD` is not reliably triggerable from pure iOS navigation alone; use optional extension step below.

---

## 3) Preconditions

1. Enable VPN/Proxy and confirm pages load normally.
2. Capture config:
   - `captureHeaders = true`
   - `captureBody = true`
   - `maxBodySize >= 10 MB`
3. Baseline run settings:
   - Disable rewrite rules, scripts, breakpoints, throttling.
4. Clean slate:
   - Clear captured HTTP requests, WebSocket connections, SSE connections.
   - Start fresh `log.txt` and `vpn_events.ndjson`.
5. Create one run marker:
   - `RID = trace-e2e-<date>-<time>`
   - Example: `trace-e2e-20260216-2230`

---

## 4) Coverage Matrix

### A. Browser-native mandatory coverage
- Methods: `GET`, `POST` (form)
- Status classes: `2xx`, `3xx`, `4xx`, `5xx`
- Redirect chain: `3xx` multi-hop
- Cache revalidation: `304 Not Modified`
- No-body responses: `204`, `304`
- Encodings: `gzip`, `br`, `deflate`
- Binary + large payload: image + >=1MB response

### B. Browser UI tester mandatory coverage (still no custom scripts)
- Methods: `PUT`, `PATCH`, `DELETE`
- JSON request body capture on mutating methods

### C. Optional extension
- `HEAD` method (best-effort, tool dependent)

### D. Streaming protocols
- WebSocket connect/send/receive/close
- SSE stream open/events/close

### E. Proxy internals
- Baseline: `response_pipeline = stream_and_capture`
- Interception phase: `response_pipeline = buffer_and_intercept`
- HTTP/2 observed (`detail=h2` in protocol select)

### F. QUIC/HTTP3
- QUIC handling mode set to `intercept`: verify HTTP/3 requests are captured with correct method/URL/headers/status/body
- QUIC handling mode set to `passThrough`: verify QUIC traffic flows without interception
- QUIC handling mode set to `block`: verify QUIC traffic is blocked and client falls back to TCP/TLS
- DualMITMPolicyEngine enforcement: verify consistent routing decisions across TCP and QUIC flows for the same host

### G. Stability
- 10+ minutes mixed browsing
- Clean tunnel stop/start, no restart loop behavior

---

## 5) Test Execution

## Phase 0: Baseline sanity

1. Open in iOS browser:
   - `https://trace.justinl.site/`
   - `https://httpbin.org/`
   - `https://example.com/`
2. Confirm pages visibly load.
3. In Trace UI, confirm requests appear in list.

---

## Phase 1: Browser-native HTTP matrix (no scripts)

Use direct URLs (replace `<RID>`):

1. GET 200:
   - `https://httpbin.org/get?rid=<RID>&case=get200`
2. 204:
   - `https://httpbin.org/status/204?rid=<RID>&case=status204`
3. 404:
   - `https://httpbin.org/status/404?rid=<RID>&case=status404`
4. 500:
   - `https://httpbin.org/status/500?rid=<RID>&case=status500`
5. Redirect chain:
   - `https://httpbin.org/redirect/3?rid=<RID>&case=redirect3`
6. Encoded responses:
   - `https://httpbin.org/gzip?rid=<RID>&case=gzip`
   - `https://httpbin.org/brotli?rid=<RID>&case=brotli`
   - `https://httpbin.org/deflate?rid=<RID>&case=deflate`
7. Binary + large payload:
   - `https://httpbin.org/image/png?rid=<RID>&case=image`
   - `https://httpbin.org/bytes/1048576?rid=<RID>&case=bytes1m`
8. Form POST:
   - Open `https://httpbin.org/forms/post`
   - Fill at least one field with `<RID>` and submit.

304 revalidation check (no script):

1. Open `https://trace.justinl.site/logos/trace-logo-bright.svg`
2. Perform explicit reload 2-3 times.
3. In Trace, confirm at least one request for that URL is `304`.

Expected:
- `304` response has no body (this is correct behavior).

---

## Phase 2: Method extension via no-code browser UI

Use `https://mockerapi.com/http-tester` and include `<RID>` in query/body fields.

Required actions:

1. `POST /post` with JSON body containing `<RID>`.
2. `PUT /put` with JSON body containing `<RID>`.
3. `PATCH /patch` with JSON body containing `<RID>`.
4. `DELETE /delete` with query parameter `rid=<RID>`.

Expected:
- Trace captures method, URL, status, headers, and request body correctly.
- No systemic `502` or upstream-failure spike.

Optional (`HEAD`):
- If you have a browser UI API tester that supports `HEAD` on iOS, send:
  - `HEAD https://httpbin.org/get?rid=<RID>&case=head`
- Expect no response body.

---

## Phase 3: WebSocket capture (no custom script)

1. Open `https://www.mywebutils.com/websocket-tester`.
2. Set WebSocket URL to `wss://ws.postman-echo.com/raw`.
3. Connect.
4. Send 2 messages:
   - `trace-ws-msg-1-<RID>`
   - `{"rid":"<RID>","kind":"ws-json"}`
5. Disconnect.

Expected:
- WebSocket connection appears in Trace WebSocket list.
- Sent and received messages are visible.

---

## Phase 4: SSE capture (no custom script)

1. Open `https://sse.dev/testpage.html`.
2. Tap `Start SSE Test`.
3. Wait for >=3 events (or ~10 seconds).
4. Stop/clear from page controls.

Expected:
- SSE connection appears in Trace SSE list.
- Events are visible in detail view.

---

## Phase 5: QUIC/HTTP3 verification

Goal: verify QUIC flow routing and HTTP/3 capture under each handling mode.

### 5a. Intercept mode (default)
1. Confirm `quicHandlingMode = intercept` in hardening config.
2. Browse to an HTTP/3-capable site (e.g., `https://www.google.com`, `https://www.cloudflare.com`).
3. In Trace, verify captured requests show HTTP/3 protocol where negotiated.
4. Verify request/response headers and body are captured correctly.

### 5b. Block mode
1. Set `quicHandlingMode = block`.
2. Browse to the same HTTP/3-capable sites.
3. Verify QUIC traffic is blocked and browser falls back to HTTP/2 over TCP.
4. Confirm requests still appear in Trace captured via TCP/TLS path.

### 5c. Pass-through mode
1. Set `quicHandlingMode = passThrough`.
2. Browse to the same HTTP/3-capable sites.
3. Verify QUIC traffic flows without interception (no HTTP/3 captures in Trace).
4. TCP/TLS requests to non-QUIC sites should still be captured normally.

### 5d. Policy engine consistency
1. Set `quicHandlingMode = intercept`.
2. Browse a site that uses both TCP and QUIC connections.
3. Verify DualMITMPolicyEngine makes consistent routing decisions (both paths either MITM or bypass for the same host based on allowlist/bypass state).

---

## Phase 6: Interception path verification

Goal: prove interception still forces buffered path after stream optimizations.

1. In Trace, enable one response rewrite rule matching `httpbin.org/get`:
   - Add response header `X-Trace-E2E: intercept-on`
2. Trigger:
   - `https://httpbin.org/get?rid=<RID>&case=intercept`
3. Verify:
   - Captured response includes rewritten header.
   - `response_pipeline` shows `buffer_and_intercept` at least once.
4. Disable rule after test.

---

## Phase 7: Stability run

1. Browse mixed websites for 10 minutes.
2. Repeated-refresh one page 20+ times.
3. Stop tunnel cleanly.
4. Confirm no restart loop and no mass `502` behavior.

---

## 6) UI Assertions (must pass)

For sampled captured entries (use `<RID>` filter where available):

1. Core fields are correct:
   - URL, method, status code, timestamp, protocol version.
2. Header capture:
   - Request headers present.
   - Response headers present.
3. Body capture:
   - Body present for normal body-bearing `200` responses.
   - No body is expected for `204`, `304`, and optional `HEAD`.
4. Redirect capture:
   - Redirected request shows chain/final destination behavior.
5. Streaming:
   - WebSocket and SSE entries exist with messages/events.

---

## 7) Log Assertions (must pass)

Run after test:

```bash
echo "h2_count $(rg 'stage=mitm_protocol_select outcome=success.*detail=h2' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "h1_count $(rg 'stage=mitm_protocol_select outcome=success.*detail=http1\\.1' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "stream_pipeline $(rg 'stage=response_pipeline outcome=selected.*stream_and_capture' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "buffer_pipeline $(rg 'stage=response_pipeline outcome=selected.*buffer_and_intercept' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "upstream_failures $(rg '\"type\":\"proxy_nio_http_upstream_failure\"' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "error_responses $(rg '\"type\":\"proxy_nio_error_response\"' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "mitm_pipeline_failures $(rg 'stage=mitm_pipeline_install outcome=failure' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "ws_persist_failures $(rg 'proxy\\.nio_ws_capture_persist outcome=failure' log.txt vpn_events.ndjson | wc -l | tr -d ' ')"
echo "sse_persist_failures $(rg 'proxy\\.nio_sse_capture_persist outcome=failure' log.txt vpn_events.ndjson | wc -l | tr -d ' ')"
echo "quic_intercept_count $(rg 'quic.*intercept' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "quic_passthrough_count $(rg 'quic.*passthrough' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "quic_block_count $(rg 'quic.*block' vpn_events.ndjson | wc -l | tr -d ' ')"
echo "policy_engine_failures $(rg 'dual_mitm_policy.*failure' vpn_events.ndjson | wc -l | tr -d ' ')"
```

Baseline expected:

1. `h2_count > 0`
2. `stream_pipeline > 0`
3. `upstream_failures = 0`
4. `error_responses = 0`
5. `mitm_pipeline_failures = 0`
6. `ws_persist_failures = 0`
7. `sse_persist_failures = 0`
8. `buffer_pipeline = 0` in baseline; `>0` only in interception phase.
9. `quic_intercept_count > 0` when `quicHandlingMode = intercept` and HTTP/3-capable sites browsed.
10. `policy_engine_failures = 0`

---

## 8) Known-Expected Behaviors (not bugs)

1. `304 Not Modified` has no response body.
2. `204 No Content` has no response body.
3. `HEAD` responses (if tested) have no response body.
4. `CONNECT 200` tunnel-establishment rows can appear alongside normal decrypted HTTP entries.
5. Some shutdown-window `client_handler_error` entries can occur during tunnel stop; separate shutdown noise from active-browsing failures.
6. QUIC flows may show adaptive fail-open behavior: initial MITM attempt failures trigger pass-through fallback with TTL-based bypass records in `HostBypassStore`.
7. DualMITMPolicyEngine shadow-mode log entries may appear when `dualMITMPolicyEngineShadow = true`; these are observational and do not affect routing.

---

## 9) Fail Criteria

Fail the run if any occurs:

1. Broad page load failures under normal browsing.
2. Repeated `502` behavior.
3. Any `proxy_nio_http_upstream_failure` during active browsing.
4. Missing core captured fields (URL/method/status/protocol/headers).
5. Missing body for normal body-bearing `200` responses.
6. Missing WS/SSE capture when Phase 3/4 actions were successful in browser UI.
7. Interception phase cannot force `buffer_and_intercept`.
8. QUIC intercept mode fails to capture HTTP/3 requests from HTTP/3-capable sites.
9. QUIC block mode fails to force TCP/TLS fallback.
10. DualMITMPolicyEngine produces inconsistent routing for the same host across TCP and QUIC flows.

---

## 10) Retest Cadence

Run this full plan:

1. Before merging major proxy/TLS/HTTP pipeline changes.
2. After `NIOMITMProxyEngine.swift` behavior changes.
3. Before release branch cut.
4. After `QUICFlowRouter` or `DualMITMPolicyEngine` behavior changes.
5. After `HardeningConfig` flag default changes.
