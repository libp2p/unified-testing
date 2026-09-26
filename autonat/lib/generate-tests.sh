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
        server="${impls[$i]}"
        server_img="${images[$i]}"

        client="${impls[$j]}"
        client_img="${images[$j]}"

        test_id="${server}_x_${client}"

        cat >> "${TEST_MATRIX_FILE}" <<ENTRY
  - id: ${test_id}
    server:
      id: ${server}
      imageName: ${server_img}
    client:
      id: ${client}
      imageName: ${client_img}
ENTRY
    done
done
