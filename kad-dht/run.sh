#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

export TEST_TYPE="kad-dht"
export TEST_PASS_DIR="${PWD}/results/$(date +%H%M%S-%d-%m-%Y)"
mkdir -p "${TEST_PASS_DIR}"/{logs,results,docker-compose}

# 1. Generate Test Matrix
echo "Generating test matrix..."
bash ./lib/generate-tests.sh

# 2. Build Docker images
echo "Building Docker images..."

# Loop over all implementations defined in images.yaml
readarray -t IMPL_IDS < <(yq eval '.implementations[].id' images.yaml)

for id in "${IMPL_IDS[@]}"; do
    IMAGE_NAME=$(yq eval ".implementations[] | select(.id == \"${id}\") | .imageName" images.yaml)
    BUILD_CONTEXT=$(yq eval ".implementations[] | select(.id == \"${id}\") | .buildContext" images.yaml)
    
    # Check if there is a github source to dynamically clone
    REPO=$(yq eval ".implementations[] | select(.id == \"${id}\") | .source.repo" images.yaml)
    COMMIT=$(yq eval ".implementations[] | select(.id == \"${id}\") | .source.commit" images.yaml)
    
    if [ -n "$REPO" ] && [ "$REPO" != "null" ]; then
        REPO_NAME=$(basename "$REPO")
        CLONE_DIR="${BUILD_CONTEXT}/${REPO_NAME}"
        
        echo "Cloning ${REPO_NAME} from ${REPO} at commit ${COMMIT}..."
        rm -rf "${CLONE_DIR}"
        git clone "https://github.com/${REPO}.git" "${CLONE_DIR}"
        pushd "${CLONE_DIR}" > /dev/null
        git checkout "${COMMIT}"
        
        # Apply any patches found in the build context
        for patch in ../*.patch; do
            if [ -f "$patch" ]; then
                echo "Applying patch $(basename "$patch")..."
                git apply "$patch"
            fi
        done
        
        popd > /dev/null
    fi
    
    echo "Building ${IMAGE_NAME} from ${BUILD_CONTEXT}..."
    docker build -t "${IMAGE_NAME}" "${BUILD_CONTEXT}"
done

# 3. Start Global Redis
echo "Starting global Redis..."
docker rm -f transport-redis 2>/dev/null || true
docker network create transport-network || true
docker run -d --name transport-redis --network transport-network --rm redis:7-alpine

# Ensure redis cleanup on exit
trap 'docker stop transport-redis || true' EXIT

# 4. Run tests
TEST_COUNT=$(yq eval '.tests | length' "${TEST_PASS_DIR}/test-matrix.yaml")
RESULTS_FILE="${TEST_PASS_DIR}/results.yaml.tmp"
> "${RESULTS_FILE}"

echo "Running ${TEST_COUNT} tests..."

for ((i=0; i<TEST_COUNT; i++)); do
    test_id=$(yq eval ".tests[${i}].id" "${TEST_PASS_DIR}/test-matrix.yaml")
    echo "Running test: ${test_id}"
    
    if bash ./lib/run-single-test.sh "${i}" "tests" "${RESULTS_FILE}"; then
        echo "  [SUCCESS]"
    else
        echo "  [FAILED]"
    fi
done

echo "Tests complete. Collecting results..."

PASSED=$(grep -c "^    status: pass" "${RESULTS_FILE}" || true)
FAILED=$(grep -c "^    status: fail" "${RESULTS_FILE}" || true)

cat > "${TEST_PASS_DIR}/results.yaml" <<EOF
summary:
  total: ${TEST_COUNT}
  passed: ${PASSED}
  failed: ${FAILED}

tests:
EOF

cat "${RESULTS_FILE}" >> "${TEST_PASS_DIR}/results.yaml"
rm "${RESULTS_FILE}"

echo "Total: ${TEST_COUNT}, Passed: ${PASSED}, Failed: ${FAILED}"
echo "Test results saved to: ${TEST_PASS_DIR}"

if [ "${FAILED}" -eq 0 ]; then
    exit 0
else
    exit 1
fi
