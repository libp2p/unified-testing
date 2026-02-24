#!/usr/bin/env bash
# Generate test matrix from ${IMAGES_YAML} with filtering
# Outputs test-matrix.yaml with content-addressed caching
# Permutations: dialer × listener × transport × secureChannel × muxer × protocol
#
# The protocol dimension is the key difference between misc and transport tests.
# Each test row includes a `protocol` field (ping | echo | identify) derived from
# the intersection of both implementations' `protocols` lists in images.yaml.
# PROTOCOL_SELECT / PROTOCOL_IGNORE follow the same two-stage filter logic used
# for every other dimension throughout the test framework.

##### 1. SETUP

set -euo pipefail

trap 'echo "ERROR in generate-tests.sh at line $LINENO: Command exited with status $?" >&2' ERR

# Source common libraries
source "${SCRIPT_LIB_DIR}/lib-filter-engine.sh"
source "${SCRIPT_LIB_DIR}/lib-generate-tests.sh"
source "${SCRIPT_LIB_DIR}/lib-host-os.sh"
source "${SCRIPT_LIB_DIR}/lib-image-building.sh"
source "${SCRIPT_LIB_DIR}/lib-image-naming.sh"
source "${SCRIPT_LIB_DIR}/lib-output-formatting.sh"
source "${SCRIPT_LIB_DIR}/lib-test-caching.sh"
source "${SCRIPT_LIB_DIR}/lib-test-filtering.sh"
source "${SCRIPT_LIB_DIR}/lib-test-images.sh"

##### 2. FILTER EXPANSION

# Load test aliases
load_aliases

# Get common entity IDs
readarray -t all_image_ids       < <(get_entity_ids "implementations")
readarray -t all_transport_names < <(get_transport_names "implementations")
readarray -t all_secure_names    < <(get_secure_names "implementations")
readarray -t all_muxer_names     < <(get_muxer_names "implementations")

# Collect all unique protocol names from images.yaml
readarray -t all_protocol_names < <(
  yq eval '.implementations[].protocols[]' "${IMAGES_YAML}" 2>/dev/null | sort -u || true
)

# Save original filters for display
ORIGINAL_IMPL_SELECT="${IMPL_SELECT}"
ORIGINAL_IMPL_IGNORE="${IMPL_IGNORE}"
ORIGINAL_TRANSPORT_SELECT="${TRANSPORT_SELECT}"
ORIGINAL_TRANSPORT_IGNORE="${TRANSPORT_IGNORE}"
ORIGINAL_SECURE_SELECT="${SECURE_SELECT}"
ORIGINAL_SECURE_IGNORE="${SECURE_IGNORE}"
ORIGINAL_MUXER_SELECT="${MUXER_SELECT}"
ORIGINAL_MUXER_IGNORE="${MUXER_IGNORE}"
ORIGINAL_PROTOCOL_SELECT="${PROTOCOL_SELECT}"
ORIGINAL_PROTOCOL_IGNORE="${PROTOCOL_IGNORE}"
ORIGINAL_TEST_SELECT="${TEST_SELECT}"
ORIGINAL_TEST_IGNORE="${TEST_IGNORE}"

# Expand implementation filters
[ -n "${IMPL_SELECT}" ]      && EXPANDED_IMPL_SELECT=$(expand_filter_string "${IMPL_SELECT}" all_image_ids) || EXPANDED_IMPL_SELECT=""
[ -n "${IMPL_IGNORE}" ]      && EXPANDED_IMPL_IGNORE=$(expand_filter_string "${IMPL_IGNORE}" all_image_ids) || EXPANDED_IMPL_IGNORE=""

# Expand transport filters
[ -n "${TRANSPORT_SELECT}" ] && EXPANDED_TRANSPORT_SELECT=$(expand_filter_string "${TRANSPORT_SELECT}" all_transport_names) || EXPANDED_TRANSPORT_SELECT=""
[ -n "${TRANSPORT_IGNORE}" ] && EXPANDED_TRANSPORT_IGNORE=$(expand_filter_string "${TRANSPORT_IGNORE}" all_transport_names) || EXPANDED_TRANSPORT_IGNORE=""

