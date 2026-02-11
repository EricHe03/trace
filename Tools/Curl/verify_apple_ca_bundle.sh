#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE_PATH="${ROOT_DIR}/TraceCurlRuntime/Resources/apple-system-roots.pem"
KEYCHAIN_PATH="/System/Library/Keychains/SystemRootCertificates.keychain"
TEMP_PATH="$(mktemp "${TMPDIR:-/tmp}/trace-apple-roots.XXXXXX.pem")"

cleanup() {
  rm -f "${TEMP_PATH}"
}
trap cleanup EXIT

if [ ! -f "${BUNDLE_PATH}" ]; then
  echo "Missing committed bundle: ${BUNDLE_PATH}" >&2
  exit 1
fi

security find-certificate -a -p "${KEYCHAIN_PATH}" > "${TEMP_PATH}"

if ! grep -q "BEGIN CERTIFICATE" "${TEMP_PATH}"; then
  echo "Failed to export Apple root certificates from keychain: ${KEYCHAIN_PATH}" >&2
  echo "Export result is empty; verify keychain access and retry." >&2
  exit 1
fi

if cmp -s "${BUNDLE_PATH}" "${TEMP_PATH}"; then
  CERT_COUNT="$(grep -c "BEGIN CERTIFICATE" "${BUNDLE_PATH}" || true)"
  echo "Apple root CA bundle is up to date (${CERT_COUNT} certificates)."
  exit 0
fi

COMMITTED_COUNT="$(grep -c "BEGIN CERTIFICATE" "${BUNDLE_PATH}" || true)"
CURRENT_COUNT="$(grep -c "BEGIN CERTIFICATE" "${TEMP_PATH}" || true)"
COMMITTED_SHA="$(shasum -a 256 "${BUNDLE_PATH}" | awk '{print $1}')"
CURRENT_SHA="$(shasum -a 256 "${TEMP_PATH}" | awk '{print $1}')"

echo "Apple root CA bundle is out of date." >&2
echo "Committed: ${BUNDLE_PATH}" >&2
echo "  certs=${COMMITTED_COUNT} sha256=${COMMITTED_SHA}" >&2
echo "Current keychain export:" >&2
echo "  certs=${CURRENT_COUNT} sha256=${CURRENT_SHA}" >&2
echo "Regenerate with: ./Tools/Curl/generate_apple_ca_bundle.sh" >&2
exit 1
