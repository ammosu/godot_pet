extends Window
class_name MonitorPanel

## What is running on this machine and what it costs — the whole of MonitorService
## that isn't the one line the pet occasionally says out loud.
##
## Fifth window of the same shape as MemoryPanel, ChatLogPanel, OutboxPanel and
## WorkPanel, including the useful side effect: a real OS window touches nothing
## in the pet window's passthrough mask, so the Windows "the mask clips
## rendering" rule doesn't reach it.
##
## The split with the speech bubble is the point of the whole feature. Scanning
## every twenty minutes and *reporting* every twenty minutes are different
## decisions — a bubble that recites a process table twenty times a day has
## stopped being a pet — so the pet speaks only on a crossed threshold and
## everything else waits here until asked for.

const DESIGN_SIZE := Vector2i(470, 560)
const MIN_SIZE_RATIO := 0.75
## Enough to see whether the machine has been busy all afternoon without the
## strip taking over the window.
const HISTORY_SHOWN := 8

var _scale := 1.0
var _stamp: Label
var _machine: Label
var _empty: Label
var _cpu_rows: VBoxContainer
var _mem_rows: VBoxContainer
var _history_rows: VBoxContainer
var _cpu_heading: Label
var _mem_heading: Label
var _history_heading: Label
var _rescan: Button
var _hours: Label


func _ready() -> void:
	title = "電腦狀況"
	visible = false
	unresizable = false
	close_requested.connect(_close)
	EventBus.resources_sampled.connect(_on_sampled)


## Built on first open rather than in _ready(), for the reason MemoryPanel
## records: every spacing in here is a design unit and the display scale isn't
## known until the window is handed one.
func open(ui_scale: float) -> void:
	_scale = ui_scale
	theme = PetStyle.panel_theme(_scale)
	min_size = Vector2i(Vector2(DESIGN_SIZE) * _scale * MIN_SIZE_RATIO)
	if _cpu_rows == null:
		_build()
	refresh()
	popup_centered(Vector2i(Vector2(DESIGN_SIZE) * _scale))
	# Opening the window is itself a request to know what is happening now, and
	# the last automatic scan can be twenty minutes stale — or, on a machine
	# opened outside working hours, never have run at all.
	_scan()


func _close() -> void:
	hide()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", roundi(12.0 * _scale))
	panel.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", roundi(8.0 * _scale))
	root.add_child(header)
	var heading := Label.new()
	heading.text = "電腦現在的樣子"
	heading.add_theme_font_size_override("font_size", roundi(17.0 * _scale))
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_stamp = Label.new()
	_stamp.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_stamp.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	header.add_child(_stamp)

	root.add_child(HSeparator.new())

	_machine = Label.new()
	_machine.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_machine.add_theme_font_size_override("font_size", roundi(15.0 * _scale))
	root.add_child(_machine)

	_empty = Label.new()
	_empty.text = "還沒掃描過。\n按下面的「重新掃描」，或等下一次自動掃描。"
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_empty.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	root.add_child(_empty)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", roundi(6.0 * _scale))
	scroll.add_child(column)

	# Two rankings rather than one, because no single order answers both halves
	# of the question: a compiler pinning four cores has a tiny footprint, and an
	# editor sitting on 6 GB may be using no CPU at all.
	_cpu_heading = _add_heading(column, "吃 CPU 的")
	_cpu_rows = _add_rows(column)
	_mem_heading = _add_heading(column, "吃記憶體的")
	_mem_rows = _add_rows(column)
	_history_heading = _add_heading(column, "最近幾次掃描")
	_history_rows = _add_rows(column)

	root.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", roundi(8.0 * _scale))
	root.add_child(footer)
	_rescan = Button.new()
	_rescan.text = "重新掃描"
	_rescan.pressed.connect(_scan)
	PetStyle.make_quiet_button(_rescan, _scale)
	footer.add_child(_rescan)
	_hours = Label.new()
	_hours.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_hours.add_theme_font_size_override("font_size", roundi(12.0 * _scale))
	_hours.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hours.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hours.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	footer.add_child(_hours)
	var close := Button.new()
	close.text = "關閉"
	close.custom_minimum_size.x = roundi(88.0 * _scale)
	footer.add_child(close)
	close.pressed.connect(_close)


