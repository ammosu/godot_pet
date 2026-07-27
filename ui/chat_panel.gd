extends Control
class_name ChatPanel

## Speech bubble + text input, laid out around the pet inside the transparent
## window.
##
## Geometry is set from code rather than the scene file because it depends on
## the display's DPI and on how big the pet currently is — neither of which the
## editor knows.

signal submitted(text: String)
## A value typed into the masked input — a key, not something to say.
signal secret_submitted(text: String)
signal input_toggled(open: bool)
## The line finished being read and faded away.
signal bubble_hidden

const CHAT_PLACEHOLDER := "跟我說說話…"

enum InputMode { CHAT, SECRET }

## Design-unit sizes; everything is multiplied by the display scale.
const BUBBLE_MAX_WIDTH := 300.0
const BUBBLE_MIN_WIDTH := 130.0
const BUBBLE_PADDING := 12.0
const BUBBLE_CORNER := 14.0
const TAIL_WIDTH := 18.0
const TAIL_HEIGHT := 11.0
## The bubble's drop shadow spreads this far past the panel, and this far down.
const BUBBLE_SHADOW := 6.0
const BUBBLE_SHADOW_DROP := 2.0
const GAP_ABOVE_PET := 10.0
const SIDE_MARGIN := 12.0
const INPUT_HEIGHT := 34.0

## Typewriter speed. Chunks arrive faster than this, so text queues up and reads
## at a steady pace instead of appearing in bursts.
const CHARS_PER_SECOND := 32.0
## How long a finished line stays up: a base plus reading time, capped.
const HOLD_BASE := 2.5
const HOLD_PER_CHAR := 0.09
## A long reply has to stay up long enough to actually be read to the end.
const HOLD_MAX := 22.0
const FADE_TIME := 0.4

@onready var _bubble: PanelContainer = $Bubble
@onready var _text: RichTextLabel = $Bubble/Text
@onready var _input: LineEdit = $Input

var _scale := 1.0
## Where the pet is drawn, in viewport pixels.
var _pet_rect := Rect2()
## The part of the window that's actually on screen, in viewport pixels. The
## window deliberately hangs off the desktop edge so the pet can reach the
## corner, which would otherwise push the bubble and the input out of sight.
var _safe_area := Rect2()

var _input_mode := InputMode.CHAT
var _full_text := ""
var _shown := 0.0
var _streaming := false
var _hold := 0.0
var _fade: Tween = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.visible = false
	_input.visible = false
	_input.text_submitted.connect(_on_submitted)
	_set_input_mode(InputMode.CHAT)


## Call once the display scale is known, and again whenever the pet resizes.
func configure(ui_scale: float, window_size: Vector2i, pet_rect: Rect2) -> void:
	_scale = ui_scale
	_pet_rect = pet_rect
	position = Vector2.ZERO
	size = Vector2(window_size)

	_bubble.add_theme_stylebox_override("panel", _make_bubble_style())
	_text.add_theme_font_size_override("normal_font_size", roundi(15.0 * _scale))
	_text.add_theme_color_override("default_color", Color("1d2733"))
	# The bubble grows upward from the pet's head, so an over-long reply would
	# run off the top of the window and get clipped. Drive the height manually
	# instead and let the text scroll once it hits the ceiling.
	_text.fit_content = false
	_text.scroll_active = true
	_text.scroll_following = true

	_input.add_theme_font_size_override("font_size", roundi(15.0 * _scale))
	_relayout()


## The window moves as the pet walks, so how much of it is on screen changes.
func set_safe_area(area: Rect2) -> void:
	_safe_area = area
	_relayout()


func _relayout() -> void:
	_layout_input()
	_reposition_bubble()


## The area the chat UI is allowed to occupy: the window, minus whatever hangs
## off the edge of the screen.
func _limits() -> Rect2:
	var window_rect := Rect2(Vector2.ZERO, size)
	if not _safe_area.has_area():
		return window_rect
	var visible := window_rect.intersection(_safe_area)
	return visible if visible.has_area() else window_rect


