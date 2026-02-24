#!/usr/bin/env bash

# run in strict failure mode
set -euo pipefail

#                                 ╔╦╦╗  ╔═╗
# ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ ║╠╣╚╦═╬╝╠═╗ ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
# ═══════════════════════════════ ║║║║║║║╔╣║║ ═════════════════════════════════
# ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ ╚╩╩═╣╔╩═╣╔╝ ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
#                                     ╚╝  ╚╝

# =============================================================================
# STEP 1: BOOTSTRAP: Load inputs.yaml BEFORE setting SCRIPT_LIB_DIR
# =============================================================================

# Capture original arguments for inputs.yaml generation
ORIGINAL_ARGS=("$@")

# Change to script directory
cd "$(dirname "$0")"

# Loads and exports the environment variables from the inputs yaml file
load_inputs_yaml_inline() {
  local inputs_file="${1:-inputs.yaml}"
  if [ ! -f "${inputs_file}" ]; then
    return 1
  fi
  echo "→ Loading configuration from ${inputs_file}"
  while IFS='=' read -r key value; do
    if [ -n "${key}" ] && [ -n "${value}" ]; then
      export "${key}"="${value}"
    fi
  done < <(yq eval '.environmentVariables | to_entries | .[] | .key + "=" + .value' "${inputs_file}" 2>/dev/null)
  return 0
}

get_yaml_args_inline() {
  local inputs_file="${1:-inputs.yaml}"
  if [ ! -f "${inputs_file}" ]; then
    return 1
  fi
  yq eval '.commandLineArgs[]' "${inputs_file}" 2>/dev/null || true
}

if [ -f "inputs.yaml" ]; then
  load_inputs_yaml_inline "inputs.yaml"
  readarray -t YAML_ARGS < <(get_yaml_args_inline "inputs.yaml")
else
  YAML_ARGS=()
fi

CMD_LINE_ARGS=(${YAML_ARGS[@]+"${YAML_ARGS[@]}"} "$@")
set -- "${CMD_LINE_ARGS[@]}"

export TEST_ROOT="$(dirname "${BASH_SOURCE[0]}")"
export SCRIPT_DIR="${SCRIPT_DIR:-$(cd "${TEST_ROOT}/lib" && pwd)}"
export SCRIPT_LIB_DIR="${SCRIPT_LIB_DIR:-${SCRIPT_DIR}/../../lib}"

# =============================================================================
# STEP 2: INITIALIZATION
# =============================================================================

source "${SCRIPT_LIB_DIR}/lib-common-init.sh"
init_common_variables
init_cache_dirs

trap handle_shutdown INT

# Misc-specific variables
# Protocol selection (pipe-separated, empty = all)
export PROTOCOL_SELECT="${PROTOCOL_SELECT:-}"
export PROTOCOL_IGNORE="${PROTOCOL_IGNORE:-}"

# Source common libraries
source "${SCRIPT_LIB_DIR}/lib-github-snapshots.sh"
source "${SCRIPT_LIB_DIR}/lib-global-services.sh"
source "${SCRIPT_LIB_DIR}/lib-image-building.sh"
source "${SCRIPT_LIB_DIR}/lib-image-naming.sh"
source "${SCRIPT_LIB_DIR}/lib-inputs-yaml.sh"
source "${SCRIPT_LIB_DIR}/lib-output-formatting.sh"
source "${SCRIPT_LIB_DIR}/lib-snapshot-creation.sh"
source "${SCRIPT_LIB_DIR}/lib-snapshot-images.sh"
source "${SCRIPT_LIB_DIR}/lib-test-caching.sh"
source "${SCRIPT_LIB_DIR}/lib-test-execution.sh"
source "${SCRIPT_LIB_DIR}/lib-test-filtering.sh"
source "${SCRIPT_LIB_DIR}/lib-test-images.sh"

print_banner

