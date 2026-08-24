#!/usr/bin/env bash
# Generate results.md dashboard from results.yaml

set -euo pipefail

# Use TEST_PASS_DIR if set, otherwise current directory
RESULTS_FILE="${TEST_PASS_DIR:-.}/results.yaml"
OUTPUT_FILE="${TEST_PASS_DIR:-.}/results.md"
LATEST_RESULTS_FILE="${TEST_PASS_DIR:-.}/LATEST_TEST_RESULTS.md"

if [ ! -f "$RESULTS_FILE" ]; then
    echo "✗ Error: $RESULTS_FILE not found"
    exit 1
fi

# Extract metadata
test_pass=$(yq eval '.metadata.testPass' "$RESULTS_FILE")
STARTED_AT=$(yq eval '.metadata.startedAt' "$RESULTS_FILE")
COMPLETED_AT=$(yq eval '.metadata.completedAt' "$RESULTS_FILE")
duration=$(yq eval '.metadata.duration' "$RESULTS_FILE")
platform=$(yq eval '.metadata.platform' "$RESULTS_FILE")
os_name=$(yq eval '.metadata.os' "$RESULTS_FILE")
worker_count=$(yq eval '.metadata.workerCount' "$RESULTS_FILE")

# Extract summary
total=$(yq eval '.summary.total' "$RESULTS_FILE")
PASSED=$(yq eval '.summary.passed' "$RESULTS_FILE")
FAILED=$(yq eval '.summary.failed' "$RESULTS_FILE")

# Calculate pass rate
if [ "$total" -gt 0 ]; then
    pass_rate=$(awk "BEGIN {printf \"%.1f\", ($PASSED / $total) * 100}")
else
    pass_rate="0.0"
fi

# Generate LATEST_TEST_RESULTS.md (detailed results)
cat > "$LATEST_RESULTS_FILE" <<EOF
# Hole Punch (DCUtR) Interoperability Test Results

## Test Pass: \`$test_pass\`

**Method:** DCUtR (Direct Connection Upgrade through Relay) over Circuit Relay v2. The transport sets the punch mechanics: TCP simultaneous open, QUIC synchronised dial.

**Summary:**
- **Total Tests:** $total
- **Passed:** ✅ $PASSED
- **Failed:** ❌ $FAILED
- **Pass Rate:** ${pass_rate}%

**Environment:**
- **Platform:** $platform
- **OS:** $os_name
- **Workers:** $worker_count
- **Duration:** $duration

**Timestamps:**
- **Started:** $STARTED_AT
- **Completed:** $COMPLETED_AT

---

## Test Results

| Test | Dialer | Listener | Transport | Relay | Status | Duration |
|------|--------|----------|-----------|-------|--------|----------|
EOF

# Read test count
TEST_COUNT=$(yq eval '.tests | length' "$RESULTS_FILE")

# Per-relay tallies for the summary and the matrix cells keyed by
# relay|dialer|listener, both filled in the single pass below.
declare -A relay_total
declare -A relay_pass
declare -A relay_fail
declare -A matrix_cell

# Only process tests if there are any
if [ "$TEST_COUNT" -gt 0 ]; then
    # Export all test data as TSV in one yq call (much faster than individual calls)
    test_data=$(yq eval '.tests[] | [.name, .status, .dialer, .listener, .transport, .relay, .duration] | @tsv' "$RESULTS_FILE")

    # Process each test and build the detailed table, the per-relay tallies,
    # and the matrix cells in one pass.
    while IFS=$'\t' read -r name status dialer listener transport relay test_duration; do

        # A suite without a relay axis reports the field as "null".
        if [ -z "$relay" ] || [ "$relay" == "null" ]; then
            relay="-"
        fi

        # Status icon
        if [ "$status" == "pass" ]; then
            status_icon="✅"
        else
            status_icon="❌"
        fi

        # Per-relay tallies
        relay_total["$relay"]=$(( ${relay_total["$relay"]:-0} + 1 ))
        if [ "$status" == "pass" ]; then
            relay_pass["$relay"]=$(( ${relay_pass["$relay"]:-0} + 1 ))
        else
            relay_fail["$relay"]=$(( ${relay_fail["$relay"]:-0} + 1 ))
        fi

        # Matrix cell: append this test's icon and transport initial to the
        # relay|dialer|listener bucket.
        cell_key="${relay}|${dialer}|${listener}"
        matrix_cell["$cell_key"]="${matrix_cell["$cell_key"]:-}${status_icon}${transport:0:1} "

        echo "| $name | $dialer | $listener | $transport | $relay | $status_icon | $test_duration |" >> "$LATEST_RESULTS_FILE"
    done <<< "$test_data"
fi

