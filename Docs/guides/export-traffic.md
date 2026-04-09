# Export Traffic

Trace can export captured traffic in several formats for sharing, offline analysis, or archiving.

## HAR (HTTP Archive)

HAR is a JSON-based format understood by browser DevTools, Charles, Proxyman, and many online analysis tools.

### Export all captured traffic

1. Open **Settings → Export → HAR Export**.
2. Tap **Export All** to include everything in the current capture session.
3. Choose a share destination (Files, AirDrop, Mail, etc.).

### Export a selection

1. On the **Network** tab, long-press a request to enter selection mode.
2. Select one or more requests.
3. Tap the **Share** button and choose **Export as HAR**.

### HAR import

To load a HAR file captured in another tool:

1. Open **Settings → Export → HAR Import**.
2. Select the `.har` file from Files.
3. Trace loads the entries into a read-only session you can browse and filter.

## cURL

### Export a single request as cURL

1. Tap any request in the **Network** tab.
2. Tap the **Share** icon.
3. Select **Copy as cURL**.

The cURL command includes method, URL, headers, and body. Cookies and authorization headers are included unless you strip them with a rewrite rule before export.

### Import a cURL command

1. On the **Network** tab, tap **+** → **Import cURL**.
2. Paste the cURL string.
3. Trace parses it into the request builder, where you can modify and replay it.

## PCAP

PCAP files contain raw packet data and can be opened in Wireshark or `tcpdump`.

Trace generates PCAP on the full-tunnel path (the VPN extension captures packets at the IP layer).

### Export PCAP

1. Open **Settings → Packet Capture**.
2. Tap **Export** next to the capture session you want.
3. Share the `.pcap` file.

Note: PCAP contains encrypted TLS payloads unless you also export the session keys (not currently supported). Use HAR for decrypted request/response content.

## VPN NDJSON log

The VPN extension produces a newline-delimited JSON log of tunnel events (connection opens, closes, UDP flows, DNS events). This is useful for debugging full-tunnel routing issues.

1. Open **Settings → Full Tunnel → Export Log**.
2. Share the `.ndjson` file.

Each line is a self-contained JSON object with a `type`, `timestamp`, and event-specific fields.

## Format comparison

| Format | Content | Best for |
|---|---|---|
| HAR | Decrypted HTTP request/response pairs | Sharing with web tooling, browser DevTools |
| cURL | Single request as a shell command | Reproducing a request in a terminal |
| PCAP | Raw IP/TCP/UDP packets (encrypted) | Wireshark analysis, packet-level debugging |
| NDJSON | Full-tunnel routing events | Diagnosing VPN / tunnel-layer issues |
