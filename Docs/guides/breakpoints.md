# Use Breakpoints

Breakpoints let you pause a request or response mid-flight, inspect it, and optionally edit it before it continues. Unlike rewrite rules (which apply transformations silently), breakpoints surface the live traffic in a dedicated editor so you can make one-off decisions or test edge cases interactively.

## Open the breakpoint editor

Go to the **Tools** tab and tap **Breakpoints**.

## Breakpoint structure

Each breakpoint has:

| Field | Description |
|---|---|
| **Name** | A human-readable label shown in the list |
| **Type** | Which phase to intercept: Request, Response, Stream Event, or Request & Response |
| **Match** | URL pattern (exact, prefix, contains, wildcard, or regex) |
| **Methods** | HTTP methods to match (empty = all) |
| **Status codes** | Response status codes to match (Response and Request & Response types only; empty = all) |
| **Execution mode** | What happens when the breakpoint fires (see below) |
| **Max hits** | Stop firing after N matches (leave empty for unlimited) |
| **Conditions** | Additional header or body conditions that must be true for the breakpoint to fire |

## Execution modes

| Mode | Behavior |
|---|---|
| **Pause Every Time** | Halts the request or response and opens the editor. Traffic is blocked until you tap **Continue** or **Abort**. |
| **Edit Once** | Opens the editor on the first match. After you save an edit, the breakpoint switches to **Always Apply** automatically, replaying those edits on subsequent matches without pausing. |
| **Always Apply** | Applies the saved edits on every match without pausing — like a rewrite rule, but backed by edits you made interactively. |
| **Log Only** | Records the match in the breakpoint hit log without pausing or modifying traffic. Useful for counting hits or confirming a pattern fires. |

## Example — inspect an auth token before it leaves the device

1. Tap **+** to create a new breakpoint.
2. Name it `Auth token`.
3. Set **Type** → Request.
4. Set **Match** → contains → `api.example.com`.
5. Set **Methods** → `POST`.
6. Set **Execution mode** → Pause Every Time.
7. Toggle the breakpoint on.

The next time the app POSTs to `api.example.com`, Trace pauses the request and shows the headers and body in the editor. Inspect or edit the `Authorization` header, then tap **Continue** to send it, or **Abort** to drop the request.

## Example — replay a fixed edit on every request

1. Create a breakpoint with **Execution mode** → Edit Once.
2. When it first fires, change the `X-Feature-Flag` header value to `beta`.
3. Tap **Continue**.
4. Trace saves that edit and switches the mode to **Always Apply**. All subsequent matching requests have `X-Feature-Flag: beta` injected automatically.

## Sync across app and VPN extension

Breakpoints are persisted in the App Group container and synchronized between the main app and the VPN extension. Edits you make while a capture session is live take effect immediately on the next matching request — you do not need to restart the session.

## Related tools

- **Rewrite Rules** (Tools tab) — declarative request/response modifications that always apply without pausing
- **Scripts** (Tools tab) — JavaScript-based transformations for logic-heavy modifications