# Expand secure channel filters
[ -n "${SECURE_SELECT}" ]    && EXPANDED_SECURE_SELECT=$(expand_filter_string "${SECURE_SELECT}" all_secure_names) || EXPANDED_SECURE_SELECT=""
[ -n "${SECURE_IGNORE}" ]    && EXPANDED_SECURE_IGNORE=$(expand_filter_string "${SECURE_IGNORE}" all_secure_names) || EXPANDED_SECURE_IGNORE=""

# Expand muxer filters
[ -n "${MUXER_SELECT}" ]     && EXPANDED_MUXER_SELECT=$(expand_filter_string "${MUXER_SELECT}" all_muxer_names) || EXPANDED_MUXER_SELECT=""
[ -n "${MUXER_IGNORE}" ]     && EXPANDED_MUXER_IGNORE=$(expand_filter_string "${MUXER_IGNORE}" all_muxer_names) || EXPANDED_MUXER_IGNORE=""

# Expand protocol filters  (protocol names are their own universe; no aliases needed beyond the ones
# defined in protocol-aliases in images.yaml, which load_aliases has already read)
[ -n "${PROTOCOL_SELECT}" ]  && EXPANDED_PROTOCOL_SELECT=$(expand_filter_string "${PROTOCOL_SELECT}" all_protocol_names) || EXPANDED_PROTOCOL_SELECT=""
[ -n "${PROTOCOL_IGNORE}" ]  && EXPANDED_PROTOCOL_IGNORE=$(expand_filter_string "${PROTOCOL_IGNORE}" all_protocol_names) || EXPANDED_PROTOCOL_IGNORE=""

# Expand test name filters
[ -n "${TEST_SELECT}" ]      && EXPANDED_TEST_SELECT=$(expand_filter_string "${TEST_SELECT}" all_image_ids) || EXPANDED_TEST_SELECT=""
[ -n "${TEST_IGNORE}" ]      && EXPANDED_TEST_IGNORE=$(expand_filter_string "${TEST_IGNORE}" all_image_ids) || EXPANDED_TEST_IGNORE=""

##### 3. DISPLAY FILTER EXPANSION

print_filter_expansion "ORIGINAL_IMPL_SELECT"      "EXPANDED_IMPL_SELECT"      "Implementation select"        "No impl-select specified (will select all implementations)"
print_filter_expansion "ORIGINAL_IMPL_IGNORE"      "EXPANDED_IMPL_IGNORE"      "Implementation ignore"        "No impl-ignore specified (will ignore none)"
print_filter_expansion "ORIGINAL_TRANSPORT_SELECT" "EXPANDED_TRANSPORT_SELECT" "Transport select"             "No transport-select specified (will select all transports)"
print_filter_expansion "ORIGINAL_TRANSPORT_IGNORE" "EXPANDED_TRANSPORT_IGNORE" "Transport ignore"             "No transport-ignore specified (will ignore none)"
print_filter_expansion "ORIGINAL_SECURE_SELECT"    "EXPANDED_SECURE_SELECT"    "Secure channel select"        "No secure-select specified (will select all secure channels)"
print_filter_expansion "ORIGINAL_SECURE_IGNORE"    "EXPANDED_SECURE_IGNORE"    "Secure channel ignore"        "No secure-ignore specified (will ignore none)"
print_filter_expansion "ORIGINAL_MUXER_SELECT"     "EXPANDED_MUXER_SELECT"     "Muxer select"                 "No muxer-select specified (will select all muxers)"
print_filter_expansion "ORIGINAL_MUXER_IGNORE"     "EXPANDED_MUXER_IGNORE"     "Muxer ignore"                 "No muxer-ignore specified (will ignore none)"
print_filter_expansion "ORIGINAL_PROTOCOL_SELECT"  "EXPANDED_PROTOCOL_SELECT"  "Protocol select"              "No protocol-select specified (will select all protocols)"
print_filter_expansion "ORIGINAL_PROTOCOL_IGNORE"  "EXPANDED_PROTOCOL_IGNORE"  "Protocol ignore"              "No protocol-ignore specified (will ignore none)"
print_filter_expansion "ORIGINAL_TEST_SELECT"      "EXPANDED_TEST_SELECT"      "Test select"                  "No test-select specified (will select all tests)"
print_filter_expansion "ORIGINAL_TEST_IGNORE"      "EXPANDED_TEST_IGNORE"      "Test ignore"                  "No test-ignore specified (will ignore none)"

