#!/usr/bin/env bash

set -euo pipefail

[ -d "/opt/homebrew/bin" ] && export PATH="/opt/homebrew/bin:$PATH"

TEST_INDEX="${1}"
TEST_PASS="${2}"
RESULTS_FILE="${3}"

# Read from matrix
SERVER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].server.id" "${TEST_PASS_DIR}/test-matrix.yaml")
SERVER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].server.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
REGISTRANT_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].registrant.id" "${TEST_PASS_DIR}/test-matrix.yaml")
REGISTRANT_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].registrant.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
DISCOVERER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].discoverer.id" "${TEST_PASS_DIR}/test-matrix.yaml")
DISCOVERER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].discoverer.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
TEST_NAME=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].id" "${TEST_PASS_DIR}/test-matrix.yaml")

TEST_KEY=$(echo -n "${TEST_NAME}" | sha256sum | cut -c1-8)
TEST_SLUG=$(echo "${TEST_NAME}" | sed 's/[^a-zA-Z0-9-]/_/g')
COMPOSE_PROJECT_NAME="rz_${TEST_SLUG}"
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
    name: rendezvous-network
    external: true

services:
  server:
    image: "${SERVER_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_server
    init: true
    environment:
      - ROLE=server
      - REDIS_ADDR=rendezvous-redis:6379
      - TEST_KEY=${TEST_KEY}

  registrant:
    image: "${REGISTRANT_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_registrant
    init: true
    depends_on:
      - server
    environment:
      - ROLE=registrant
      - REDIS_ADDR=rendezvous-redis:6379
      - TEST_KEY=${TEST_KEY}

  discoverer:
    image: "${DISCOVERER_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_discoverer
    init: true
    depends_on:
      - server
      - registrant
    environment:
      - ROLE=discoverer
      - REDIS_ADDR=rendezvous-redis:6379
      - TEST_KEY=${TEST_KEY}
COMPOSE

TEST_START=$(date +%s)

if timeout 120 docker compose -f "${COMPOSE_FILE}" up --exit-code-from discoverer --abort-on-container-exit >> "${LOG_FILE}" 2>&1; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

TEST_END=$(date +%s)
TEST_DURATION=$((${TEST_END} - ${TEST_START}))

DISCOVERER_LOGS=$(docker compose -f "${COMPOSE_FILE}" logs discoverer 2>/dev/null || true)
DISCOVERER_YAML=$(echo "${DISCOVERER_LOGS}" | grep -E "discoverer.*\| (status:|error:)" | sed 's/^.*| //' || true)
INDENTED_YAML=$(echo "${DISCOVERER_YAML}" | sed 's/^/    /')

# Determine final status (treat as fail if exit code is non-zero OR if discoverer printed status: fail)
if [ "${EXIT_CODE}" -ne 0 ] || echo "${DISCOVERER_YAML}" | grep -q "status: fail"; then
    FINAL_STATUS="fail"
else
    FINAL_STATUS="pass"
fi

# Save complete result to individual file
cat > "${TEST_PASS_DIR}/results/${TEST_NAME}.yaml" <<RESULT
test: ${TEST_NAME}
server: ${SERVER_ID}
registrant: ${REGISTRANT_ID}
discoverer: ${DISCOVERER_ID}
status: ${FINAL_STATUS}
duration: ${TEST_DURATION}s

# Output from discoverer
${DISCOVERER_YAML}
RESULT

# Append to combined results file
cat >> "${RESULTS_FILE}" <<RESULT
  - id: ${TEST_NAME}
    server: ${SERVER_ID}
    registrant: ${REGISTRANT_ID}
    discoverer: ${DISCOVERER_ID}
    status: ${FINAL_STATUS}
    duration: ${TEST_DURATION}s
    discoverer_output: |
${INDENTED_YAML}
RESULT

if [ "${FINAL_STATUS}" = "pass" ]; then
    exit 0
else
    exit 1
fi
