extends RefCounted
class_name PetStyle

## Every colour and edge the app draws, in one place.
##
## Two surfaces, deliberately opposed. What the *pet* says is paper: warm, light,
## soft-cornered, with a tail. What the *app* asks is ink: a dark slab that reads
## as system chrome, so a menu never looks like the character talking. One
## persimmon accent is the only saturated colour in either, which is what makes it
## mean anything — the caret, the ring around the field being typed into, the row
## under the cursor.
##
## The dark chrome is not only a taste call. PopupMenu's check and radio marks
## come from the engine's default theme and are near-white; on a light panel they
## vanish, and there is no per-item icon modulate to fix that with. A dark panel
## keeps them legible without shipping custom icons.
##
## Sizes here are design units — multiply by `WindowController.get_ui_scale()` at
## the point of use, like everything else (see the DPI section of CLAUDE.md).

## Carries the CJK font fallback. The themes below are built from a copy of it so
## they inherit that, rather than dropping to a font with no Chinese coverage.
const BASE_THEME := preload("res://ui/theme.tres")

# --- Palette ------------------------------------------------------------------

## The pet's voice: warm paper, warm ink. Near-opaque, because the window sits on
## whatever wallpaper the user happens to have.
const PAPER := Color("fffaf3", 0.97)
const INK := Color("2b2018")
const INK_SOFT := Color("6b5b4e")
const EDGE := Color("2b2018", 0.11)
## Warm rather than black — a neutral shadow over a warm panel looks like dirt.
const SHADOW := Color("3a2a1e", 0.20)

## The app's chrome.
const NIGHT := Color("241d1a", 0.98)
const NIGHT_TEXT := Color("f1e7da")
const NIGHT_MUTED := Color("f1e7da", 0.35)
const NIGHT_EDGE := Color("f1e7da", 0.10)
const NIGHT_WASH := Color("f1e7da", 0.07)

## The one saturated colour: live things only.
const ACCENT := Color("e2603c")
## Lifted for use as text on the dark panel, where full-strength persimmon is
## too dim to read.
const ACCENT_TEXT := Color("f08a63")
## Typing a key is not conversation, and must not look like it.
const SECRET := Color("3a8f86")

# --- Sizes --------------------------------------------------------------------

const BUBBLE_PADDING := 13.0
const BUBBLE_CORNER := 18.0
## Tighter at the bottom, so the bubble sits down onto its tail instead of
## floating as an even-cornered box.
const BUBBLE_CORNER_BOTTOM := 12.0
const BUBBLE_BORDER := 1.0
## The accent stripe on a system notice, which is otherwise identical to speech.
const BUBBLE_NOTICE_BORDER := 3.0
const BUBBLE_SHADOW := 12.0
const BUBBLE_SHADOW_DROP := 4.0
const TAIL_WIDTH := 20.0
const TAIL_HEIGHT := 12.0

const INPUT_PADDING := 16.0
## See input_style(): this sets the field's minimum height, not just its inset.
const INPUT_PADDING_Y := 5.0
const INPUT_BORDER := 1.0
const INPUT_FOCUS_BORDER := 2.0
const INPUT_SHADOW := 10.0
const INPUT_SHADOW_DROP := 3.0
## Halo around the focused field. Stays within the shadow's reach so it doesn't
## widen the region the chat panel reports as drawn.
const INPUT_FOCUS_GLOW := 5.0


# --- Speech bubble ------------------------------------------------------------

## `notice` is for lines the app generates rather than the pet — errors, mostly.
## Same paper, but wearing the accent, so a disconnection doesn't read as
## something the character chose to say.
static func bubble_style(scale: float, notice := false) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = PAPER
	box.border_color = bubble_edge(notice)
	box.set_border_width_all(maxi(1, roundi(BUBBLE_BORDER * scale)))
	box.corner_radius_top_left = roundi(BUBBLE_CORNER * scale)
	box.corner_radius_top_right = roundi(BUBBLE_CORNER * scale)
	box.corner_radius_bottom_left = roundi(BUBBLE_CORNER_BOTTOM * scale)
	box.corner_radius_bottom_right = roundi(BUBBLE_CORNER_BOTTOM * scale)
	box.corner_detail = 12
	box.set_content_margin_all(BUBBLE_PADDING * scale)
	box.shadow_color = SHADOW
	box.shadow_size = roundi(BUBBLE_SHADOW * scale)
	box.shadow_offset = Vector2(0.0, BUBBLE_SHADOW_DROP * scale)
	if notice:
		box.border_width_left = roundi(BUBBLE_NOTICE_BORDER * scale)
		box.content_margin_left = (BUBBLE_PADDING + 3.0) * scale
	return box


