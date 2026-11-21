#!/usr/bin/env bash

set -euo pipefail

[ -d "/opt/homebrew/bin" ] && export PATH="/opt/homebrew/bin:$PATH"

TEST_INDEX="${1}"
TEST_PASS="${2}"
RESULTS_FILE="${3}"

# Read from matrix
JOINER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].joiner.id" "${TEST_PASS_DIR}/test-matrix.yaml")
JOINER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].joiner.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
BOOTSTRAP_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].bootstrap.id" "${TEST_PASS_DIR}/test-matrix.yaml")
BOOTSTRAP_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].bootstrap.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
TEST_NAME=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].id" "${TEST_PASS_DIR}/test-matrix.yaml")

TEST_KEY=$(echo -n "${TEST_NAME}" | sha256sum | cut -c1-8)
TEST_SLUG=$(echo "${TEST_NAME}" | sed 's/[^a-zA-Z0-9-]/_/g')
COMPOSE_PROJECT_NAME="bs_${TEST_SLUG}"
COMPOSE_FILE="${TEST_PASS_DIR}/docker-compose/${TEST_SLUG}.yaml"
LOG_FILE="${TEST_PASS_DIR}/logs/${TEST_SLUG}.log"

cleanup() {
  if [ -f "${COMPOSE_FILE}" ]; then
    docker compose -f "${COMPOSE_FILE}" down --volumes --remove-orphans >> "${LOG_FILE}" 2>&1 || true
  fi
}
trap cleanup EXIT

cat > "${COMPOSE_FILE}" <<COMPOSE
name: ${COMPOSE_PROJECT_NAME}

networks:
  default:
    name: bootstrap-network
    external: true

services:
  bootstrap:
    image: "${BOOTSTRAP_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_bootstrap
    init: true
    environment:
      - ROLE=bootstrap
      - REDIS_ADDR=bootstrap-redis:6379
      - TEST_KEY=${TEST_KEY}

  joiner:
    image: "${JOINER_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_joiner
    init: true
    depends_on:
      - bootstrap
    environment:
      - ROLE=joiner
      - REDIS_ADDR=bootstrap-redis:6379
      - TEST_KEY=${TEST_KEY}
COMPOSE

TEST_START=$(date +%s)

if timeout 120 docker compose -f "${COMPOSE_FILE}" up --exit-code-from joiner --abort-on-container-exit >> "${LOG_FILE}" 2>&1; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

TEST_END=$(date +%s)
TEST_DURATION=$((${TEST_END} - ${TEST_START}))

JOINER_LOGS=$(docker compose -f "${COMPOSE_FILE}" logs joiner 2>/dev/null || true)
JOINER_YAML=$(echo "${JOINER_LOGS}" | grep -E "joiner.*\| (status:|error:)" | sed 's/^.*| //' || true)
INDENTED_YAML=$(echo "${JOINER_YAML}" | sed 's/^/    /')

# Determine final status (treat as fail if exit code is non-zero OR if joiner printed status: fail)
if [ "${EXIT_CODE}" -ne 0 ] || echo "${JOINER_YAML}" | grep -q "status: fail"; then
    FINAL_STATUS="fail"
else
    FINAL_STATUS="pass"
fi

# Save complete result to individual file
cat > "${TEST_PASS_DIR}/results/${TEST_NAME}.yaml" <<RESULT
test: ${TEST_NAME}
joiner: ${JOINER_ID}
bootstrap: ${BOOTSTRAP_ID}
status: ${FINAL_STATUS}
duration: ${TEST_DURATION}s

# Output from joiner
${JOINER_YAML}
RESULT

# Append to combined results file
cat >> "${RESULTS_FILE}" <<RESULT
  - id: ${TEST_NAME}
    joiner: ${JOINER_ID}
    bootstrap: ${BOOTSTRAP_ID}
    status: ${FINAL_STATUS}
    duration: ${TEST_DURATION}s
    joiner_output: |
${INDENTED_YAML}
RESULT

if [ "${FINAL_STATUS}" = "pass" ]; then
    exit 0
else
    exit 1
fi
