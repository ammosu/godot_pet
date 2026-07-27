#!/usr/bin/env bash
# Rebuild the exported app's Dock icon from whichever pet is currently selected,
# so the icon matches what's actually on the desktop.
#
# Run after exporting:
#   godot --headless --path . --export-release "macOS" "build/Godot Pet.app"
#   tools/make_app_icon.sh
#
# The sprite is NOT copied into the repo. Packs are third-party art licensed for
# personal, non-commercial use, so the icon it produces belongs to your local
# build only — don't hand the .app to anyone else with a pet's face on it.
# Without this script the app keeps the project's own icon.svg, which does ship.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-build/Godot Pet.app}"
CONFIG="$HOME/Library/Application Support/Godot/app_userdata/Godot Pet/config.cfg"
PETS="$HOME/.codex/pets"

[ -d "$APP" ] || { echo "No app at $APP — export it first." >&2; exit 1; }

PET_ID=$(sed -n 's/^id="\(.*\)"$/\1/p' "$CONFIG" 2>/dev/null | head -1)
[ -n "$PET_ID" ] || { echo "No pet selected; the app keeps icon.svg." >&2; exit 0; }

SHEET="$PETS/$PET_ID/spritesheet.webp"
[ -f "$SHEET" ] || { echo "No spritesheet for '$PET_ID' at $SHEET" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$SHEET" "$WORK/icon_1024.png" <<'PY'
import sys
from PIL import Image

sheet = Image.open(sys.argv[1]).convert("RGBA")
cols, rows = 8, 9
cw, ch = sheet.width // cols, sheet.height // rows

# Row 0 is idle everywhere this format is used; frame 0 is the resting pose.
frame = sheet.crop((0, 0, cw, ch))
box = frame.getbbox()
if box:
    frame = frame.crop(box)

# Square it on the character's own centre, then scale up by nearest neighbour so
# the pixel art stays crisp at Dock sizes. Barely any padding: macOS adds its own
# rounded container and insets on top, and the character ends up small otherwise.
side = int(max(frame.width, frame.height) * 1.02)
canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
canvas.paste(frame, ((side - frame.width) // 2, (side - frame.height) // 2))
canvas.resize((1024, 1024), Image.NEAREST).save(sys.argv[2])
PY

ICONSET="$WORK/pet.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
	sips -z $SIZE $SIZE "$WORK/icon_1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
	sips -z $((SIZE * 2)) $((SIZE * 2)) "$WORK/icon_1024.png" \
		--out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK/icon.icns"

cp "$WORK/icon.icns" "$APP/Contents/Resources/icon.icns"
# Replacing a file inside a signed bundle invalidates the signature.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

# The Dock caches by path and mtime; touching the bundle makes it re-read.
touch "$APP"
echo "Icon rebuilt from '$PET_ID'."
