#!/usr/bin/env bash
#
# build-tests.sh — Build and run Trace test suites
#
# Workaround for Xcode 26 beta SPM bug:
#   When a swift-crypto package product has the same name as its target,
#   Xcode skips the Ld step for the versioned package product framework.
#   We detect this, apply the fix, and rebuild automatically.
#
# Usage:
#   ./Tools/build-tests.sh [simulator-id] [xcodebuild-extra-args...]
#
# Examples:
#   ./Tools/build-tests.sh
#   ./Tools/build-tests.sh 12662A3A-B65C-4357-ADA4-88D7F3A04579
#   ./Tools/build-tests.sh 12662A3A-... -only-testing:TraceLogicTests

set -euo pipefail

SIMULATOR_ID="${1:-12662A3A-B65C-4357-ADA4-88D7F3A04579}"
shift 2>/dev/null || true
EXTRA_ARGS=("$@")

XCODEBUILD_BASE=(
    xcodebuild
    -project Trace.xcodeproj
    -scheme Trace
    -testPlan Trace
    -destination "platform=iOS Simulator,id=${SIMULATOR_ID}"
    -enableCodeCoverage NO
)

# ---------------------------------------------------------------------------
# Step 1: Resolve BUILD_DIR from Xcode build settings
# ---------------------------------------------------------------------------
BUILD_DIR=$(xcodebuild "${XCODEBUILD_BASE[@]:1:4}" -showBuildSettings 2>/dev/null \
    | awk '/^\s+BUILD_DIR\s*=/ { print $3; exit }')

if [[ -z "$BUILD_DIR" ]]; then
    echo "error: could not determine BUILD_DIR" >&2
    exit 1
fi

FRAMEWORKS="${BUILD_DIR}/PackageFrameworks"

# ---------------------------------------------------------------------------
# fix_crypto — Copy Crypto.framework binary into the missing PackageProduct
# ---------------------------------------------------------------------------
fix_crypto() {
    local crypto_binary="${FRAMEWORKS}/Crypto.framework/Crypto"
    local product_dir="${FRAMEWORKS}/Crypto_17A3B1FFC41E47_PackageProduct.framework"
    local product_binary="${product_dir}/Crypto_17A3B1FFC41E47_PackageProduct"
    local product_plist="${product_dir}/Info.plist"

    if [[ ! -f "$crypto_binary" ]]; then
        echo "warn: Crypto.framework binary not found — cannot apply workaround" >&2
        return 1
    fi

    if [[ -f "$product_binary" ]]; then
        return 0  # already fixed
    fi

    echo "→ Applying Crypto package product workaround…"
    cp "$crypto_binary" "$product_binary"

    [[ -f "$product_plist" ]] && \
        plutil -replace CFBundleIdentifier \
               -string "swift-crypto.Crypto.PackageProduct" \
               "$product_plist" 2>/dev/null || true

    # Fix embedded copy in Trace.app (needed for TraceTests host app install)
    local app_plist="${BUILD_DIR}/Debug-iphonesimulator/Trace.app/Frameworks/Crypto_17A3B1FFC41E47_PackageProduct.framework/Info.plist"
    [[ -f "$app_plist" ]] && \
        plutil -replace CFBundleIdentifier \
               -string "swift-crypto.Crypto.PackageProduct" \
               "$app_plist" 2>/dev/null || true

    echo "→ Workaround applied."
}

# ---------------------------------------------------------------------------
# Step 2: First build attempt
# ---------------------------------------------------------------------------
echo "==> Building for testing (pass 1)…"
if "${XCODEBUILD_BASE[@]}" build-for-testing "${EXTRA_ARGS[@]}" 2>&1; then
    BUILD_OK=1
else
    BUILD_OK=0
fi

# ---------------------------------------------------------------------------
# Step 3: If build failed, apply workaround and retry
# ---------------------------------------------------------------------------
if [[ "$BUILD_OK" -eq 0 ]]; then
    echo "==> Build failed. Attempting Crypto package product workaround…"
    if fix_crypto; then
        echo "==> Rebuilding (pass 2)…"
        "${XCODEBUILD_BASE[@]}" build-for-testing "${EXTRA_ARGS[@]}"
    else
        echo "error: workaround could not be applied" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: Run tests
# ---------------------------------------------------------------------------
echo "==> Running tests…"
"${XCODEBUILD_BASE[@]}" test-without-building "${EXTRA_ARGS[@]}"
