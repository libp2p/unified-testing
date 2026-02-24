#!/usr/bin/env bash
# Run a single misc protocol test using docker-compose.
# Identical to transport/lib/run-single-test.sh except:
#  • reads `.protocol` from test-matrix.yaml
#  • passes PROTOCOL env var to both dialer and listener containers

set -euo pipefail

export LOG_FILE

source "${SCRIPT_LIB_DIR}/lib-output-formatting.sh"
source "${SCRIPT_LIB_DIR}/lib-test-caching.sh"
source "${SCRIPT_LIB_DIR}/lib-test-execution.sh"
source "${SCRIPT_LIB_DIR}/lib-generate-tests.sh"

TEST_INDEX="${1}"
TEST_PASS="${2:-tests}"
RESULTS_FILE="${3:-"${TEST_PASS_DIR}/results.yaml.tmp"}"

print_debug "test index: ${TEST_INDEX}"
print_debug "test_pass:  ${TEST_PASS}"

# Read test configuration from matrix
DIALER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].dialer.id"   "${TEST_PASS_DIR}/test-matrix.yaml")
LISTENER_ID=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].listener.id" "${TEST_PASS_DIR}/test-matrix.yaml")
TRANSPORT_NAME=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].transport"    "${TEST_PASS_DIR}/test-matrix.yaml")
SECURE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].secureChannel"   "${TEST_PASS_DIR}/test-matrix.yaml")
MUXER_NAME=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].muxer"         "${TEST_PASS_DIR}/test-matrix.yaml")
PROTOCOL=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].protocol"      "${TEST_PASS_DIR}/test-matrix.yaml")
TEST_NAME=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].id"            "${TEST_PASS_DIR}/test-matrix.yaml")

DIALER_LEGACY=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].dialer.legacy // \"false\""   "${TEST_PASS_DIR}/test-matrix.yaml")
LISTENER_LEGACY=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].listener.legacy // \"false\"" "${TEST_PASS_DIR}/test-matrix.yaml")
IS_LEGACY_TEST="false"
{ [ "${DIALER_LEGACY}" == "true" ] || [ "${LISTENER_LEGACY}" == "true" ]; } && IS_LEGACY_TEST="true"

print_debug "test name:   ${TEST_NAME}"
print_debug "dialer id:   ${DIALER_ID}"
print_debug "listener id: ${LISTENER_ID}"
print_debug "transport:   ${TRANSPORT_NAME}"
print_debug "secure:      ${SECURE}"
print_debug "muxer:       ${MUXER_NAME}"
print_debug "protocol:    ${PROTOCOL}"
print_debug "legacy:      ${IS_LEGACY_TEST}"
print_debug "debug:       ${DEBUG}"

# Compute TEST_KEY for Redis key namespacing (8-char hex hash)
TEST_KEY=$(compute_test_key "${TEST_NAME}")
TEST_SLUG=$(echo "${TEST_NAME}" | sed 's/[^a-zA-Z0-9-]/_/g')
LOG_FILE="${TEST_PASS_DIR}/logs/${TEST_SLUG}.log"
>> "${LOG_FILE}"

print_debug "test key:  ${TEST_KEY}"
print_debug "slug:      ${TEST_SLUG}"
print_debug "log file:  ${LOG_FILE}"

log_message "[$((${TEST_INDEX} + 1))] ${TEST_NAME} (key: ${TEST_KEY})"

# Construct Docker image names
DIALER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].dialer.imageName"   "${TEST_PASS_DIR}/test-matrix.yaml")
LISTENER_IMAGE=$(yq eval ".${TEST_PASS}[${TEST_INDEX}].listener.imageName" "${TEST_PASS_DIR}/test-matrix.yaml")

print_debug "dialer image:   ${DIALER_IMAGE}"
print_debug "listener image: ${LISTENER_IMAGE}"

