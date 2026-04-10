# Stream Interception V2

## Overview

Stream Interception V2 is the sole event-first pipeline for SSE and WebSocket traffic, with parity to the HTTP interception model.

- Feature flag: removed (V2 is the only path)
- Canonical persistence is append-only (`stream_sessions` + `stream_events`)

## Runtime Flow

1. `NIOMITMHTTPConnectHandler` classifies streaming requests (`SSE`/`WebSocket`).
2. When v2 is enabled, routing is delegated to `TraceProxy/MITM/Streams/`:
   - `StreamFlowController`
   - `SSEFlowHandler`
   - `WebSocketFlowHandler`
   - `StreamSessionRuntime`
3. Stream open lifecycle interception runs through `InterceptionProviding`:
   - `interceptStreamOpen(session:)`
4. Protocol handlers apply event-level interception:
   - SSE: incremental parse -> decision (`forward`/`modify`/`block`/`inject`/`replay`) -> forward.
   - WebSocket: frame-aware relay with event decisions, UTF-8 validation for text, fragmented-message reassembly for interception/mutation, and replay injection.
   - WebSocket RFC6455 guards are enforced before interception: continuation sequencing, RSV bit validation, control-frame FIN/payload limits, and close-frame payload/code validity.
   - Compression-aware mutation path for `permessage-deflate` (`RSV1`) using decode/edit/re-encode helpers.
5. Capture state dual-writes into the canonical event journal (`stream_sessions` / `stream_events`)

## Storage Model

Migration `v3_stream_event_journal` adds:

- `stream_sessions`: per stream connection/session metadata
- `stream_events`: append-only sequence journal
- `stream_payload_chunks`: overflow payload chunks for large event payloads
- `stream_replays`: replay specs/results

Backfill runs from legacy tables:

- `websocket_connections` -> `stream_sessions` + `stream_events`
- `sse_connections` -> `stream_sessions` + `stream_events`

## AppGroupStorage APIs

New APIs:

- `upsertStreamSession(_:)`
- `appendStreamEvent(_:)`
- `loadStreamSession(_:)`
- `loadStreamSessions(protocolType:limit:)`
- `loadStreamEvents(sessionID:limit:)`
- `startStreamReplay(_:)`
- `completeStreamReplay(_:)`
- `loadStreamReplayRecords(sessionID:limit:)`
- `observeStreamUpdates(handler:)`
- `deleteStreamSessions(olderThan:)`

Compatibility projection:

- `loadAllWebSocketConnections()` and `loadAllSSEConnections()` project from canonical stream tables when v2 is enabled.
- Legacy readers/writers still function for rollback safety.

## Interception Surface

`InterceptionProviding` now includes:

- `interceptStreamOpen(session:)`
- `interceptStreamEvent(session:event:)`
- `interceptStreamClose(session:reason:)`

`RequestInterceptor` currently provides:

- open-time block decision support (rules)
- stream event breakpoint pause/edit/drop flow (`BreakpointType.stream`)
- stream payload modification support via rewrite `replaceBody` actions
- stream script execution support (`ScriptType.stream`) with event payload/metadata mutation and `forward`/`block`/`drop` actions
- stored stream breakpoint edit replay (`edit once` / `always apply`)

## Cleanup and Retention

`DataCleanupManager` now deletes old stream sessions by retention window through:

- `AppGroupStorage.deleteStreamSessions(olderThan:)`

This enforces retention by expiring old sessions instead of truncating live events.

## Extension Points

- `SSEInterceptionRuntime`: customize SSE event mutation/replay composition.
- `NIOMITMWebSocketRelayHandler`: add opcode-specific policy, control-frame policy, or richer replay timing.
- `StreamReplayEngine`: timing scheduler is enabled for replay (`original_timing` preserves captured inter-event deltas; `step` sends immediately). Extend selectors/scheduling policy as needed.
- `RequestInterceptor.interceptStreamEvent`: add script-native stream transforms and protocol-aware mutation policies.
- UI can read replay audit records from `loadStreamReplayRecords(sessionID:)` for operator traceability.

## UI Tooling (Phase E)

- `SSEDetailView` and `WebSocketDetailView` include replay audit sections backed by `stream_replays`.
- Both detail views expose a "Copy Replay Spec" action to export deterministic replay inputs (`session_id`, `event_ids`, timing mode).
- SSE event details support multi-view payload inspection (`text` / `hex` / `raw`) to match stream-editing operator workflows.