show_help() {
  cat <<EOF
libp2p Miscellaneous Protocol Interoperability Test Runner

Validates Ping, Echo, and Identify protocol correctness across
libp2p implementations. Acts as a catch-all suite for protocols
that do not require their own dedicated top-level test suite.

Usage: ${0} [options]

Filter Options (Two-Stage Filtering):
  Filters are applied in two stages:
    Stage 1: SELECT filters narrow from complete list (empty = select all)
    Stage 2: IGNORE filters remove from selected set (empty = ignore none)
    Stage 3: TEST filters match complete test names (applied during generation)

  Implementation Filtering:
    --impl-select VALUE         Select implementations (pipe-separated patterns)
    --impl-ignore VALUE         Ignore implementations (pipe-separated patterns)

  Component Filtering:
    --transport-select VALUE    Select transports (pipe-separated patterns)
    --transport-ignore VALUE    Ignore transports (pipe-separated patterns)
    --secure-select VALUE       Select secure channels (pipe-separated patterns)
    --secure-ignore VALUE       Ignore secure channels (pipe-separated patterns)
    --muxer-select VALUE        Select muxers (pipe-separated patterns)
    --muxer-ignore VALUE        Ignore muxers (pipe-separated patterns)

  Protocol Filtering:
    --protocol-select VALUE     Select protocols to test (pipe-separated)
                                  e.g., --protocol-select 'ping|echo'
                                  Valid values: ping, echo, identify
    --protocol-ignore VALUE     Ignore protocols (pipe-separated patterns)
                                  e.g., --protocol-ignore '!identify'
                                  Alias inversion also works: --protocol-ignore '!~echo'

  Test Name Filtering:
    --test-select VALUE         Select tests by name pattern (pipe-separated patterns)
    --test-ignore VALUE         Ignore tests by name pattern (pipe-separated patterns)

Other Options:
  --workers VALUE             Number of parallel workers (default: from get_cpu_count)
  --cache-dir VALUE           Cache directory (default: /srv/cache)
  --snapshot                  Create test pass snapshot after completion
  --debug                     Enable debug mode (sets DEBUG=true in test containers)
  --force-matrix-rebuild      Force regeneration of test matrix (bypass cache)
  --force-image-rebuild       Force rebuilding of all docker images (bypass cache)
  --yes, -y                   Skip confirmation prompt and run tests immediately
  --check-deps                Only check dependencies and exit
  --list-images               List all image types used by this test suite and exit
  --list-tests                List all selected tests and exit
  --show-ignored              Shows the list of ignored tests
  --help, -h                  Show this help message

Filter Pattern Syntax:
  - Literal match:          "ping"
  - Pipe-separated OR:      "ping|echo"
  - Alias expansion:        "~js" (expands to all js versions)
  - Negation:               "!~js" (everything NOT matching js)
  - Inversion + alias:      "!~echo" (all protocols except echo)
  - Substring match:        "v3" (matches any ID containing this)

Protocols Tested:
  - ping      /ping/1.0.0 — basic round-trip latency measurement
  - echo      /echo/1.0.0 — bidirectional stream payload integrity
  - identify  /identify/1.0.0 — peer metadata exchange (protocol list, pubkey)

Examples:
  # Run only ping tests
  ${0} --protocol-select "ping"

  # Run ping and echo, skip identify
  ${0} --protocol-ignore "identify"

  # Run only JS ↔ Go combinations
  ${0} --impl-select "~js|~go"

  # Run only TCP echo between rust and js
  ${0} --impl-select "~rust|~js" --transport-select "tcp" --protocol-select "echo"

  # Run all except echo tests
  ${0} --protocol-ignore "echo"

Dependencies:
  Required: bash 4.0+, docker 20.10+ (or podman), docker-compose, yq 4.0+
            wget, zip, unzip, bc, sha256sum, cut, timeout, flock
  Optional: gnuplot (box plots), git (submodule-based builds)
  Run with --check-deps to verify installation.

EOF
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "${1}" in
    # Implementation filtering
    --impl-select) IMPL_SELECT="${2}"; shift 2 ;;
    --impl-ignore) IMPL_IGNORE="${2}"; shift 2 ;;

    # Component filtering
    --transport-select) TRANSPORT_SELECT="${2}"; shift 2 ;;
    --transport-ignore) TRANSPORT_IGNORE="${2}"; shift 2 ;;
    --secure-select) SECURE_SELECT="${2}"; shift 2 ;;
    --secure-ignore) SECURE_IGNORE="${2}"; shift 2 ;;
    --muxer-select) MUXER_SELECT="${2}"; shift 2 ;;
    --muxer-ignore) MUXER_IGNORE="${2}"; shift 2 ;;

    # Protocol filtering
    --protocol-select) PROTOCOL_SELECT="${2}"; shift 2 ;;
    --protocol-ignore) PROTOCOL_IGNORE="${2}"; shift 2 ;;

    # Test name filtering
    --test-select) TEST_SELECT="${2}"; shift 2 ;;
    --test-ignore) TEST_IGNORE="${2}"; shift 2 ;;

    # Other options
    --workers) WORKER_COUNT="${2}"; shift 2 ;;
    --cache-dir) CACHE_DIR="${2}"; shift 2 ;;
    --snapshot) CREATE_SNAPSHOT=true; shift ;;
    --debug) DEBUG=true; shift ;;
    --force-matrix-rebuild) FORCE_MATRIX_REBUILD=true; shift ;;
    --force-image-rebuild) FORCE_IMAGE_REBUILD=true; shift ;;
    --yes|-y) AUTO_YES=true; shift ;;
    --check-deps) CHECK_DEPS=true; shift ;;
    --list-images) LIST_IMAGES=true; shift ;;
    --list-tests) LIST_TESTS=true; shift ;;
    --show-ignored) SHOW_IGNORED=true; shift ;;
    --help|-h) show_help; exit 0 ;;
    *)
      echo "Unknown option: ${1}"
      echo ""
      show_help
      exit 1
      ;;
  esac
