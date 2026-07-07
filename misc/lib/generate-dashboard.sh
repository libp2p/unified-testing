#!/usr/bin/env bash
# Generate results.md dashboard from results.yaml for misc protocol interop tests.
# Extends the transport dashboard format with a Protocol column and protocol-scoped
# matrix views so each of ping / echo / identify is shown in its own section.

set -euo pipefail

RESULTS_FILE="${TEST_PASS_DIR:-.}/results.yaml"
OUTPUT_FILE="${TEST_PASS_DIR:-.}/results.md"
LATEST_RESULTS_FILE="${TEST_PASS_DIR:-.}/LATEST_TEST_RESULTS.md"

if [ ! -f "${RESULTS_FILE}" ]; then
    echo "✗ Error: ${RESULTS_FILE} not found"
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract metadata & summary
# ---------------------------------------------------------------------------
test_pass=$(yq eval '.metadata.testPass'     "${RESULTS_FILE}")
STARTED_AT=$(yq eval '.metadata.startedAt'  "${RESULTS_FILE}")
COMPLETED_AT=$(yq eval '.metadata.completedAt' "${RESULTS_FILE}")
duration=$(yq eval '.metadata.duration'     "${RESULTS_FILE}")
platform=$(yq eval '.metadata.platform'     "${RESULTS_FILE}")
os_name=$(yq eval '.metadata.os'            "${RESULTS_FILE}")
worker_count=$(yq eval '.metadata.workerCount' "${RESULTS_FILE}")

total=$(yq eval '.summary.total'   "${RESULTS_FILE}")
PASSED=$(yq eval '.summary.passed' "${RESULTS_FILE}")
FAILED=$(yq eval '.summary.failed' "${RESULTS_FILE}")

if [ "${total}" -gt 0 ]; then
    pass_rate=$(echo "scale=1; (${PASSED} * 100) / ${total}" | bc)
else
    pass_rate="0.0"
fi

# ---------------------------------------------------------------------------
# LATEST_TEST_RESULTS.md  (flat table)
# ---------------------------------------------------------------------------
cat > "${LATEST_RESULTS_FILE}" <<EOF
# Misc Protocol Interoperability Test Results

## Test Pass: \`${test_pass}\`

**Summary:**
- **Total Tests:** ${total}
- **Passed:** ✅ ${PASSED}
- **Failed:** ❌ ${FAILED}
- **Pass Rate:** ${pass_rate}%

**Environment:**
- **Platform:** ${platform}
- **OS:** ${os_name}
- **Workers:** ${worker_count}
- **Duration:** ${duration}

**Timestamps:**
- **Started:** ${STARTED_AT}
- **Completed:** ${COMPLETED_AT}

---

## Test Results

| Test | Dialer | Listener | Transport | Secure | Muxer | Protocol | Status | Duration |
|------|--------|----------|-----------|--------|-------|----------|--------|----------|
EOF

TEST_COUNT=$(yq eval '.tests | length' "${RESULTS_FILE}")

# Associative array for matrix lookups
declare -A test_status_map
declare -A test_protocol_map

if [ "${TEST_COUNT}" -gt 0 ]; then
    test_data=$(yq eval '.tests[] | [.name, .status, .dialer, .listener, .transport, (.secureChannel // "null"), (.muxer // "null"), .protocol, .duration] | @tsv' "${RESULTS_FILE}")

    while IFS=$'\t' read -r name status dialer listener transport secure muxer protocol test_duration; do
        test_status_map["${name}"]="${status}"
        test_protocol_map["${name}"]="${protocol}"

        [ "${status}" == "pass" ] && status_icon="✅" || status_icon="❌"
        [ "${secure}"   == "null" ] && secure="-"
        [ "${muxer}"    == "null" ] && muxer="-"

        echo "| ${name} | ${dialer} | ${listener} | ${transport} | ${secure} | ${muxer} | ${protocol} | ${status_icon} | ${test_duration} |" >> "${LATEST_RESULTS_FILE}"
    done <<< "${test_data}"
fi

cat >> "${LATEST_RESULTS_FILE}" <<EOF

---

*Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)*
EOF

echo "  ✓ Generated ${LATEST_RESULTS_FILE}"

