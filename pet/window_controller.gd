extends Node
class_name WindowController

## Owns everything about the OS window: per-pixel transparency, always-on-top,
## where the window sits on the desktop, and which part of it actually eats
## mouse clicks (everything else falls through to the app behind).
##
## Nothing else in the project should touch `get_window()` directly.

## Design size of the pet window, in DPI-independent units.
##
## Far larger than the pet, because the speech bubble grows upward from its head
## and is clipped by the window, not by the screen — at 440 tall the bubble ran
## out of room after a few lines and started scrolling away text while most of
## the display sat empty. The extra area is transparent and click-through, so it
## costs nothing but fill rate.
const BASE_SIZE := Vector2i(440, 760)

## Where the pet stands inside the window: centred horizontally, and low enough
## that nearly all of it is bubble space.
const ANCHOR_RATIO := Vector2(0.5, 0.80)

## Dots per inch at 100%. Windows and Linux report a DPI rather than a factor,
## and 96 is the unscaled baseline on both.
const BASE_DPI := 96.0

var _win: Window
var _hit_region := PackedVector2Array()
## Where the visible pet sits inside the window, in viewport pixels. The window
## is mostly transparent padding, so all screen-edge maths uses this instead —
## otherwise the pet stops well short of the corner.
var _content_rect := Rect2i()
var _passthrough_suspended := false
var _ui_scale := 1.0


func _ready() -> void:
	_win = get_window()
	# Project settings already declare these, but re-applying in code means the
	# scene also behaves correctly when run standalone from the editor.
	get_viewport().transparent_bg = true
	_win.transparent = true
	_win.borderless = true
	_win.always_on_top = true
	_apply_dpi_scale()


## Godot reports window size and screen rects in physical pixels, so on a 2x
## Retina display a 320px window is only 160 points wide. Grow the window by the
## display scale and let the visual scale to match, which keeps viewport
## coordinates 1:1 with window pixels — the mouse passthrough region depends on
## that, since DisplayServer expects window pixels.
func _apply_dpi_scale() -> void:
	_ui_scale = display_scale(DisplayServer.get_primary_screen())
	_win.size = Vector2i(Vector2(BASE_SIZE) * _ui_scale)
	_content_rect = Rect2i(Vector2i.ZERO, _win.size)


## How much bigger than its design size everything has to be drawn.
##
## `screen_get_scale()` is implemented on **macOS only**. Everywhere else it
## returns 1.0 no matter what the desktop is set to, which left the pet and the
## right-click menu drawn at design size on a 125% Windows display — correct in
## pixels, and visibly too small. Windows and Linux report a DPI instead, so fall
## back to that.
##
## The result is deliberately not rounded to a whole number. Pixel art prefers
## integer scales, but 125% means 125%: snapping to 1.0 is the bug this replaces,
## and snapping to 2.0 would make the pet enormous.
static func display_scale(screen: int) -> float:
	var scale := DisplayServer.screen_get_scale(screen)
	if scale > 1.0:
		return scale
	var dpi := DisplayServer.screen_get_dpi(screen)
	return maxf(1.0, float(dpi) / BASE_DPI) if dpi > 0 else 1.0


func get_ui_scale() -> float:
	return _ui_scale


# --- Position -----------------------------------------------------------------

## Absolute desktop position of the pet.
func get_pet_screen_position() -> Vector2i:
	return _win.position + _anchor_offset()


## Move the window so the pet lands on `screen_pos`.
func set_pet_screen_position(screen_pos: Vector2i) -> void:
	_win.position = _clamp_to_desktop(screen_pos - _anchor_offset())
	EventBus.pet_moved.emit(get_pet_screen_position())


## Where the pet stands *inside* the window, in viewport pixels.
func get_window_anchor() -> Vector2:
	return Vector2(_win.size) * ANCHOR_RATIO


func get_window_size() -> Vector2i:
	return _win.size


## The slice of the window that's actually on screen, in viewport pixels. The
## window is allowed to hang off the desktop edge so the pet can reach the
## corner, so UI that must stay readable has to be clamped to this instead.
func get_visible_area() -> Rect2:
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	return Rect2(Vector2(screen.position - _win.position), Vector2(screen.size))


