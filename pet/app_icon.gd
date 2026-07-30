extends RefCounted
class_name AppIcon

## Makes the app's icon out of whichever pet is currently selected, so the thing
## in the taskbar is the same character that's on the desktop.
##
## This runs in-engine rather than in `tools/make_app_icon.sh`, and the two are
## deliberately different tools for different jobs. The script rewrites an
## *exported* macOS bundle's `.icns` after the fact, because a Dock icon is read
## from the bundle and nothing the running process does can change it. Everywhere
## else the icon is a live window property — `_NET_WM_ICON` on X11, the window
## class icon on Windows — so it can simply be set, and set again the moment the
## user picks a different pet. No export step, no script to remember.
##
## Derived art is written to `user://`, never into the repo. Community packs are
## the user's own install and their licensing is between them and the pack's
## author; an icon cut out of one belongs only to this machine. See the same note
## in `tools/make_app_icon.sh`.

## Written for a desktop entry's `Icon=` to point at. A stable path rewritten in
## place, so the entry is edited once and then follows the selected pet by itself.
const EXPORT_PATH := "user://app_icon.png"
## The project-owned mascot, used when there is no pack to cut a frame out of.
const BUNDLED_PATH := "res://icon.png"

## **`DisplayServer.set_icon()` silently does nothing above a certain size on
## X11**, and it is the *icon* that is too big, not the image — no error, nothing
## in the log, and `_NET_WM_ICON` simply stays empty, which reads as the call
## having been forgotten rather than refused. Measured on Xvfb with Godot 4.7.1:
## 64, 96, 128, 192 and 224 square all set the property; 254, 255 and 256 all
## leave it empty. The cliff is somewhere in between and its cause was not
## established, so this stays well clear of it rather than sitting one measurement
## away from a failure that is invisible.
##
## 128 is also what a taskbar or alt-tab switcher actually draws, so the room
## above it buys nothing.
const WM_SIZE := 128
## The PNG is a file, subject to none of the above, and a desktop entry's icon can
## be drawn large. Keep the detail the window property can't carry.
const FILE_SIZE := 256

## Barely any padding. A window manager adds its own inset on top, and the
## character ends up looking small inside its own icon otherwise.
const PADDING := 1.02


## Point the app's icon at `pack`'s resting pose. `idle_row` is the *resolved*
## row from `PetVisual.state_rows()`, not a guess: the per-pet `[pet_rows]`
## corrections and the fallback for a state a pack has no art for both land
## there, and an icon cut from the wrong row is a pet mid-pounce or a bare prop.
##
## Pass a null pack — the emergency-blob case — to fall back to the bundled
## mascot, so there is no state in which the app has no icon at all.
static func apply(pack: PetPack, idle_row: int) -> void:
	var smooth := pack.smooth_filter if pack != null else true
	var frame := _cropped(pack, idle_row)
	if frame == null:
		frame = _bundled()
		# The bundled mascot is hand-drawn whatever the pack that failed was.
		smooth = true
	if frame == null:
		return
	DisplayServer.set_icon(_scaled(frame, WM_SIZE, smooth))
	# Only a desktop entry reads this, and only on Linux, but writing it
	# unconditionally keeps the file in step with the live icon everywhere rather
	# than only on the platform that currently happens to consume it.
	_scaled(frame, FILE_SIZE, smooth).save_png(EXPORT_PATH)


## Absolute path to the written PNG, for a desktop entry or a shortcut.
static func exported_path() -> String:
	return ProjectSettings.globalize_path(EXPORT_PATH)


## The pet's resting frame, cropped to the pixels it actually draws.
static func _cropped(pack: PetPack, idle_row: int) -> Image:
	if pack == null or pack.frames == null or not pack.has_row(idle_row):
		return null
	var texture := pack.frames.get_frame_texture(PetPack.row_anim(idle_row), 0) \
		as AtlasTexture
	if texture == null or texture.atlas == null:
		return null
	var sheet := texture.atlas.get_image()
	if sheet == null:
		return null
	if sheet.get_format() != Image.FORMAT_RGBA8:
		sheet.convert(Image.FORMAT_RGBA8)

	# Frame 0's own bounding box, not `rect_for_row`'s union over the row. The
	# union has to cover every frame of the animation, which for a walk cycle is
	# wider than any single pose — and this only ever shows one pose.
	var cell := sheet.get_region(Rect2i(texture.region))
	var box := cell.get_used_rect()
	if box.size.x <= 0 or box.size.y <= 0:
		return null
	return cell.get_region(box)


## Centre the character on its own square before scaling, so a tall pet and a
## wide one both end up filling the icon rather than one being letterboxed.
static func _scaled(frame: Image, side_px: int, smooth: bool) -> Image:
	var side := int(maxi(frame.get_width(), frame.get_height()) * PADDING)
	var canvas := Image.create_empty(side, side, false, Image.FORMAT_RGBA8)
	canvas.blit_rect(frame, Rect2i(Vector2i.ZERO, frame.get_size()),
		(Vector2i(side, side) - frame.get_size()) / 2)
	# The bundled mascot is hand-drawn and wants a smooth resample; a community
	# pack is pixel art, where anything but nearest neighbour turns the outline to
	# mush at icon sizes. `smooth_filter` is the same flag the sprite is drawn
	# with, so the icon can never disagree with the pet about which it is.
	canvas.resize(side_px, side_px,
		Image.INTERPOLATE_LANCZOS if smooth else Image.INTERPOLATE_NEAREST)
	return canvas


static func _bundled() -> Image:
	var texture := load(BUNDLED_PATH) as Texture2D
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null:
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image
