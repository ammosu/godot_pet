extends Window
class_name WorkPanel

## The fourth window of the same shape as the memory, transcript and outbox
## panels — and for the same three reasons, including the useful one: it is a real
## OS window, so nothing in here touches the pet window's passthrough mask.
##
## Two halves, deliberately in this order. The top is the job running right now,
## because that is what you open this for while the pet is working. The bottom is
## the list of folders the pet may touch, which is the durable thing and the one
## you come back to rarely.
##
## The bubble gets one line; this gets everything. That split is the whole design
## of the work feature — a speech bubble filling with tool calls has stopped being
## a pet — so this window is where "what is it actually doing" is answerable.

## A workspace was added or removed, so the menu that lists them needs rebuilding.
signal workspaces_changed

const DESIGN_SIZE := Vector2i(480, 560)
const MIN_SIZE_RATIO := 0.8

## Older steps stay in WorkService's log but stop being drawn. The interesting
## end of a progress list is the recent end.
const VISIBLE_STEPS := 60

var _scale := 1.0
var _job_box: VBoxContainer
var _job_title: Label
var _job_status: Label
var _steps: VBoxContainer
var _steps_scroll: ScrollContainer
var _cancel: Button
var _idle_label: Label
var _spaces: VBoxContainer
var _spaces_empty: Label
var _picker: FileDialog
## The last finished job, so closing and reopening the window doesn't lose what
## just happened. Empty until one completes.
var _last := {}


func _ready() -> void:
	title = "工作"
	visible = false
	unresizable = false
	close_requested.connect(_close)
	WorkService.progress.connect(_on_progress)
	WorkService.state_changed.connect(_on_state_changed)
	WorkService.finished.connect(_on_finished)
	WorkService.failed.connect(_on_failed)
	WorkspaceService.changed.connect(_refresh_spaces_if_open)


## Built on first open, not in _ready(): every spacing here is a design unit that
## needs the display scale, which the window can't know until it's handed one.
func open(ui_scale: float) -> void:
	_scale = ui_scale
	theme = PetStyle.panel_theme(_scale)
	min_size = Vector2i(Vector2(DESIGN_SIZE) * _scale * MIN_SIZE_RATIO)
	if _spaces == null:
		_build()
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

	# --- The job ---
	_job_box = VBoxContainer.new()
	# Without this the box takes its minimum height, and the scroll container
	# inside it has a minimum of zero — so the progress log collapses to nothing
	# and a running job shows a header with a blank space where the steps are.
	_job_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_job_box)

	var job_header := HBoxContainer.new()
	_job_box.add_child(job_header)
	_job_title = Label.new()
	_job_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_job_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	job_header.add_child(_job_title)
	_cancel = Button.new()
	_cancel.text = "停下來"
	_cancel.pressed.connect(WorkService.cancel)
	job_header.add_child(_cancel)

	_job_status = Label.new()
	_job_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_job_box.add_child(_job_status)

	_steps_scroll = ScrollContainer.new()
	_steps_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_steps_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_steps_scroll.custom_minimum_size.y = roundi(90.0 * _scale)
	_job_box.add_child(_steps_scroll)
	_steps = VBoxContainer.new()
	_steps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_steps_scroll.add_child(_steps)

	_idle_label = Label.new()
	_idle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_idle_label.text = "現在沒有在做什麼。\n右鍵選單的「幫我做事…」可以交代事情給我。"
	root.add_child(_idle_label)

	root.add_child(HSeparator.new())

	# --- The workspaces ---
	var spaces_header := HBoxContainer.new()
	root.add_child(spaces_header)
	var spaces_heading := Label.new()
	spaces_heading.text = "我可以動的資料夾"
	spaces_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spaces_header.add_child(spaces_heading)
	var add := Button.new()
	add.text = "加資料夾…"
	add.pressed.connect(_on_add_pressed)
	spaces_header.add_child(add)

	_spaces_empty = Label.new()
	_spaces_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Names the two ways in, because an empty allowlist with no visible way to
	# fill it reads as a feature that isn't finished.
	_spaces_empty.text = "還沒有。把資料夾拖到我身上，或按上面的按鈕加一個。"
	root.add_child(_spaces_empty)

	var spaces_scroll := ScrollContainer.new()
	spaces_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	spaces_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spaces_scroll)
	_spaces = VBoxContainer.new()
	_spaces.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spaces_scroll.add_child(_spaces)

	root.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	root.add_child(footer)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var close := Button.new()
	close.text = "關閉"
	close.pressed.connect(_close)
	footer.add_child(close)

	_picker = FileDialog.new()
	_picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	# The whole filesystem, not just res:// — these are the user's own projects.
	_picker.access = FileDialog.ACCESS_FILESYSTEM
	_picker.use_native_dialog = true
	_picker.title = "挑一個資料夾"
	_picker.dir_selected.connect(_on_dir_picked)
	add_child(_picker)

	_style(root, job_header, spaces_header, footer, spaces_heading, add, close)


