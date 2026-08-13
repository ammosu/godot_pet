extends Window
class_name GamePanel

## The window the mini-games live in — one window, whichever game.
##
## A real OS window, like the memory and transcript panels, and for the same
## reasons: subwindow embedding is off project-wide, the pet's own window is far
## too small to host anything, and — the useful side effect — nothing in here
## touches the pet window's passthrough mask, so none of the "the mask clips
## rendering on Windows" rules reach it.
##
## This file owns everything around a game: score, difficulty, the record, the
## banner, and the rule that nothing may hold focus. `MiniGame` is the field. The
## pet's *reaction* to a run belongs to neither and is emitted for the
## composition root, which is the only thing that knows how the pet reacts to
## anything.

## A run played out to its end. `record` rides along because beating your own
## best is the one result worth a different line, and only this file knows the
## table; `game` because with several of them the pet naming the one you just
## played is the difference between it having been there and it having been told.
signal played(game: String, score: int, treats: int, record: bool)

## The games, in the order the menu lists them. `id` keys the saved record and
## the saved difficulty, so it must not change once anyone has a score.
##
## A plain table rather than static methods on the game classes: this is the one
## place that has to know all of them, adding another is one line, and the menu
## can be built without instantiating anything.
##
## `preload()` rather than the global class names — a `class_name` is not a
## constant expression, and putting one in here is a parse error on the whole
## file, which takes pet.gd down with it.
const CATCH_GAME := preload("res://ui/games/catch_game.gd")
const JUMP_GAME := preload("res://ui/games/jump_game.gd")
const MEMORY_GAME := preload("res://ui/games/memory_game.gd")
const VOLLEYBALL_GAME := preload("res://ui/games/volleyball_game.gd")
const DESCENT_GAME := preload("res://ui/games/descent_game.gd")
const BREAKOUT_GAME := preload("res://ui/games/breakout_game.gd")
const SOKOBAN_GAME := preload("res://ui/games/sokoban_game.gd")
const ONE_STROKE_GAME := preload("res://ui/games/one_stroke_game.gd")
const SNAKE_GAME := preload("res://ui/games/snake_game.gd")
const MINESWEEPER_GAME := preload("res://ui/games/minesweeper_game.gd")
const BEE_GAME := preload("res://ui/games/bee_game.gd")

const GAMES: Array[Dictionary] = [
	{"id": "catch", "label": "接東西", "script": CATCH_GAME},
	{"id": "jump", "label": "跳過去", "script": JUMP_GAME},
	{"id": "memory", "label": "翻翻看", "script": MEMORY_GAME},
	{"id": "volleyball", "label": "排球對決", "script": VOLLEYBALL_GAME},
	{"id": "descent", "label": "下樓梯", "script": DESCENT_GAME},
	{"id": "breakout", "label": "敲磚塊", "script": BREAKOUT_GAME},
	{"id": "sokoban", "label": "推箱子尋零食", "script": SOKOBAN_GAME},
	{"id": "one_stroke", "label": "一筆畫", "script": ONE_STROKE_GAME},
	{"id": "snake", "label": "貪吃小蛇", "script": SNAKE_GAME},
	{"id": "minesweeper", "label": "踩地雷", "script": MINESWEEPER_GAME},
	{"id": "bee", "label": "小蜜蜂", "script": BEE_GAME},
]

var _scale := 1.0
var _index := -1
var _field: MiniGame = null
var _stage: Control = null
var _score_label: Label = null
var _best_label: Label = null
var _banner: PanelContainer = null
var _banner_title: Label = null
var _banner_hint: Label = null
var _level_buttons: Array[Button] = []


static func game_count() -> int:
	return GAMES.size()


static func game_title(index: int) -> String:
	return str(GAMES[index]["label"])


func _ready() -> void:
	visible = false
	unresizable = false
	# This is a separate game window, not a sheet attached to the desktop pet.
	# Native transient windows follow their parent on macOS, which made the whole
	# game slide around whenever the roaming pet took a step.
	transient = false
	transient_to_focused = false
	# The scene's historical value asks the OS to centre relative to the main
	# window and makes explicit `position` writes advisory. This window now owns
	# its absolute screen position instead.
	initial_position = Window.WINDOW_INITIAL_POSITION_ABSOLUTE
	close_requested.connect(_close)


