extends Window
class_name ChatLogPanel

## The conversation, as a list you can scroll back through.
##
## The speech bubble is the pet talking, and it behaves like talking: one line at
## a time, gone in at most twenty-two seconds, and a long reply scrolls away
## inside the bubble while you are still reading it. That is right for a pet and
## useless for going back to something it said. This window is the other half —
## nothing here is live, nothing fades, and every turn already on record is
## readable in order.
##
## It reads MemoryStore rather than keeping its own copy, for the same reason
## LLMService does: a second copy of the history alongside the persisted one is
## exactly how the two drift apart.
##
## A real OS window, like MemoryPanel, because subwindow embedding is off
## project-wide — the pet's own window is far too small to host anything.

## Emitted after the history is dropped, so the pet can say something about it.
signal conversation_cleared

const DESIGN_SIZE := Vector2i(440, 540)
## How far below the design size the user is allowed to drag the window.
const MIN_SIZE_RATIO := 0.8
## Panel margins plus room for the scrollbar, in design units. Only ever used to
## work out how wide a bubble is allowed to be, so an approximation is fine as
## long as it errs high.
const CHROME_WIDTH := 62.0
## The widest a bubble may be, as a fraction of the room available. Well under
## the full width on purpose: which side a line sits on is the only thing
## marking who said it, and a bubble that spans the panel has no side.
const BUBBLE_MAX_RATIO := 0.78

var _scale := 1.0
var _scroll: ScrollContainer
var _rows: VBoxContainer
var _count_label: Label
var _empty_label: Label
var _folded_note: Label
var _clear: Button
## The turns are gone for good and there is nowhere to get them back from, so
## the button asks first by becoming the question — the same answer MemoryPanel
## gives to the same problem one window along.
var _clear_armed := false


func _ready() -> void:
	title = "對話記錄"
	visible = false
	unresizable = false
	close_requested.connect(_close)

	# Kept current while it is open, so talking to the pet with the window up
	# doesn't leave a transcript that quietly stops matching the conversation.
	# Deferred because the turn is written to MemoryStore by another listener on
	# these same signals, and connection order decides which of us runs first.
	EventBus.user_said.connect(_on_conversation_changed.unbind(1))
	EventBus.file_content_said.connect(_on_conversation_changed.unbind(1))
	EventBus.reply_finished.connect(_on_conversation_changed.unbind(1))
	EventBus.pet_nudged.connect(_on_conversation_changed.unbind(2))


## Built on first open rather than in _ready(), because every spacing in here is
## a design unit that needs the display scale — which the window has no way to
## know until someone hands it one.
func open(ui_scale: float) -> void:
	_scale = ui_scale
	theme = PetStyle.panel_theme(_scale)
	min_size = Vector2i(Vector2(DESIGN_SIZE) * _scale * MIN_SIZE_RATIO)
	if _rows == null:
		_build()
	_clear_armed = false
	refresh()
	popup_centered(Vector2i(Vector2(DESIGN_SIZE) * _scale))
	_scroll_to_end()


func _close() -> void:
	hide()


func _on_conversation_changed() -> void:
	if not visible:
		return
	_refresh_and_follow.call_deferred()


## Following the end is what makes this readable while a conversation is going
## on; it is also wrong to do on open-and-scroll-up, which is why only the live
## path calls it.
func _refresh_and_follow() -> void:
	if not visible:
		return
	# Someone carried on talking with the question still on the button. That is
	# an answer of sorts, and it isn't yes.
	_clear_armed = false
	refresh()
	_scroll_to_end()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var root := VBoxContainer.new()
	panel.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var heading := Label.new()
	heading.text = "我們聊過的"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_count_label = Label.new()
	header.add_child(_count_label)

	root.add_child(HSeparator.new())

	_empty_label = Label.new()
	_empty_label.text = "還沒聊過什麼。\n跟我說句話，這裡就會開始有東西。"
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_empty_label)

	# Only what fits in the verbatim window is here; everything older has been
	# folded into the summary. Saying so is the difference between a list that
	# looks incomplete and one that is honest about where the rest went.
	_folded_note = Label.new()
	_folded_note.text = "更早以前的已經摺成摘要了，在「記憶與資料」裡。"
	_folded_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_folded_note)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_scroll)

	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)

	root.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	root.add_child(footer)
	_clear = Button.new()
	_clear.tooltip_text = "忘掉我們剛剛聊的，但還記得你是誰"
	_clear.pressed.connect(_on_clear)
	footer.add_child(_clear)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var close := Button.new()
	close.text = "關閉"
	close.pressed.connect(_close)
	footer.add_child(close)

	_style(root, header, heading, close)


## Everything here is laid out in physical pixels, so every constant is a design
## unit scaled at the point of use — same rule as the rest of the app.
func _style(root: VBoxContainer, header: HBoxContainer, heading: Label,
		close: Button) -> void:
	root.add_theme_constant_override("separation", roundi(12.0 * _scale))
	header.add_theme_constant_override("separation", roundi(8.0 * _scale))
	_rows.add_theme_constant_override("separation", roundi(8.0 * _scale))

	heading.add_theme_font_size_override("font_size", roundi(17.0 * _scale))
	_count_label.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_count_label.add_theme_font_size_override("font_size", roundi(13.0 * _scale))

	_empty_label.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_folded_note.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_folded_note.add_theme_font_size_override("font_size", roundi(12.0 * _scale))

	# Left as an ordinary themed button on purpose. It doesn't get the outlined
	# accent that 全部忘掉 wears next door, because it spares the facts and that
	# one doesn't — and it doesn't get the ghost treatment either, which turned
	# out to hide the one thing this window is *for* behind a button that read as
	# disabled, while 關閉 sat beside it looking like the real control.
	close.custom_minimum_size.x = roundi(88.0 * _scale)