## Sits just under the pet's feet, pulled back on screen if that would fall below
## the desktop.
func _layout_input() -> void:
	var limit := _limits()
	var margin := SIDE_MARGIN * _scale
	var height := INPUT_HEIGHT * _scale
	_input.size = Vector2(maxf(height, limit.size.x - margin * 2.0), height)

	var lowest := limit.end.y - margin - height
	var y := clampf(_pet_rect.end.y + margin, limit.position.y + margin, maxf(limit.position.y, lowest))
	_input.position = Vector2(limit.position.x + margin, y)


func _make_bubble_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1.0, 1.0, 1.0, 0.96)
	box.border_color = Color(0.0, 0.0, 0.0, 0.12)
	box.set_border_width_all(roundi(1.0 * _scale))
	box.set_corner_radius_all(roundi(BUBBLE_CORNER * _scale))
	box.set_content_margin_all(BUBBLE_PADDING * _scale)
	box.shadow_color = Color(0.0, 0.0, 0.0, 0.18)
	box.shadow_size = roundi(BUBBLE_SHADOW * _scale)
	box.shadow_offset = Vector2(0.0, BUBBLE_SHADOW_DROP * _scale)
	return box


func _process(delta: float) -> void:
	if not _bubble.visible:
		return
	_reposition_bubble()
	_advance_typing(delta)


# --- Bubble -------------------------------------------------------------------

## Start a fresh line. Called when the pet begins replying.
func begin_reply() -> void:
	_kill_fade()
	_full_text = ""
	_shown = 0.0
	_streaming = true
	_hold = 0.0
	_text.text = ""
	_text.visible_characters = 0
	_bubble.visible = true
	_bubble.modulate.a = 1.0


func append_reply(chunk: String) -> void:
	if not _streaming:
		begin_reply()
	_full_text += chunk
	_text.text = _full_text


func end_reply() -> void:
	_streaming = false


## Show a line immediately, with no typewriter — for errors and system notes.
func show_notice(message: String) -> void:
	begin_reply()
	_full_text = message
	_text.text = message
	_shown = float(message.length())
	_text.visible_characters = -1
	_streaming = false


func hide_bubble() -> void:
	if not _bubble.visible:
		return
	_kill_fade()
	_streaming = false
	_bubble.visible = false
	bubble_hidden.emit()


func is_showing() -> bool:
	return _bubble.visible


func _advance_typing(delta: float) -> void:
	var total := float(_full_text.length())
	if _shown < total:
		_shown = minf(total, _shown + CHARS_PER_SECOND * delta)
		_text.visible_characters = int(_shown)
		return

	_text.visible_characters = -1
	if _streaming or _fade != null:
		return
	# Caught up and nothing more is coming: start the countdown to fading out.
	if _hold <= 0.0:
		_hold = minf(HOLD_MAX, HOLD_BASE + total * HOLD_PER_CHAR)
	_hold -= delta
	if _hold <= 0.0:
		_start_fade()


func _start_fade() -> void:
	_fade = create_tween()
	_fade.tween_property(_bubble, "modulate:a", 0.0, FADE_TIME)
	_fade.tween_callback(hide_bubble)


func _kill_fade() -> void:
	if _fade != null:
		_fade.kill()
		_fade = null


## The bubble sizes itself to its text, so its position has to follow.
func _reposition_bubble() -> void:
	var limit := _limits()
	var margin := SIDE_MARGIN * _scale
	var padding := BUBBLE_PADDING * 2.0 * _scale
	var tail := _tail_point()

	# Narrow the bubble when the window is half off the screen, otherwise it
	# would be clamped flush to the edge and still overflow. Width first: the
	# text height below depends on it.
	var width := clampf(limit.size.x - margin * 2.0,
		BUBBLE_MIN_WIDTH * _scale, BUBBLE_MAX_WIDTH * _scale)
	_text.custom_minimum_size.x = maxf(1.0, width - padding)

	# The bubble grows upward from the pet's head; cap it at the space actually
	# available so it can't run off the top, and let the text scroll instead.
	var ceiling := tail.y - (GAP_ABOVE_PET + TAIL_HEIGHT) * _scale - (limit.position.y + margin)
	_text.custom_minimum_size.y = clampf(
		float(_text.get_content_height()), 0.0, maxf(0.0, ceiling - padding))

	var box := _bubble.get_combined_minimum_size()
	_bubble.size = box
	var min_x := limit.position.x + margin
	var min_y := limit.position.y + margin
	var x := clampf(tail.x - box.x * 0.5, min_x, maxf(min_x, limit.end.x - box.x - margin))
	var y := maxf(min_y, tail.y - (GAP_ABOVE_PET + TAIL_HEIGHT) * _scale - box.y)
	_bubble.position = Vector2(x, y)
	queue_redraw()