func _anchor_offset() -> Vector2i:
	return Vector2i(get_window_anchor())


## Union of every screen, including the menu bar and Dock strips. Dragging is
## limited only by the physical edge of the desktop.
func _desktop_bounds() -> Rect2i:
	var bounds := _screen_rect(0)
	for i in range(1, DisplayServer.get_screen_count()):
		bounds = bounds.merge(_screen_rect(i))
	return bounds


func _screen_rect(screen: int) -> Rect2i:
	return Rect2i(DisplayServer.screen_get_position(screen), DisplayServer.screen_get_size(screen))


## Keep the *visible pet* on the desktop; the transparent window is free to hang
## off the edge, which is what lets the pet reach the very corner.
func _clamp_to_desktop(top_left: Vector2i) -> Vector2i:
	var bounds := _desktop_bounds()
	var min_pos := bounds.position - _content_rect.position
	var max_pos := bounds.position + bounds.size - _content_rect.size - _content_rect.position
	return Vector2i(
		clampi(top_left.x, min_pos.x, maxi(min_pos.x, max_pos.x)),
		clampi(top_left.y, min_pos.y, maxi(min_pos.y, max_pos.y)))


## Min/max pet centre x for wandering. Uses the *usable* rect so the pet doesn't
## stroll behind the Dock on its own — you can still drag it there.
func get_walk_bounds() -> Vector2:
	var rect := DisplayServer.screen_get_usable_rect(DisplayServer.get_primary_screen())
	var anchor_x := float(_anchor_offset().x)
	return Vector2(
		rect.position.x + anchor_x - float(_content_rect.position.x),
		rect.position.x + rect.size.x + anchor_x - float(_content_rect.end.x))


## Bottom-right of the primary screen, with a small margin — the classic
## desktop-pet resting spot. Measured on the pet, not the window.
func park_at_default_spot() -> void:
	var rect := DisplayServer.screen_get_usable_rect(DisplayServer.get_primary_screen())
	var margin := roundi(16.0 * _ui_scale)
	var content_pos := rect.position + rect.size - Vector2i(margin, margin) - _content_rect.size
	set_pet_screen_position(content_pos - _content_rect.position + _anchor_offset())


# --- Click-through ------------------------------------------------------------

## Does the passthrough mask clip what the window *draws*, as well as what it
## catches?
##
## Windows implements window_set_mouse_passthrough() with SetWindowRgn(), which
## sets the window region outright — anything outside it is neither clickable nor
## drawn. macOS and Linux shape input alone, so there the mask can stay tight to
## the pet and let the rest of the window still render.
##
## Callers that draw outside the pet's silhouette — the speech bubble — have to
## widen the mask when this is true, or they are silently invisible.
static func passthrough_clips_rendering() -> bool:
	return OS.get_name() == "Windows"


## `points` are in viewport coordinates. Clicks inside reach us; clicks outside
## go to whatever is behind the window.
##
## Re-pushing an unchanged region is skipped: where the mask clips rendering it
## has to track the bubble frame by frame, and SetWindowRgn() forces a redraw
## every time it is called.
func set_hit_region(points: PackedVector2Array) -> void:
	if points == _hit_region:
		return
	_hit_region = points
	if not _passthrough_suspended:
		DisplayServer.window_set_mouse_passthrough(_hit_region)


## The pet's visible extent inside the window, used for every screen-edge
## calculation. Kept separate from the hit region, which grows to cover chat UI
## and would otherwise drag the pet away from the screen edge.
func set_content_bounds(rect: Rect2) -> void:
	_content_rect = Rect2i(rect.abs()) if rect.has_area() else Rect2i(Vector2i.ZERO, _win.size)


## Make the whole window catch input. Used while dragging: a fast mouse move can
## outrun the hit region, and losing the motion events would drop the drag.
func suspend_passthrough() -> void:
	_passthrough_suspended = true
	DisplayServer.window_set_mouse_passthrough(PackedVector2Array())


func resume_passthrough() -> void:
	_passthrough_suspended = false
	DisplayServer.window_set_mouse_passthrough(_hit_region)
