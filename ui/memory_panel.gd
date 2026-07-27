extends Window
class_name MemoryPanel

## What the pet remembers, shown as a list you can edit.
##
## This used to be a menu item that dumped every remembered line into the speech
## bubble, which was the wrong shape twice over: the bubble fades on a timer, so
## the answer to "what do you remember?" would time out while being read, and a
## list you can only read is a list you can only wipe. Here each line can go on
## its own — a pet quietly carrying one wrong fact about you shouldn't cost you
## all the right ones.
##
## A real OS window, because subwindow embedding is off project-wide (the pet's
## own window is far too small to host anything).

## Emitted whenever something was forgotten, so the menu can re-evaluate what it
## offers.
signal memories_changed

const DESIGN_SIZE := Vector2i(400, 440)

var _scale := 1.0
var _facts_box: VBoxContainer
var _summary_label: Label
var _summary_section: VBoxContainer
var _count_label: Label
var _empty_label: Label
var _forget_all: Button
## Wiping everything is one click away from a list of things you might want to
## keep, so the button asks first by becoming the question.
var _forget_armed := false


func _ready() -> void:
	title = "記憶與資料"
	visible = false
	unresizable = false
	close_requested.connect(_close)


## Built on first open rather than in _ready(), because every spacing in here is
## a design unit that needs the display scale — which the window has no way to
## know until someone hands it one.
func open(ui_scale: float) -> void:
	_scale = ui_scale
	theme = PetStyle.panel_theme(_scale)
	min_size = Vector2i(Vector2(DESIGN_SIZE) * _scale * 0.8)
	if _facts_box == null:
		_build()
	_disarm()
	refresh()
	popup_centered(Vector2i(Vector2(DESIGN_SIZE) * _scale))


func _close() -> void:
	hide()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var root := VBoxContainer.new()
	panel.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var heading := Label.new()
	heading.text = "我記得你這些事"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_count_label = Label.new()
	header.add_child(_count_label)

	root.add_child(HSeparator.new())

	_empty_label = Label.new()
	_empty_label.text = "還沒記住什麼欸。\n多跟我聊幾句，我就會開始記住你的事。"
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_empty_label)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)

	_facts_box = VBoxContainer.new()
	_facts_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_facts_box)

	# The summary is one paragraph written by the model, so it can't be edited a
	# line at a time the way the facts can — it clears as a block or not at all.
	_summary_section = VBoxContainer.new()
	_summary_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_summary_section)

	var summary_head := HBoxContainer.new()
	_summary_section.add_child(summary_head)
	var summary_title := Label.new()
	summary_title.text = "我們聊過什麼"
	summary_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_head.add_child(summary_title)
	var clear_summary := Button.new()
	clear_summary.text = "清掉"
	clear_summary.pressed.connect(func() -> void:
		MemoryStore.forget_summary()
		_announce())
	summary_head.add_child(clear_summary)

	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_section.add_child(_summary_label)

	root.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	root.add_child(footer)
	_forget_all = Button.new()
	_forget_all.pressed.connect(_on_forget_all)
	footer.add_child(_forget_all)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var close := Button.new()
	close.text = "關閉"
	close.pressed.connect(_close)
	footer.add_child(close)

	_style(root, header, heading, summary_title, clear_summary, close)


## Everything here is laid out in physical pixels, so every constant is a design
## unit scaled at the point of use — same rule as the rest of the app.
func _style(root: VBoxContainer, header: HBoxContainer, heading: Label,
		summary_title: Label, clear_summary: Button, close: Button) -> void:
	root.add_theme_constant_override("separation", roundi(12.0 * _scale))
	header.add_theme_constant_override("separation", roundi(8.0 * _scale))
	_facts_box.add_theme_constant_override("separation", roundi(2.0 * _scale))
	_summary_section.add_theme_constant_override("separation", roundi(6.0 * _scale))

	heading.add_theme_font_size_override("font_size", roundi(17.0 * _scale))
	_count_label.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_count_label.add_theme_font_size_override("font_size", roundi(13.0 * _scale))

	_empty_label.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_summary_label.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_summary_label.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	summary_title.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	summary_title.add_theme_font_size_override("font_size", roundi(12.0 * _scale))

	PetStyle.make_quiet_button(clear_summary, _scale)
	PetStyle.make_danger_button(_forget_all, _scale)
	close.custom_minimum_size.x = roundi(88.0 * _scale)


func refresh() -> void:
	for row in _facts_box.get_children():
		row.queue_free()

	var facts := MemoryStore.facts()
	for fact in facts:
		_facts_box.add_child(_make_row(fact))

	_count_label.text = "%d 則" % facts.size()
	_count_label.visible = not facts.is_empty()
	_empty_label.visible = not MemoryStore.has_memories()

	var summary := MemoryStore.summary()
	_summary_section.visible = not summary.is_empty()
	_summary_label.text = summary
	_forget_all.disabled = not MemoryStore.has_memories()
	_forget_all.text = "真的全部忘掉？" if _forget_armed else "全部忘掉"


func _make_row(fact: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", roundi(8.0 * _scale))

	var bullet := Label.new()
	bullet.text = "·"
	bullet.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	row.add_child(bullet)

	var text := Label.new()
	text.text = fact
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(text)

	var drop := Button.new()
	drop.text = "✕"
	drop.tooltip_text = "忘掉這一則"
	PetStyle.make_quiet_button(drop, _scale)
	drop.pressed.connect(func() -> void:
		MemoryStore.forget_fact(fact)
		_announce())
	row.add_child(drop)
	return row


func _on_forget_all() -> void:
	if not _forget_armed:
		_forget_armed = true
		refresh()
		return
	MemoryStore.forget_all()
	_disarm()
	_announce()


func _disarm() -> void:
	_forget_armed = false


func _announce() -> void:
	refresh()
	memories_changed.emit()
