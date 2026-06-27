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
docker build -t kad-dht-py ./images/py
docker build -t kad-dht-dotnet ./images/dotnet

# 3. Start Global Redis
echo "Starting global Redis..."
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

PASSED=$(grep -c "status: pass" "${RESULTS_FILE}" || true)
FAILED=$(grep -c "status: fail" "${RESULTS_FILE}" || true)

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

if [ "${FAILED}" -eq 0 ]; then
    exit 0
else
    exit 1
fi
