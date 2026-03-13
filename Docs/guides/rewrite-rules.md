# Use Rewrite Rules

Rewrite rules let you modify requests and responses in flight without changing any app code. Rules run on the MITM proxy path, so they apply to all traffic Trace can decrypt.

## Open the rewrite rule editor

Go to the **Tools** tab and tap **Rewrite Rules**.

## Rule structure

Each rule has:

| Field | Description |
|---|---|
| **Name** | A human-readable label shown in the list |
| **Match** | URL pattern (exact, prefix, contains, or regex) |
| **Scope** | Request, response, or both |
| **Actions** | One or more modifications to apply when the rule matches |

Rules are evaluated in list order. Drag to reorder.

## Available actions

### Request actions

| Action | What it does |
|---|---|
| Add / set header | Adds a header or overwrites an existing one |
| Remove header | Strips the header from the request |
| Replace URL | Rewrites the request URL (supports capture groups when using regex match) |
| Set body | Replaces the request body with a static string or JSON |

### Response actions

| Action | What it does |
|---|---|
| Add / set header | Injects a header into the response |
| Remove header | Strips a response header |
| Set status code | Overrides the HTTP status returned to the client |
| Set body | Replaces the response body |
| Inject script | Appends a `<script>` tag to HTML responses |

## Example — strip cache headers

To force revalidation on every request to an API endpoint:

1. Tap **+** to create a new rule.
2. Name it `Strip Cache`.
3. Set **Match** → contains → `api.example.com`.
4. Set **Scope** → Response.
5. Add action: **Remove header** → `Cache-Control`.
6. Add action: **Remove header** → `ETag`.
7. Toggle the rule on and start a capture session.

## Example — mock a 500 response

1. Create a rule named `Force 500`.
2. Match the specific endpoint URL.
3. Scope: Response.
4. Action: **Set status code** → `500`.
5. Action: **Set body** → `{"error":"injected"}`.

The client app receives a 500 with the injected body.

## Enable and disable rules

Each rule has an on/off toggle. Disabled rules are preserved but not evaluated. This is useful for keeping a library of rules and activating only the ones relevant to the current debugging session.

## Related tools

- **Request Maps** (Tools tab) — redirect entire URLs or URL prefixes to a different host or local file, without per-field action editing
- **Breakpoints** (Tools tab) — pause a request mid-flight and edit it interactively before it continues
- **Scripts** (Tools tab) — apply JavaScript-based transformations for logic that cannot be expressed as declarative rules
