#!/usr/bin/env bash

set -euo pipefail

[ -d "/opt/homebrew/bin" ] && export PATH="/opt/homebrew/bin:$PATH"

cd "$(dirname "$0")/.."

TEST_MATRIX_FILE="${TEST_PASS_DIR:-.}/test-matrix.yaml"

if ! command -v yq &> /dev/null; then
    echo "yq is required but not installed." >&2
    exit 1
fi

echo "tests:" > "${TEST_MATRIX_FILE}"

readarray -t impls < <(yq eval '.implementations[].id' images.yaml)
readarray -t images < <(yq eval '.implementations[].imageName' images.yaml)

for i in "${!impls[@]}"; do
    for j in "${!impls[@]}"; do
        joiner="${impls[$i]}"
        joiner_img="${images[$i]}"

        bootstrap="${impls[$j]}"
        bootstrap_img="${images[$j]}"

        test_id="${joiner}_x_${bootstrap}"

        cat >> "${TEST_MATRIX_FILE}" <<ENTRY
  - id: ${test_id}
    joiner:
      id: ${joiner}
      imageName: ${joiner_img}
    bootstrap:
      id: ${bootstrap}
      imageName: ${bootstrap_img}
ENTRY
    done
done
