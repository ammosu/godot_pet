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

## The way out of the chat field, tucked inside its right cap.
##
## Inside rather than beside, for two reasons. The passthrough mask is built
## from `ChatPanel.get_input_rect()` — the field's own rect — so a button within
## it is clickable with no change to the mask at all, where one hanging off the
## edge would silently not receive the click that closes it. And the field is
## the only thing on screen at that moment that the button belongs to; floating
## it outside would read as a second, unrelated control.
##
## Sized as a fraction of the field's height so it stays a circle inside the
## rounded cap at any display scale.
const INPUT_CLOSE_RATIO := 0.58
const INPUT_CLOSE_INSET := 5.0


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
## `right_pad` is room reserved for the close button, on top of the ordinary
## padding, so a long line of text never slides underneath it.
##
## `height` is only ever read for the corner radius, so a field that has grown
## taller than one line still passes its *single-line* height here and keeps the
## pill's corner instead of turning into a lozenge. `pad_y` overrides the
## vertical inset for the same reason in reverse: a LineEdit centres its one line
## itself, a TextEdit draws from the top, so the multi-line field has to be given
## the padding that puts a single row in the middle of the same pill.
static func input_style(scale: float, height: float, secret: bool,
		right_pad := 0.0, pad_y := -1.0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = PAPER
	box.border_color = Color(SECRET, 0.45) if secret else EDGE
	box.set_border_width_all(maxi(1, roundi(INPUT_BORDER * scale)))
	box.set_corner_radius_all(roundi(height * 0.5))
	box.corner_detail = 12
	box.content_margin_left = roundi(INPUT_PADDING * scale)
	box.content_margin_right = roundi(INPUT_PADDING * scale + right_pad)
	box.content_margin_top = _input_inset_y(scale, pad_y)
	box.content_margin_bottom = _input_inset_y(scale, pad_y)
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
static func input_focus_style(scale: float, height: float, secret: bool,
		right_pad := 0.0, pad_y := -1.0) -> StyleBoxFlat:
	var tint := SECRET if secret else ACCENT
	var box := StyleBoxFlat.new()
	box.bg_color = Color(PAPER, 1.0)
	box.border_color = Color(tint, 0.85)
	box.set_border_width_all(maxi(1, roundi(INPUT_FOCUS_BORDER * scale)))
	box.set_corner_radius_all(roundi(height * 0.5))
	box.corner_detail = 12
	box.content_margin_left = roundi(INPUT_PADDING * scale)
	# Must match input_style()'s, or the text jumps sideways when the field takes
	# focus — the two boxes are the same field in two states, not two fields.
	box.content_margin_right = roundi(INPUT_PADDING * scale + right_pad)
	box.content_margin_top = _input_inset_y(scale, pad_y)
	box.content_margin_bottom = _input_inset_y(scale, pad_y)
	# Not blurred — Godot has no such thing — so it reads as a ring rather than a
	# glow. Kept faint enough that it registers as "this field is live" instead of
	# as a second border.
	box.shadow_color = Color(tint, 0.18)
	box.shadow_size = roundi(INPUT_FOCUS_GLOW * scale)
	return box


## The two boxes above are the same field in two states, so they must agree on
## every inset or the text jumps when it takes focus.
static func _input_inset_y(scale: float, pad_y: float) -> int:
	return roundi(INPUT_PADDING_Y * scale) if pad_y < 0.0 else roundi(pad_y)


static func input_caret_color(secret: bool) -> Color:
	return SECRET if secret else ACCENT


static func input_close_size(height: float) -> float:
	return roundf(height * INPUT_CLOSE_RATIO)


## Room the field has to leave on its right so text clears the close button.
static func input_close_reserve(height: float, scale: float) -> float:
	return input_close_size(height) + INPUT_CLOSE_INSET * scale


## Quiet on paper. The one saturated colour in this project marks the live thing
## on screen, and a way out of a field is not that — so this is ink, and it has
## no fill at all until the pointer is over it.
##
## Styles a *blank* hit target. The cross is drawn by ChatPanel rather than set
## as this button's text, because a Button centres its label's line box, and the
## tall CJK face this project ships puts a "×" visibly above the middle of a
## circle this small — as well as setting a minimum height that stops the circle
## being a circle.
static func make_input_close_button(button: Button, height: float) -> void:
	var d := input_close_size(height)
	button.add_theme_stylebox_override("normal", _round_style(Color(0, 0, 0, 0), d))
	button.add_theme_stylebox_override("focus", _round_style(Color(0, 0, 0, 0), d))
	button.add_theme_stylebox_override("hover", _round_style(Color(INK, 0.08), d))
	button.add_theme_stylebox_override("pressed", _round_style(Color(INK, 0.16), d))


## A circle, for the one control small enough that a rounded rectangle would
## just look like a mistake.
static func _round_style(fill: Color, diameter: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(roundi(diameter * 0.5))
	box.corner_detail = 8
	box.set_content_margin_all(0.0)
	return box


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


# --- Conversation log ---------------------------------------------------------

const LOG_BUBBLE_CORNER := 13.0
## The corner nearest the speaker, squared off rather than rounded.
const LOG_BUBBLE_ROOT := 4.0
const LOG_BUBBLE_PADDING := 11.0
const LOG_BUBBLE_PADDING_Y := 8.0


## One row of the transcript.
##
## The two surfaces this file opens with are exactly the distinction a
## conversation list needs, so it borrows them rather than inventing a third:
## what the pet said is paper, what you said is the app's own ink. The pet's
## lines are the ones that carry the character, and on the dark slab paper is
## also the one that catches the eye first — which is the right way round.
##
## No tail. One is a bubble; a column of twelve is noise. The corner nearest the
## speaker is squared off instead, which says the same thing quietly enough to
## repeat.
static func chat_log_bubble_style(scale: float, mine: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = NIGHT_WASH if mine else PAPER
	# Paper needs no outline against the night panel; the wash is faint enough
	# that without one it stops reading as a bubble at all.
	box.border_color = NIGHT_EDGE if mine else Color(0, 0, 0, 0)
	box.set_border_width_all(maxi(1, roundi(1.0 * scale)))
	box.set_corner_radius_all(roundi(LOG_BUBBLE_CORNER * scale))
	if mine:
		box.corner_radius_bottom_right = roundi(LOG_BUBBLE_ROOT * scale)
	else:
		box.corner_radius_bottom_left = roundi(LOG_BUBBLE_ROOT * scale)
	box.corner_detail = 10
	box.content_margin_left = roundi(LOG_BUBBLE_PADDING * scale)
	box.content_margin_right = roundi(LOG_BUBBLE_PADDING * scale)
	box.content_margin_top = roundi(LOG_BUBBLE_PADDING_Y * scale)
	box.content_margin_bottom = roundi(LOG_BUBBLE_PADDING_Y * scale)
	return box


static func chat_log_text_color(mine: bool) -> Color:
	return NIGHT_TEXT if mine else INK


# --- Mini-game ----------------------------------------------------------------

## The play field is a screen set into the panel: a shade darker than the chrome
## around it, so it reads as somewhere else rather than as more panel.
const GAME_FIELD := Color("17110f")
const GAME_GROUND := Color("f1e7da", 0.16)
## The three dots that count what got past you. Spent ones stay visible, so the
## row always says how many there were as well as how many are left.
const GAME_LIFE := Color("f1e7da", 0.55)
const GAME_LIFE_SPENT := Color("f1e7da", 0.12)

## The food. This is the one surface in the app that needs several saturated
## colours at once — three treats have to be told apart while falling — so the
## rule that keeps it from turning into confetti is a different one: **the only
## red on the field is the thing you must not catch.** Everything edible is
## cream, green or teal, and the miss is unambiguous at a glance and at speed.
const GAME_RICE := Color("f4ecdd")
const GAME_NORI := Color("39463f")
const GAME_APPLE := Color("9ec46a")
const GAME_STEM := Color("6d5136")
const GAME_FISH := Color("5fb0ad")
## Gold rather than the persimmon accent: the accent means "the live control" in
## every other window, and a bonus that looks like the chilli would undo the
## whole point of the rule above.
const GAME_STAR := Color("f0c05a")
const GAME_CHILLI := Color("c8383f")
const GAME_CHILLI_STEM := Color("6f8f4e")
## The three that exist only so 翻翻看 has eight faces to tell apart. Shape does
## most of that work — a ring and a stem read differently from a circle at any
## size — but colour has to carry the rest.
const GAME_DONUT := Color("d9a06b")
const GAME_MUSHROOM := Color("a98cc9")
const GAME_MUSHROOM_STEM := Color("efe4d2")
const GAME_HEART := Color("e08a9a")
## The last two exist because 翻翻看's hardest board is ten pairs, and nine
## faces would mean two of them repeating — which sounds harder and is in fact
## easier, since any two of four identical cards match. Both were picked to fill
## the hues the other eight left empty: there was no blue and no dark green.
const GAME_CLOUD := Color("9fb8d0")
const GAME_LEAF := Color("4f8f5a")
const GAME_LEAF_VEIN := Color("2f5f39")
## Eyes and other holes. A named ink rather than the field colour, because the
## same shapes are drawn on the dark field in one game and on a paper card in
## another — punching a hole the colour of one background leaves a smudge on the
## other.
const GAME_ITEM_INK := Color("2b2018")
## Court markings for 排球對決. The player's persimmon and the rival's teal
## identify sides without recolouring whichever pet pack the user installed.
const GAME_VOLLEY_PLAYER := Color("dc7b56")
const GAME_VOLLEY_RIVAL := Color("5fb0ad")
const GAME_VOLLEY_BALL := Color("f4ecdd")
const GAME_VOLLEY_SEAM := Color("b87958")
const GAME_VOLLEY_NET := Color("d8cfc1", 0.72)
## Platform language for 下樓梯. Normal ground is quiet paper; every special
## platform has one distinct hue and silhouette so it can be read while falling.
const GAME_DESCENT_PLATFORM := Color("d8cfc1")
const GAME_DESCENT_MOVING := Color("5fb0ad")
const GAME_DESCENT_SPRING := Color("f0c05a")
const GAME_DESCENT_BREAK := Color("b87958")
const GAME_DESCENT_DANGER := Color("c8383f")
## Brick rows for 敲磚塊 reuse the field's established hues, but every row keeps
## one colour so the wall reads as a structure instead of scattered confetti.
const GAME_BREAKOUT_CREAM := Color("e9dfd1")
const GAME_BREAKOUT_TEAL := Color("5fb0ad")
const GAME_BREAKOUT_GOLD := Color("f0c05a")
const GAME_BREAKOUT_PERSIMMON := Color("dc7b56")
const GAME_BREAKOUT_GREEN := Color("83a968")
const GAME_BREAKOUT_BALL := Color("f4ecdd")
const GAME_BREAKOUT_PADDLE := Color("dc7b56")


## A card in 翻翻看. Face down it is chrome; face up it is paper, which is the
## same two surfaces the rest of the app already uses and puts the thing you are
## being asked to remember on the brighter one.
static func game_card_style(scale: float, face_up: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = PAPER if face_up else Color("241d1a")
	box.border_color = Color(0, 0, 0, 0) if face_up else NIGHT_EDGE
	box.set_border_width_all(maxi(1, roundi(1.0 * scale)))
	box.set_corner_radius_all(roundi(9.0 * scale))
	box.corner_detail = 8
	return box


## A pair already found. Still legible — the board you have solved so far is
## half of what you are remembering — but plainly out of play.
static func game_card_done_style(scale: float) -> StyleBoxFlat:
	var box := game_card_style(scale, true)
	box.bg_color = Color(PAPER, 0.22)
	return box


## The ring around whichever card the keyboard is on. Drawn over the card rather
## than replacing it, so it says "here" without saying anything about what state
## the card underneath is in.
static func game_card_cursor_style(scale: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0)
	box.border_color = ACCENT
	box.set_border_width_all(maxi(2, roundi(2.0 * scale)))
	box.set_corner_radius_all(roundi(9.0 * scale))
	box.corner_detail = 8
	return box


## The field itself. Rounded and inset, because a square hole in the panel reads
## as a rendering mistake rather than as a screen.
static func game_field_style(scale: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = GAME_FIELD
	box.border_color = NIGHT_EDGE
	box.set_border_width_all(maxi(1, roundi(1.0 * scale)))
	box.set_corner_radius_all(roundi(12.0 * scale))
	box.corner_detail = 10
	return box


## What the field says when nothing is falling — before a run, and after one.
## Sits over the field rather than replacing it, so the pet stays on screen
## holding the score instead of the whole game blinking out.
static func game_banner_style(scale: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color("17110f", 0.88)
	box.border_color = NIGHT_EDGE
	box.set_border_width_all(maxi(1, roundi(1.0 * scale)))
	box.set_corner_radius_all(roundi(14.0 * scale))
	box.corner_detail = 10
	box.content_margin_left = roundi(26.0 * scale)
	box.content_margin_right = roundi(26.0 * scale)
	box.content_margin_top = roundi(18.0 * scale)
	box.content_margin_bottom = roundi(18.0 * scale)
	return box


## One segment of a picker where exactly one option is on at a time.
##
## The chosen one is filled with the accent and the others carry nothing at all.
## A row of three outlined buttons reads as three separate things you could
## press; one filled and two bare reads as a single setting with a current
## value, which is what it is.
static func make_choice_button(button: Button, scale: float, chosen: bool) -> void:
	var box := func(fill: Color, border: Color) -> StyleBoxFlat:
		var style := StyleBoxFlat.new()
		style.bg_color = fill
		style.border_color = border
		style.set_border_width_all(maxi(1, roundi(1.0 * scale)))
		style.set_corner_radius_all(roundi(8.0 * scale))
		style.corner_detail = 8
		style.content_margin_left = roundi(13.0 * scale)
		style.content_margin_right = roundi(13.0 * scale)
		style.content_margin_top = roundi(6.0 * scale)
		style.content_margin_bottom = roundi(6.0 * scale)
		return style

	var idle: StyleBoxFlat = box.call(ACCENT, Color(0, 0, 0, 0)) if chosen \
		else box.call(Color(0, 0, 0, 0), Color(0, 0, 0, 0))
	var lit: StyleBoxFlat = box.call(ACCENT.lightened(0.10), Color(0, 0, 0, 0)) if chosen \
		else box.call(NIGHT_WASH, NIGHT_EDGE)
	button.add_theme_stylebox_override("normal", idle)
	button.add_theme_stylebox_override("focus", idle)
	button.add_theme_stylebox_override("hover", lit)
	button.add_theme_stylebox_override("pressed", lit)
	button.add_theme_color_override("font_color",
		Color("fffaf3") if chosen else NIGHT_MUTED)
	button.add_theme_color_override("font_hover_color", Color("fffaf3"))
	button.add_theme_color_override("font_pressed_color", Color("fffaf3"))
	button.add_theme_font_size_override("font_size", roundi(13.0 * scale))


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
