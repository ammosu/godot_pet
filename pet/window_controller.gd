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
## that nearly all of it is bubble space. Only a default — see `_anchor`.
const ANCHOR_RATIO := Vector2(0.5, 0.80)

## Dots per inch at 100%. Windows and Linux report a DPI rather than a factor,
## and 96 is the unscaled baseline on both.
const BASE_DPI := 96.0

## How long to wait for the window manager to have its say about a position we
## just asked for. The correction rides in on a ConfigureNotify, so it is not
## visible in the same frame.
const WM_PROBE_FRAMES := 3

## Godot's macOS backend converts physical-pixel positions through integer
## native point coordinates. On a mixed Retina/non-Retina desktop, that round
## trip can move an odd coordinate by one pixel even when macOS honoured it.
const WM_POSITION_TOLERANCE := 1

var _win: Window
var _hit_region := PackedVector2Array()
## The visible pet's extent, *relative to where the pet stands*. The window is
## mostly transparent padding, so every screen-edge calculation uses this rather
## than the window rect — otherwise the pet stops well short of the corner.
## Relative rather than in viewport pixels because the anchor below moves.
var _content_rel := Rect2i()
## Where the pet stands inside the window, in viewport pixels. ANCHOR_RATIO of
## the window size, except where the window could not travel as far as the pet
## needed it to and the pet had to make up the difference on its own.
var _anchor := Vector2i.ZERO
## Where the pet was last asked to stand on the desktop, before any clamping.
## Kept so the move can be redone once the WM's real limits are known.
var _pet_pos := Vector2i.ZERO
var _passthrough_suspended := false
var _ui_scale := 1.0

## Does the window manager force the whole window inside the work area?
##
## GNOME's mutter does, on X11. A 440x760 window asked to sit at (1700, 600)
## lands at (1480, 320), and one asked for (-300, -400) lands at (66, 32) — the
## two corners of _NET_WORKAREA. That defeats the deliberately oversized,
## overhanging window outright: with the pet anchored 220px inside it, the pet
## then stops 220px short of the screen edge and no clamping on our side can move
## it further. The anchor is what gets it the rest of the way.
##
## macOS, and the lighter X11 window managers, put the window where they are
## told. So this is measured rather than assumed — the one clean way to opt out
## of WM management, FLAG_POPUP (override-redirect on X11), is refused for the
## main window by Godot itself: "Main window can't be popup."
var _wm_confines_window := false
var _wm_probed := false
var _wm_probe_frames := 0
var _wm_probe_want := Vector2i.ZERO


func _ready() -> void:
	_win = get_window()
	# Project settings already declare these, but re-applying in code means the
	# scene also behaves correctly when run standalone from the editor.
	get_viewport().transparent_bg = true
	_win.transparent = true
	_win.borderless = true
	_win.always_on_top = true
	_win.files_dropped.connect(_on_files_dropped)
	_apply_dpi_scale()
	# Only ticks while a probe is in flight, which is once per run at most.
	set_process(false)


## Godot reports window size and screen rects in physical pixels, so on a 2x
## Retina display a 320px window is only 160 points wide. Grow the window by the
## display scale and let the visual scale to match, which keeps viewport
## coordinates 1:1 with window pixels — the mouse passthrough region depends on
## that, since DisplayServer expects window pixels.
func _apply_dpi_scale() -> void:
	_ui_scale = display_scale(DisplayServer.get_primary_screen())
	_win.size = Vector2i(Vector2(BASE_SIZE) * _ui_scale)
	_anchor = _default_anchor()
	_content_rel = Rect2i(-_anchor, _win.size)


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
	return _win.position + _anchor


## Move the window so the pet lands on `screen_pos` — and where the window can't
## go that far, move the pet within the window to cover the rest.
func set_pet_screen_position(screen_pos: Vector2i) -> void:
	_pet_pos = screen_pos
	var window_pos := _clamp_window(screen_pos - _default_anchor())
	_anchor = _clamp_anchor(screen_pos - window_pos, window_pos)
	_win.position = window_pos
	_probe_wm(window_pos)
	EventBus.pet_moved.emit(get_pet_screen_position())


## Where the pet stands *inside* the window, in viewport pixels.
func get_window_anchor() -> Vector2:
	return Vector2(_anchor)


func get_window_size() -> Vector2i:
	return _win.size


## The slice of the window that's actually on screen, in viewport pixels. The
## window is allowed to hang off the desktop edge so the pet can reach the
## corner, so UI that must stay readable has to be clamped to this instead.
func get_visible_area() -> Rect2:
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	return Rect2(Vector2(screen.position - _win.position), Vector2(screen.size))


func _default_anchor() -> Vector2i:
	return Vector2i(Vector2(_win.size) * ANCHOR_RATIO)


## Union of every screen, including the menu bar and Dock strips. Dragging is
## limited only by the physical edge of the desktop.
func _desktop_bounds() -> Rect2i:
	var bounds := _screen_rect(0)
	for i in range(1, DisplayServer.get_screen_count()):
		bounds = bounds.merge(_screen_rect(i))
	return bounds


func _screen_rect(screen: int) -> Rect2i:
	return Rect2i(DisplayServer.screen_get_position(screen), DisplayServer.screen_get_size(screen))


func _work_area() -> Rect2i:
	return DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())


