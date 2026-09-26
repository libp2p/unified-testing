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
# Hole Punch Interoperability Test Results

## Test Pass: \`$test_pass\`

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

| Test | Dialer | Listener | Transport | Status | Duration |
|------|--------|----------|-----------|--------|----------|
EOF

# Read test count
TEST_COUNT=$(yq eval '.tests | length' "$RESULTS_FILE")

# Declare associative arrays for fast lookups in matrix generation
declare -A test_status_map
declare -A test_transport_map

# Only process tests if there are any
if [ "$TEST_COUNT" -gt 0 ]; then
    # Export all test data as TSV in one yq call (much faster than individual calls)
    test_data=$(yq eval '.tests[] | [.name, .status, .dialer, .listener, .transport, .duration] | @tsv' "$RESULTS_FILE")

    # Process each test and build both the table and hash maps
    while IFS=$'\t' read -r name status dialer listener transport test_duration; do

        # Store in hash maps for later matrix lookup
        test_status_map["$name"]="$status"
        test_transport_map["$name"]="$transport"

        # Status icon
        if [ "$status" == "pass" ]; then
            status_icon="✅"
        else
            status_icon="❌"
        fi

        echo "| $name | $dialer | $listener | $transport | $status_icon | $test_duration |" >> "$LATEST_RESULTS_FILE"
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
# Hole Punch Interoperability Test Results

## Test Pass: \`$test_pass\`

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

## Latest Test Results

See [Latest Test Results](LATEST_TEST_RESULTS.md) for detailed results table.

---

## Legend

- ✅ Test passed
- ❌ Test failed
- Matrix cells aggregate all transports/relays for the pair: ✅n ❌m = n passed, m failed

---

## Matrix View

EOF

# Only generate matrix view if there are tests
if [ "$TEST_COUNT" -gt 0 ]; then
    # Generate matrix view (dialer x listener grid)
    # Get unique dialers and listeners
    dialers=$(yq eval '.tests[].dialer' "$RESULTS_FILE" | sort -u)
    listeners=$(yq eval '.tests[].listener' "$RESULTS_FILE" | sort -u)

# Create header row
echo -n "| Dialer \\ Listener |" >> "$OUTPUT_FILE"
for listener in $listeners; do
    echo -n " $listener |" >> "$OUTPUT_FILE"
done
echo "" >> "$OUTPUT_FILE"

# Create separator row
echo -n "|---|" >> "$OUTPUT_FILE"
for listener in $listeners; do
    echo -n "---|" >> "$OUTPUT_FILE"
done
echo "" >> "$OUTPUT_FILE"

# Create data rows
for dialer in $dialers; do
    echo -n "| **$dialer** |" >> "$OUTPUT_FILE"

    for listener in $listeners; do
        # Aggregate all tests for this dialer x listener pair. Test IDs
        # carry extra dimensions (secure channel, muxer, relay, routers),
        # so an exact "$dialer x $listener ($transport)" key never matches.
        # Match on the "<dialer> x <listener> (" prefix instead.
        pass_count=0
        fail_count=0
        for key in "${!test_status_map[@]}"; do
            case "$key" in
                "$dialer x $listener ("*)
                    if [ "${test_status_map[$key]}" == "pass" ]; then
                        pass_count=$((pass_count + 1))
                    else
                        fail_count=$((fail_count + 1))
                    fi
                    ;;
            esac
        done

        if [ "$pass_count" -gt 0 ] || [ "$fail_count" -gt 0 ]; then
            result="✅${pass_count} ❌${fail_count}"
        else
            result="-"
        fi

        echo -n " $result |" >> "$OUTPUT_FILE"
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
        --metadata title="Hole Punch Interop Results" \
        --css style.css 2>/dev/null || pandoc -f markdown -t html -s -o "$HTML_FILE" "$OUTPUT_FILE"
    echo "  ✓ Generated $HTML_FILE"
else
    echo "  ✗ pandoc not found, skipping HTML generation"
fi