## Built on first open rather than in _ready(), because every spacing in here is
## a design unit that needs the display scale — which the window has no way to
## know until someone hands it one. Same shape as MemoryPanel.
##
## `pack` and `rows` come from PetVisual, so the character in every game is
## whichever one is standing on the desktop, wearing the same row corrections.
func open(ui_scale: float, pack: PetPack, rows: Dictionary, index: int) -> void:
	_scale = ui_scale
	theme = PetStyle.panel_theme(_scale)
	if _stage == null:
		_build()
	if index != _index:
		_swap_field(index)

	title = game_title(_index)
	_field.setup(_scale, pack, rows)
	_field.set_level(clampi(
		int(Config.get_value("game", "level_%s" % _game_id(), MiniGame.DEFAULT_LEVEL)),
		0, MiniGame.LEVEL_COUNT - 1))
	_refresh_levels()
	_refresh_best()
	_on_score_changed(0)
	_show_ready()

	var wanted := Vector2i(Vector2(_field.design_size()) * _scale)
	min_size = Vector2i(Vector2(wanted) * 0.75)
	_show_independent(wanted)


## Window.popup*() always makes a native window transient. Use an ordinary
## show at an explicitly calculated screen position so the game remains where
## the player put it while the desktop pet roams underneath.
func _show_independent(wanted: Vector2i) -> void:
	transient = false
	transient_to_focused = false
	size = wanted
	var parent_window := get_parent().get_window() if get_parent() != null else null
	var screen_index := parent_window.current_screen \
		if parent_window != null else DisplayServer.get_primary_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen_index)
	position = centred_position(usable, wanted)
	show()
	grab_focus()


static func centred_position(screen_rect: Rect2i, window_size: Vector2i) -> Vector2i:
	return screen_rect.position + (screen_rect.size - window_size) / 2


func _close() -> void:
	# A run left half-played when the window goes away is not a score.
	if _field != null:
		_field.abandon()
	hide()


## Esc closes, the way it does in any dialog. MiniGame consumes only the keys a
## running game uses, so this still gets it.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		_close()
		set_input_as_handled()


# --- Building -----------------------------------------------------------------

func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", roundi(12.0 * _scale))
	panel.add_child(root)

	root.add_child(_build_header())

	# The field and the banner are siblings inside a bare Control rather than the
	# banner being a child of the field: the field is replaced whenever the game
	# changes, and a banner parented to it would go with it.
	_stage = Control.new()
	_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_stage)

	_build_banner()
	root.add_child(_build_footer())


## The title bar already names the game, so the header doesn't repeat it. What it
## carries instead is the pair of numbers that change: the live score hard left
## against its caption, the record hard right. Split apart because the two sat
## adjacent at first and read as one figure — "還沒有紀錄 2".
func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", roundi(8.0 * _scale))

	var caption := Label.new()
	caption.text = "分數"
	caption.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	caption.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(caption)

	_score_label = Label.new()
	_score_label.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_score_label.add_theme_font_size_override("font_size", roundi(20.0 * _scale))
	_score_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_score_label)

	_best_label = Label.new()
	_best_label.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_best_label.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	_best_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(_best_label)
	return header


## Over the field, not above it, so the field never changes size between "ready"
## and "playing" — the pet would jump the moment a run started.
func _build_banner() -> void:
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(centre)

	_banner = PanelContainer.new()
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_theme_stylebox_override("panel", PetStyle.game_banner_style(_scale))
	centre.add_child(_banner)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", roundi(7.0 * _scale))
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(column)

	_banner_title = Label.new()
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_title.add_theme_font_size_override("font_size", roundi(20.0 * _scale))
	column.add_child(_banner_title)

	_banner_hint = Label.new()
	_banner_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Deliberately not autowrapped, and every hint line is broken by hand. The
	# banner is inside a CenterContainer, so it takes its width from its content:
	# an autowrapping label has no width it insists on, the two collapse into
	# each other, and the result was a six-line column reading 點一下開 / 始.
	_banner_hint.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_banner_hint.add_theme_font_size_override("font_size", roundi(13.0 * _scale))
	column.add_child(_banner_hint)