func refresh() -> void:
	# Unparented before being freed, not just freed: queue_free() only takes
	# effect at the end of the frame, so otherwise the old rows are still
	# children while the new ones go in, and the list is briefly twice as long
	# as the conversation.
	for row in _rows.get_children():
		_rows.remove_child(row)
		row.queue_free()

	var history := MemoryStore.history()
	for message in history:
		_add_row(message)

	_count_label.text = "%d 則" % history.size()
	_count_label.visible = not history.is_empty()
	_empty_label.visible = history.is_empty()
	_folded_note.visible = not MemoryStore.summary().is_empty()
	_clear.disabled = history.is_empty()
	_clear.text = "真的清空？" if _clear_armed else "清空，開新對話"


## Widest a bubble may be, in physical pixels.
##
## Derived from the window's *minimum* width rather than its current one: the
## list has no horizontal scroll, so a bubble measured against today's width
## would be clipped the moment the window is dragged narrower, and re-measuring
## every row on every frame of a resize drag is not worth what it buys.
func _bubble_limit() -> float:
	var narrowest := float(DESIGN_SIZE.x) * MIN_SIZE_RATIO - CHROME_WIDTH
	return maxf(80.0, narrowest * BUBBLE_MAX_RATIO) * _scale


func _add_row(message: Dictionary) -> void:
	var mine: bool = str(message.get("role", "")) == "user"
	var text: String = str(message.get("content", ""))

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_child(row)

	# The column, not the bubble, is what hugs its side of the panel — so the
	# ephemeral footnote underneath lines up with the bubble it belongs to.
	#
	# SIZE_EXPAND is not optional on the right-hand side. An HBoxContainer lays
	# its children out end to end and gives a non-expanding one exactly its
	# minimum width, which leaves SHRINK_END nothing to shrink *within* — every
	# row comes out flush left, and which side a line sits on is the only thing
	# here saying who said it.
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", roundi(3.0 * _scale))
	column.size_flags_horizontal = Control.SIZE_EXPAND | \
		(Control.SIZE_SHRINK_END if mine else Control.SIZE_SHRINK_BEGIN)
	row.add_child(column)

	var bubble := PanelContainer.new()
	bubble.add_theme_stylebox_override("panel",
		PetStyle.chat_log_bubble_style(_scale, mine))
	column.add_child(bubble)

	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", PetStyle.chat_log_text_color(mine))
	label.add_theme_font_size_override("font_size", roundi(14.0 * _scale))
	# Chinese sits in a solid block without it — the same reason the speech
	# bubble opens its lines up.
	label.add_theme_constant_override("line_spacing", roundi(4.0 * _scale))
	bubble.add_child(label)
	# Only once it is in the tree: the width is measured off the theme's font,
	# and the theme is the window's.
	label.custom_minimum_size.x = _measure(label, text)

	if not message.get("ephemeral", false):
		return
	# What the pet saw on the screen stays in the recent window so follow-up
	# questions work, but never reaches the summary, the facts or the save file.
	# Showing it unlabelled here would make that promise invisible.
	var note := Label.new()
	note.text = "這則關掉就忘了"
	note.horizontal_alignment = \
		HORIZONTAL_ALIGNMENT_RIGHT if mine else HORIZONTAL_ALIGNMENT_LEFT
	note.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	note.add_theme_font_size_override("font_size", roundi(11.0 * _scale))
	column.add_child(note)


## How wide the bubble's text wants to be, so a two-word line gets a two-word
## bubble instead of one spanning the panel.
##
## Measured off the font rather than off the laid-out label, the same way the
## speech bubble does it: asking the label would feed its own width back into
## the answer.
func _measure(label: Label, text: String) -> float:
	var limit := _bubble_limit() - PetStyle.LOG_BUBBLE_PADDING * 2.0 * _scale
	var font := label.get_theme_font("font")
	if font == null:
		return limit
	var font_size := label.get_theme_font_size("font_size")
	var wrapped := font.get_multiline_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, limit, font_size)
	# A hair of slack: landing exactly on the measured width wraps the last
	# glyph of a line often enough to look like a bug.
	return clampf(wrapped.x + 2.0 * _scale, 0.0, limit)


## The newest turn is the one worth seeing first, and it is at the bottom.
##
## Two frames: the rows have to exist, and then the container has to lay them
## out, before the scrollbar knows how far it reaches.
func _scroll_to_end() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(_scroll) or not visible:
		return
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _on_clear() -> void:
	if not _clear_armed:
		_clear_armed = true
		refresh()
		return
	_clear_armed = false
	if not MemoryStore.clear_history():
		return
	refresh()
	conversation_cleared.emit()
