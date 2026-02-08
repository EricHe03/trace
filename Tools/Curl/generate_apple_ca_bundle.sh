#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_PATH="${ROOT_DIR}/TraceCurlRuntime/Resources/apple-system-roots.pem"
KEYCHAIN_PATH="/System/Library/Keychains/SystemRootCertificates.keychain"

mkdir -p "$(dirname "${OUTPUT_PATH}")"
security find-certificate -a -p "${KEYCHAIN_PATH}" > "${OUTPUT_PATH}"

CERT_COUNT="$(grep -c "BEGIN CERTIFICATE" "${OUTPUT_PATH}" || true)"
echo "Wrote ${OUTPUT_PATH} (${CERT_COUNT} certificates)"
