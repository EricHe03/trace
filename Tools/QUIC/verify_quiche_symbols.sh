#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <libquiche.a|quiche.xcframework>"
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

require_command nm

TARGET_PATH="$1"

declare -a LIBS=()
if [[ -f "${TARGET_PATH}" ]]; then
  LIBS+=("${TARGET_PATH}")
elif [[ -d "${TARGET_PATH}" ]]; then
  while IFS= read -r lib; do
    LIBS+=("${lib}")
  done < <(find "${TARGET_PATH}" -type f -name "libquiche.a" | sort)
else
  echo "Path does not exist: ${TARGET_PATH}"
  exit 1
fi

if [[ ${#LIBS[@]} -eq 0 ]]; then
  echo "No libquiche.a files found in: ${TARGET_PATH}"
  exit 1
fi

required_symbols=(
  "quiche_version"
  "quiche_conn_new_with_tls"
  "quiche_conn_recv"
  "quiche_conn_send"
  "quiche_conn_timeout_as_nanos"
  "quiche_h3_conn_new_with_transport"
  "quiche_h3_conn_poll"
  "quiche_h3_send_request"
  "quiche_h3_send_body"
  "quiche_h3_recv_body"
)

verify_lib() {
  local lib_path="$1"
  local symbol_table

  if ! symbol_table="$(nm -g "${lib_path}" 2>/dev/null)"; then
    echo "Failed to inspect symbols for: ${lib_path}"
    return 1
  fi

  local missing=0
  for symbol in "${required_symbols[@]}"; do
    if ! grep -Eq "(^|[[:space:]])_?${symbol}$" <<<"${symbol_table}"; then
      echo "Missing symbol in ${lib_path}: ${symbol}"
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    return 1
  fi
  echo "Verified symbols: ${lib_path}"
}

failed=0
for lib in "${LIBS[@]}"; do
  if ! verify_lib "${lib}"; then
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  echo "quiche symbol verification failed."
  exit 1
fi

echo "quiche symbol verification passed."
