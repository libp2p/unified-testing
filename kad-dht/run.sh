#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

export TEST_ROOT="$(pwd)"
export SCRIPT_DIR="${TEST_ROOT}/lib"
export SCRIPT_LIB_DIR="${SCRIPT_DIR}/../../lib"

source "${SCRIPT_LIB_DIR}/lib-common-init.sh"
init_common_variables
init_cache_dirs

source "${SCRIPT_LIB_DIR}/lib-output-formatting.sh"
source "${SCRIPT_LIB_DIR}/lib-image-building.sh"
source "${SCRIPT_DIR}/build-images.sh"

export TEST_TYPE="kad-dht"

show_help() {
  cat <<EOF
libp2p Kademlia DHT Interoperability Test Runner

Usage: ${0} [options]

Filter Options:
  --impl-select VALUE       Select implementations to build (pipe-separated, e.g. "py|dotnet")
  --impl-ignore VALUE       Ignore implementations when building (pipe-separated)
  --test-select VALUE       Run only tests matching name patterns (pipe-separated)
  --test-ignore VALUE       Skip tests matching name patterns (pipe-separated)

Other Options:
  --cache-dir VALUE         Cache directory for git clones (default: ${TEST_ROOT}/.cache)
  --force-image-rebuild     Rebuild Docker images even if they already exist
  --force-matrix-rebuild    Force regeneration of test matrix
  --check-deps              Verify dependencies and exit
  --list-images             List implementations and image names, then exit
  --list-tests              Generate and list all test IDs, then exit
  --help, -h                Show this help message

Examples:
  ${0}                                    # Run full test matrix
  ${0} --test-select "py_x_py_x_py"       # Run a single test
  ${0} --force-image-rebuild              # Rebuild all Docker images
  ${0} --impl-select "py" --list-tests    # List tests (matrix still uses all impls)

Dependencies:
  Required: bash 4.0+, docker 20.10+, docker compose, yq 4.0+, git
  Run with --check-deps to verify installation.

Notes:
  Docker images are cached locally. Vendored sources (dotnet-libp2p) are cloned once
  into --cache-dir and copied into the build context only when the commit changes.
  Re-running without --force-image-rebuild skips rebuild when images already exist.

EOF
}

impl_matches_filter() {
  local impl_id="$1"
  local select="${2:-}"
  local ignore="${3:-}"

  if [ -n "${select}" ]; then
    local match_found=false
    IFS='|' read -ra patterns <<< "${select}"
    for pattern in "${patterns[@]}"; do
      case "${impl_id}" in
        ${pattern}) match_found=true; break ;;
      esac
    done
    if [ "${match_found}" == "false" ]; then
      return 1
    fi
  fi

  if [ -n "${ignore}" ]; then
    IFS='|' read -ra patterns <<< "${ignore}"
    for pattern in "${patterns[@]}"; do
      case "${impl_id}" in
        ${pattern}) return 1 ;;
      esac
    done
  fi

  return 0
}

test_matches_filter() {
  local test_id="$1"

  if [ -n "${TEST_SELECT}" ]; then
    local match_found=false
    IFS='|' read -ra patterns <<< "${TEST_SELECT}"
    for pattern in "${patterns[@]}"; do
      case "${test_id}" in
        *${pattern}*) match_found=true; break ;;
      esac
    done
    if [ "${match_found}" == "false" ]; then
      return 1
    fi
  fi

  if [ -n "${TEST_IGNORE}" ]; then
    IFS='|' read -ra patterns <<< "${TEST_IGNORE}"
    for pattern in "${patterns[@]}"; do
      case "${test_id}" in
        *${pattern}*) return 1 ;;
      esac
    done
  fi

  return 0
}

required_impl_filter_from_matrix() {
  local matrix_file="$1"
  local -n _out="$2"
  local ids=()
  local count test_id bootstrap provider querier

  count=$(yq eval '.tests | length' "${matrix_file}")
  for ((i=0; i<count; i++)); do
    test_id=$(yq eval ".tests[${i}].id" "${matrix_file}")
    if ! test_matches_filter "${test_id}"; then
      continue
    fi
    bootstrap=$(yq eval ".tests[${i}].bootstrap.id" "${matrix_file}")
    provider=$(yq eval ".tests[${i}].provider.id" "${matrix_file}")
    querier=$(yq eval ".tests[${i}].querier.id" "${matrix_file}")
    ids+=("${bootstrap}" "${provider}" "${querier}")
  done

  if [ ${#ids[@]} -eq 0 ]; then
    _out=""
    return 0
  fi

  _out=$(printf '%s\n' "${ids[@]}" | sort -u | paste -sd'|' -)
}

compute_build_filter() {
  local required="${1:-}"
  local -n _out="$2"
  local parts=()

  readarray -t all_impls < <(yq eval '.implementations[].id' "${IMAGES_YAML}")
  for impl_id in "${all_impls[@]}"; do
    if ! impl_matches_filter "${impl_id}" "${IMPL_SELECT}" "${IMPL_IGNORE}"; then
      continue
    fi
    if [ -n "${required}" ]; then
      local needed=false
      IFS='|' read -ra req <<< "${required}"
      for r in "${req[@]}"; do
        if [ "${impl_id}" = "${r}" ]; then
          needed=true
          break
        fi
      done
      if [ "${needed}" == "false" ]; then
        continue
      fi
    fi
    parts+=("${impl_id}")
  done

  if [ ${#parts[@]} -eq 0 ]; then
    _out=""
  else
    _out=$(printf '%s|' "${parts[@]}" | sed 's/|$//')
  fi
}

while [ $# -gt 0 ]; do
  case "${1}" in
    --impl-select|--image-select) IMPL_SELECT="${2}"; shift 2 ;;
    --impl-ignore|--image-ignore) IMPL_IGNORE="${2}"; shift 2 ;;
    --test-select) TEST_SELECT="${2}"; shift 2 ;;
    --test-ignore) TEST_IGNORE="${2}"; shift 2 ;;
    --cache-dir) CACHE_DIR="${2}"; init_cache_dirs; shift 2 ;;
    --force-image-rebuild) FORCE_IMAGE_REBUILD=true; shift ;;
    --force-matrix-rebuild) FORCE_MATRIX_REBUILD=true; shift ;;
    --check-deps) CHECK_DEPS=true; shift ;;
    --list-images) LIST_IMAGES=true; shift ;;
    --list-tests) LIST_TESTS=true; shift ;;
    --help|-h) show_help; exit 0 ;;
    *)
      echo "Unknown option: ${1}" >&2
      echo "" >&2
      show_help
      exit 1
      ;;
  esac
