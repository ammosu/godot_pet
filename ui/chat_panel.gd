extends Control
class_name ChatPanel

## Speech bubble + text input, laid out around the pet inside the transparent
## window.
##
## Geometry is set from code rather than the scene file because it depends on
## the display's DPI and on how big the pet currently is — neither of which the
## editor knows. Colours and edges all come from PetStyle.

signal submitted(text: String)
## A job for the pet to hand to a coding-agent CLI, which goes to WorkService
## rather than into the conversation.
signal work_submitted(text: String)
signal input_toggled(open: bool)
## The field grew or shrank a row. The passthrough mask is built from
## get_input_rect(), and outside the frame-by-frame case (Windows, where the mask
## also clips rendering) it is only pushed on discrete events — so without this,
## typing a second line would draw a field whose upper half doesn't take clicks.
signal input_resized
## The line finished being read and faded away.
signal bubble_hidden
## A holding bubble can carry one immediate action. Recording uses it to stop
## without sending the user back through the right-click menu.
signal holding_action_pressed
## The clickable part of this panel changed. On platforms where the transparent
## window's hit region is pushed only on discrete events, the pet has to refresh
## that region as soon as a holding action appears or disappears.
signal hit_region_changed

const CHAT_PLACEHOLDER := "跟我說說話…"

## WORK is unmasked and styled like chat — the only thing separating it is the
## placeholder and where the text is sent.
##
## **Nothing here is masked any more, and that is the point.** Keys and service
## addresses used to be typed into this field, which meant the app's settings
## were collected through the pet's own mouth, inside the transparent
## click-through window, behind a passthrough mask that has to be kept in step
## with whatever the field is doing. They have their own window now
## (`pet.gd::_ask_for_entry`), and everything that existed to serve them — a
## second LineEdit, `_field()`, a `secret` styling branch — went with them.
enum InputMode { CHAT, WORK }

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
## One row. The field is a pill at this height and grows by exactly one line per
## row after it — see _field_height().
const INPUT_HEIGHT := 38.0
## Past this the field scrolls instead of growing. The window is only so tall,
## the pet has to stay visible above it, and a field that keeps growing turns
## into a document editor sitting on the desktop.
const INPUT_MAX_ROWS := 5
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

## Half-diagonal of the close cross, as a fraction of its circle. Small enough
## that the stroke ends stay clear of the hover wash's edge.
const CLOSE_ARM_RATIO := 0.21
const CLOSE_STROKE := 1.6

@onready var _bubble: PanelContainer = $Bubble
@onready var _content: VBoxContainer = $Bubble/Content
@onready var _text: RichTextLabel = $Bubble/Content/Text
@onready var _holding_action: Button = $Bubble/Content/Action
## The one field. Everything the user says to the pet goes through it, and a
## TextEdit is what it has to be: only that one grows past a single line.
@onready var _area: TextEdit = $Area
## Built here rather than in the scene because it is sized off the display
## scale, which nothing knows until configure() runs. Parented to the field so it
## inherits its visibility — every existing path that shows or hides the input
## gets the button for free, and none of them can forget it.
var _close: Button

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
## A bubble that must not time out, because it is reporting something still
## happening rather than something the pet said. See show_holding().
var _holding := false
var _appear := 1.0
## Widest the bubble has needed to be during this reply. Text only ever grows, so
## holding the maximum stops the bubble from breathing in and out as it wraps.
var _natural_width := 0.0
## Whatever the current bubble style uses for its edge, so the hand-drawn tail
## can match it.
var _edge_color := PetStyle.EDGE
var _close_hovered := false
## Last height the field was laid out at, so input_resized only fires on a row
## actually being gained or lost — _layout_input() also runs on every pet step.
var _field_height := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.visible = false
	_holding_action.visible = false
	_holding_action.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_holding_action.pressed.connect(holding_action_pressed.emit)
	_area.visible = false
	_area.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_area.scroll_fit_content_height = false
	_area.caret_blink = true
	_area.caret_blink_interval = 0.6
	_area.text_changed.connect(_layout_input)
	# Connected as a signal rather than overridden: Control emits `gui_input`
	# *before* running its own handler precisely so a listener can take the event
	# first, which is the only way to stop Enter inserting a newline.
	_area.gui_input.connect(_on_area_gui_input)
	# Past INPUT_MAX_ROWS the field scrolls, and the engine's default scrollbar
	# inside a paper pill reads as a rendering fault. Emptied rather than hidden:
	# TextEdit re-shows the bar itself whenever it decides one is needed.
	var blank := StyleBoxEmpty.new()
	for item in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
		_area.get_v_scroll_bar().add_theme_stylebox_override(item, blank)

	# No text: the cross is drawn in _on_close_draw(), so the button is only a
	# hit target and a hover wash, and its minimum size stays zero.
	_close = Button.new()
	_close.flat = true
	# Never a tab stop: the field beside it must keep the caret, or Enter stops
	# submitting the moment the pointer has been anywhere near the button.
	_close.focus_mode = Control.FOCUS_NONE
	_close.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_close.pressed.connect(_on_close_pressed)
	_close.mouse_entered.connect(_on_close_hover.bind(true))
	_close.mouse_exited.connect(_on_close_hover.bind(false))
	_close.draw.connect(_on_close_draw)

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
	_content.add_theme_constant_override("separation", roundi(7.0 * _scale))
	# The bubble grows upward from the pet's head, so an over-long reply would
	# run off the top of the window and get clipped. Drive the height manually
	# instead and let the text scroll once it hits the ceiling.
	_text.fit_content = false
	_text.scroll_active = true
	_text.scroll_following = true
	PetStyle.make_bubble_action_button(_holding_action, _scale)

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
	var had_action := _holding_action.visible
	_holding_action.visible = false
	_full_text = ""
	_shown = 0.0
	_streaming = true
	# Anything the pet actually says replaces the indicator and gets to fade
	# normally; only show_holding() sets this back.
	_holding = false
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
	if had_action:
		_reposition_bubble()
		hit_region_changed.emit()


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


