#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

TEST_MATRIX_FILE="${TEST_PASS_DIR:-.}/test-matrix.yaml"

# Ensure yq is available
if ! command -v yq &> /dev/null; then
    echo "yq is required but not installed." >&2
    exit 1
fi

echo "tests:" > "${TEST_MATRIX_FILE}"

# Read implementations
readarray -t impls < <(yq eval '.implementations[].id' images.yaml)
readarray -t images < <(yq eval '.implementations[].imageName' images.yaml)

for i in "${!impls[@]}"; do
    for j in "${!impls[@]}"; do
        for k in "${!impls[@]}"; do
            bootstrap="${impls[$i]}"
            bootstrap_img="${images[$i]}"
            
            provider="${impls[$j]}"
            provider_img="${images[$j]}"
            
            querier="${impls[$k]}"
            querier_img="${images[$k]}"
            
            # The user initially requested 4 combinations, but the dynamic matrix will generate all 8 combinations
            # of (py, dotnet)^3.
            
            test_id="${bootstrap}_x_${provider}_x_${querier}"
            
            cat >> "${TEST_MATRIX_FILE}" <<EOF
  - id: ${test_id}
    bootstrap:
      id: ${bootstrap}
      imageName: ${bootstrap_img}
    provider:
      id: ${provider}
      imageName: ${provider_img}
    querier:
      id: ${querier}
      imageName: ${querier_img}
EOF
        done
    done
done
