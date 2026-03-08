#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
QUICHE_DIR="${ROOT_DIR}/ThirdParty/quiche"
OUT_DIR="${ROOT_DIR}/build/quiche"
CARGO_TARGET_DIR="${OUT_DIR}/cargo-target"
PROFILE="${QUICHE_PROFILE:-release}"
FEATURES="${QUICHE_FEATURES:-ffi,pkg-config-meta,qlog}"

TARGET_DEVICE="aarch64-apple-ios"
TARGET_SIM_ARM64="aarch64-apple-ios-sim"
TARGET_SIM_X64="x86_64-apple-ios"
TARGETS=("${TARGET_DEVICE}" "${TARGET_SIM_ARM64}" "${TARGET_SIM_X64}")

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

require_command cargo
require_command rustup
require_command lipo
require_command xcodebuild

if [[ ! -f "${QUICHE_DIR}/Cargo.toml" ]]; then
  echo "Missing quiche source at ${QUICHE_DIR}"
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

if [[ ! -d "${QUICHE_DIR}/quiche/include" ]]; then
  echo "quiche headers not found at ${QUICHE_DIR}/quiche/include"
  exit 1
fi

mkdir -p "${OUT_DIR}/lib" "${CARGO_TARGET_DIR}"

echo "==> Building quiche static libraries (profile=${PROFILE}, features=${FEATURES})"
echo "    Source: ${QUICHE_DIR}"
echo "    Output: ${OUT_DIR}"

for target in "${TARGETS[@]}"; do
  rustup target add "${target}"
done

export CARGO_TARGET_DIR
export CMAKE_OSX_DEPLOYMENT_TARGET="${QUICHE_DEPLOYMENT_TARGET:-16.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${QUICHE_DEPLOYMENT_TARGET:-16.0}"

for target in "${TARGETS[@]}"; do
  echo "==> cargo rustc (staticlib) target=${target}"
  cargo rustc \
    --manifest-path "${QUICHE_DIR}/Cargo.toml" \
    --package quiche \
    --profile "${PROFILE}" \
    --features "${FEATURES}" \
    --target "${target}" \
    --crate-type staticlib

  source_lib="${CARGO_TARGET_DIR}/${target}/${PROFILE}/libquiche.a"
  if [[ ! -f "${source_lib}" ]]; then
    echo "Expected artifact not found: ${source_lib}"
    exit 1
  fi

  target_out_dir="${OUT_DIR}/lib/${target}"
  mkdir -p "${target_out_dir}"
  cp "${source_lib}" "${target_out_dir}/libquiche.a"
done

# BoringSSL's hand-written assembly files are compiled with platform=IOS (2)
# even when building for iOS simulator targets. Xcode 15+ (and Xcode 26
# strictly) reject xcframeworks containing libraries with mixed platform
# markers. vtool cannot fix these files because the compact assembly object
# files leave no room in the header for load command replacement, so we patch
# the LC_BUILD_VERSION platform field directly in the binary (IOS=2 → IOSSIMULATOR=7).
fix_simulator_platform() {
  local lib="$1"
  local tmpdir
  tmpdir=$(mktemp -d)

  (cd "$tmpdir" && ar x "$lib")

  local fixed
  fixed=$(python3 - "$tmpdir"/*.o << 'PYEOF'
import struct, sys, os

LC_BUILD_VERSION = 0x32
IOS, IOS_SIM = 2, 7
fixed = 0

for path in sys.argv[1:]:
    if not os.path.isfile(path):
        continue
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    magic = struct.unpack_from('<I', data, 0)[0]
    endian = '<' if magic == 0xFEEDFACF else ('>' if magic == 0xCFFAEDFE else None)
    if endian is None:
        continue
    ncmds = struct.unpack_from(endian + 'I', data, 16)[0]
    offset = 32
    changed = False
    for _ in range(ncmds):
        cmd     = struct.unpack_from(endian + 'I', data, offset)[0]
        cmdsize = struct.unpack_from(endian + 'I', data, offset + 4)[0]
        if cmd == LC_BUILD_VERSION:
            if struct.unpack_from(endian + 'I', data, offset + 8)[0] == IOS:
                struct.pack_into(endian + 'I', data, offset + 8, IOS_SIM)
                changed = True
        offset += cmdsize
    if changed:
        with open(path, 'wb') as f:
            f.write(data)
        fixed += 1

print(fixed)
PYEOF
)

  if [ "${fixed}" -gt 0 ]; then
    echo "    Fixed ${fixed} object file(s) with wrong platform marker in $(basename "$lib")"
    (cd "$tmpdir" && ar rcs libquiche_fixed.a ./*.o)
    cp "$tmpdir/libquiche_fixed.a" "$lib"
  fi

  rm -rf "$tmpdir"
}

echo "==> Fixing simulator platform markers"
fix_simulator_platform "${OUT_DIR}/lib/${TARGET_SIM_ARM64}/libquiche.a"
fix_simulator_platform "${OUT_DIR}/lib/${TARGET_SIM_X64}/libquiche.a"

headers_dir="${OUT_DIR}/include"
rm -rf "${headers_dir}"
mkdir -p "${headers_dir}"
cp -R "${QUICHE_DIR}/quiche/include/." "${headers_dir}/"

sim_universal_dir="${OUT_DIR}/lib/ios-simulator-universal"
sim_universal_lib="${sim_universal_dir}/libquiche.a"
mkdir -p "${sim_universal_dir}"

lipo -create \
  "${OUT_DIR}/lib/${TARGET_SIM_ARM64}/libquiche.a" \
  "${OUT_DIR}/lib/${TARGET_SIM_X64}/libquiche.a" \
  -output "${sim_universal_lib}"

xcframework_path="${OUT_DIR}/quiche.xcframework"
rm -rf "${xcframework_path}"
xcodebuild -create-xcframework \
  -library "${OUT_DIR}/lib/${TARGET_DEVICE}/libquiche.a" -headers "${headers_dir}" \
  -library "${sim_universal_lib}" -headers "${headers_dir}" \
  -output "${xcframework_path}"

echo
echo "quiche artifacts generated:"
echo "  - Device static lib: ${OUT_DIR}/lib/${TARGET_DEVICE}/libquiche.a"
echo "  - Simulator static lib: ${sim_universal_lib}"
echo "  - XCFramework: ${xcframework_path}"