done

# Re-derive paths from (possibly updated) CACHE_DIR
export TEST_RUN_DIR="${CACHE_DIR}/test-run"
init_cache_dirs

# Generate test run key and test pass name
export TEST_TYPE="misc"
export TEST_RUN_KEY=$(compute_test_run_key \
  "${IMAGES_YAML}" \
  "${IMPL_SELECT}" \
  "${IMPL_IGNORE}" \
  "${TRANSPORT_SELECT}" \
  "${TRANSPORT_IGNORE}" \
  "${SECURE_SELECT}" \
  "${SECURE_IGNORE}" \
  "${MUXER_SELECT}" \
  "${MUXER_IGNORE}" \
  "${TEST_SELECT}" \
  "${TEST_IGNORE}" \
  "${DEBUG}" \
  "${PROTOCOL_SELECT}" \
  "${PROTOCOL_IGNORE}" \
)
export TEST_PASS_NAME="${TEST_TYPE}-${TEST_RUN_KEY}-$(date +%H%M%S-%d-%m-%Y)"
export TEST_PASS_DIR="${TEST_RUN_DIR}/${TEST_PASS_NAME}"

# =============================================================================
# STEP 3.A: LIST IMAGES
# =============================================================================

if [ "${LIST_IMAGES}" == "true" ]; then
  if [ ! -f "${IMAGES_YAML}" ]; then
    print_error "${IMAGES_YAML} not found"
    exit 1
  fi

  print_header "Available Docker Images"
  indent

  readarray -t all_image_ids < <(get_entity_ids "implementations")
  print_list "Implementations" all_image_ids

  println
  unindent
  exit 0
fi

# =============================================================================
# STEP 3.B: LIST TESTS
# =============================================================================

if [ "${LIST_TESTS}" == "true" ]; then
  TEMP_DIR=$(mktemp -d)
  trap "rm -rf \"${TEMP_DIR}\"" EXIT

  export TEST_PASS_DIR="${TEMP_DIR}"
  export TEST_PASS_NAME="temp-list"
  export CACHE_DIR
  export DEBUG
  export TEST_IGNORE TRANSPORT_IGNORE SECURE_IGNORE MUXER_IGNORE PROTOCOL_IGNORE
  export FORCE_MATRIX_REBUILD

  print_header "Generating test matrix..."
  indent

  bash "${SCRIPT_DIR}/generate-tests.sh" || true

  if [ ! -f "${TEMP_DIR}/test-matrix.yaml" ]; then
    print_error "Failed to generate test matrix"
    bash "${SCRIPT_DIR}/generate-tests.sh" 2>&1 | tail -10
    unindent
    exit 1
  fi
  unindent
  println

  print_header "Test Selection..."
  indent

  readarray -t selected_main_tests < <(get_entity_ids "tests" "${TEMP_DIR}/test-matrix.yaml")
  print_list "Selected main tests" selected_main_tests

  println

  readarray -t ignored_main_tests < <(get_entity_ids "ignoredTests" "${TEMP_DIR}/test-matrix.yaml")
  if [ "${SHOW_IGNORED}" == "true" ]; then
    print_list "Ignored main tests" ignored_main_tests
    println
  fi

  print_message "Total selected: ${#selected_main_tests[@]} tests"
  print_message "Total ignored: ${#ignored_main_tests[@]} tests"
  println

  unindent
  exit 0
