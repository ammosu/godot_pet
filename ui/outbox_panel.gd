extends Window
class_name OutboxPanel

## The things the pet has made, as a list you can open and prune.
##
## Same shape and the same reasoning as MemoryPanel and ChatLogPanel: a list you
## can only read is a list you can only wipe, so every line goes on its own. And
## a real OS window, because subwindow embedding is off project-wide — with the
## useful side effect that nothing in here touches the pet window's passthrough
## mask, so the Windows "the mask clips rendering" rule doesn't reach it.
##
## This window is also the whole consent story for writing files. There is no
## per-file dialog, because a write into a folder that exists for this sends
## nothing anywhere and destroys nothing; what it risks is clutter. The answer to
## clutter is being able to see the clutter and delete it, which is this.

## Emitted whenever the list changed, so the menu can re-evaluate what it offers.
signal contents_changed

const DESIGN_SIZE := Vector2i(420, 460)
const MIN_SIZE_RATIO := 0.8

var _scale := 1.0
var _rows: VBoxContainer
var _count_label: Label
var _empty_label: Label
var _delete_all: Button
## Wiping the lot is one click away from a list of things worth keeping, so the
## button asks by becoming the question — same as MemoryPanel's 全部忘掉.
var _delete_armed := false


func _ready() -> void:
	title = "我做的東西"
	visible = false
	unresizable = false
	close_requested.connect(_close)


## Built on first open, not in _ready(): every spacing in here is a design unit
## that needs the display scale, which the window can't know until it's handed one.
func open(ui_scale: float) -> void:
	_scale = ui_scale
	theme = PetStyle.panel_theme(_scale)
	min_size = Vector2i(Vector2(DESIGN_SIZE) * _scale * MIN_SIZE_RATIO)
	if _rows == null:
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
	heading.text = "我幫你做的東西"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_count_label = Label.new()
	header.add_child(_count_label)

	root.add_child(HSeparator.new())

	_empty_label = Label.new()
	# Names the folder, because "nothing here yet" leaves the obvious question —
	# where would it be if there were something — unanswered.
	_empty_label.text = "還沒做過什麼東西。\n做出來的檔案會放在：\n%s" % OutboxService.folder_path()
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_empty_label)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)

	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_rows)

	root.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	root.add_child(footer)
	_delete_all = Button.new()
	_delete_all.pressed.connect(_on_delete_all)
	footer.add_child(_delete_all)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var open_folder := Button.new()
	open_folder.text = "開啟資料夾"
	open_folder.pressed.connect(OutboxService.open_folder)
	footer.add_child(open_folder)
	var close := Button.new()
	close.text = "關閉"
	close.pressed.connect(_close)
	footer.add_child(close)

	_style(root, header, footer, heading, open_folder, close)


## Laid out in physical pixels, so every constant is a design unit scaled where
## it's used — the same rule as the rest of the app.
func _style(root: VBoxContainer, header: HBoxContainer, footer: HBoxContainer,
		heading: Label, open_folder: Button, close: Button) -> void:
	root.add_theme_constant_override("separation", roundi(12.0 * _scale))
	header.add_theme_constant_override("separation", roundi(8.0 * _scale))
	footer.add_theme_constant_override("separation", roundi(8.0 * _scale))
	_rows.add_theme_constant_override("separation", roundi(2.0 * _scale))

	heading.add_theme_font_size_override("font_size", roundi(17.0 * _scale))
	_count_label.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_count_label.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	_empty_label.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_empty_label.add_theme_font_size_override("font_size", roundi(13.0 * _scale))

	PetStyle.make_danger_button(_delete_all, _scale)
	PetStyle.make_quiet_button(open_folder, _scale)
	close.custom_minimum_size.x = roundi(88.0 * _scale)


## Something else wrote a file while this was on screen. Ignored when the window
## has never been opened, since _build() hasn't run and there is nothing to redraw.
func refresh_if_open() -> void:
	if visible and _rows != null:
		refresh()


func refresh() -> void:
	for row in _rows.get_children():
		row.queue_free()

	var files := OutboxService.list_files()
	for file in files:
		_rows.add_child(_make_row(file))

	_count_label.text = "%d 個" % files.size()
	_count_label.visible = not files.is_empty()
	_empty_label.visible = files.is_empty()
	_delete_all.disabled = files.is_empty()
	_delete_all.text = "真的全部刪掉？" if _delete_armed else "全部刪掉"


func _make_row(file: Dictionary) -> Control:
	var name := str(file["name"])

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", roundi(8.0 * _scale))

	# The filename is the button: opening the thing is why you came here, so it
	# gets the whole row rather than a separate verb next to a label.
	var open := Button.new()
	open.text = name
	open.tooltip_text = "用系統預設程式開啟"
	open.alignment = HORIZONTAL_ALIGNMENT_LEFT
	open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	PetStyle.make_quiet_button(open, _scale)
	open.pressed.connect(func() -> void:
		OutboxService.open_file(name))
	row.add_child(open)

	var size := Label.new()
	size.text = OutboxService.human_size(int(file["size"]))
	size.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	size.add_theme_font_size_override("font_size", roundi(12.0 * _scale))
	size.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(size)

	var drop := Button.new()
	drop.text = "✕"
	drop.tooltip_text = "刪掉這個檔案"
	PetStyle.make_quiet_button(drop, _scale)
	drop.pressed.connect(func() -> void:
		OutboxService.delete(name)
		_announce())
	row.add_child(drop)
	return row


func _on_delete_all() -> void:
	if not _delete_armed:
		_delete_armed = true
		refresh()
		return
	for file in OutboxService.list_files():
		OutboxService.delete(str(file["name"]))
	_disarm()
	_announce()


func _disarm() -> void:
	_delete_armed = false


func _announce() -> void:
	refresh()
	contents_changed.emit()