done

if [ "${CHECK_DEPS}" == "true" ]; then
  print_header "Checking dependencies..."
  indent
  bash "${SCRIPT_LIB_DIR}/check-dependencies.sh" docker yq git || {
    unindent
    exit 1
  }
  unindent
  exit 0
fi

if [ "${LIST_IMAGES}" == "true" ]; then
  print_header "Kad-DHT implementations"
  indent
  yq eval '.implementations[] | "  " + .id + " -> " + .imageName' "${IMAGES_YAML}"
  unindent
  exit 0
fi

if [ "${LIST_TESTS}" == "true" ]; then
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "${TEMP_DIR}"' EXIT
  export TEST_PASS_DIR="${TEMP_DIR}"
  bash "${SCRIPT_DIR}/generate-tests.sh"
  print_header "Test matrix"
  indent
  yq eval '.tests[].id' "${TEST_PASS_DIR}/test-matrix.yaml" | sed 's/^/  /'
  unindent
  exit 0
fi

export TEST_PASS_DIR="${PWD}/results/$(date +%H%M%S-%d-%m-%Y)"
mkdir -p "${TEST_PASS_DIR}"/{logs,results,docker-compose}

print_header "Generating test matrix..."
indent
bash "${SCRIPT_DIR}/generate-tests.sh"
unindent

# Build only implementations required by selected tests (after impl filter)
REQUIRED_IMPLS=""
BUILD_FILTER=""
required_impl_filter_from_matrix "${TEST_PASS_DIR}/test-matrix.yaml" REQUIRED_IMPLS
compute_build_filter "${REQUIRED_IMPLS}" BUILD_FILTER

build_kad_dht_images "${FORCE_IMAGE_REBUILD}" "${BUILD_FILTER}"

print_header "Starting global Redis..."
indent
docker rm -f transport-redis 2>/dev/null || true
docker network create transport-network 2>/dev/null || true
docker run -d --name transport-redis --network transport-network --rm redis:7-alpine >/dev/null
unindent

trap 'docker stop transport-redis 2>/dev/null || true' EXIT

TEST_COUNT=$(yq eval '.tests | length' "${TEST_PASS_DIR}/test-matrix.yaml")
RESULTS_FILE="${TEST_PASS_DIR}/results.yaml.tmp"
> "${RESULTS_FILE}"

RAN_COUNT=0
SKIPPED_COUNT=0

print_header "Running tests..."
indent

for ((i=0; i<TEST_COUNT; i++)); do
  test_id=$(yq eval ".tests[${i}].id" "${TEST_PASS_DIR}/test-matrix.yaml")

  if ! test_matches_filter "${test_id}"; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  echo "Running test: ${test_id}"
  RAN_COUNT=$((RAN_COUNT + 1))

  if bash "${SCRIPT_DIR}/run-single-test.sh" "${i}" "tests" "${RESULTS_FILE}"; then
    echo "  [SUCCESS]"
  else
    echo "  [FAILED]"
  fi
done

unindent

echo "Tests complete. Collecting results..."

PASSED=$(grep -A1 "^    status: pass$" "${RESULTS_FILE}" | grep -c "^    duration:" || true)
FAILED=$(grep -A1 "^    status: fail$" "${RESULTS_FILE}" | grep -c "^    duration:" || true)

cat > "${TEST_PASS_DIR}/results.yaml" <<EOF
summary:
  total: ${RAN_COUNT}
  skipped: ${SKIPPED_COUNT}
  passed: ${PASSED}
  failed: ${FAILED}

tests:
EOF

cat "${RESULTS_FILE}" >> "${TEST_PASS_DIR}/results.yaml"
rm "${RESULTS_FILE}"

echo "Ran: ${RAN_COUNT}, Skipped: ${SKIPPED_COUNT}, Passed: ${PASSED}, Failed: ${FAILED}"
echo "Test results saved to: ${TEST_PASS_DIR}"

if [ "${FAILED}" -eq 0 ]; then
  exit 0
else
  exit 1
fi