func _build_footer() -> Control:
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", roundi(6.0 * _scale))

	var caption := Label.new()
	caption.text = "難度"
	caption.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	caption.add_theme_font_size_override("font_size", roundi(12.0 * _scale))
	footer.add_child(caption)

	for i in MiniGame.LEVEL_COUNT:
		var button := Button.new()
		# Nothing in this window may hold focus: a focused Button turns the arrow
		# keys into focus navigation, and several games use them. See
		# MiniGame._unhandled_key_input().
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_level_pressed.bind(i))
		footer.add_child(button)
		_level_buttons.append(button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	var close := Button.new()
	close.text = "關閉"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size.x = roundi(84.0 * _scale)
	close.pressed.connect(_close)
	footer.add_child(close)
	return footer


## Games are built on first use and then kept, so going back to one you were
## playing costs nothing — and, more to the point, dropping the node would drop
## the pet inside it and rebuild the sprite from the pack every time.
func _swap_field(index: int) -> void:
	if _field != null:
		_field.abandon()
		_field.visible = false
	_index = clampi(index, 0, GAMES.size() - 1)

	var existing := _stage.get_node_or_null(_game_id())
	if existing != null:
		_field = existing as MiniGame
	else:
		var script: GDScript = GAMES[_index]["script"]
		_field = script.new()
		_field.name = _game_id()
		_field.set_anchors_preset(Control.PRESET_FULL_RECT)
		_field.finished.connect(_on_finished)
		_field.started.connect(_on_started)
		_field.score_changed.connect(_on_score_changed)
		# Below the banner, which was added to the stage first — so move it to
		# the front of the child list rather than appending.
		_stage.add_child(_field)
		_stage.move_child(_field, 0)
	_field.visible = true


# --- State --------------------------------------------------------------------

func _game_id() -> String:
	return str(GAMES[_index]["id"])


func _on_level_pressed(index: int) -> void:
	# set_level() abandons any run in progress: the rules changing mid-fall would
	# leave a score that means nothing, and it must not reach the record.
	_field.set_level(index)
	Config.set_value("game", "level_%s" % _game_id(), index)
	_refresh_levels()
	_refresh_best()
	_on_score_changed(0)
	_show_ready()


func _refresh_levels() -> void:
	var labels := _field.level_labels()
	var current := _field.get_level()
	for i in _level_buttons.size():
		_level_buttons[i].text = labels[i] if i < labels.size() else str(i + 1)
		PetStyle.make_choice_button(_level_buttons[i], _scale, i == current)


func _best() -> int:
	return int(Config.get_value("game", _best_key(), 0))


func _best_key() -> String:
	# Per game *and* per difficulty. One shared record would make 悠哉 pointless
	# the first time anyone tried 手忙腳亂, and a record shared across games
	# would be meaningless in both.
	return "best_%s_%d" % [_game_id(), _field.get_level()]


func _refresh_best() -> void:
	var best := _best()
	_best_label.text = "最高 %d" % best if best > 0 else "還沒有紀錄"


func _on_score_changed(score: int) -> void:
	_score_label.text = str(score)


func _on_started() -> void:
	_banner.visible = false


func _on_finished(score: int, treats: int) -> void:
	var record := score > _best()
	if record:
		Config.set_value("game", _best_key(), score)
		_refresh_best()
	_show_over(score, record)
	played.emit(game_title(_index), score, treats, record)


func _show_ready() -> void:
	_banner_title.text = game_title(_index)
	_banner_hint.text = _field.ready_hint()
	_banner.visible = true


func _show_over(score: int, record: bool) -> void:
	_banner_title.text = "新紀錄！%d 分" % score if record else "%d 分" % score
	_banner_hint.text = "空白鍵再來一次" if record \
		else "最高 %d ・ 空白鍵再來一次" % maxi(_best(), score)
	_banner.visible = true
