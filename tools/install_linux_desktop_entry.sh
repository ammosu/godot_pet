#!/usr/bin/env bash
# Give the pet a real icon in the GNOME dash, the app grid and alt-tab.
#
#   tools/install_linux_desktop_entry.sh            # derive the launch command
#   tools/install_linux_desktop_entry.sh /path/cmd  # or give it one
#
# Run once. The entry points at the PNG the app rewrites on every pack change,
# so the icon then follows the selected pet by itself.
#
# Why this is needed at all, and why setting the window's own icon is not enough:
# `DisplayServer.set_icon()` sets `_NET_WM_ICON`, and **mutter no longer reads
# it**. Measured on GNOME Shell 46 / mutter 46 (Ubuntu 24.04): the property is
# present on the window and the dash still draws Yaru's
# `application-x-executable` cog, because a window matching no desktop entry
# becomes a "window-backed app" with no icon to show. The property is still worth
# setting — Windows and the lighter X11 window managers do use it — but on GNOME
# the only thing that works is being matched to a desktop entry.
#
# That match is by `StartupWMClass`, which is why the name here is read out of
# project.godot rather than written down: the window's WM_CLASS class comes from
# `application/config/name`, and a copy of it here would silently stop matching
# the day that setting is edited. A mismatch has no symptom other than the cog
# coming back.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

APP_NAME=$(sed -n 's/^config\/name="\(.*\)"$/\1/p' project.godot | head -1)
[ -n "$APP_NAME" ] || { echo "Can't read config/name from project.godot" >&2; exit 1; }

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# Where `user://` lands on Linux, and so where AppIcon.EXPORT_PATH is written.
ICON="$DATA_HOME/godot/app_userdata/$APP_NAME/app_icon.png"
APPS="$DATA_HOME/applications"
ENTRY="$APPS/godot-pet.desktop"

# The launcher script exists on machines that run from source so the run log
# stays out of the repo; fall back to invoking Godot directly.
if [ $# -ge 1 ]; then
	EXEC="$1"
elif [ -x "$HOME/.local/bin/godot-pet" ]; then
	EXEC="$HOME/.local/bin/godot-pet"
else
	case "$REPO" in
		*\ *) EXEC="godot --path \"$REPO\"" ;;   # Exec= quotes a path with spaces
		*)    EXEC="godot --path $REPO" ;;
	esac
fi

if [ ! -f "$ICON" ]; then
	echo "Note: $ICON doesn't exist yet — run the pet once and it will appear."
fi

mkdir -p "$APPS"
cat > "$ENTRY" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Transparent always-on-top desktop pet
Exec=$EXEC
Icon=$ICON
Terminal=false
Categories=Utility;
StartupWMClass=$APP_NAME
EOF

command -v update-desktop-database >/dev/null && update-desktop-database "$APPS"

echo "Wrote $ENTRY"
echo "  StartupWMClass=$APP_NAME"
echo "  Icon=$ICON"

# Checking the match is the whole point, and it is silent when wrong. Only
# possible while the pet is running, so this reports rather than fails.
if command -v xprop >/dev/null && command -v xdotool >/dev/null; then
	for w in $(xdotool search --name "$APP_NAME" 2>/dev/null || true); do
		CLASS=$(xprop -id "$w" WM_CLASS 2>/dev/null \
			| sed -n 's/.*, "\(.*\)"$/\1/p')
		[ -n "$CLASS" ] || continue
		if [ "$CLASS" = "$APP_NAME" ]; then
			echo "  matches the running window's WM_CLASS"
		else
			echo "  WARNING: running window's WM_CLASS is '$CLASS', not '$APP_NAME'" >&2
		fi
	done
fi

echo "Already running? Restart it — GNOME matches a window to an entry once."
