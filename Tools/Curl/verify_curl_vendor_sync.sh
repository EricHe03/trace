#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SUBMODULE_DIR="$ROOT_DIR/ThirdParty/curl"
VENDOR_HEADER="$ROOT_DIR/ThirdParty/curl-shim/include/trace_curl_vendor.h"

if [ ! -d "$SUBMODULE_DIR" ]; then
  echo "Missing curl submodule directory: $SUBMODULE_DIR" >&2
  exit 1
fi

if [ ! -f "$VENDOR_HEADER" ]; then
  echo "Missing vendor metadata header: $VENDOR_HEADER" >&2
  exit 1
fi

submodule_commit="$(git -C "$SUBMODULE_DIR" rev-parse HEAD)"

header_tag="$(
  sed -n 's/^#define TRACE_CURL_VENDOR_TAG "\(.*\)"$/\1/p' "$VENDOR_HEADER"
)"
header_commit="$(
  sed -n 's/^#define TRACE_CURL_VENDOR_COMMIT "\(.*\)"$/\1/p' "$VENDOR_HEADER"
)"

if [ -z "$header_tag" ] || [ -z "$header_commit" ]; then
  echo "Could not parse tag/commit from $VENDOR_HEADER" >&2
  exit 1
fi

if [ "$submodule_commit" != "$header_commit" ]; then
  echo "Mismatch detected:" >&2
  echo "  submodule: $submodule_commit" >&2
  echo "  header:    $header_commit" >&2
  echo "Run ./Tools/Curl/fetch_curl_source.sh <version> submodule to resync." >&2
  exit 1
fi

echo "cURL vendor metadata is in sync."
echo "  tag:    $header_tag"
echo "  commit: $header_commit"