func _style(root: VBoxContainer, job_header: HBoxContainer, spaces_header: HBoxContainer,
		footer: HBoxContainer, spaces_heading: Label, add: Button, close: Button) -> void:
	root.add_theme_constant_override("separation", roundi(12.0 * _scale))
	_job_box.add_theme_constant_override("separation", roundi(6.0 * _scale))
	job_header.add_theme_constant_override("separation", roundi(8.0 * _scale))
	spaces_header.add_theme_constant_override("separation", roundi(8.0 * _scale))
	footer.add_theme_constant_override("separation", roundi(8.0 * _scale))
	_steps.add_theme_constant_override("separation", roundi(1.0 * _scale))
	_spaces.add_theme_constant_override("separation", roundi(2.0 * _scale))

	for heading in [_job_title, spaces_heading]:
		heading.add_theme_font_size_override("font_size", roundi(16.0 * _scale))
	for muted in [_job_status, _idle_label, _spaces_empty]:
		muted.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
		muted.add_theme_font_size_override("font_size", roundi(13.0 * _scale))

	PetStyle.make_danger_button(_cancel, _scale)
	PetStyle.make_quiet_button(add, _scale)
	close.custom_minimum_size.x = roundi(88.0 * _scale)


func refresh_if_open() -> void:
	if visible and _spaces != null:
		refresh()


func _refresh_spaces_if_open() -> void:
	if visible and _spaces != null:
		_refresh_spaces()


func refresh() -> void:
	_refresh_job()
	_refresh_spaces()


# --- The job ------------------------------------------------------------------

func _refresh_job() -> void:
	var job := WorkService.current()
	var busy := not job.is_empty()
	_job_box.visible = busy or not _last.is_empty()
	_idle_label.visible = not _job_box.visible
	_cancel.visible = busy

	if busy:
		_job_title.text = str(job["request"])
		_job_status.text = "在 %s ・ %s ・ 已經 %d 秒" % [
			str(job["space"].get("name", "")),
			WorkService.runner_label(str(job["runner"])),
			int(job["seconds"]),
		]
		_redraw_steps(WorkService.log_entries())
		return

	if _last.is_empty():
		return
	_job_title.text = str(_last.get("request", ""))
	_job_status.text = str(_last.get("summary", ""))
	_redraw_steps(_last.get("lines", []))


## The whole list, from scratch. Only used on open and at the end of a job — a
## running one appends single rows instead (see _on_progress), so a job that takes
## ten minutes doesn't rebuild a 400-row list four times a second.
func _redraw_steps(entries: Array) -> void:
	for row in _steps.get_children():
		row.queue_free()
	var start := maxi(0, entries.size() - VISIBLE_STEPS)
	for i in range(start, entries.size()):
		_steps.add_child(_make_step(entries[i]))


func _make_step(entry: Dictionary) -> Control:
	var label := Label.new()
	var note := str(entry.get("kind", "")) == "note"
	label.text = ("— %s" % str(entry.get("text", ""))) if note else str(entry.get("text", ""))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", roundi(12.0 * _scale))
	label.add_theme_color_override("font_color",
		PetStyle.ACCENT_TEXT if note else PetStyle.NIGHT_MUTED)
	return label


## Appending one row rather than redrawing, and scrolling to it — a progress log
## you have to chase with the scrollbar is one nobody reads.
func _on_progress(entry: Dictionary) -> void:
	if not visible or _steps == null:
		return
	_steps.add_child(_make_step(entry))
	while _steps.get_child_count() > VISIBLE_STEPS:
		var oldest := _steps.get_child(0)
		_steps.remove_child(oldest)
		oldest.queue_free()
	# The scrollbar's range only grows once the container has laid out.
	await get_tree().process_frame
	if is_instance_valid(_steps_scroll):
		_steps_scroll.scroll_vertical = int(_steps_scroll.get_v_scroll_bar().max_value)


func _on_state_changed() -> void:
	if visible and _spaces != null:
		_refresh_job()