echo ""

##### 4. CACHE CHECK

print_message "Checking for cached test-matrix.yaml file"
indent
if check_and_load_cache "${TEST_RUN_KEY}" "${CACHE_DIR}/test-run-matrix" "${TEST_PASS_DIR}/test-matrix.yaml" "${FORCE_MATRIX_REBUILD}" "${TEST_TYPE}"; then
  unindent
  exit 0
fi
unindent
echo ""

##### 5. FILTERING

print_message "Filtering implementations..."
readarray -t selected_image_ids  < <(select_from_list all_image_ids "${EXPANDED_IMPL_SELECT}")
readarray -t filtered_image_ids  < <(ignore_from_list selected_image_ids "${EXPANDED_IMPL_IGNORE}")
indent; print_success "Filtered to ${#filtered_image_ids[@]} implementations (${#all_image_ids[@]} total)"; unindent

print_message "Filtering transports..."
readarray -t selected_transport_names < <(select_from_list all_transport_names "${EXPANDED_TRANSPORT_SELECT}")
readarray -t filtered_transport_names < <(ignore_from_list selected_transport_names "${EXPANDED_TRANSPORT_IGNORE}")
indent; print_success "Filtered to ${#filtered_transport_names[@]} transports (${#all_transport_names[@]} total)"; unindent

print_message "Filtering secure channels..."
readarray -t selected_secure_names < <(select_from_list all_secure_names "${EXPANDED_SECURE_SELECT}")
readarray -t filtered_secure_names < <(ignore_from_list selected_secure_names "${EXPANDED_SECURE_IGNORE}")
indent; print_success "Filtered to ${#filtered_secure_names[@]} secure channels (${#all_secure_names[@]} total)"; unindent

print_message "Filtering muxers..."
readarray -t selected_muxer_names < <(select_from_list all_muxer_names "${EXPANDED_MUXER_SELECT}")
readarray -t filtered_muxer_names < <(ignore_from_list selected_muxer_names "${EXPANDED_MUXER_IGNORE}")
indent; print_success "Filtered to ${#filtered_muxer_names[@]} muxers (${#all_muxer_names[@]} total)"; unindent

print_message "Filtering protocols..."
readarray -t selected_protocol_names < <(select_from_list all_protocol_names "${EXPANDED_PROTOCOL_SELECT}")
readarray -t filtered_protocol_names < <(ignore_from_list selected_protocol_names "${EXPANDED_PROTOCOL_IGNORE}")
indent; print_success "Filtered to ${#filtered_protocol_names[@]} protocols (${#all_protocol_names[@]} total)"; unindent

echo ""

##### 6. LOAD PARAMETER LISTS

print_message "Loading implementation data into memory..."

declare -A image_transports
declare -A image_secure
declare -A image_muxers
declare -A image_protocols
declare -A image_dial_only
declare -A image_commit
declare -A image_legacy

for image_id in "${all_image_ids[@]}"; do
  image_transports["${image_id}"]=$(yq eval ".implementations[] | select(.id == \"${image_id}\") | .transports | join(\" \")" "${IMAGES_YAML}")
  image_secure["${image_id}"]=$(yq eval ".implementations[] | select(.id == \"${image_id}\") | .secureChannels | join(\" \")" "${IMAGES_YAML}")
  image_muxers["${image_id}"]=$(yq eval ".implementations[] | select(.id == \"${image_id}\") | .muxers | join(\" \")" "${IMAGES_YAML}")
  image_protocols["${image_id}"]=$(yq eval ".implementations[] | select(.id == \"${image_id}\") | .protocols | join(\" \")" "${IMAGES_YAML}" 2>/dev/null || echo "")
  image_dial_only["${image_id}"]=$(yq eval ".implementations[] | select(.id == \"${image_id}\") | .dialOnly | join(\" \")" "${IMAGES_YAML}" 2>/dev/null || echo "")
  local_commit=$(yq eval ".implementations[] | select(.id == \"${image_id}\") | .source.commit" "${IMAGES_YAML}" 2>/dev/null || echo "")
  [ -n "${local_commit}" ] && image_commit["${image_id}"]="${local_commit}"
  image_legacy["${image_id}"]=$(yq eval ".implementations[] | select(.id == \"${image_id}\") | .legacy // false" "${IMAGES_YAML}" 2>/dev/null || echo "false")
