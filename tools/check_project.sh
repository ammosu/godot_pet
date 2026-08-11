#!/bin/sh
# Import every resource, then run every headless test scene. A Godot test can
# still exit zero after a runtime error, so both the process status and its log
# are part of the result.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(dirname -- "$script_dir")
godot_bin=${GODOT_BIN:-godot}

if ! command -v "$godot_bin" >/dev/null 2>&1; then
	echo "Godot executable not found: $godot_bin" >&2
	echo "Set GODOT_BIN to the Godot 4.7 executable." >&2
	exit 127
fi

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/godot-pet-check.XXXXXX")
keep_logs=0
cleanup() {
	if [ "$keep_logs" -eq 0 ]; then
		rm -rf "$run_dir"
	fi
}
trap cleanup EXIT HUP INT TERM

failure_pattern='SCRIPT ERROR|Parse Error|Failed to load'
failed=0

echo "Importing project resources..."
import_output="$run_dir/import.out"
if ! "$godot_bin" --headless --import --path "$project_root" \
		--log-file "$run_dir/import.log" >"$import_output" 2>&1; then
	echo "Import command failed." >&2
	failed=1
fi
if grep -Eq "$failure_pattern" "$import_output"; then
	echo "Import reported script or resource errors:" >&2
	grep -E "$failure_pattern" "$import_output" >&2
	failed=1
fi

test_count=0
for scene in "$project_root"/tests/test_*.tscn; do
	[ -e "$scene" ] || continue
	test_count=$((test_count + 1))
	name=$(basename "$scene" .tscn)
	output="$run_dir/$name.out"
	log="$run_dir/$name.log"

	if ! "$godot_bin" --headless --path "$project_root" "$scene" --quit-after 1800 \
			--log-file "$log" >"$output" 2>&1; then
		echo "$name: FAILED (non-zero exit)" >&2
		failed=1
	elif grep -Eq "$failure_pattern" "$output"; then
		echo "$name: FAILED (runtime error in log)" >&2
		failed=1
	elif ! grep -Eq 'passed|tests completed|tests ran to the end' "$output"; then
		echo "$name: FAILED (no completion marker)" >&2
		failed=1
	else
		summary=$(grep -E 'passed|tests completed|tests ran to the end' "$output" | tail -1)
		echo "$name: $summary"
		continue
	fi

	grep -E "$failure_pattern|checks failed|failures across|did not run to the end" \
		"$output" >&2 || tail -40 "$output" >&2
done

if [ "$test_count" -eq 0 ]; then
	echo "No test scenes found under tests/." >&2
	failed=1
fi

if [ "$failed" -ne 0 ]; then
	keep_logs=1
	echo "Project checks failed. Logs: $run_dir" >&2
	exit 1
fi

echo "All project checks passed ($test_count test scenes)."
