extends Window
class_name CompanionStatusPanel

## A qualitative view of the shared companion state. Internal values remain
## numeric for decay and thresholds, but this surface deliberately avoids bars
## and percentages so caring for the companion does not become dashboard work.

const DESIGN_SIZE := Vector2i(380, 330)

var _scale := 1.0
var _heading: Label
var _rows: VBoxContainer
var _gap: Label


func _ready() -> void:
	title = "小夥伴狀態"
	visible = false
	unresizable = false
	close_requested.connect(hide)
	EventBus.state_tick.connect(_on_state_tick)
	CompanionProfile.changed.connect(_on_profile_changed)


func open(ui_scale: float) -> void:
	_scale = ui_scale
	theme = PetStyle.panel_theme(_scale)
	min_size = Vector2i(Vector2(DESIGN_SIZE) * _scale * 0.8)
	if _rows == null:
		_build()
	refresh()
	popup_centered(Vector2i(Vector2(DESIGN_SIZE) * _scale))


func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", roundi(12.0 * _scale))
	panel.add_child(root)

	_heading = Label.new()
	_heading.add_theme_font_size_override("font_size", roundi(17.0 * _scale))
	root.add_child(_heading)
	root.add_child(HSeparator.new())

	_rows = VBoxContainer.new()
	_rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", roundi(8.0 * _scale))
	root.add_child(_rows)

	_gap = Label.new()
	_gap.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_gap.add_theme_font_size_override("font_size", roundi(12.0 * _scale))
	root.add_child(_gap)

	root.add_child(HSeparator.new())
	var footer := HBoxContainer.new()
	root.add_child(footer)
	var note := Label.new()
	note.text = "狀態會隨相處與時間自然改變"
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	note.add_theme_font_size_override("font_size", roundi(12.0 * _scale))
	footer.add_child(note)
	var close := Button.new()
	close.text = "關閉"
	close.custom_minimum_size.x = roundi(88.0 * _scale)
	close.pressed.connect(hide)
	footer.add_child(close)


func refresh() -> void:
	if _rows == null:
		return
	for child in _rows.get_children():
		child.queue_free()
	_heading.text = "%s現在怎麼樣" % CompanionProfile.self_name()
	if CompanionProfile.care_enabled():
		_add_row(&"care")
	_add_row(&"energy")
	_add_row(&"mood")
	_add_row(&"bond")
	_gap.text = "距離上次聊天：%s" % _gap_text(PetState.minutes_since_talk())


func _add_row(state: StringName) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", roundi(12.0 * _scale))
	_rows.add_child(row)
	var name := Label.new()
	name.text = CompanionProfile.state_label(state)
	name.custom_minimum_size.x = roundi(92.0 * _scale)
	name.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	row.add_child(name)
	var value := Label.new()
	value.text = CompanionProfile.grade(state, PetState.get_need(state))
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.add_theme_font_size_override("font_size", roundi(15.0 * _scale))
	row.add_child(value)


func _gap_text(minutes: float) -> String:
	if minutes < 5.0:
		return "剛剛"
	if minutes < 60.0:
		return "%d 分鐘前" % int(minutes)
	if minutes < 24.0 * 60.0:
		return "%d 小時前" % int(minutes / 60.0)
	return "超過一天"


func _on_state_tick(_state: Dictionary) -> void:
	if visible:
		refresh()


func _on_profile_changed() -> void:
	if visible:
		refresh()
