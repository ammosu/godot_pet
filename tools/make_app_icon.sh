#!/usr/bin/env bash
# Rebuild the exported app's Dock icon from whichever pet is currently selected,
# so the icon matches what's actually on the desktop.
#
# Run after exporting:
#   godot --headless --path . --export-release "macOS" "build/Godot Pet.app"
#   tools/make_app_icon.sh
#
# The bundled default uses the project-owned Sprig Tail icon. Community-pack
# sprites are never copied into the repo; an icon derived from one belongs only
# to the user's local build and should not be redistributed with that artwork.
# Without this script every exported app keeps the bundled mascot icon.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-build/Godot Pet.app}"
CONFIG="$HOME/Library/Application Support/Godot/app_userdata/Godot Pet/config.cfg"
PETS="$HOME/.codex/pets"

[ -d "$APP" ] || { echo "No app at $APP — export it first." >&2; exit 1; }

PET_ID=$(sed -n 's/^id="\(.*\)"$/\1/p' "$CONFIG" 2>/dev/null | head -1)
[ -n "$PET_ID" ] || PET_ID="__default__"

if [ "$PET_ID" = "__default__" ]; then
	SOURCE="icon.png"
	SOURCE_KIND="icon"
	[ -f "$SOURCE" ] || { echo "No bundled mascot icon at $SOURCE" >&2; exit 1; }
else
	SOURCE="$PETS/$PET_ID/spritesheet.webp"
	SOURCE_KIND="sheet"
	[ -f "$SOURCE" ] || { echo "No spritesheet for '$PET_ID' at $SOURCE" >&2; exit 1; }
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$SOURCE" "$WORK/icon_1024.png" "$SOURCE_KIND" <<'PY'
import sys
from PIL import Image

source = Image.open(sys.argv[1]).convert("RGBA")
if sys.argv[3] == "icon":
    source.resize((1024, 1024), Image.Resampling.LANCZOS).save(sys.argv[2])
    raise SystemExit

sheet = source
cols = 8
if sheet.width % cols:
    raise SystemExit(f"spritesheet width {sheet.width} is not divisible by {cols}")
cw = sheet.width // cols
if cw * 208 % 192:
    raise SystemExit(f"cell width {cw} cannot produce a whole 192:208 cell")
ch = cw * 208 // 192
if sheet.height % ch:
    raise SystemExit(f"spritesheet height {sheet.height} is not divisible by cell height {ch}")

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
if [ "$PET_ID" = "__default__" ]; then
	echo "Icon rebuilt from the bundled Sprig Tail mascot."
else
	echo "Icon rebuilt from '$PET_ID'."
fi