## A line that stays up until something takes it down, and can be rewritten in
## place — the recording indicator, which has to be true for as long as the
## microphone is open. A bubble that fades after twenty-two seconds is the pet
## having said something; this is the pet still doing something.
##
## `_streaming` is already exactly "more is coming, don't start the fade
## countdown" (see _advance_typing), so this is that flag used honestly rather
## than a second timer racing it. Repeat calls only rewrite the text: they must
## not replay the appear animation or re-run the typewriter, or a clock ticking
## once a second would make the bubble jump once a second.
func show_holding(message: String, action_label := "") -> void:
	if not _holding:
		begin_reply()
		_apply_bubble_style(true)
		_holding = true
	_holding_action.text = action_label
	_holding_action.visible = not action_label.is_empty()
	_streaming = true
	_full_text = message
	_text.text = message
	_shown = float(message.length())
	_text.visible_characters = -1
	# Unlike ordinary speech, this bubble is interactive. Lay it out now rather
	# than waiting for the next frame, then let the window include its new bounds
	# in the click-through mask before the user can reach for the button.
	_reposition_bubble()
	hit_region_changed.emit()


func is_holding() -> bool:
	return _holding and _bubble.visible


func hide_bubble() -> void:
	if not _bubble.visible:
		return
	_kill_fade()
	_streaming = false
	_holding = false
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


## The close button's cross, drawn rather than set as its text.
##
## A Button centres the *line box* of its label, not the glyph inside it, and
## this project ships a CJK face whose line box is far taller than a "×" —
## which put the cross visibly above the middle of its circle. The same tall
## line box also set the button's minimum height, so asking for a square gave
## back something taller.
##
## Painted onto the button's own canvas, via its `draw` signal, rather than in
## this node's `_draw()`. A Control draws underneath its children, and the field
## this button sits inside fills itself with opaque paper — so a cross drawn
## here is painted and then immediately covered, with nothing to show for it.
## (The bubble's tail gets away with living in `_draw()` only because it hangs
## below the panel it belongs to, outside anything that would paint over it.)
func _on_close_draw() -> void:
	var centre := _close.size * 0.5
	var arm := _close.size.x * CLOSE_ARM_RATIO
	var width := maxf(1.0, roundf(CLOSE_STROKE * _scale))
	var tint := PetStyle.INK if _close_hovered else PetStyle.INK_SOFT
	_close.draw_line(centre - Vector2(arm, arm), centre + Vector2(arm, arm),
		tint, width, true)
	_close.draw_line(centre - Vector2(arm, -arm), centre + Vector2(arm, -arm),
		tint, width, true)


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
	set_input_open(not is_input_open())


func set_input_open(open: bool) -> void:
	if is_input_open() == open:
		return
	var field := _area
	field.visible = open
	if open:
		# Before the fade, not after: the field is sized to its content, and one
		# laid out at a stale width flashes at the wrong size for a frame.
		_layout_input()
		field.grab_focus()
		field.modulate.a = 0.0
		create_tween().tween_property(field, "modulate:a", 1.0, 0.14)
	else:
		field.release_focus()
		_close_hovered = false
		_set_input_mode(InputMode.CHAT)
	input_toggled.emit(open)