## The tail is drawn by hand rather than by the stylebox, so it has to be told
## what the bubble's edge currently looks like.
static func bubble_edge(notice: bool) -> Color:
	return Color(ACCENT, 0.55) if notice else EDGE


static func bubble_edge_width(scale: float) -> float:
	return maxf(1.0, BUBBLE_BORDER * scale)


# --- Chat input ---------------------------------------------------------------

## A pill under the pet's feet. `height` is what the corner radius is derived
## from, so it stays a true pill at any display scale.
##
## The vertical padding is deliberately far smaller than the horizontal one: a
## stylebox's content margins set the control's *minimum* height, so padding it
## evenly quietly overrode the height the chat panel asked for and left a
## rounded-rectangle box where a pill was meant to be.
static func input_style(scale: float, height: float, secret: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = PAPER
	box.border_color = Color(SECRET, 0.45) if secret else EDGE
	box.set_border_width_all(maxi(1, roundi(INPUT_BORDER * scale)))
	box.set_corner_radius_all(roundi(height * 0.5))
	box.corner_detail = 12
	box.content_margin_left = roundi(INPUT_PADDING * scale)
	box.content_margin_right = roundi(INPUT_PADDING * scale)
	box.content_margin_top = roundi(INPUT_PADDING_Y * scale)
	box.content_margin_bottom = roundi(INPUT_PADDING_Y * scale)
	box.shadow_color = SHADOW
	box.shadow_size = roundi(INPUT_SHADOW * scale)
	box.shadow_offset = Vector2(0.0, INPUT_SHADOW_DROP * scale)
	return box


## Drawn over the normal box, so it only needs to say what changes: the edge
## lights up and gains a halo of the same colour.
##
## The fill has to be repeated here, opaque. A StyleBoxFlat's shadow is a solid
## expanded copy of its own shape drawn behind it — including behind the part the
## box itself covers — so a focus box with a see-through fill doesn't glow, it
## just stains the field the colour of the halo.
static func input_focus_style(scale: float, height: float, secret: bool) -> StyleBoxFlat:
	var tint := SECRET if secret else ACCENT
	var box := StyleBoxFlat.new()
	box.bg_color = Color(PAPER, 1.0)
	box.border_color = Color(tint, 0.85)
	box.set_border_width_all(maxi(1, roundi(INPUT_FOCUS_BORDER * scale)))
	box.set_corner_radius_all(roundi(height * 0.5))
	box.corner_detail = 12
	box.content_margin_left = roundi(INPUT_PADDING * scale)
	box.content_margin_right = roundi(INPUT_PADDING * scale)
	box.content_margin_top = roundi(INPUT_PADDING_Y * scale)
	box.content_margin_bottom = roundi(INPUT_PADDING_Y * scale)
	# Not blurred — Godot has no such thing — so it reads as a ring rather than a
	# glow. Kept faint enough that it registers as "this field is live" instead of
	# as a second border.
	box.shadow_color = Color(tint, 0.18)
	box.shadow_size = roundi(INPUT_FOCUS_GLOW * scale)
	return box


static func input_caret_color(secret: bool) -> Color:
	return SECRET if secret else ACCENT


# --- Right-click menu ---------------------------------------------------------

static func menu_theme(scale: float) -> Theme:
	var theme: Theme = BASE_THEME.duplicate()
	theme.default_font_size = roundi(15.0 * scale)

	var panel := StyleBoxFlat.new()
	panel.bg_color = NIGHT
	panel.border_color = NIGHT_EDGE
	panel.set_border_width_all(maxi(1, roundi(1.0 * scale)))
	panel.set_corner_radius_all(roundi(12.0 * scale))
	panel.corner_detail = 12
	# Horizontal margin insets the hover highlight from the panel edge; vertical
	# keeps the first and last row off it.
	panel.set_content_margin_all(roundi(7.0 * scale))
	theme.set_stylebox("panel", "PopupMenu", panel)

	var hover := StyleBoxFlat.new()
	hover.bg_color = ACCENT
	hover.set_corner_radius_all(roundi(8.0 * scale))
	hover.corner_detail = 8
	theme.set_stylebox("hover", "PopupMenu", hover)

	var rule := StyleBoxLine.new()
	rule.color = NIGHT_EDGE
	rule.thickness = maxi(1, roundi(1.0 * scale))
	theme.set_stylebox("separator", "PopupMenu", rule)
	theme.set_stylebox("labeled_separator_left", "PopupMenu", rule)
	theme.set_stylebox("labeled_separator_right", "PopupMenu", rule)

	theme.set_color("font_color", "PopupMenu", NIGHT_TEXT)
	# The row under the cursor is a solid persimmon bar, so its label flips to
	# the paper colour rather than staying cream-on-orange.
	theme.set_color("font_hover_color", "PopupMenu", Color("fffaf3"))
	theme.set_color("font_disabled_color", "PopupMenu", NIGHT_MUTED)
	theme.set_color("font_accelerator_color", "PopupMenu", NIGHT_MUTED)
	theme.set_color("font_separator_color", "PopupMenu", ACCENT_TEXT)
	theme.set_font_size("font_size", "PopupMenu", roundi(15.0 * scale))
	# Section headings read as headings by being smaller and coloured, not bigger.
	theme.set_font_size("font_separator_size", "PopupMenu", roundi(12.0 * scale))

	theme.set_constant("v_separation", "PopupMenu", roundi(7.0 * scale))
	theme.set_constant("h_separation", "PopupMenu", roundi(10.0 * scale))
	theme.set_constant("indent", "PopupMenu", roundi(10.0 * scale))
	theme.set_constant("item_start_padding", "PopupMenu", roundi(9.0 * scale))
	theme.set_constant("item_end_padding", "PopupMenu", roundi(9.0 * scale))
	theme.set_constant("icon_max_width", "PopupMenu", roundi(16.0 * scale))
	return theme


# --- Consent dialog -----------------------------------------------------------

## The dialog is a native OS window, so its title bar belongs to the desktop and
## only the inside of it is ours. A Theme reaches the label and the buttons
## alike; per-node overrides only reach the node they are on.
static func dialog_theme(scale: float) -> Theme:
	var theme: Theme = BASE_THEME.duplicate()
	theme.default_font_size = roundi(15.0 * scale)

	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(NIGHT, 1.0)
	# Square: the window underneath is opaque, so rounded corners would only cut
	# holes in the panel rather than round the window.
	panel.set_content_margin_all(roundi(18.0 * scale))
	theme.set_stylebox("panel", "AcceptDialog", panel)
	theme.set_constant("buttons_separation", "AcceptDialog", roundi(10.0 * scale))

	theme.set_color("font_color", "Label", NIGHT_TEXT)
	theme.set_font_size("font_size", "Label", roundi(15.0 * scale))

	theme.set_stylebox("normal", "Button", _button_style(scale, NIGHT_WASH, NIGHT_EDGE))
	theme.set_stylebox("hover", "Button", _button_style(scale, Color("f1e7da", 0.14), NIGHT_EDGE))
	theme.set_stylebox("pressed", "Button", _button_style(scale, Color("f1e7da", 0.20), NIGHT_EDGE))
	theme.set_stylebox("focus", "Button", _button_style(scale, Color(0, 0, 0, 0), Color(ACCENT, 0.7)))
	theme.set_stylebox("disabled", "Button", _button_style(scale, Color("f1e7da", 0.03), NIGHT_EDGE))
	theme.set_color("font_color", "Button", NIGHT_TEXT)
	theme.set_color("font_hover_color", "Button", Color("fffaf3"))
	theme.set_color("font_pressed_color", "Button", Color("fffaf3"))
	theme.set_color("font_disabled_color", "Button", NIGHT_MUTED)
	theme.set_font_size("font_size", "Button", roundi(15.0 * scale))
	return theme


# --- Memory panel -------------------------------------------------------------

## The dialog's ink surface, plus what a panel of its own needs: a slab to sit
## on, rules between its sections, and room to breathe.
static func panel_theme(scale: float) -> Theme:
	var theme := dialog_theme(scale)

	var slab := StyleBoxFlat.new()
	slab.bg_color = Color(NIGHT, 1.0)
	slab.content_margin_left = roundi(20.0 * scale)
	slab.content_margin_right = roundi(20.0 * scale)
	slab.content_margin_top = roundi(18.0 * scale)
	slab.content_margin_bottom = roundi(18.0 * scale)
	theme.set_stylebox("panel", "PanelContainer", slab)

	var rule := StyleBoxLine.new()
	rule.color = NIGHT_EDGE
	rule.thickness = maxi(1, roundi(1.0 * scale))
	theme.set_stylebox("separator", "HSeparator", rule)
	theme.set_constant("separation", "HSeparator", roundi(1.0 * scale))
	return theme


## A button that only shows up when reached for — for the per-row actions, which
## outnumber everything else on screen and must not compete with the text they
## sit beside.
static func make_quiet_button(button: Button, scale: float) -> void:
	var blank := StyleBoxFlat.new()
	blank.bg_color = Color(0, 0, 0, 0)
	blank.set_corner_radius_all(roundi(7.0 * scale))
	blank.content_margin_left = roundi(9.0 * scale)
	blank.content_margin_right = roundi(9.0 * scale)
	blank.content_margin_top = roundi(4.0 * scale)
	blank.content_margin_bottom = roundi(4.0 * scale)

	var lit := blank.duplicate() as StyleBoxFlat
	lit.bg_color = Color(ACCENT, 0.85)
	var held := blank.duplicate() as StyleBoxFlat
	held.bg_color = Color(ACCENT, 1.0)

	button.add_theme_stylebox_override("normal", blank)
	button.add_theme_stylebox_override("focus", blank)
	button.add_theme_stylebox_override("hover", lit)
	button.add_theme_stylebox_override("pressed", held)
	button.add_theme_color_override("font_color", NIGHT_MUTED)
	button.add_theme_color_override("font_hover_color", Color("fffaf3"))
	button.add_theme_color_override("font_pressed_color", Color("fffaf3"))
	button.add_theme_font_size_override("font_size", roundi(13.0 * scale))


## Present but unemphatic — for a choice that is allowed but shouldn't be the
## one the eye lands on. Carries no accent at all, so nothing about it says
## "this is the answer".
static func make_ghost_button(button: Button, scale: float) -> void:
	var blank := _button_style(scale, Color(0, 0, 0, 0), Color(0, 0, 0, 0))
	var lit := _button_style(scale, NIGHT_WASH, NIGHT_EDGE)
	var held := _button_style(scale, Color("f1e7da", 0.14), NIGHT_EDGE)
	button.add_theme_stylebox_override("normal", blank)
	button.add_theme_stylebox_override("focus", lit)
	button.add_theme_stylebox_override("hover", lit)
	button.add_theme_stylebox_override("pressed", held)
	button.add_theme_color_override("font_color", NIGHT_MUTED)
	button.add_theme_color_override("font_hover_color", NIGHT_TEXT)
	button.add_theme_color_override("font_pressed_color", NIGHT_TEXT)


## Wiping everything is allowed, but it should never be the easiest thing on
## screen to hit. Outlined rather than filled, and quiet until hovered.
static func make_danger_button(button: Button, scale: float) -> void:
	var outline := _button_style(scale, Color(0, 0, 0, 0), Color(ACCENT, 0.45))
	var lit := _button_style(scale, Color(ACCENT, 0.18), Color(ACCENT, 0.8))
	var held := _button_style(scale, Color(ACCENT, 0.30), ACCENT)
	button.add_theme_stylebox_override("normal", outline)
	button.add_theme_stylebox_override("focus", outline)
	button.add_theme_stylebox_override("hover", lit)
	button.add_theme_stylebox_override("pressed", held)
	button.add_theme_stylebox_override("disabled",
		_button_style(scale, Color(0, 0, 0, 0), Color("f1e7da", 0.08)))
	button.add_theme_color_override("font_color", ACCENT_TEXT)
	button.add_theme_color_override("font_hover_color", Color("fffaf3"))
	button.add_theme_color_override("font_disabled_color", NIGHT_MUTED)


# --- Consent dialog buttons ---------------------------------------------------

## The one action that sends a picture of the screen somewhere. It should not
## look like the two next to it.
static func primary_button_styles(scale: float) -> Dictionary:
	return {
		"normal": _button_style(scale, ACCENT, Color(0, 0, 0, 0)),
		"hover": _button_style(scale, ACCENT.lightened(0.10), Color(0, 0, 0, 0)),
		"pressed": _button_style(scale, ACCENT.darkened(0.12), Color(0, 0, 0, 0)),
		"focus": _button_style(scale, ACCENT, Color("fffaf3", 0.6)),
	}


static func _button_style(scale: float, fill: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(maxi(1, roundi(1.0 * scale)))
	box.set_corner_radius_all(roundi(9.0 * scale))
	box.corner_detail = 8
	box.content_margin_left = roundi(18.0 * scale)
	box.content_margin_right = roundi(18.0 * scale)
	box.content_margin_top = roundi(9.0 * scale)
	box.content_margin_bottom = roundi(9.0 * scale)
	return box
