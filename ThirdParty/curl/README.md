# Vendored curl Runtime

This directory contains a pinned upstream curl source checkout (tool + lib)
consumed by `CCurlShim` for runtime capability reporting and the planned
authoritative analyzer/executor path.

Current status: vendored as git submodule at `ThirdParty/curl/upstream`.

## Pinned release

- Current pinned target: `8.18.0`
- Current vendored git tag: `curl-8_18_0`
- Current vendored commit: `2eebc58c4b8d68c98c8344381a9f6df4cca838fd`
- Update this when vendoring a newer stable release.

## Submodule

- Submodule path: `ThirdParty/curl/upstream`
- URL: `https://github.com/curl/curl.git`
- This avoids nested standalone repositories and keeps pinning explicit in the superproject.

## Layout

- `upstream/` git submodule (canonical curl repository)
- `README.md` this integration guide

## Bootstrap

1. Run `git submodule update --init --recursive` after clone.
2. To retarget version/tag, run:
   `/Users/lujuncheng/Trace-iOS/Trace/Tools/Curl/fetch_curl_source.sh 8.18.0 submodule`.
3. Commit both `.gitmodules` and the updated submodule pointer.
4. Commit regenerated vendor metadata:
   `ThirdParty/curl-shim/include/trace_curl_vendor.h`.
5. Verify metadata consistency:
   `/Users/lujuncheng/Trace-iOS/Trace/Tools/Curl/verify_curl_vendor_sync.sh`.
6. Update `CCurlShim` integration code if required by the new upstream release.

## Notes

- Runtime execution path:
  simulator/macOS builds use host `/usr/bin/curl` via `TraceCurlRuntime`, with
  argv-based invocation (no shell command wrapping) and dynamic capability
  discovery from `curl --version` / `curl --help all`.
- Device fallback:
  iOS device builds still run the URLSession fallback path and report
  unsupported capability diagnostics where parity is not available.
- A `tarball` mode exists in the fetch script for local one-off snapshots under
  `ThirdParty/curl/snapshots/`; it does not change the git submodule pointer or
  shim vendor metadata.
- Full in-process tool/libcurl wiring is still planned; the current runtime path
  keeps parity behavior explicit through backend capability diagnostics.
