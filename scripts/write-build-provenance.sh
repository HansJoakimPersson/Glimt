#!/bin/bash
set -euo pipefail

python3 "${SRCROOT}/scripts/write-build-provenance.py" \
    --source-root "${SRCROOT}" \
    --bundle-path "${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}" \
    --configuration "${CONFIGURATION}" \
    --code-sign-identity "${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-unknown}}"
