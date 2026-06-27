#!/usr/bin/env bash

set -euo pipefail

TEST_INDEX="${1}"
TEST_PASS="${2}"
RESULTS_FILE="${3}"

# Read from matrix
BOOTSTRAP_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].bootstrap.id" "${TEST_PASS_DIR}/test-matrix.yaml")
BOOTSTRAP_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].bootstrap.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
PROVIDER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].provider.id" "${TEST_PASS_DIR}/test-matrix.yaml")
PROVIDER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].provider.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
QUERIER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].querier.id" "${TEST_PASS_DIR}/test-matrix.yaml")
QUERIER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].querier.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")
TEST_NAME=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].id" "${TEST_PASS_DIR}/test-matrix.yaml")

TEST_KEY=$(echo -n "${TEST_NAME}" | sha256sum | cut -c1-8)
TEST_SLUG=$(echo "${TEST_NAME}" | sed 's/[^a-zA-Z0-9-]/_/g')
COMPOSE_PROJECT_NAME="kad_${TEST_SLUG}"
COMPOSE_FILE="${TEST_PASS_DIR}/docker-compose/${TEST_SLUG}.yaml"
LOG_FILE="${TEST_PASS_DIR}/logs/${TEST_SLUG}.log"

cleanup() {
  if [ -f "${COMPOSE_FILE}" ]; then
    docker compose -f "${COMPOSE_FILE}" down --volumes --remove-orphans >> "${LOG_FILE}" 2>&1 || true
  fi
}
trap cleanup EXIT

cat > "${COMPOSE_FILE}" <<EOF
name: ${COMPOSE_PROJECT_NAME}

networks:
  default:
    name: transport-network
    external: true

services:
  bootstrap:
    image: "${BOOTSTRAP_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_bootstrap
    init: true
    environment:
      - ROLE=bootstrap
      - REDIS_ADDR=transport-redis:6379
      - TEST_KEY=${TEST_KEY}

  provider:
    image: "${PROVIDER_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_provider
    init: true
    depends_on:
      - bootstrap
    environment:
      - ROLE=provider
      - REDIS_ADDR=transport-redis:6379
      - TEST_KEY=${TEST_KEY}

  querier:
    image: "${QUERIER_IMAGE}"
    container_name: ${COMPOSE_PROJECT_NAME}_querier
    init: true
    depends_on:
      - bootstrap
      - provider
    environment:
      - ROLE=querier
      - REDIS_ADDR=transport-redis:6379
      - TEST_KEY=${TEST_KEY}
EOF

TEST_START=$(date +%s)

if timeout 180 docker compose -f "${COMPOSE_FILE}" up --exit-code-from querier --abort-on-container-exit >> "${LOG_FILE}" 2>&1; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

TEST_END=$(date +%s)
TEST_DURATION=$((${TEST_END} - ${TEST_START}))

QUERIER_LOGS=$(docker compose -f "${COMPOSE_FILE}" logs querier 2>/dev/null || true)
QUERIER_YAML=$(echo "${QUERIER_LOGS}" | grep -E "querier.*\| (latency:|  (handshake_plus_one_rtt|ping_rtt|unit):)" | sed 's/^.*| //' || true)
INDENTED_YAML=$(echo "${QUERIER_YAML}" | sed 's/^/    /')

cat >> "${RESULTS_FILE}" <<EOF
  - name: ${TEST_NAME}
    bootstrap: ${BOOTSTRAP_ID}
    provider: ${PROVIDER_ID}
    querier: ${QUERIER_ID}
    status: $([ "${EXIT_CODE}" -eq 0 ] && echo "pass" || echo "fail")
    duration: ${TEST_DURATION}s
${INDENTED_YAML}
EOF

exit ${EXIT_CODE}