fi

# =============================================================================
# STEP 3.C: CHECK DEPS
# =============================================================================

if [ "${CHECK_DEPS}" == "true" ]; then
  print_header "Checking dependencies..."
  indent
  bash "${SCRIPT_LIB_DIR}/check-dependencies.sh" docker yq || {
    println
    print_error "Error: Missing required dependencies."
    print_message "Run '${0}' --check-deps to see details."
    unindent
    exit 1
  }
  unindent
  exit 0
fi

# =============================================================================
# STEP 4: INITIALIZE
# =============================================================================

print_header "Misc Protocol Test"
indent

print_message "Test Type: ${TEST_TYPE}"
print_message "Test Run Key: ${TEST_RUN_KEY}"
print_message "Test Pass: ${TEST_PASS_NAME}"
print_message "Test Pass Dir: ${TEST_PASS_DIR}"
print_message "Cache Dir: ${CACHE_DIR}"
print_message "Workers: ${WORKER_COUNT}"
[ -n "${IMPL_SELECT}" ]       && print_message "Impl Select: ${IMPL_SELECT}"
[ -n "${IMPL_IGNORE}" ]       && print_message "Impl Ignore: ${IMPL_IGNORE}"
[ -n "${TRANSPORT_SELECT}" ]  && print_message "Transport Select: ${TRANSPORT_SELECT}"
[ -n "${TRANSPORT_IGNORE}" ]  && print_message "Transport Ignore: ${TRANSPORT_IGNORE}"
[ -n "${SECURE_SELECT}" ]     && print_message "Secure Select: ${SECURE_SELECT}"
[ -n "${SECURE_IGNORE}" ]     && print_message "Secure Ignore: ${SECURE_IGNORE}"
[ -n "${MUXER_SELECT}" ]      && print_message "Muxer Select: ${MUXER_SELECT}"
[ -n "${MUXER_IGNORE}" ]      && print_message "Muxer Ignore: ${MUXER_IGNORE}"
[ -n "${PROTOCOL_SELECT}" ]   && print_message "Protocol Select: ${PROTOCOL_SELECT}"
[ -n "${PROTOCOL_IGNORE}" ]   && print_message "Protocol Ignore: ${PROTOCOL_IGNORE}"
[ -n "${TEST_SELECT}" ]        && print_message "Test Select: ${TEST_SELECT}"
[ -n "${TEST_IGNORE}" ]        && print_message "Test Ignore: ${TEST_IGNORE}"
print_message "Create Snapshot: ${CREATE_SNAPSHOT}"
print_message "Debug: ${DEBUG}"
print_message "Force Matrix Rebuild: ${FORCE_MATRIX_REBUILD}"
print_message "Force Image Rebuild: ${FORCE_IMAGE_REBUILD}"
println

mkdir -p "${TEST_PASS_DIR}"/{logs,results,docker-compose}

generate_inputs_yaml "${TEST_PASS_DIR}/inputs.yaml" "${TEST_TYPE}" "${ORIGINAL_ARGS[@]}"

println
unindent

# Check dependencies
print_header "Checking dependencies..."
indent
bash "${SCRIPT_LIB_DIR}/check-dependencies.sh" docker yq || {
  println
  print_error "Error: Missing required dependencies."
  print_message "Run '${0}' --check-deps to see details."
  unindent
  exit 1
}

if [ -f /tmp/docker-compose-cmd.txt ]; then
  export DOCKER_COMPOSE_CMD=$(cat /tmp/docker-compose-cmd.txt)
else
  print_error "Error: Could not determine docker compose command"
  unindent
  exit 1
fi
unindent

# Start timing
TEST_START_TIME=$(date +%s)

# =============================================================================
# STEP 5: GENERATE TEST MATRIX
# =============================================================================

print_header "Generating test matrix..."
indent

bash "${SCRIPT_DIR}/generate-tests.sh" || {
  print_error "Test matrix generation failed"
  unindent
  exit 1
}
unindent
println

