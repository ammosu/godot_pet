extends Control
class_name ChatPanel

## Speech bubble + text input, laid out around the pet inside the transparent
## window.
##
## Geometry is set from code rather than the scene file because it depends on
## the display's DPI and on how big the pet currently is — neither of which the
## editor knows. Colours and edges all come from PetStyle.

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
## Small enough that a two-word reply gets a two-word bubble. The bubble is sized
## to its text now, so this is a floor rather than the usual width.
const BUBBLE_MIN_WIDTH := 76.0
## While waiting for the first token there is nothing to measure, so the bubble
## holds this width and shows three breathing dots.
const BUBBLE_WAITING_WIDTH := 74.0
const GAP_ABOVE_PET := 10.0
const SIDE_MARGIN := 12.0
const INPUT_HEIGHT := 38.0
## The bubble tops out at 300; an input running the full width of a 440-wide
## window under it looks like a different piece of software.
const INPUT_MAX_WIDTH := 320.0

## Typewriter speed. Chunks arrive faster than this, so text queues up and reads
## at a steady pace instead of appearing in bursts.
const CHARS_PER_SECOND := 32.0
## How long a finished line stays up: a base plus reading time, capped.
const HOLD_BASE := 2.5
const HOLD_PER_CHAR := 0.09
## A long reply has to stay up long enough to actually be read to the end.
const HOLD_MAX := 22.0
const FADE_TIME := 0.4

## The bubble rises into place as it fades in. Short enough to read as the pet
## drawing breath, not as an animation being played at you.
const APPEAR_TIME := 0.18
const APPEAR_RISE := 7.0

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
var _appear := 1.0
## Widest the bubble has needed to be during this reply. Text only ever grows, so
## holding the maximum stops the bubble from breathing in and out as it wraps.
var _natural_width := 0.0
## Whatever the current bubble style uses for its edge, so the hand-drawn tail
## can match it.
var _edge_color := PetStyle.EDGE


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.visible = false
	_input.visible = false
	_input.text_submitted.connect(_on_submitted)
	_input.caret_blink = true
	_input.caret_blink_interval = 0.6
	_set_input_mode(InputMode.CHAT)


## Call once the display scale is known, and again whenever the pet resizes.
func configure(ui_scale: float, window_size: Vector2i, pet_rect: Rect2) -> void:
	_scale = ui_scale
	_pet_rect = pet_rect
	position = Vector2.ZERO
	size = Vector2(window_size)

	_apply_bubble_style(false)
	_text.add_theme_font_size_override("normal_font_size", roundi(15.0 * _scale))
	_text.add_theme_color_override("default_color", PetStyle.INK)
	# Chinese sits in a solid block without it; a line of air between rows is the
	# single biggest thing that makes a wall of CJK readable.
	_text.add_theme_constant_override("line_separation", roundi(5.0 * _scale))
	# The bubble grows upward from the pet's head, so an over-long reply would
	# run off the top of the window and get clipped. Drive the height manually
	# instead and let the text scroll once it hits the ceiling.
	_text.fit_content = false
	_text.scroll_active = true
	_text.scroll_following = true

	_apply_input_style()
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


func _process(delta: float) -> void:
	if not _bubble.visible:
		return
	_appear = minf(1.0, _appear + delta / APPEAR_TIME)
	if _streaming and _full_text.is_empty():
		_text.text = _waiting_dots()
	_reposition_bubble()
	_advance_typing(delta)


# --- Bubble -------------------------------------------------------------------

## Start a fresh line. Called when the pet begins replying.
func begin_reply() -> void:
	_kill_fade()
	_apply_bubble_style(false)
	_full_text = ""
	_shown = 0.0
	_streaming = true
	_hold = 0.0
	_natural_width = 0.0
	_text.text = ""
	_text.visible_characters = 0
	# Only animate in when the bubble wasn't already up; a follow-up line
	# replacing one still on screen shouldn't make the whole thing jump.
	if not _bubble.visible:
		_appear = 0.0
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
## Wears the accent edge: a disconnection isn't something the pet chose to say.
func show_notice(message: String) -> void:
	begin_reply()
	_apply_bubble_style(true)
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


func _apply_bubble_style(notice: bool) -> void:
	_edge_color = PetStyle.bubble_edge(notice)
	_bubble.add_theme_stylebox_override("panel", PetStyle.bubble_style(_scale, notice))


## Three dots breathing out of phase, so the pause before the first token reads
## as the pet thinking rather than as nothing happening. Same glyph count every
## frame — only the alpha moves — so the bubble doesn't twitch.
func _waiting_dots() -> String:
	var t := float(Time.get_ticks_msec()) / 1000.0
	var out := "[center]"
	for i in 3:
		var pulse := 0.5 + 0.5 * sin(t * 4.2 - float(i) * 0.9)
		var dot := Color(PetStyle.INK_SOFT, lerpf(0.22, 0.85, pulse))
		out += "[color=#%s]●[/color] " % dot.to_html(true)
	return out + "[/center]"


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