## Open the input for a "go and do this" request — the one thing left that is not
## ordinary conversation, and it stays here because it *is* conversational: you
## are telling the pet what to go and do. Reverts to chat on submit or dismissal,
## since a field that quietly stayed in a special mode would send the next
## ordinary sentence somewhere surprising, and here "somewhere surprising" is an
## agent loose in a repository.
func ask_what_to_do(placeholder: String) -> void:
	var was_open := is_input_open()
	_set_input_mode(InputMode.WORK, placeholder)
	if was_open:
		_area.grab_focus()
	else:
		set_input_open(true)


## Only the placeholder and where the text is sent change now. The close button
## is parented once, here, and being the field's child is what makes it
## impossible to show the input without its way out.
func _set_input_mode(mode: InputMode, placeholder := CHAT_PLACEHOLDER) -> void:
	_input_mode = mode
	_area.placeholder_text = placeholder
	_area.text = ""
	if _close.get_parent() == null:
		_area.add_child(_close)

	_apply_input_style()
	_layout_input()


## One field, one style. The `secret` argument `PetStyle` still takes is passed
## `false` from here for good: it switched the accent from persimmon to a cool
## green to say "this is not conversation", which was the masked key field's job
## and is now the entry window's — a window says it far better than a colour did.
##
## Theme item names do **not** carry over from the bubble, and a wrong one is
## silent — it simply never applies, the same trap ChatLogPanel records for
## RichTextLabel. TextEdit wants `line_spacing` where the bubble wants
## `line_separation`.
func _apply_input_style() -> void:
	var height := INPUT_HEIGHT * _scale
	var reserve := PetStyle.input_close_reserve(height, _scale)
	var caret := PetStyle.input_caret_color(false)
	var font_size := roundi(15.0 * _scale)

	# Font and spacing before the boxes: the vertical padding below is derived
	# from the line height, which is not knowable until they are applied.
	_area.add_theme_font_size_override("font_size", font_size)
	_area.add_theme_constant_override("line_spacing", roundi(4.0 * _scale))
	var pad := _text_pad_y()
	_area.add_theme_stylebox_override("normal",
		PetStyle.input_style(_scale, height, false, reserve, pad))
	_area.add_theme_stylebox_override("read_only",
		PetStyle.input_style(_scale, height, false, reserve, pad))
	_area.add_theme_stylebox_override("focus",
		PetStyle.input_focus_style(_scale, height, false, reserve, pad))
	_area.add_theme_color_override("font_color", PetStyle.INK)
	_area.add_theme_color_override("font_placeholder_color", PetStyle.INK_SOFT)
	_area.add_theme_color_override("font_selected_color", PetStyle.INK)
	_area.add_theme_color_override("caret_color", caret)
	_area.add_theme_color_override("selection_color", Color(caret, 0.20))
	# Its own background and the row highlight would both draw on top of the
	# paper pill the stylebox already paints.
	_area.add_theme_color_override("background_color", Color(0, 0, 0, 0))
	_area.add_theme_color_override("current_line_color", Color(0, 0, 0, 0))
	_area.add_theme_constant_override("caret_width", maxi(1, roundi(2.0 * _scale)))

	PetStyle.make_input_close_button(_close, height)


## What the multi-line field needs above and below its text so that *one* row
## sits centred in the same pill the LineEdit draws. A LineEdit centres its
## single line itself; a TextEdit draws from the top, so left at PetStyle's own
## inset the text rides visibly high in the field.
func _text_pad_y() -> float:
	return maxf(0.0, (INPUT_HEIGHT * _scale - float(_area.get_line_height())) * 0.5)


## How many rows the text currently occupies, wrapping included, capped at what
## the field will grow to.
##
## Summed from get_line_wrap_count() rather than taken from
## get_total_visible_line_count(), whose name reads as "how many rows are on
## screen" — which is a different number the moment the field starts scrolling,
## and would feed the field's own height back into the answer.
func _row_count() -> int:
	var rows := 0
	for i in _area.get_line_count():
		rows += 1 + _area.get_line_wrap_count(i)
		if rows >= INPUT_MAX_ROWS:
			return INPUT_MAX_ROWS
	return maxi(1, rows)