# Generate docker-compose file
COMPOSE_FILE="${TEST_PASS_DIR}/docker-compose/${TEST_SLUG}-compose.yaml"
print_debug "compose file: ${COMPOSE_FILE}"

# Ensure cleanup runs regardless of how the script exits
cleanup() {
  if [ -n "${COMPOSE_FILE:-}" ] && [ -f "${COMPOSE_FILE}" ]; then
    log_debug "Cleaning up containers..."
    # WARNING: Do NOT put quotes around this because the command has two parts
    ${DOCKER_COMPOSE_CMD} -f "${COMPOSE_FILE}" down --volumes --remove-orphans >> "${LOG_FILE}" 2>&1 || true
  fi
}
trap cleanup EXIT

# Build environment variable blocks.
# The PROTOCOL env var is appended as an extra parameter to both containers so
# the test app knows which protocol exercise to run (ping | echo | identify).
if [ "${LISTENER_LEGACY}" == "true" ]; then
  LISTENER_ENV=$(generate_legacy_env_vars "false" "proxy-${TEST_KEY}:6379" "${TRANSPORT_NAME}" "${SECURE}" "${MUXER_NAME}")
  # Append PROTOCOL for legacy containers that have been updated to read it
  LISTENER_ENV="${LISTENER_ENV}
      - PROTOCOL=${PROTOCOL}
      - protocol=${PROTOCOL}"
else
  LISTENER_ENV=$(generate_modern_env_vars "false" "misc-redis:6379" "${TEST_KEY}" "${TRANSPORT_NAME}" "${SECURE}" "${MUXER_NAME}" "${DEBUG:-false}" "PROTOCOL=${PROTOCOL}")
fi

if [ "${DIALER_LEGACY}" == "true" ]; then
  DIALER_ENV=$(generate_legacy_env_vars "true" "proxy-${TEST_KEY}:6379" "${TRANSPORT_NAME}" "${SECURE}" "${MUXER_NAME}")
  DIALER_ENV="${DIALER_ENV}
      - PROTOCOL=${PROTOCOL}
      - protocol=${PROTOCOL}"
else
  DIALER_ENV=$(generate_modern_env_vars "true" "misc-redis:6379" "${TEST_KEY}" "${TRANSPORT_NAME}" "${SECURE}" "${MUXER_NAME}" "${DEBUG:-false}" "PROTOCOL=${PROTOCOL}")
fi

# Generate docker-compose file
if [ "${IS_LEGACY_TEST}" == "true" ]; then
  cat > "${COMPOSE_FILE}" <<EOF
name: ${TEST_SLUG}

networks:
  default:
    name: misc-network
    external: true
  misc-network:
    name: misc-network
    external: true

services:
  proxy-${TEST_KEY}:
    image: libp2p-redis-proxy
    container_name: ${TEST_SLUG}_proxy
    networks:
      - misc-network
    environment:
      - TEST_KEY=${TEST_KEY}
      - REDIS_ADDR=misc-redis:6379

  listener:
    image: "${LISTENER_IMAGE}"
    container_name: ${TEST_SLUG}_listener
    init: true
    depends_on:
      - proxy-${TEST_KEY}
    networks:
      - misc-network
    environment:
${LISTENER_ENV}

  dialer:
    image: "${DIALER_IMAGE}"
    container_name: ${TEST_SLUG}_dialer
    depends_on:
      - listener
      - proxy-${TEST_KEY}
    networks:
      - misc-network
    environment:
${DIALER_ENV}
EOF
else
  cat > "${COMPOSE_FILE}" <<EOF
name: ${TEST_SLUG}

networks:
  default:
    name: misc-network
    external: true
  misc-network:
    name: misc-network
    external: true

services:
  listener:
    image: "${LISTENER_IMAGE}"
    container_name: ${TEST_SLUG}_listener
    init: true
    networks:
      - misc-network
    environment:
${LISTENER_ENV}

  dialer:
    image: "${DIALER_IMAGE}"
    container_name: ${TEST_SLUG}_dialer
    depends_on:
      - listener
    networks:
      - misc-network
    environment:
${DIALER_ENV}
EOF
fi

# Run the test
log_debug "Starting containers..."
log_message "Running: ${TEST_NAME}"

TEST_TIMEOUT=180
TEST_START=$(date +%s)

# WARNING: Do NOT put quotes around this because the command has two parts
if timeout "${TEST_TIMEOUT}" ${DOCKER_COMPOSE_CMD} -f "${COMPOSE_FILE}" up --exit-code-from dialer --abort-on-container-exit >> "${LOG_FILE}" 2>&1; then
  EXIT_CODE=0
  log_message "  ✓ Test complete"
else
  TEST_EXIT=$?
  if [ "${TEST_EXIT}" -eq 124 ]; then
    EXIT_CODE=1
    log_error "  ✗ Test timed out after ${TEST_TIMEOUT}s"
    echo "" >> "${LOG_FILE}"
    log_error "Test timed out after ${TEST_TIMEOUT} seconds"
  else
    EXIT_CODE=1
    log_error "  ✗ Test failed"
  fi
fi

TEST_END=$(date +%s)
TEST_DURATION=$(( TEST_END - TEST_START ))

# Extract YAML measurement output from the dialer container logs.
# The misc test apps emit a `measurements:` YAML block to stdout.
DIALER_LOGS=$(${DOCKER_COMPOSE_CMD} -f "${COMPOSE_FILE}" logs dialer 2>/dev/null || echo "")

if [ "${DIALER_LEGACY}" == "true" ]; then
  DIALER_YAML=$(echo "${DIALER_LOGS}" | grep "dialer.*|" | sed 's/^.*| //' | tr -d '\r' | grep -v '^\s*$' | grep -E '^\s*[\[{"]' | tr '\n' ' ') || true
  DIALER_YAML=$(echo "${DIALER_YAML}" | yq eval -P '.' - 2>/dev/null || echo "")
else
  # Extract measurement sections emitted by the test app to stdout
  DIALER_YAML=$(echo "${DIALER_LOGS}" | grep -E "dialer.*\| (latency:|measurements:|  (handshake_plus_one_rtt|ping_rtt|rtt|echo_rtt|identify_rtt|unit):)" | sed 's/^.*| //' || echo "")
fi

# Validate DIALER_YAML — discard if it starts with a list item marker
if [ -n "${DIALER_YAML}" ]; then
  echo "${DIALER_YAML}" | head -1 | grep -q '^-' && DIALER_YAML=""
fi

# Save complete result to individual file
cat > "${TEST_PASS_DIR}/results/${TEST_NAME}.yaml" <<EOF
test: ${TEST_NAME}
dialer: ${DIALER_ID}
listener: ${LISTENER_ID}
transport: ${TRANSPORT_NAME}
secureChannel: ${SECURE}
muxer: ${MUXER_NAME}
protocol: ${PROTOCOL}
status: $([ "${EXIT_CODE}" -eq 0 ] && echo "pass" || echo "fail")
duration: ${TEST_DURATION}

${DIALER_YAML}
EOF

INDENTED_YAML=$(echo "${DIALER_YAML}" | sed 's/^/    /')

# Append to combined results file with file locking
(
  flock -x 200
  cat >> "${RESULTS_FILE}" <<EOF
  - name: ${TEST_NAME}
    dialer: ${DIALER_ID}
    listener: ${LISTENER_ID}
    transport: ${TRANSPORT_NAME}
    secureChannel: ${SECURE}
    muxer: ${MUXER_NAME}
    protocol: ${PROTOCOL}
    status: $([ "${EXIT_CODE}" -eq 0 ] && echo "pass" || echo "fail")
    duration: ${TEST_DURATION}s
${INDENTED_YAML}
EOF
) 200>/tmp/results.lock

exit "${EXIT_CODE}"