## How wide the bubble wants to be for the text it holds. Measured off the font
## rather than off the laid-out label: asking the label would feed its own width
## back into the answer, and the bubble would oscillate a pixel at a time
## forever.
func _wanted_width() -> float:
	var max_width := BUBBLE_MAX_WIDTH * _scale
	if _full_text.is_empty():
		return BUBBLE_WAITING_WIDTH * _scale
	var font := _text.get_theme_font("normal_font")
	if font == null:
		return max_width
	var padding := PetStyle.BUBBLE_PADDING * 2.0 * _scale
	var font_size := _text.get_theme_font_size("normal_font_size")
	var wrapped := font.get_multiline_string_size(
		_full_text, HORIZONTAL_ALIGNMENT_LEFT, max_width - padding, font_size)
	# A hair of slack: landing exactly on the measured width wraps the last
	# glyph of a line often enough to look like a bug.
	return clampf(wrapped.x + padding + 2.0 * _scale, BUBBLE_MIN_WIDTH * _scale, max_width)


## The bubble sizes itself to its text, so its position has to follow.
func _reposition_bubble() -> void:
	var limit := _limits()
	var margin := SIDE_MARGIN * _scale
	var padding := PetStyle.BUBBLE_PADDING * 2.0 * _scale
	var tail := _tail_point()

	# Narrow the bubble when the window is half off the screen, otherwise it
	# would be clamped flush to the edge and still overflow. Width first: the
	# text height below depends on it.
	_natural_width = maxf(_natural_width, _wanted_width())
	var room := limit.size.x - margin * 2.0
	var width := clampf(_natural_width, BUBBLE_MIN_WIDTH * _scale,
		maxf(BUBBLE_MIN_WIDTH * _scale, minf(BUBBLE_MAX_WIDTH * _scale, room)))
	_text.custom_minimum_size.x = maxf(1.0, width - padding)

	# The bubble grows upward from the pet's head; cap it at the space actually
	# available so it can't run off the top, and let the text scroll instead.
	var ceiling := tail.y - (GAP_ABOVE_PET + PetStyle.TAIL_HEIGHT) * _scale - (limit.position.y + margin)
	_text.custom_minimum_size.y = clampf(
		float(_text.get_content_height()), 0.0, maxf(0.0, ceiling - padding))

	var box := _bubble.get_combined_minimum_size()
	_bubble.size = box
	var min_x := limit.position.x + margin
	var min_y := limit.position.y + margin
	var x := clampf(tail.x - box.x * 0.5, min_x, maxf(min_x, limit.end.x - box.x - margin))
	var y := maxf(min_y, tail.y - (GAP_ABOVE_PET + PetStyle.TAIL_HEIGHT) * _scale - box.y)

	# Rise into place. The tail is drawn from the bubble's position, so offsetting
	# here carries it along instead of leaving it behind.
	var eased := 1.0 - pow(1.0 - _appear, 3.0)
	_bubble.position = Vector2(x, y + (1.0 - eased) * APPEAR_RISE * _scale)
	if _fade == null:
		_bubble.modulate.a = eased
	queue_redraw()


## Where the bubble points: the top-centre of the pet.
func _tail_point() -> Vector2:
	return Vector2(_pet_rect.get_center().x, _pet_rect.position.y)


func _draw() -> void:
	if not _bubble.visible:
		return
	var alpha := _bubble.modulate.a
	var top := _bubble.position.y + _bubble.size.y
	# Keep the tail attached to the bubble even when the bubble got pushed
	# sideways by the window edge.
	var tip_x := clampf(_tail_point().x,
		_bubble.position.x + PetStyle.TAIL_WIDTH * _scale,
		_bubble.position.x + _bubble.size.x - PetStyle.TAIL_WIDTH * _scale)

	var left := _tail_side(top, tip_x, -1.0)
	var right := _tail_side(top, tip_x, 1.0)
	var fill := PackedVector2Array(left)
	# The right side runs base-to-tip like the left one, so it has to come back
	# reversed for the two to close into one outline.
	for i in range(right.size() - 1, -1, -1):
		fill.append(right[i])

	# The panel's own drop shadow stops at its bottom edge, so the tail needs its
	# own. Two soft passes rather than one hard offset copy.
	for pass_index in 2:
		var drop := Vector2(0.0, (1.0 + float(pass_index) * 1.6) * _scale)
		var faint := Color(PetStyle.SHADOW, PetStyle.SHADOW.a * 0.35 * alpha)
		draw_colored_polygon(_offset_points(fill, drop), faint)

	draw_colored_polygon(fill, Color(PetStyle.PAPER, PetStyle.PAPER.a * alpha))
	# Only the two slanted sides carry the border; the top edge is under the
	# panel, which draws its own.
	var edge := Color(_edge_color, _edge_color.a * alpha)
	var edge_width := PetStyle.bubble_edge_width(_scale)
	draw_polyline(left, edge, edge_width, true)
	draw_polyline(right, edge, edge_width, true)