done

indent; print_success "Loaded data for ${#all_image_ids[@]} implementations"; unindent

echo ""

##### 7. GENERATE TEST MATRIX

WORKER_COUNT="${WORKER_COUNT:-$(get_cpu_count)}"

# ---------------------------------------------------------------------------
# _emit_test: Write a single YAML test entry to a worker output file.
# Defined at top-level so it can be exported to background worker subshells.
# Args: dest_file test_id transport protocol secureChannel muxer
#       dialer_id dialer_image dialer_commit dialer_legacy
#       listener_id listener_image listener_commit listener_legacy
# (Called exclusively from generate_tests_worker below.)
# ---------------------------------------------------------------------------
_emit_test() {
  local dest="$1"
  local test_id="$2"
  local transport="$3"
  local protocol="$4"
  local sec="$5"
  local mux="$6"
  local d_id="$7"
  local d_img="$8"
  local d_commit="$9"
  local d_legacy="${10}"
  local l_id="${11}"
  local l_img="${12}"
  local l_commit="${13}"
  local l_legacy="${14}"

  cat >> "${dest}" <<EOF
  - id: "${test_id}"
    transport: ${transport}
    secureChannel: ${sec}
    muxer: ${mux}
    protocol: ${protocol}
    dialer:
      id: ${d_id}
      imageName: ${d_img}
EOF
  [ -n "${d_commit}" ]       && echo "      snapshot: snapshots/${d_commit}.zip" >> "${dest}"
  [ "${d_legacy}" == "true" ] && echo "      legacy: true" >> "${dest}"
  cat >> "${dest}" <<EOF
    listener:
      id: ${l_id}
      imageName: ${l_img}
EOF
  [ -n "${l_commit}" ]       && echo "      snapshot: snapshots/${l_commit}.zip" >> "${dest}"
  [ "${l_legacy}" == "true" ] && echo "      legacy: true" >> "${dest}"
}

