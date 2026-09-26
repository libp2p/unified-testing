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
        for k in "${!impls[@]}"; do
            relay="${impls[$i]}"
            relay_img="${images[$i]}"

            listener="${impls[$j]}"
            listener_img="${images[$j]}"

            dialer="${impls[$k]}"
            dialer_img="${images[$k]}"

            test_id="${relay}_x_${listener}_x_${dialer}"

            cat >> "${TEST_MATRIX_FILE}" <<ENTRY
  - id: ${test_id}
    relay:
      id: ${relay}
      imageName: ${relay_img}
    listener:
      id: ${listener}
      imageName: ${listener_img}
    dialer:
      id: ${dialer}
      imageName: ${dialer_img}
ENTRY
        done
    done
done