## Where the window itself may sit.
##
## Normally the physical desktop, measured on the *visible pet* rather than the
## window rect, which is what lets the transparent padding hang off the edge and
## the pet reach the very corner. Where the WM won't allow that, the window has
## to fit inside the work area instead and the anchor takes over.
func _clamp_window(top_left: Vector2i) -> Vector2i:
	var lo: Vector2i
	var hi: Vector2i
	if _wm_confines_window:
		var area := _work_area()
		lo = area.position
		hi = area.position + area.size - _win.size
	else:
		var bounds := _desktop_bounds()
		var content := _default_anchor() + _content_rel.position
		lo = bounds.position - content
		hi = bounds.position + bounds.size - content - _content_rel.size
	return Vector2i(
		clampi(top_left.x, lo.x, maxi(lo.x, hi.x)),
		clampi(top_left.y, lo.y, maxi(lo.y, hi.y)))


## How far the pet may stand from the window's own origin: far enough to reach
## the desktop edge, but not so far that its silhouette leaves the window, where
## it would simply not be drawn.
##
## Where the window was free to travel this always lands back on the default,
## because the window stopped exactly when the pet hit the desktop edge.
func _clamp_anchor(anchor: Vector2i, window_pos: Vector2i) -> Vector2i:
	var in_window_lo := -_content_rel.position
	var in_window_hi := _win.size - _content_rel.size - _content_rel.position
	var desktop := _desktop_bounds()
	var on_screen_lo := desktop.position - window_pos - _content_rel.position
	var on_screen_hi := desktop.position + desktop.size - window_pos \
		- _content_rel.size - _content_rel.position
	var lo := Vector2i(maxi(in_window_lo.x, on_screen_lo.x), maxi(in_window_lo.y, on_screen_lo.y))
	var hi := Vector2i(mini(in_window_hi.x, on_screen_hi.x), mini(in_window_hi.y, on_screen_hi.y))
	return Vector2i(
		clampi(anchor.x, lo.x, maxi(lo.x, hi.x)),
		clampi(anchor.y, lo.y, maxi(lo.y, hi.y)))


## Ask, once, whether this window manager honours a window that hangs off the
## work area — by watching what becomes of one that does.
##
## Parking at the corner already requests such a position, so the answer arrives
## during startup at no extra cost in movement. A request that was inside the
## work area all along proves nothing, so those are ignored and the question is
## simply asked again on the next move that does overhang.
func _probe_wm(window_pos: Vector2i) -> void:
	if _wm_probed or _work_area().encloses(Rect2i(window_pos, _win.size)):
		return
	_wm_probe_want = window_pos
	_wm_probe_frames = 0
	set_process(true)


func _process(_delta: float) -> void:
	_wm_probe_frames += 1
	if _wm_probe_frames < WM_PROBE_FRAMES:
		return
	set_process(false)
	_wm_probed = true
	var correction := (_win.position - _wm_probe_want).abs()
	if correction.x <= WM_POSITION_TOLERANCE \
			and correction.y <= WM_POSITION_TOLERANCE:
		return
	_wm_confines_window = true
	# Redo the move now that the real limits are known.
	set_pet_screen_position(_pet_pos)


## Min/max pet centre x for wandering. Uses the *usable* rect so the pet doesn't
## stroll behind the Dock on its own — you can still drag it there.
func get_walk_bounds() -> Vector2:
	var rect := DisplayServer.screen_get_usable_rect(DisplayServer.get_primary_screen())
	return Vector2(
		float(rect.position.x - _content_rel.position.x),
		float(rect.position.x + rect.size.x - _content_rel.position.x - _content_rel.size.x))


## Bottom-right of the primary screen, with a small margin — the classic
## desktop-pet resting spot. Measured on the pet, not the window.
func park_at_default_spot() -> void:
	var rect := DisplayServer.screen_get_usable_rect(DisplayServer.get_primary_screen())
	var margin := roundi(16.0 * _ui_scale)
	set_pet_screen_position(rect.position + rect.size - Vector2i(margin, margin)
		- _content_rel.size - _content_rel.position)


# --- Files ---------------------------------------------------------------------

## OS drag-and-drop reaches the whole window regardless of the mouse-
## passthrough mask (see EventBus.files_dropped_on_window), so this can fire
## from anywhere in the window's mostly transparent, overhanging rect — not
## just the visible pet. Report it in window-local pixels, the same frame
## set_hit_region() works in, and let pet.gd, which owns the pet's
## silhouette, decide whether it actually landed on the pet.
func _on_files_dropped(files: PackedStringArray) -> void:
	var local := Vector2(DisplayServer.mouse_get_position() - _win.position)
	EventBus.files_dropped_on_window.emit(files, local)


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


## The pet's visible extent, measured relative to where the pet itself stands.
## Used for every screen-edge calculation. Relative because the anchor moves near
## an edge, which would leave a rect in viewport pixels stale the moment it did.
##
## Kept separate from the hit region, which grows to cover chat UI and would
## otherwise drag the pet away from the screen edge.
func set_content_bounds(rect: Rect2) -> void:
	_content_rel = Rect2i(rect.abs()) if rect.has_area() else Rect2i(-_anchor, _win.size)


## Make the whole window catch input. Used while dragging: a fast mouse move can
## outrun the hit region, and losing the motion events would drop the drag.
func suspend_passthrough() -> void:
	_passthrough_suspended = true
	DisplayServer.window_set_mouse_passthrough(PackedVector2Array())


func resume_passthrough() -> void:
	_passthrough_suspended = false
	DisplayServer.window_set_mouse_passthrough(_hit_region)