# ---------------------------------------------------------------------------
# Worker function: generates tests for a chunk of dialers.
# Adds a `protocol` field to every test entry — the key addition vs transport.
# ---------------------------------------------------------------------------
generate_tests_worker() {
  local worker_id=$1
  shift
  local dialer_chunk=("$@")

  local worker_selected="${TEST_PASS_DIR}/worker-${worker_id}-selected.yaml"
  local worker_ignored="${TEST_PASS_DIR}/worker-${worker_id}-ignored.yaml"
  > "${worker_selected}"
  > "${worker_ignored}"

  # Re-load associative arrays from serialised worker data files
  declare -A image_transports image_secure image_muxers image_protocols image_dial_only image_commit image_legacy
  while IFS='|' read -r k v; do image_transports["${k}"]="${v}"; done < "${WORKER_DATA_DIR}/transports.dat"
  while IFS='|' read -r k v; do image_secure["${k}"]="${v}";     done < "${WORKER_DATA_DIR}/secure.dat"
  while IFS='|' read -r k v; do image_muxers["${k}"]="${v}";     done < "${WORKER_DATA_DIR}/muxers.dat"
  [ -f "${WORKER_DATA_DIR}/protocols.dat" ] && while IFS='|' read -r k v; do image_protocols["${k}"]="${v}"; done < "${WORKER_DATA_DIR}/protocols.dat"
  [ -f "${WORKER_DATA_DIR}/dial_only.dat" ] && while IFS='|' read -r k v; do image_dial_only["${k}"]="${v}"; done < "${WORKER_DATA_DIR}/dial_only.dat"
  [ -f "${WORKER_DATA_DIR}/commits.dat"   ] && while IFS='|' read -r k v; do image_commit["${k}"]="${v}";   done < "${WORKER_DATA_DIR}/commits.dat"
  [ -f "${WORKER_DATA_DIR}/legacy.dat"    ] && while IFS='|' read -r k v; do image_legacy["${k}"]="${v}";   done < "${WORKER_DATA_DIR}/legacy.dat"

  for dialer_id in "${dialer_chunk[@]}"; do
    local dialer_transports="${image_transports[${dialer_id}]}"
    local dialer_secure="${image_secure[${dialer_id}]}"
    local dialer_muxers="${image_muxers[${dialer_id}]}"
    local dialer_protocols="${image_protocols[${dialer_id}]:-}"
    local dialer_legacy="${image_legacy[${dialer_id}]:-false}"
    local dialer_commit="${image_commit[${dialer_id}]:-}"
    local dialer_selected=true

    [[ ! " ${filtered_image_ids[*]} " =~ " ${dialer_id} " ]] && dialer_selected=false

    for listener_id in "${all_image_ids[@]}"; do
      local listener_transports="${image_transports[${listener_id}]}"
      local listener_secure="${image_secure[${listener_id}]}"
      local listener_muxers="${image_muxers[${listener_id}]}"
      local listener_protocols="${image_protocols[${listener_id}]:-}"
      local listener_legacy="${image_legacy[${listener_id}]:-false}"
      local listener_commit="${image_commit[${listener_id}]:-}"
      local listener_selected=true

      [[ ! " ${filtered_image_ids[*]} " =~ " ${listener_id} " ]] && listener_selected=false

      local common_transports
      common_transports=$(get_common "${dialer_transports}" "${listener_transports}")
      [ -z "${common_transports}" ] && continue

      # Common protocols (intersection of both implementations)
      local common_protocols
      common_protocols=$(get_common "${dialer_protocols}" "${listener_protocols}")
      [ -z "${common_protocols}" ] && continue

      local dialer_image_name listener_image_name
      dialer_image_name=$(get_image_name "${TEST_TYPE}" "implementations" "${dialer_id}")
      listener_image_name=$(get_image_name "${TEST_TYPE}" "implementations" "${listener_id}")

      for transport in ${common_transports}; do
        local transport_selected=true
        [[ ! " ${filtered_transport_names[*]} " =~ " ${transport} " ]] && transport_selected=false

        # Skip if listener has this transport as dial-only
        local dial_only_transports="${image_dial_only[${listener_id}]:-}"
        case " ${dial_only_transports} " in *" ${transport} "*) continue ;; esac

        # Find common secure channels and muxers for layered transports
        local skip_layers=false
        is_standalone_transport "${transport}" && skip_layers=true

        if "${skip_layers}"; then
          local common_secure="" common_muxers=""
        else
          local common_secure common_muxers
          common_secure=$(get_common "${dialer_secure}" "${listener_secure}")
          common_muxers=$(get_common "${dialer_muxers}" "${listener_muxers}")
          { [ -z "${common_secure}" ] || [ -z "${common_muxers}" ]; } && continue
        fi

        # Iterate protocol dimension
        for protocol in ${common_protocols}; do
          local protocol_selected=true
          [[ ! " ${filtered_protocol_names[*]} " =~ " ${protocol} " ]] && protocol_selected=false

          if "${skip_layers}"; then
            # Standalone transport: no secure/muxer
            local test_id="${dialer_id} x ${listener_id} (${transport}) [${protocol}]"
            local test_is_selected=false
            { [ "${dialer_selected}" == "true" ] && [ "${listener_selected}" == "true" ] && \
              [ "${transport_selected}" == "true" ] && [ "${protocol_selected}" == "true" ]; } && test_is_selected=true

            local test_name_selected=true
            if [ -n "${EXPANDED_TEST_SELECT}" ]; then
              test_name_selected=false
              filter_matches "${test_id}" "${EXPANDED_TEST_SELECT}" && test_name_selected=true
            fi
            if [ "${test_name_selected}" == "true" ] && [ -n "${EXPANDED_TEST_IGNORE}" ]; then
              filter_matches "${test_id}" "${EXPANDED_TEST_IGNORE}" && test_name_selected=false
            fi

            if [ "${test_is_selected}" == "true" ] && [ "${test_name_selected}" == "true" ]; then
              _emit_test "${worker_selected}" "${test_id}" "${transport}" "${protocol}" "null" "null" \
                "${dialer_id}" "${dialer_image_name}" "${dialer_commit}" "${dialer_legacy}" \
                "${listener_id}" "${listener_image_name}" "${listener_commit}" "${listener_legacy}"
            else
              _emit_test "${worker_ignored}"  "${test_id}" "${transport}" "${protocol}" "null" "null" \
                "${dialer_id}" "${dialer_image_name}" "${dialer_commit}" "${dialer_legacy}" \
                "${listener_id}" "${listener_image_name}" "${listener_commit}" "${listener_legacy}"
            fi

          else
            for secure in ${common_secure}; do
              local secure_selected=true
              [[ ! " ${filtered_secure_names[*]} " =~ " ${secure} " ]] && secure_selected=false

              for muxer in ${common_muxers}; do
                local muxer_selected=true
                [[ ! " ${filtered_muxer_names[*]} " =~ " ${muxer} " ]] && muxer_selected=false

                local test_id="${dialer_id} x ${listener_id} (${transport}, ${secure}, ${muxer}) [${protocol}]"
                local test_is_selected=false
                { [ "${dialer_selected}" == "true" ]   && [ "${listener_selected}" == "true" ] && \
                  [ "${transport_selected}" == "true" ] && [ "${secure_selected}" == "true" ]  && \
                  [ "${muxer_selected}" == "true" ]     && [ "${protocol_selected}" == "true" ]; } && test_is_selected=true

                local test_name_selected=true
                if [ -n "${EXPANDED_TEST_SELECT}" ]; then
                  test_name_selected=false
                  filter_matches "${test_id}" "${EXPANDED_TEST_SELECT}" && test_name_selected=true
                fi
                if [ "${test_name_selected}" == "true" ] && [ -n "${EXPANDED_TEST_IGNORE}" ]; then
                  filter_matches "${test_id}" "${EXPANDED_TEST_IGNORE}" && test_name_selected=false
                fi

                if [ "${test_is_selected}" == "true" ] && [ "${test_name_selected}" == "true" ]; then
                  _emit_test "${worker_selected}" "${test_id}" "${transport}" "${protocol}" "${secure}" "${muxer}" \
                    "${dialer_id}" "${dialer_image_name}" "${dialer_commit}" "${dialer_legacy}" \
                    "${listener_id}" "${listener_image_name}" "${listener_commit}" "${listener_legacy}"
                else
                  _emit_test "${worker_ignored}"  "${test_id}" "${transport}" "${protocol}" "${secure}" "${muxer}" \
                    "${dialer_id}" "${dialer_image_name}" "${dialer_commit}" "${dialer_legacy}" \
                    "${listener_id}" "${listener_image_name}" "${listener_commit}" "${listener_legacy}"
                fi
              done
            done
          fi
        done  # protocol loop
      done  # transport loop
    done  # listener loop
  done  # dialer loop
}

