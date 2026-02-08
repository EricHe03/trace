#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./Tools/Curl/fetch_curl_source.sh 8.18.0 submodule
#   ./Tools/Curl/fetch_curl_source.sh 8.18.0 tarball

VERSION="${1:-8.18.0}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_MODE="${2:-submodule}"
DEST_DIR="$ROOT_DIR/ThirdParty/curl"
SNAPSHOT_DIR="$ROOT_DIR/ThirdParty/curl/snapshots/curl-${VERSION}"
TMP_DIR="$(mktemp -d)"
SUBMODULE_PATH="ThirdParty/curl"
TAG="curl-${VERSION//./_}"
VENDOR_HEADER="$ROOT_DIR/ThirdParty/curl-shim/include/trace_curl_vendor.h"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

write_vendor_header() {
  local tag="$1"
  local commit="$2"

  cat > "$VENDOR_HEADER" <<EOF
#ifndef TRACE_CURL_VENDOR_H
#define TRACE_CURL_VENDOR_H

#define TRACE_CURL_VENDOR_TAG "${tag}"
#define TRACE_CURL_VENDOR_COMMIT "${commit}"

#endif /* TRACE_CURL_VENDOR_H */
EOF
  echo "Updated $VENDOR_HEADER"
}

case "$SOURCE_MODE" in
  submodule)
    if [ ! -e "$ROOT_DIR/.gitmodules" ]; then
      echo "Expected .gitmodules in repository root" >&2
      exit 1
    fi

    if [ ! -d "$DEST_DIR/.git" ] && [ ! -f "$DEST_DIR/.git" ]; then
      git -C "$ROOT_DIR" submodule update --init -- "$SUBMODULE_PATH"
    fi

    git -C "$DEST_DIR" remote set-url origin https://github.com/curl/curl.git
    if ! git -C "$DEST_DIR" fetch --tags origin; then
      echo "Warning: failed to fetch tags from origin, using local tag refs only." >&2
    fi
    if ! git -C "$DEST_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
      echo "Tag $TAG is not available in $SUBMODULE_PATH." >&2
      echo "Run with network access or fetch tags manually in the submodule." >&2
      exit 1
    fi
    git -C "$DEST_DIR" checkout "$TAG"

    COMMIT="$(git -C "$DEST_DIR" rev-parse HEAD)"
    write_vendor_header "$TAG" "$COMMIT"
    echo "Pinned $SUBMODULE_PATH to $TAG ($COMMIT)"
    echo "Remember to commit the updated submodule pointer in the superproject."
    ;;
  tarball)
    ARCHIVE="curl-${VERSION}.tar.xz"
    URL="https://curl.se/download/${ARCHIVE}"
    mkdir -p "$TMP_DIR/extract"
    curl -fL "$URL" -o "$TMP_DIR/$ARCHIVE"
    tar -xf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR/extract"
    rm -rf "$SNAPSHOT_DIR"
    mkdir -p "$(dirname "$SNAPSHOT_DIR")"
    cp -R "$TMP_DIR/extract/curl-${VERSION}/" "$SNAPSHOT_DIR"
    echo "Fetched curl ${VERSION} tarball snapshot into $SNAPSHOT_DIR"
    echo "Submodule and shim metadata were not modified."
    ;;
  *)
    echo "Unsupported source mode: $SOURCE_MODE" >&2
    echo "Supported modes: submodule, tarball" >&2
    exit 1
    ;;
esac