## One row is the pill the field has always been; each row after it adds exactly
## one line height. Deriving it from the padding instead would make the step from
## one row to two smaller than every step after it, which reads as the field
## having lost its padding rather than gained a line.
func _field_height_for(field: Control) -> float:
	var single := INPUT_HEIGHT * _scale
	if field != _area:
		return single
	return single + float(_row_count() - 1) * float(_area.get_line_height())


## Sits just under the pet's feet, pulled back on screen if that would fall below
## the desktop. Centred on the pet rather than on the window, so the field and
## the bubble share an axis.
func _layout_input() -> void:
	var limit := _limits()
	var margin := SIDE_MARGIN * _scale
	var single := INPUT_HEIGHT * _scale
	var width := clampf(limit.size.x - margin * 2.0, single, INPUT_MAX_WIDTH * _scale)
	var field := _area
	# Width first, and as its own assignment: how many rows the text wraps into
	# depends on it, and the height depends on that. Setting both at once would
	# measure the wrap against the width the field had a moment ago.
	field.size.x = width
	var height := _field_height_for(field)
	field.size.y = height

	var min_x := limit.position.x + margin
	var lowest := limit.end.y - margin - height
	field.position = Vector2(
		clampf(_pet_rect.get_center().x - width * 0.5, min_x,
			maxf(min_x, limit.end.x - width - margin)),
		clampf(_pet_rect.end.y + margin, limit.position.y + margin,
			maxf(limit.position.y, lowest)))

	# In the field's right cap, and measured from its *bottom* rather than
	# centred in it. Where the pet lives — the corner — the field is pinned to
	# the desktop edge and grows upward, so an anchor at the bottom is the one
	# that leaves the button sitting still while you type.
	var d := PetStyle.input_close_size(single)
	_close.size = Vector2(d, d)
	_close.position = Vector2(width - d - PetStyle.INPUT_CLOSE_INSET * _scale,
		height - d - (single - d) * 0.5)
	# The cross is scaled off the button's own size, so a resize has to repaint
	# it. Godot redraws a Control whose size changed, but not one that only moved.
	_close.queue_redraw()

	if not is_equal_approx(height, _field_height):
		_field_height = height
		input_resized.emit()


func is_input_open() -> bool:
	return _area.visible


## Viewport-space rect that must receive clicks. Ordinary speech bubbles remain
## display-only and click-through; a holding bubble with an action is the one
## exception, because its button has to be reachable without reopening a menu.
func get_input_rect() -> Rect2:
	var box := Rect2()
	if is_input_open():
		var field := _area
		box = Rect2(field.position, field.size)
	if _bubble.visible and _holding_action.visible:
		var bubble := Rect2(_bubble.position, _bubble.size)
		box = bubble if not box.has_area() else box.merge(bubble)
	return box


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
	if is_input_open():
		box = get_input_rect().grow((PetStyle.INPUT_SHADOW + PetStyle.INPUT_SHADOW_DROP) * _scale)
	if not _bubble.visible:
		return box
	# The tail is drawn by this node rather than the panel, hanging below it, so
	# the panel's own rect isn't enough.
	var bubble := Rect2(_bubble.position,
		_bubble.size + Vector2(0.0, PetStyle.TAIL_HEIGHT * _scale)) \
		.grow((PetStyle.BUBBLE_SHADOW + PetStyle.BUBBLE_SHADOW_DROP) * _scale)
	return bubble if not box.has_area() else box.merge(bubble)


## Enter sends, Shift+Enter breaks a line. The field grows for a reason, and the
## reason is the reply the pet gets, not composing a document — so the shortcut
## everyone already presses has to stay the one that sends.
func _on_area_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var key := event as InputEventKey
	if key.keycode != KEY_ENTER and key.keycode != KEY_KP_ENTER:
		return
	if key.shift_pressed:
		return
	_area.accept_event()
	_on_submitted(_area.text)


func _on_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	_area.text = ""
	# Back to one row before anything else runs: the branches below can leave the
	# field open, and a submitted five-line message must not leave a five-line
	# hole behind it.
	_layout_input()
	if trimmed.is_empty():
		return
	if _input_mode == InputMode.WORK:
		_set_input_mode(InputMode.CHAT)
		work_submitted.emit(trimmed)
	else:
		submitted.emit(trimmed)


## The same thing Escape does, and the same thing tapping the pet does — this
## just makes it something you can see.
func _on_close_pressed() -> void:
	set_input_open(false)


## The wash under the cross is the button's own hover stylebox; the cross itself
## is ours to redraw.
func _on_close_hover(inside: bool) -> void:
	_close_hovered = inside
	_close.queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_input_open():
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		set_input_open(false)
		get_viewport().set_input_as_handled()