## One side of the tail, bowed slightly inward so it reads as a drip off the
## bubble rather than as a triangle stuck to it. Runs from the base to the tip.
func _tail_side(top: float, tip_x: float, direction: float) -> PackedVector2Array:
	const STEPS := 7
	var half := PetStyle.TAIL_WIDTH * 0.5 * _scale
	var height := PetStyle.TAIL_HEIGHT * _scale
	# Start just inside the panel so the fill covers the seam.
	var base := Vector2(tip_x + half * direction, top - 1.0 * _scale)
	var tip := Vector2(tip_x, top + height)
	var control := Vector2(tip_x + half * 0.22 * direction, top + height * 0.45)

	var points := PackedVector2Array()
	for i in STEPS + 1:
		var t := float(i) / float(STEPS)
		points.append(base.lerp(control, t).lerp(control.lerp(tip, t), t))
	return points


func _offset_points(points: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(p + by)
	return out


# --- Input --------------------------------------------------------------------

func toggle_input() -> void:
	set_input_open(not _input.visible)


func set_input_open(open: bool) -> void:
	if _input.visible == open:
		return
	_input.visible = open
	if open:
		_input.grab_focus()
		_input.modulate.a = 0.0
		create_tween().tween_property(_input, "modulate:a", 1.0, 0.14)
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
	_apply_input_style()


## Typing a key is not conversation, so the field says so in colour as well as in
## its placeholder — the accent switches from persimmon to a cool green.
func _apply_input_style() -> void:
	var secret := _input_mode == InputMode.SECRET
	var height := INPUT_HEIGHT * _scale
	_input.add_theme_stylebox_override("normal", PetStyle.input_style(_scale, height, secret))
	_input.add_theme_stylebox_override("read_only", PetStyle.input_style(_scale, height, secret))
	_input.add_theme_stylebox_override("focus", PetStyle.input_focus_style(_scale, height, secret))
	_input.add_theme_color_override("font_color", PetStyle.INK)
	_input.add_theme_color_override("font_placeholder_color", PetStyle.INK_SOFT)
	_input.add_theme_color_override("font_selected_color", PetStyle.INK)
	_input.add_theme_color_override("caret_color", PetStyle.input_caret_color(secret))
	_input.add_theme_color_override("selection_color",
		Color(PetStyle.input_caret_color(secret), 0.20))
	_input.add_theme_constant_override("caret_width", maxi(1, roundi(2.0 * _scale)))
	_input.add_theme_font_size_override("font_size", roundi(15.0 * _scale))


## Sits just under the pet's feet, pulled back on screen if that would fall below
## the desktop. Centred on the pet rather than on the window, so the field and
## the bubble share an axis.
func _layout_input() -> void:
	var limit := _limits()
	var margin := SIDE_MARGIN * _scale
	var height := INPUT_HEIGHT * _scale
	var width := clampf(limit.size.x - margin * 2.0, height, INPUT_MAX_WIDTH * _scale)
	_input.size = Vector2(width, height)

	var min_x := limit.position.x + margin
	var lowest := limit.end.y - margin - height
	_input.position = Vector2(
		clampf(_pet_rect.get_center().x - width * 0.5, min_x,
			maxf(min_x, limit.end.x - width - margin)),
		clampf(_pet_rect.end.y + margin, limit.position.y + margin,
			maxf(limit.position.y, lowest)))


func is_input_open() -> bool:
	return _input.visible


## Viewport-space rect that must receive clicks. Empty when the input is closed —
## the bubble is display-only, so it stays click-through.
func get_input_rect() -> Rect2:
	if not _input.visible:
		return Rect2()
	return Rect2(_input.position, _input.size)


## Viewport-space rect covering everything this panel currently *draws* — the
## bubble with its tail and drop shadow, the input with its shadow and focus
## glow. Empty when nothing is showing.
##
## Deliberately separate from get_input_rect(): that one answers "what has to
## catch clicks", this one answers "what has to stay visible". They only differ
## where the passthrough mask also clips rendering — see
## WindowController.passthrough_clips_rendering().
func get_chrome_rect() -> Rect2:
	var box := Rect2()
	if _input.visible:
		box = get_input_rect().grow((PetStyle.INPUT_SHADOW + PetStyle.INPUT_SHADOW_DROP) * _scale)
	if not _bubble.visible:
		return box
	# The tail is drawn by this node rather than the panel, hanging below it, so
	# the panel's own rect isn't enough.
	var bubble := Rect2(_bubble.position,
		_bubble.size + Vector2(0.0, PetStyle.TAIL_HEIGHT * _scale)) \
		.grow((PetStyle.BUBBLE_SHADOW + PetStyle.BUBBLE_SHADOW_DROP) * _scale)
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