# =============================================================================
# STEP 6: PRINT TEST SELECTION
# =============================================================================

print_header "Test Selection..."
indent

readarray -t selected_main_tests < <(get_entity_ids "tests" "${TEST_PASS_DIR}/test-matrix.yaml")
print_list "Selected main tests" selected_main_tests

println

readarray -t ignored_main_tests < <(get_entity_ids "ignoredTests" "${TEST_PASS_DIR}/test-matrix.yaml")
if [ "${SHOW_IGNORED}" == "true" ]; then
  print_list "Ignored main tests" ignored_main_tests
  println
fi

TEST_COUNT=${#selected_main_tests[@]}
TOTAL_TESTS=${TEST_COUNT}

print_message "Total selected: ${TOTAL_TESTS} tests"
print_message "Total ignored: ${#ignored_main_tests[@]} tests"
println
unindent

# Get unique implementations from main tests
REQUIRED_IMAGES=$(mktemp)
yq eval '.tests[].dialer.id' "${TEST_PASS_DIR}/test-matrix.yaml" 2>/dev/null | sort -u >> "${REQUIRED_IMAGES}" || true
yq eval '.tests[].listener.id' "${TEST_PASS_DIR}/test-matrix.yaml" 2>/dev/null | sort -u >> "${REQUIRED_IMAGES}" || true
sort -u "${REQUIRED_IMAGES}" -o "${REQUIRED_IMAGES}"
IMAGE_COUNT=$(wc -l < "${REQUIRED_IMAGES}")

# Exit early if no tests were selected
if [ "${TOTAL_TESTS}" -eq 0 ]; then
  println
  print_error "No tests selected with current filters"
  indent
  print_message "All tests were filtered out by your selection criteria."
  print_message "Adjust your --protocol-select/--impl-select settings to select tests."
  unindent
  println
  exit 0
fi

indent
if [ "${AUTO_YES}" != true ]; then
  read -p "  Build ${IMAGE_COUNT} Docker images and execute ${TOTAL_TESTS} tests? (Y/n): " response
  response=${response:-Y}
  if [[ ! "${response}" =~ ^[Yy]$ ]]; then
    println
    print_error "Test execution cancelled."
    unindent
    exit 0
  fi
else
  print_success "Automatically running the tests..."
fi
unindent

# =============================================================================
# STEP 7: BUILD MISSING DOCKER IMAGES
# =============================================================================

println
print_header "Building Docker images..."
indent

print_message "Building ${IMAGE_COUNT} required implementations"
println

IMAGE_FILTER=$(cat "${REQUIRED_IMAGES}" | paste -sd'|' -)
build_images_from_section "implementations" "${IMAGE_FILTER}" "${FORCE_IMAGE_REBUILD}"

println
print_message "Building Redis proxy image..."
build_redis_proxy_image "${FORCE_IMAGE_REBUILD}"

print_success "All images built successfully"

rm -f "${REQUIRED_IMAGES}"
unindent
println

# =============================================================================
# STEP 8: RUN TESTS
# =============================================================================

print_header "Starting global services..."
indent
start_redis_service "misc-network" "misc-redis" || {
  print_error "Starting global services failed"
  unindent
  return 1
}
unindent
println

print_header "Running tests... (${WORKER_COUNT} workers)"
indent

TEST_RESULTS_FILE="${TEST_PASS_DIR}/results.yaml.tmp"
> "${TEST_RESULTS_FILE}"

run_test() {
  local index="${1}"
  local name=$(yq eval ".tests[${index}].id" "${TEST_PASS_DIR}/test-matrix.yaml")
  local slug=$(echo "${name}" | sed 's/[^a-zA-Z0-9-]/_/g')
  local log_file="${TEST_PASS_DIR}/logs/${slug}.log"

  source "${SCRIPT_LIB_DIR}/lib-output-formatting.sh"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Starting test: ${name}" > "${log_file}"

  if bash "${SCRIPT_DIR}/run-single-test.sh" "${index}" "tests" "${TEST_PASS_DIR}/results.yaml.tmp"; then
    result="[SUCCESS]"
    exit_code=0
  else
    result="[FAILED]"
    exit_code=1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Test script failed with exit code" >> "${log_file}"
  fi

  if ! grep -q "name: ${name}" "${TEST_PASS_DIR}/results.yaml.tmp" 2>/dev/null; then
    (
      flock -x 200
      cat >> "${TEST_PASS_DIR}/results.yaml.tmp" <<EOF
  - name: ${name}
    status: fail
    duration: 0s
    error: "test script failed to execute"
EOF
    ) 200>/tmp/results.lock
  fi

  (
    flock -x 200
    print_message "[$((index + 1))/${TEST_COUNT}] ${name}...${result}"
  ) 200>/tmp/misc-test-output.lock

  return ${exit_code}
}

export TEST_COUNT
export -f run_test

seq 0 $((TEST_COUNT - 1)) | xargs -P "${WORKER_COUNT}" -I {} bash -c 'run_test {}' || true

unindent
println

print_header "Stopping global services..."
indent
stop_redis_service "misc-network" "misc-redis" || {
  print_error "Stopping global services failed"
  unindent
  return 1
}
unindent
println

TEST_END_TIME=$(date +%s)
TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))