# Serialise associative arrays for workers (bash can't export assoc arrays)
WORKER_DATA_DIR="${TEST_PASS_DIR}/worker-data"
mkdir -p "${WORKER_DATA_DIR}"

for k in "${!image_transports[@]}"; do echo "${k}|${image_transports[${k}]}" >> "${WORKER_DATA_DIR}/transports.dat"; done
for k in "${!image_secure[@]}";     do echo "${k}|${image_secure[${k}]}"     >> "${WORKER_DATA_DIR}/secure.dat";     done
for k in "${!image_muxers[@]}";     do echo "${k}|${image_muxers[${k}]}"     >> "${WORKER_DATA_DIR}/muxers.dat";     done
for k in "${!image_protocols[@]}";  do echo "${k}|${image_protocols[${k}]}"  >> "${WORKER_DATA_DIR}/protocols.dat";  done
for k in "${!image_dial_only[@]}";  do echo "${k}|${image_dial_only[${k}]}"  >> "${WORKER_DATA_DIR}/dial_only.dat";  done
for k in "${!image_commit[@]}";     do echo "${k}|${image_commit[${k}]}"     >> "${WORKER_DATA_DIR}/commits.dat";    done
for k in "${!image_legacy[@]}";     do echo "${k}|${image_legacy[${k}]}"     >> "${WORKER_DATA_DIR}/legacy.dat";     done

export -f _emit_test generate_tests_worker get_common get_image_name is_standalone_transport print_debug filter_matches
export TEST_PASS_DIR WORKER_DATA_DIR filtered_image_ids all_image_ids
export filtered_transport_names filtered_secure_names filtered_muxer_names filtered_protocol_names
export EXPANDED_TEST_SELECT EXPANDED_TEST_IGNORE