func _on_finished(result: Dictionary) -> void:
	var changes: PackedStringArray = result.get("changes", PackedStringArray())
	var summary := "%s ・ %d 秒" % [
		str(result.get("message", "")),
		int(result.get("seconds", 0.0)),
	]
	var cost := float(result.get("cost", 0.0))
	if cost > 0.0:
		summary += " ・ 約 $%.2f" % cost
	if changes.is_empty():
		summary += "\n（沒有檔案被改動）"
	else:
		summary += "\n改了 %d 項：\n%s" % [changes.size(), "\n".join(changes)]
	_remember(result, summary)


func _on_failed(reason: String) -> void:
	_remember({"request": WorkService.last_request()}, reason)


## Snapshot the log as well as the summary: WorkService clears its own on the next
## job, and this window should still show what the last one did.
func _remember(result: Dictionary, summary: String) -> void:
	_last = {
		"request": str(result.get("request", _last.get("request", ""))),
		"summary": summary,
		"lines": WorkService.log_entries().duplicate(true),
	}
	if visible and _spaces != null:
		_refresh_job()
		# A finished job is what creates a session, so the row's 重來 button
		# appears here and nowhere else.
		_refresh_spaces()


# --- The workspaces -----------------------------------------------------------

func _refresh_spaces() -> void:
	for row in _spaces.get_children():
		row.queue_free()
	var spaces := WorkspaceService.list()
	for space in spaces:
		_spaces.add_child(_make_space_row(space))
	_spaces_empty.visible = spaces.is_empty()


func _make_space_row(space: Dictionary) -> Control:
	var path := str(space["path"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", roundi(8.0 * _scale))

	var name_box := VBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.add_theme_constant_override("separation", 0)
	row.add_child(name_box)

	var name := Label.new()
	name.text = str(space["name"])
	name.add_theme_font_size_override("font_size", roundi(14.0 * _scale))
	if not bool(space["exists"]):
		# A folder can be moved or deleted while it is still on the list. Saying so
		# beats a job that fails to start for no visible reason.
		name.text += "（找不到了）"
		name.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	name_box.add_child(name)

	var where := Label.new()
	where.text = path
	where.add_theme_font_size_override("font_size", roundi(11.0 * _scale))
	where.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	# A Label's minimum width is its whole text, so a long path pushes the window
	# wider than it was sized for and shoves the level and delete buttons off the
	# right edge. Clipping drops that minimum to zero; the full path is still
	# readable in the tooltip.
	where.clip_text = true
	where.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	where.tooltip_text = path
	name_box.add_child(where)

	# The level is a button rather than a label: it is the one thing here worth
	# changing often, and a switch you can read is a switch you can flip.
	var level := Button.new()
	var editable := str(space["level"]) == WorkspaceService.LEVEL_EDIT
	level.text = WorkspaceService.level_label(str(space["level"]))
	level.tooltip_text = "按一下切換：可以改 / 只能看"
	PetStyle.make_quiet_button(level, _scale)
	level.pressed.connect(func() -> void:
		WorkspaceService.set_level(path,
			WorkspaceService.LEVEL_READ if editable else WorkspaceService.LEVEL_EDIT)
		_refresh_spaces()
		workspaces_changed.emit())
	row.add_child(level)

	# Only when there is something to forget, so the ordinary row stays two
	# buttons wide. A conversation that has run long enough to wander is the one
	# case where carrying it on costs more than it saves.
	if not WorkspaceService.get_session(path).is_empty():
		var fresh := Button.new()
		fresh.text = "重來"
		fresh.tooltip_text = "忘掉上次的脈絡，下次從頭開始"
		PetStyle.make_quiet_button(fresh, _scale)
		fresh.pressed.connect(func() -> void:
			WorkspaceService.clear_session(path)
			_refresh_spaces())
		row.add_child(fresh)

	var drop := Button.new()
	drop.text = "✕"
	drop.tooltip_text = "從清單移除（不會刪掉資料夾）"
	PetStyle.make_quiet_button(drop, _scale)
	drop.pressed.connect(func() -> void:
		WorkspaceService.remove(path)
		_refresh_spaces()
		workspaces_changed.emit())
	row.add_child(drop)
	return row


## Reachable from the menu as well as from the button, so 加一個資料夾 works
## without the user having to find it in here first.
func pick_folder() -> void:
	if _picker == null:
		return
	_picker.popup_centered_ratio(0.6)


func _on_add_pressed() -> void:
	pick_folder()


func _on_dir_picked(dir: String) -> void:
	var reason := WorkspaceService.add(dir)
	if not reason.is_empty():
		_spaces_empty.text = reason
		_spaces_empty.visible = true
		return
	_spaces_empty.text = "還沒有。把資料夾拖到我身上，或按上面的按鈕加一個。"
	_refresh_spaces()
	workspaces_changed.emit()
