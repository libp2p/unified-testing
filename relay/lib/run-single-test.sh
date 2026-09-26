#!/usr/bin/env bash

set -euo pipefail

[ -d "/opt/homebrew/bin" ] && export PATH="/opt/homebrew/bin:$PATH"

TEST_INDEX="${1}"
TEST_PASS="${2}"
RESULTS_FILE="${3}"

# Read from matrix
RELAY_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].relay.id" "${TEST_PASS_DIR}/test-matrix.yaml")
RELAY_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].relay.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
LISTENER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].listener.id" "${TEST_PASS_DIR}/test-matrix.yaml")
LISTENER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].listener.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
DIALER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].dialer.id" "${TEST_PASS_DIR}/test-matrix.yaml")
DIALER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].dialer.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
TEST_NAME=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].id" "${TEST_PASS_DIR}/test-matrix.yaml")

TEST_KEY=$(echo -n "${TEST_NAME}" | sha256sum | cut -c1-8)
TEST_SLUG=$(echo "${TEST_NAME}" | sed 's/[^a-zA-Z0-9-]/_/g')
COMPOSE_PROJECT_NAME="relay_${TEST_SLUG}"
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
    name: relay-network
    external: true

services:
  relay:
    image: "${RELAY_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_relay
    init: true
    environment:
      - ROLE=relay
      - REDIS_ADDR=relay-redis:6379
      - TEST_KEY=${TEST_KEY}

  listener:
    image: "${LISTENER_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_listener
    init: true
    depends_on:
      - relay
    environment:
      - ROLE=listener
      - REDIS_ADDR=relay-redis:6379
      - TEST_KEY=${TEST_KEY}

  dialer:
    image: "${DIALER_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_dialer
    init: true
    depends_on:
      - relay
      - listener
    environment:
      - ROLE=dialer
      - REDIS_ADDR=relay-redis:6379
      - TEST_KEY=${TEST_KEY}
COMPOSE

TEST_START=$(date +%s)

if timeout 120 docker compose -f "${COMPOSE_FILE}" up --exit-code-from dialer --abort-on-container-exit >> "${LOG_FILE}" 2>&1; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

TEST_END=$(date +%s)
TEST_DURATION=$((${TEST_END} - ${TEST_START}))

DIALER_LOGS=$(docker compose -f "${COMPOSE_FILE}" logs dialer 2>/dev/null || true)
DIALER_YAML=$(echo "${DIALER_LOGS}" | grep -E "dialer.*\| (status:|error:)" | sed 's/^.*| //' || true)
INDENTED_YAML=$(echo "${DIALER_YAML}" | sed 's/^/    /')

# Determine final status (treat as fail if exit code is non-zero OR if dialer printed status: fail)
if [ "${EXIT_CODE}" -ne 0 ] || echo "${DIALER_YAML}" | grep -q "status: fail"; then
    FINAL_STATUS="fail"
else
    FINAL_STATUS="pass"
fi

# Save complete result to individual file
cat > "${TEST_PASS_DIR}/results/${TEST_NAME}.yaml" <<RESULT
test: ${TEST_NAME}
relay: ${RELAY_ID}
listener: ${LISTENER_ID}
dialer: ${DIALER_ID}
status: ${FINAL_STATUS}
duration: ${TEST_DURATION}s

# Output from dialer
${DIALER_YAML}
RESULT

# Append to combined results file
cat >> "${RESULTS_FILE}" <<RESULT
  - id: ${TEST_NAME}
    relay: ${RELAY_ID}
    listener: ${LISTENER_ID}
    dialer: ${DIALER_ID}
    status: ${FINAL_STATUS}
    duration: ${TEST_DURATION}s
    dialer_output: |
${INDENTED_YAML}
RESULT

exit ${EXIT_CODE}