# =============================================================================
# STEP 9: COLLECT RESULTS
# =============================================================================

print_header "Collecting results..."
indent

PASSED=0
FAILED=0
if [ -f "${TEST_PASS_DIR}/results.yaml.tmp" ]; then
  PASSED=$(grep -c "status: pass" "${TEST_PASS_DIR}/results.yaml.tmp" || true)
  FAILED=$(grep -c "status: fail" "${TEST_PASS_DIR}/results.yaml.tmp" || true)
fi

PASSED=${PASSED:-0}
FAILED=${FAILED:-0}

cat > "${TEST_PASS_DIR}/results.yaml" <<EOF
metadata:
  testPass: ${TEST_PASS_NAME}
  startedAt: $(format_timestamp "${TEST_START_TIME}")
  completedAt: $(date -u +%Y-%m-%dT%H:%M:%SZ)
  duration: ${TEST_DURATION}s
  platform: $(uname -m)
  os: $(uname -s)
  workerCount: ${WORKER_COUNT}

summary:
  total: ${TEST_COUNT}
  passed: ${PASSED}
  failed: ${FAILED}

tests:
EOF

if [ -f "${TEST_PASS_DIR}/results.yaml.tmp" ]; then
  cat "${TEST_PASS_DIR}/results.yaml.tmp" >> "${TEST_PASS_DIR}/results.yaml"
  rm "${TEST_PASS_DIR}/results.yaml.tmp"
fi

print_message "Results:"
indent
print_message "Total: ${TEST_COUNT}"
print_success "Passed: ${PASSED}"
print_error "Failed: ${FAILED}"

if [ "${FAILED}" -gt 0 ]; then
  readarray -t FAILED_TESTS < <(yq eval '.tests[]? | select(.status == "fail") | .name' "${TEST_PASS_DIR}/results.yaml" 2>/dev/null || true)
  if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    for test_name in "${FAILED_TESTS[@]}"; do
      echo "    - ${test_name}"
    done
  fi
fi

unindent
println

HOURS=$((TEST_DURATION / 3600))
MINUTES=$(((TEST_DURATION % 3600) / 60))
SECONDS=$((TEST_DURATION % 60))
print_message "$(printf "Total time: %02d:%02d:%02d\n" "${HOURS}" "${MINUTES}" "${SECONDS}")"
println

if [ "${FAILED}" -eq 0 ]; then
  print_success "All tests passed!"
  EXIT_FINAL=0
else
  print_error "${FAILED} test(s) failed"
  EXIT_FINAL=1
fi

unindent
println

# =============================================================================
# STEP 10: GENERATE RESULTS DASHBOARD
# =============================================================================

print_header "Generating results dashboard..."
indent

print_success "Generated ${TEST_PASS_DIR}/results.yaml"
bash "${SCRIPT_DIR}/generate-dashboard.sh" || {
  print_error "Dashboard generation failed"
}
println
print_success "Dashboard generation complete"
unindent
println

# =============================================================================
# STEP 11: CREATE SNAPSHOT
# =============================================================================

if [ "${CREATE_SNAPSHOT}" == "true" ]; then
  print_header "Creating test pass snapshot..."
  indent
  create_snapshot || {
    print_error "Snapshot creation failed"
  }
  unindent
fi

exit "${EXIT_FINAL}"
