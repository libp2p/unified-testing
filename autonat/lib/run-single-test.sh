#!/usr/bin/env bash

set -euo pipefail

[ -d "/opt/homebrew/bin" ] && export PATH="/opt/homebrew/bin:$PATH"

TEST_INDEX="${1}"
TEST_PASS="${2}"
RESULTS_FILE="${3}"

# Read from matrix
SERVER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].server.id" "${TEST_PASS_DIR}/test-matrix.yaml")
SERVER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].server.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
CLIENT_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].client.id" "${TEST_PASS_DIR}/test-matrix.yaml")
CLIENT_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].client.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
TEST_NAME=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].id" "${TEST_PASS_DIR}/test-matrix.yaml")

TEST_KEY=$(echo -n "${TEST_NAME}" | sha256sum | cut -c1-8)
TEST_SLUG=$(echo "${TEST_NAME}" | sed 's/[^a-zA-Z0-9-]/_/g')
COMPOSE_PROJECT_NAME="an_${TEST_SLUG}"
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
    name: transport-network
    external: true

services:
  server:
    image: "${SERVER_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_server
    init: true
    environment:
      - ROLE=server
      - REDIS_ADDR=transport-redis:6379
      - TEST_KEY=${TEST_KEY}

  client:
    image: "${CLIENT_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_client
    init: true
    depends_on:
      - server
    environment:
      - ROLE=client
      - REDIS_ADDR=transport-redis:6379
      - TEST_KEY=${TEST_KEY}
COMPOSE

TEST_START=$(date +%s)

if timeout 120 docker compose -f "${COMPOSE_FILE}" up --exit-code-from client --abort-on-container-exit >> "${LOG_FILE}" 2>&1; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

TEST_END=$(date +%s)
TEST_DURATION=$((${TEST_END} - ${TEST_START}))

CLIENT_LOGS=$(docker compose -f "${COMPOSE_FILE}" logs client 2>/dev/null || true)
CLIENT_YAML=$(echo "${CLIENT_LOGS}" | grep -E "client.*\| (status:|error:|verdict:)" | sed 's/^.*| //' || true)
INDENTED_YAML=$(echo "${CLIENT_YAML}" | sed 's/^/    /')

# Determine final status (treat as fail if exit code is non-zero OR if client printed status: fail)
if [ "${EXIT_CODE}" -ne 0 ] || echo "${CLIENT_YAML}" | grep -q "status: fail"; then
    FINAL_STATUS="fail"
else
    FINAL_STATUS="pass"
fi

# Save complete result to individual file
cat > "${TEST_PASS_DIR}/results/${TEST_NAME}.yaml" <<RESULT
test: ${TEST_NAME}
server: ${SERVER_ID}
client: ${CLIENT_ID}
status: ${FINAL_STATUS}
duration: ${TEST_DURATION}s

# Output from client
${CLIENT_YAML}
RESULT

# Append to combined results file
cat >> "${RESULTS_FILE}" <<RESULT
  - id: ${TEST_NAME}
    server: ${SERVER_ID}
    client: ${CLIENT_ID}
    status: ${FINAL_STATUS}
    duration: ${TEST_DURATION}s
    client_output: |
${INDENTED_YAML}
RESULT

exit ${EXIT_CODE}