# ---------------------------------------------------------------------------
# results.md  (summary + matrix view per protocol)
# ---------------------------------------------------------------------------
cat > "${OUTPUT_FILE}" <<EOF
# Misc Protocol Interoperability Test Results

## Test Pass: \`${test_pass}\`

**Summary:**
- **Total Tests:** ${total}
- **Passed:** ✅ ${PASSED}
- **Failed:** ❌ ${FAILED}
- **Pass Rate:** ${pass_rate}%

**Environment:**
- **Platform:** ${platform}
- **OS:** ${os_name}
- **Workers:** ${worker_count}
- **Duration:** ${duration}

**Timestamps:**
- **Started:** ${STARTED_AT}
- **Completed:** ${COMPLETED_AT}

---

## Latest Test Results

See [Latest Test Results](LATEST_TEST_RESULTS.md) for the full flat results table.

---

## Matrix View (grouped by Protocol → Transport + Secure + Muxer)

EOF

if [ "${TEST_COUNT}" -gt 0 ]; then

    # Get unique protocols that were actually tested
    protocols=$(yq eval '.tests[] | .protocol' "${RESULTS_FILE}" | sort -u)

    for protocol in ${protocols}; do
        echo "## Protocol: \`${protocol}\`" >> "${OUTPUT_FILE}"
        echo "" >> "${OUTPUT_FILE}"

        # Get unique transport+secure+muxer combos for this protocol
        combinations=$(yq eval ".tests[] | select(.protocol == \"${protocol}\") | .transport + \"|\" + (.secureChannel // \"null\") + \"|\" + (.muxer // \"null\")" "${RESULTS_FILE}" | sort -u)

        for combo in ${combinations}; do
            IFS='|' read -r transport secure muxer <<< "${combo}"

            if [ "${secure}" == "null" ] || [ "${muxer}" == "null" ]; then
                echo "### ${transport}" >> "${OUTPUT_FILE}"
            else
                echo "### ${transport} + ${secure} + ${muxer}" >> "${OUTPUT_FILE}"
            fi
            echo "" >> "${OUTPUT_FILE}"

            dialers=$(yq eval ".tests[] | select(.protocol == \"${protocol}\" and .transport == \"${transport}\" and (.secureChannel // \"null\") == \"${secure}\" and (.muxer // \"null\") == \"${muxer}\") | .dialer" "${RESULTS_FILE}" | sort -u)
            listeners=$(yq eval ".tests[] | select(.protocol == \"${protocol}\" and .transport == \"${transport}\" and (.secureChannel // \"null\") == \"${secure}\" and (.muxer // \"null\") == \"${muxer}\") | .listener" "${RESULTS_FILE}" | sort -u)

            # Table header
            echo -n "| Dialer \\ Listener |" >> "${OUTPUT_FILE}"
            for listener in ${listeners}; do
                echo -n " ${listener} |" >> "${OUTPUT_FILE}"
            done
            echo "" >> "${OUTPUT_FILE}"

            # Separator
            echo -n "|---|" >> "${OUTPUT_FILE}"
            for listener in ${listeners}; do
                echo -n "---|" >> "${OUTPUT_FILE}"
            done
            echo "" >> "${OUTPUT_FILE}"

            # Data rows
            for dialer in ${dialers}; do
                echo -n "| **${dialer}** |" >> "${OUTPUT_FILE}"
                for listener in ${listeners}; do
                    if [ "${secure}" == "null" ] || [ "${muxer}" == "null" ]; then
                        test_name="${dialer} x ${listener} (${transport}) [${protocol}]"
                    else
                        test_name="${dialer} x ${listener} (${transport}, ${secure}, ${muxer}) [${protocol}]"
                    fi

                    if [ -n "${test_status_map[${test_name}]:-}" ]; then
                        [ "${test_status_map[${test_name}]}" == "pass" ] && cell="✅" || cell="❌"
                    else
                        cell="—"
                    fi
                    echo -n " ${cell} |" >> "${OUTPUT_FILE}"
                done
                echo "" >> "${OUTPUT_FILE}"
            done

            echo "" >> "${OUTPUT_FILE}"
        done
    done
fi

cat >> "${OUTPUT_FILE}" <<EOF

---

*Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)*
EOF

echo "  ✓ Generated ${OUTPUT_FILE}"
