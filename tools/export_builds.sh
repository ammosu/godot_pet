#!/bin/sh
# Export the macOS and Windows release builds into build/dist/, as the two
# archives a user actually downloads. CI runs this; it works the same locally
# once the 4.7.1 export templates are installed.
#
# The macOS build is exported straight to a .zip rather than a .app: an .app
# is a directory, and anything that re-archives it later (CI artifact upload
# included) drops the executable bit, leaving an app that will not launch.
# Godot writes the bit into its own zip.
#
# Both builds are cross-exported from whatever host runs this. A clean export
# says the packaging step worked, nothing more — see "跨平台" in PLAN.md.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(dirname -- "$script_dir")
godot_bin=${GODOT_BIN:-godot}
dist="$project_root/build/dist"
failure_pattern='SCRIPT ERROR|Parse Error|Failed to load|ERROR:'

rm -rf "$dist" "$project_root/build/windows-export"
mkdir -p "$dist" "$project_root/build/windows-export"

run() {
	label=$1
	shift
	log="$dist/$label.log"
	if ! "$godot_bin" --headless --path "$project_root" "$@" >"$log" 2>&1; then
		echo "$label: Godot exited non-zero" >&2
		cat "$log" >&2
		exit 1
	fi
	if grep -Eq "$failure_pattern" "$log"; then
		echo "$label: errors in the log" >&2
		grep -E "$failure_pattern" "$log" >&2
		exit 1
	fi
}

echo "Importing project resources..."
run import --import

echo "Exporting macOS..."
run macos --export-release "macOS" "$dist/GodotPet-macOS.zip"

echo "Exporting Windows..."
run windows --export-release "Windows" "$project_root/build/windows-export/Godot Pet.exe"
# The .exe and its .pck travel together; zip the pair so they cannot part.
(cd "$project_root/build/windows-export" && zip -qr "$dist/GodotPet-Windows.zip" .)

for f in "$dist"/*.zip; do
	[ -s "$f" ] || { echo "Missing or empty: $f" >&2; exit 1; }
done
echo "Built:"
ls -l "$dist"/*.zip