## Where the bubble points: the top-centre of the pet.
func _tail_point() -> Vector2:
	return Vector2(_pet_rect.get_center().x, _pet_rect.position.y)


func _draw() -> void:
	if not _bubble.visible:
		return
	var top := _bubble.position.y + _bubble.size.y
	var tip_y := top + TAIL_HEIGHT * _scale
	# Keep the tail attached to the bubble even when the bubble got pushed
	# sideways by the window edge.
	var tip_x := clampf(_tail_point().x,
		_bubble.position.x + TAIL_WIDTH * _scale,
		_bubble.position.x + _bubble.size.x - TAIL_WIDTH * _scale)
	var half := TAIL_WIDTH * 0.5 * _scale
	var tail := PackedVector2Array([
		Vector2(tip_x - half, top - 1.0),
		Vector2(tip_x + half, top - 1.0),
		Vector2(tip_x, tip_y),
	])
	draw_colored_polygon(tail, Color(1.0, 1.0, 1.0, 0.96 * _bubble.modulate.a))


# --- Input --------------------------------------------------------------------

func toggle_input() -> void:
	set_input_open(not _input.visible)


func set_input_open(open: bool) -> void:
	if _input.visible == open:
		return
	_input.visible = open
	if open:
		_input.grab_focus()
	else:
		_input.release_focus()
		_input.text = ""
		_set_input_mode(InputMode.CHAT)
	input_toggled.emit(open)


## Open the input masked, for a key rather than a sentence. Reverts to chat as
## soon as it's submitted or dismissed, so the pet can't end up quietly
## swallowing conversation into a settings field.
func ask_for_secret(placeholder: String) -> void:
	_set_input_mode(InputMode.SECRET, placeholder)
	if _input.visible:
		_input.grab_focus()
	else:
		set_input_open(true)


func _set_input_mode(mode: InputMode, placeholder := CHAT_PLACEHOLDER) -> void:
	_input_mode = mode
	_input.secret = mode == InputMode.SECRET
	_input.placeholder_text = placeholder
	_input.text = ""


func is_input_open() -> bool:
	return _input.visible


## Viewport-space rect that must receive clicks. Empty when the input is closed —
## the bubble is display-only, so it stays click-through.
func get_input_rect() -> Rect2:
	if not _input.visible:
		return Rect2()
	return Rect2(_input.position, _input.size)


## Viewport-space rect covering everything this panel currently *draws* — the
## bubble with its tail and shadow, plus the input when it's open. Empty when
## nothing is showing.
##
## Deliberately separate from get_input_rect(): that one answers "what has to
## catch clicks", this one answers "what has to stay visible". They only differ
## where the passthrough mask also clips rendering — see
## WindowController.passthrough_clips_rendering().
func get_chrome_rect() -> Rect2:
	var box := get_input_rect()
	if not _bubble.visible:
		return box
	# The tail is drawn by this node rather than the panel, hanging below it, so
	# the panel's own rect isn't enough.
	var bubble := Rect2(_bubble.position,
		_bubble.size + Vector2(0.0, TAIL_HEIGHT * _scale)) \
		.grow((BUBBLE_SHADOW + BUBBLE_SHADOW_DROP) * _scale)
	return bubble if not box.has_area() else box.merge(bubble)


func _on_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	_input.text = ""
	if trimmed.is_empty():
		return
	if _input_mode == InputMode.SECRET:
		_set_input_mode(InputMode.CHAT)
		secret_submitted.emit(trimmed)
	else:
		submitted.emit(trimmed)


func _unhandled_key_input(event: InputEvent) -> void:
	if not _input.visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		set_input_open(false)
		get_viewport().set_input_as_handled()