# Add footer to LATEST_TEST_RESULTS.md
cat >> "$LATEST_RESULTS_FILE" <<EOF

---

*Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)*
EOF

echo "  ✓ Generated $LATEST_RESULTS_FILE"

# Generate main results.md (with matrix)
cat > "$OUTPUT_FILE" <<EOF
# Hole Punch (DCUtR) Interoperability Test Results

## Test Pass: \`$test_pass\`

**Method:** DCUtR (Direct Connection Upgrade through Relay) over Circuit Relay v2. The transport sets the punch mechanics: TCP simultaneous open, QUIC synchronised dial.

**Summary:**
- **Total Tests:** $total
- **Passed:** ✅ $PASSED
- **Failed:** ❌ $FAILED
- **Pass Rate:** ${pass_rate}%

**Environment:**
- **Platform:** $platform
- **OS:** $os_name
- **Workers:** $worker_count
- **Duration:** $duration

**Timestamps:**
- **Started:** $STARTED_AT
- **Completed:** $COMPLETED_AT

---

## Results by Relay

EOF

# Per-relay summary table. Every cell in the suite is relayed, so this splits
# the headline pass rate by which relay carried it.
if [ "$TEST_COUNT" -gt 0 ]; then
    {
        echo "| Relay | Total | Passed | Failed | Pass Rate |"
        echo "|-------|-------|--------|--------|-----------|"
        for relay in $(printf '%s\n' "${!relay_total[@]}" | sort); do
            r_total="${relay_total["$relay"]:-0}"
            r_pass="${relay_pass["$relay"]:-0}"
            r_fail="${relay_fail["$relay"]:-0}"
            if [ "$r_total" -gt 0 ]; then
                r_rate=$(awk "BEGIN {printf \"%.1f\", ($r_pass / $r_total) * 100}")
            else
                r_rate="0.0"
            fi
            echo "| $relay | $r_total | ✅ $r_pass | ❌ $r_fail | ${r_rate}% |"
        done
    } >> "$OUTPUT_FILE"
fi

cat >> "$OUTPUT_FILE" <<EOF

---

## Latest Test Results

See [Latest Test Results](LATEST_TEST_RESULTS.md) for detailed results table.

---

## Legend

- ✅ Test passed
- ❌ Test failed
- **Transport abbreviations**: t=tcp, q=quic, w=ws, W=wss (first letter)
- Example: ✅t = TCP test passed, ❌q = QUIC test failed

---

## Matrix View

EOF

# One dialer x listener grid per relay, so a pair's outcome through each relay
# is shown side by side rather than collapsed onto one square.
if [ "$TEST_COUNT" -gt 0 ]; then
    dialers=$(yq eval '.tests[].dialer' "$RESULTS_FILE" | sort -u)
    listeners=$(yq eval '.tests[].listener' "$RESULTS_FILE" | sort -u)

    for relay in $(printf '%s\n' "${!relay_total[@]}" | sort); do
        echo "### Relay: $relay" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"

        # Header row
        echo -n "| Dialer \\ Listener |" >> "$OUTPUT_FILE"
        for listener in $listeners; do
            echo -n " $listener |" >> "$OUTPUT_FILE"
        done
        echo "" >> "$OUTPUT_FILE"

        # Separator row
        echo -n "|---|" >> "$OUTPUT_FILE"
        for listener in $listeners; do
            echo -n "---|" >> "$OUTPUT_FILE"
        done
        echo "" >> "$OUTPUT_FILE"

        # Data rows
        for dialer in $dialers; do
            echo -n "| **$dialer** |" >> "$OUTPUT_FILE"
            for listener in $listeners; do
                result="${matrix_cell["${relay}|${dialer}|${listener}"]:-}"
                [ -z "$result" ] && result="-"
                echo -n " $result |" >> "$OUTPUT_FILE"
            done
            echo "" >> "$OUTPUT_FILE"
        done
        echo "" >> "$OUTPUT_FILE"
    done
fi

cat >> "$OUTPUT_FILE" <<EOF

---

*Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)*
EOF

echo "  ✓ Generated $OUTPUT_FILE"

# Generate HTML if pandoc is available
if command -v pandoc &> /dev/null; then
    HTML_FILE="${TEST_PASS_DIR:-.}/results.html"
    pandoc -f markdown -t html -s -o "$HTML_FILE" "$OUTPUT_FILE" \
        --metadata title="Hole Punch (DCUtR) Interop Results" \
        --css style.css 2>/dev/null || pandoc -f markdown -t html -s -o "$HTML_FILE" "$OUTPUT_FILE"
    echo "  ✓ Generated $HTML_FILE"
else
    echo "  ✗ pandoc not found, skipping HTML generation"
fi