print_message "Generating main test combinations (using ${WORKER_COUNT} workers)..."

total_dialers=${#all_image_ids[@]}
chunk_size=$(( (total_dialers + WORKER_COUNT - 1) / WORKER_COUNT ))

pids=()
for (( w=0; w<WORKER_COUNT; w++ )); do
  start=$(( w * chunk_size ))
  [ "${start}" -ge "${total_dialers}" ] && break
  chunk=("${all_image_ids[@]:${start}:${chunk_size}}")
  [ "${#chunk[@]}" -eq 0 ] && continue
  generate_tests_worker "${w}" "${chunk[@]}" &
  pids+=($!)
done

for pid in "${pids[@]}"; do wait "${pid}"; done

# Count results from worker files
total_selected=0
total_ignored=0
for (( w=0; w<WORKER_COUNT; w++ )); do
  [ -f "${TEST_PASS_DIR}/worker-${w}-selected.yaml" ] && \
    total_selected=$(( total_selected + $(grep -c "^  - id:" "${TEST_PASS_DIR}/worker-${w}-selected.yaml" 2>/dev/null || echo 0) ))
  [ -f "${TEST_PASS_DIR}/worker-${w}-ignored.yaml" ] && \
    total_ignored=$(( total_ignored + $(grep -c "^  - id:" "${TEST_PASS_DIR}/worker-${w}-ignored.yaml" 2>/dev/null || echo 0) ))
done

rm -rf "${WORKER_DATA_DIR}"

indent
print_success "${total_selected} Selected"
print_error   "${total_ignored} Ignored"
unindent
echo ""

##### 8. OUTPUT TEST MATRIX

cat > "${TEST_PASS_DIR}/test-matrix.yaml" <<EOF
metadata:
  implSelect: |-
    ${IMPL_SELECT}
  implIgnore: |-
    ${IMPL_IGNORE}
  transportSelect: |-
    ${TRANSPORT_SELECT}
  transportIgnore: |-
    ${TRANSPORT_IGNORE}
  secureSelect: |-
    ${SECURE_SELECT}
  secureIgnore: |-
    ${SECURE_IGNORE}
  muxerSelect: |-
    ${MUXER_SELECT}
  muxerIgnore: |-
    ${MUXER_IGNORE}
  protocolSelect: |-
    ${PROTOCOL_SELECT}
  protocolIgnore: |-
    ${PROTOCOL_IGNORE}
  testSelect: |-
    ${TEST_SELECT}
  testIgnore: |-
    ${TEST_IGNORE}
  totalTests: ${total_selected}
  ignoredTests: ${total_ignored}
  debug: ${DEBUG}

tests:
EOF

for (( w=0; w<WORKER_COUNT; w++ )); do
  if [ -f "${TEST_PASS_DIR}/worker-${w}-selected.yaml" ]; then
    cat "${TEST_PASS_DIR}/worker-${w}-selected.yaml" >> "${TEST_PASS_DIR}/test-matrix.yaml"
    rm -f "${TEST_PASS_DIR}/worker-${w}-selected.yaml"
  fi
done

cat >> "${TEST_PASS_DIR}/test-matrix.yaml" <<EOF

ignoredTests:
EOF

for (( w=0; w<WORKER_COUNT; w++ )); do
  if [ -f "${TEST_PASS_DIR}/worker-${w}-ignored.yaml" ]; then
    cat "${TEST_PASS_DIR}/worker-${w}-ignored.yaml" >> "${TEST_PASS_DIR}/test-matrix.yaml"
    rm -f "${TEST_PASS_DIR}/worker-${w}-ignored.yaml"
  fi
done

cp "${IMAGES_YAML}" "${TEST_PASS_DIR}/"
print_success "Copied ${IMAGES_YAML}: ${TEST_PASS_DIR}/${IMAGES_YAML}"
print_success "Generated test-matrix.yaml: ${TEST_PASS_DIR}/test-matrix.yaml"
indent
save_to_cache "${TEST_PASS_DIR}/test-matrix.yaml" "${TEST_RUN_KEY}" "${CACHE_DIR}/test-run-matrix" "${TEST_TYPE}"
unindent
exit 0
