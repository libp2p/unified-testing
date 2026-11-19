#!/usr/bin/env bash
# Unit tests for the build ordering in lib-image-building.sh
# Tests that images are built after the images they depend on (the `depends` list and the
# base image of a browser image), that dependencies are built even when they are not
# selected, and that bad dependencies fail before anything is built.
#
# Needs yq. Docker is not needed: the image existence check and the build script are stubbed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# Output helpers, the real ones need a terminal
print_error() { echo "ERROR: $1" >&2; }
print_success() { echo "OK: $1" >&2; }
print_message() { :; }

source "$SCRIPT_DIR/lib-image-naming.sh"
source "$SCRIPT_DIR/lib-image-building.sh"

# Stubs: nothing is built, the names of the images that would be built are logged in order
docker_image_exists() {
  case " ${EXISTING_IMAGES:-} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

mkdir -p "${WORK_DIR}/lib"
cat > "${WORK_DIR}/lib/build-single-image.sh" <<'STUB'
#!/usr/bin/env bash
yq eval '.imageName' "$1" >> "${BUILD_LOG}"
STUB

export TEST_TYPE="transport"
export SCRIPT_LIB_DIR="${WORK_DIR}/lib"
export CACHE_DIR="${WORK_DIR}/cache"
export IMAGES_YAML="${WORK_DIR}/images.yaml"
export BUILD_LOG="${WORK_DIR}/build.log"
mkdir -p "${CACHE_DIR}/build-yamls"

# Test framework globals
TEST_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0
FAILED_TESTS=()

fail() {
  echo "  ✗ FAIL: $1" >&2
  return 1
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  if [ "$actual" != "$expected" ]; then
    fail "expected '$expected', got '$actual'"
  fi
}

# Run build_images_from_section for the current images.yaml and print the images it built,
# in order, on one line.
# Usage: built_images <section> <filter> [force]
built_images() {
  : > "${BUILD_LOG}"
  build_images_from_section "$1" "$2" "${3:-false}" 2>"${WORK_DIR}/stderr.log"
  tr '\n' ' ' < "${BUILD_LOG}" | sed 's/ $//'
}

# A browser image listed before the image it is built on, like chromium-js-v2.x in transport/images.yaml
write_browser_yaml() {
  cat > "${IMAGES_YAML}" <<'YAML'
implementations:
  - id: chromium-js-v2.x
    source:
      type: browser
      baseImage: js-v2.x
      browser: chromium
      dockerfile: images/js/v2.x/BrowserDockerfile
  - id: js-v2.x
    source:
      type: local
      path: images/js/v2.x
  - id: rust-v0.56
    source:
      type: local
      path: images/rust/v0.56
YAML
}

# =============================================================================
# TEST SUITE
# =============================================================================

test_browser_image_selected_alone_builds_its_base_first() {
  write_browser_yaml
  assert_equals "$(built_images implementations 'chromium-js-v2.x')" \
    "transport-implementations-js-v2.x transport-implementations-chromium-js-v2.x"
}

test_browser_image_is_built_after_its_base_when_both_are_selected() {
  write_browser_yaml
  assert_equals "$(built_images implementations 'chromium-js-v2.x|js-v2.x')" \
    "transport-implementations-js-v2.x transport-implementations-chromium-js-v2.x"
}

test_unrelated_images_are_not_built() {
  write_browser_yaml
  assert_equals "$(built_images implementations 'js-v2.x')" "transport-implementations-js-v2.x"
}

test_images_without_dependencies_keep_their_order() {
  write_browser_yaml
  assert_equals "$(built_images implementations 'rust-v0.56|js-v2.x')" \
    "transport-implementations-js-v2.x transport-implementations-rust-v0.56"
}

test_depends_list_builds_dependencies_first() {
  cat > "${IMAGES_YAML}" <<'YAML'
implementations:
  - id: app
    depends: [lib-a, lib-b]
    source: {type: local, path: app}
  - id: lib-a
    depends: [core]
    source: {type: local, path: a}
  - id: lib-b
    depends: [core]
    source: {type: local, path: b}
  - id: core
    source: {type: local, path: core}
YAML
  assert_equals "$(built_images implementations 'app')" \
    "transport-implementations-core transport-implementations-lib-a transport-implementations-lib-b transport-implementations-app"
}

test_shared_dependency_is_built_once() {
  write_browser_yaml
  cat >> "${IMAGES_YAML}" <<'YAML'
  - id: firefox-js-v2.x
    source:
      type: browser
      baseImage: js-v2.x
      browser: firefox
      dockerfile: images/js/v2.x/BrowserDockerfile
YAML
  assert_equals "$(built_images implementations 'chromium-js-v2.x|firefox-js-v2.x')" \
    "transport-implementations-js-v2.x transport-implementations-chromium-js-v2.x transport-implementations-firefox-js-v2.x"
}

test_dependency_that_is_already_built_is_skipped() {
  write_browser_yaml
  EXISTING_IMAGES="transport-implementations-js-v2.x"
  assert_equals "$(built_images implementations 'chromium-js-v2.x')" "transport-implementations-chromium-js-v2.x"
}

test_force_rebuild_rebuilds_dependencies_too() {
  write_browser_yaml
  EXISTING_IMAGES="transport-implementations-js-v2.x transport-implementations-chromium-js-v2.x"
  assert_equals "$(built_images implementations 'chromium-js-v2.x' true)" \
    "transport-implementations-js-v2.x transport-implementations-chromium-js-v2.x"
}

test_empty_filter_builds_nothing() {
  write_browser_yaml
  assert_equals "$(built_images implementations '')" ""
}

test_unknown_dependency_fails_before_building() {
  cat > "${IMAGES_YAML}" <<'YAML'
implementations:
  - id: app
    depends: [missing]
    source: {type: local, path: app}
YAML
  : > "${BUILD_LOG}"
  local status=0
  (build_images_from_section implementations "app" false) 2>"${WORK_DIR}/stderr.log" || status=$?
  [ "${status}" -ne 0 ] || fail "expected a failure"
  grep -q "app depends on missing" "${WORK_DIR}/stderr.log" || fail "missing error message"
  [ ! -s "${BUILD_LOG}" ] || fail "nothing should be built"
}

test_circular_dependency_fails_before_building() {
  cat > "${IMAGES_YAML}" <<'YAML'
implementations:
  - id: a
    depends: [b]
    source: {type: local, path: a}
  - id: b
    depends: [a]
    source: {type: local, path: b}
YAML
  : > "${BUILD_LOG}"
  local status=0
  (build_images_from_section implementations "a" false) 2>"${WORK_DIR}/stderr.log" || status=$?
  [ "${status}" -ne 0 ] || fail "expected a failure"
  grep -q "Circular image dependency" "${WORK_DIR}/stderr.log" || fail "missing error message"
  [ ! -s "${BUILD_LOG}" ] || fail "nothing should be built"
}

run_test() {
  local test_name="$1"
  local test_function="$2"

  TEST_COUNT=$((TEST_COUNT + 1))
  echo -n "Test $TEST_COUNT: $test_name ... "

  # Run test in a subshell to isolate variables
  if ( EXISTING_IMAGES=""; $test_function ) 2>"${WORK_DIR}/test-stderr.log"; then
    echo "✓ PASS"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo "✗ FAIL"
    sed 's/^/    /' "${WORK_DIR}/test-stderr.log" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_TESTS+=("$test_name")
  fi
}

run_test "Browser image selected alone builds its base first" test_browser_image_selected_alone_builds_its_base_first
run_test "Browser image is built after its base when both are selected" test_browser_image_is_built_after_its_base_when_both_are_selected
run_test "Unrelated images are not built" test_unrelated_images_are_not_built
run_test "Images without dependencies keep their order" test_images_without_dependencies_keep_their_order
run_test "depends list builds dependencies first" test_depends_list_builds_dependencies_first
run_test "Shared dependency is built once" test_shared_dependency_is_built_once
run_test "Dependency that is already built is skipped" test_dependency_that_is_already_built_is_skipped
run_test "Force rebuild rebuilds dependencies too" test_force_rebuild_rebuilds_dependencies_too
run_test "Empty filter builds nothing" test_empty_filter_builds_nothing
run_test "Unknown dependency fails before building" test_unknown_dependency_fails_before_building
run_test "Circular dependency fails before building" test_circular_dependency_fails_before_building

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Results: $PASSED_COUNT/$TEST_COUNT passed"

if [ $FAILED_COUNT -gt 0 ]; then
  echo "Failed tests:"
  for test in "${FAILED_TESTS[@]}"; do
    echo "  ✗ $test"
  done
  echo "════════════════════════════════════════════════════════════════"
  exit 1
else
  echo "✓ All tests passed!"
  echo "════════════════════════════════════════════════════════════════"
  exit 0
fi