func _add_heading(parent: VBoxContainer, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	label.add_theme_font_size_override("font_size", roundi(12.0 * _scale))
	parent.add_child(label)
	return label


func _add_rows(parent: VBoxContainer) -> VBoxContainer:
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", roundi(2.0 * _scale))
	parent.add_child(rows)
	return rows


## A scan lands two seconds after it is asked for, so the button says what it is
## waiting for rather than looking dead.
func _scan() -> void:
	if not MonitorService.is_supported():
		return
	_rescan.disabled = true
	_rescan.text = "掃描中…"
	await MonitorService.scan()
	if not is_inside_tree():
		return
	_rescan.disabled = false
	_rescan.text = "重新掃描"


## A scan finished while this was on screen. Ignored before the first open, when
## _build() hasn't run and there is nothing to redraw.
func _on_sampled(_sample: Dictionary) -> void:
	if visible and _cpu_rows != null:
		refresh()


func refresh() -> void:
	_hours.text = "自動掃描：%s" % MonitorService.hours_label() \
		if MonitorService.is_enabled() else "自動掃描已關閉"

	var sample := MonitorService.latest()
	var has := not sample.is_empty()
	_empty.visible = not has
	_machine.visible = has
	_cpu_heading.visible = has
	_mem_heading.visible = has
	if not has:
		_stamp.text = ""
		_history_heading.visible = false
		_clear(_cpu_rows)
		_clear(_mem_rows)
		_clear(_history_rows)
		return

	_stamp.text = "%s 掃描" % _clock(float(sample["at"]))
	var total: int = sample["mem_total"]
	var available: int = sample["mem_available"]
	_machine.text = "CPU %d%%　・　記憶體 %d%%（還有 %s / 共 %s）　・　%d 個程序" % [
		roundi(float(sample["cpu"])),
		roundi(float(sample["mem_ratio"]) * 100.0),
		MonitorService.human_bytes(available),
		MonitorService.human_bytes(total),
		int(sample["process_count"]),
	]

	_fill(_cpu_rows, sample["top_cpu"], true)
	_fill(_mem_rows, sample["top_mem"], false)
	_fill_history()


func _fill(rows: VBoxContainer, entries: Array, by_cpu: bool) -> void:
	_clear(rows)
	for entry in entries:
		var value := "%d%%" % roundi(float(entry["cpu"])) if by_cpu \
			else "%s（%d%%）" % [MonitorService.human_bytes(int(entry["rss"])),
				roundi(float(entry["mem_ratio"]) * 100.0)]
		rows.add_child(_make_row(str(entry["name"]), value))


func _fill_history() -> void:
	_clear(_history_rows)
	var entries := MonitorService.history()
	# One scan is the one already shown above in full; a strip of it alone says
	# nothing about whether the machine has been busy.
	_history_heading.visible = entries.size() > 1
	if entries.size() <= 1:
		return
	var shown := entries.slice(maxi(0, entries.size() - HISTORY_SHOWN))
	shown.reverse()
	for entry in shown:
		_history_rows.add_child(_make_row(_clock(float(entry["at"])),
			"CPU %d%%　・　記憶體 %d%%" % [
				roundi(float(entry["cpu"])),
				roundi(float(entry["mem_ratio"]) * 100.0)]))


## Name on the left, number on the right, so the numbers form a column that can
## be read down without reading any of the names.
func _make_row(name: String, value: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", roundi(8.0 * _scale))

	var label := Label.new()
	label.text = name
	label.clip_text = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	row.add_child(label)

	var amount := Label.new()
	amount.text = value
	amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	amount.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	amount.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	row.add_child(amount)
	return row


func _clear(rows: VBoxContainer) -> void:
	for row in rows.get_children():
		row.queue_free()


## Local wall-clock, which is the only form a "when was this" reads as.
func _clock(unix_time: float) -> String:
	var t := Time.get_datetime_dict_from_unix_time(
		int(unix_time) + Time.get_time_zone_from_system()["bias"] * 60)
	return "%02d:%02d" % [int(t["hour"]), int(t["minute"])]
