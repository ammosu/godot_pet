extends MiniGame
class_name MinesweeperGame

## 踩地雷 — a compact, first-click-safe logic board.
##
## Left click reveals and right click flags. Keyboard users share the same
## cursor with the pointer: arrows move, Space reveals, and F places a flag.
## Opening a numbered cell again performs the classic chord when the surrounding
## flag count matches it.

const LEVELS: Array[Dictionary] = [
	{"columns": 8, "rows": 8, "mines": 8},
	{"columns": 10, "rows": 10, "mines": 16},
	{"columns": 12, "rows": 12, "mines": 27},
]
const BOARD_PAD_X := 20.0
const BOARD_PAD_TOP := 20.0
const PET_STRIP := 82.0
const CELL_GAP := 2.0
const SAFE_POINTS := 1
const CLEAR_BONUS := 50
const REACTION_TIME := 0.48

var _mines := {}
var _open := {}
var _flags := {}
var _numbers := {}
var _cursor := Vector2i.ZERO
var _laid := false
var _lost := false
var _reaction_left := 0.0
var _reaction_good := true
var _cell := 24.0
var _origin := Vector2.ZERO


func design_size() -> Vector2i:
	return Vector2i(540, 620)


func ready_hint() -> String:
	return "左鍵／空白鍵翻開・右鍵／F 插旗\n數字是周圍八格的地雷數\n第一格一定安全，找出所有安全格就完成"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["8×8", "10×10", "12×12"])


func uses_lives() -> bool:
	return false


func pet_design_height() -> float:
	return 62.0


func _prepare() -> void:
	_mines.clear()
	_open.clear()
	_flags.clear()
	_numbers.clear()
	_cursor = Vector2i(_columns() / 2, _rows() / 2)
	_laid = false
	_lost = false
	_reaction_left = 0.0
	_reaction_good = true
	if _pet != null:
		_pet.visible = true
		_pet.set_state(&"idle")
		_pet.set_squash(0.0)


func _columns() -> int:
	return int(LEVELS[_level]["columns"])


func _rows() -> int:
	return int(LEVELS[_level]["rows"])


func _mine_count() -> int:
	return int(LEVELS[_level]["mines"])


# --- Board --------------------------------------------------------------------

func _lay_mines(first: Vector2i) -> void:
	var excluded := {first: true}
	for neighbour in neighbours_for(first, Vector2i(_columns(), _rows())):
		excluded[neighbour] = true

	var candidates: Array[Vector2i] = []
	for y in _rows():
		for x in _columns():
			var cell := Vector2i(x, y)
			if not excluded.has(cell):
				candidates.append(cell)
	candidates.shuffle()
	for i in mini(_mine_count(), candidates.size()):
		_mines[candidates[i]] = true

	for y in _rows():
		for x in _columns():
			var cell := Vector2i(x, y)
			var count := 0
			for neighbour in neighbours_for(cell, Vector2i(_columns(), _rows())):
				if _mines.has(neighbour):
					count += 1
			_numbers[cell] = count
	_laid = true


static func neighbours_for(cell: Vector2i, board_size: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for y in range(cell.y - 1, cell.y + 2):
		for x in range(cell.x - 1, cell.x + 2):
			var candidate := Vector2i(x, y)
			if candidate == cell:
				continue
			if x >= 0 and y >= 0 and x < board_size.x and y < board_size.y:
				result.append(candidate)
	return result


func _reveal(cell: Vector2i) -> void:
	if not is_playing() or not _inside(cell) or _flags.has(cell) or _lost:
		return
	if not _laid:
		_lay_mines(cell)
	if _open.has(cell):
		_chord(cell)
		return
	if _mines.has(cell):
		_lose(cell)
		return
	_flood_reveal(cell)
	_react(true)
	_check_clear()


func _flood_reveal(start: Vector2i) -> void:
	var pending: Array[Vector2i] = [start]
	while not pending.is_empty():
		var cell: Vector2i = pending.pop_back()
		if _open.has(cell) or _flags.has(cell) or _mines.has(cell):
			continue
		_open[cell] = true
		_add_score(SAFE_POINTS)
		if int(_numbers.get(cell, 0)) != 0:
			continue
		for neighbour in neighbours_for(cell, Vector2i(_columns(), _rows())):
			if not _open.has(neighbour) and not _flags.has(neighbour):
				pending.append(neighbour)


func _chord(cell: Vector2i) -> void:
	var number := int(_numbers.get(cell, 0))
	if number <= 0:
		return
	var neighbours := neighbours_for(cell, Vector2i(_columns(), _rows()))
	var flag_count := 0
	for neighbour in neighbours:
		if _flags.has(neighbour):
			flag_count += 1
	if flag_count != number:
		return
	for neighbour in neighbours:
		if _flags.has(neighbour) or _open.has(neighbour):
			continue
		if _mines.has(neighbour):
			_lose(neighbour)
			return
		_flood_reveal(neighbour)
	_react(true)
	_check_clear()


func _toggle_flag(cell: Vector2i) -> void:
	if not is_playing() or not _inside(cell) or _open.has(cell) or _lost:
		return
	if _flags.has(cell):
		_flags.erase(cell)
	elif _flags.size() < _mine_count():
		_flags[cell] = true


func _lose(cell: Vector2i) -> void:
	_lost = true
	_open[cell] = true
	_reaction_good = false
	_reaction_left = REACTION_TIME
	_pet.set_state(&"sad")
	_pet.set_squash(-0.12)
	_finish()


func _check_clear() -> void:
	var safe_total := _columns() * _rows() - _mine_count()
	if _open.size() < safe_total:
		return
	_add_score(CLEAR_BONUS)
	for mine in _mines:
		_flags[mine] = true
	_finish()


# --- Frame, geometry and input ------------------------------------------------

func _tick(delta: float) -> void:
	_measure()
	if _reaction_left > 0.0:
		_reaction_left = maxf(0.0, _reaction_left - delta)
		_pet.set_state(&"happy" if _reaction_good else &"sad")
		_pet.set_squash((0.10 if _reaction_good else -0.10)
			* _reaction_left / REACTION_TIME)
	else:
		_pet.set_state(&"idle")
		_pet.set_squash(0.0)
	var centre := _cell_centre(_cursor)
	_pet.stand_on(size.y - 12.0 * _scale, centre.x)


func _react(good: bool) -> void:
	_reaction_good = good
	_reaction_left = REACTION_TIME


func _measure() -> void:
	var pad_x := BOARD_PAD_X * _scale
	var top := BOARD_PAD_TOP * _scale
	var available := Vector2(
		size.x - pad_x * 2.0,
		size.y - top - PET_STRIP * _scale)
	_cell = maxf(8.0, minf(
		available.x / float(_columns()),
		available.y / float(_rows())))
	var board := Vector2(float(_columns()), float(_rows())) * _cell
	_origin = Vector2((size.x - board.x) * 0.5,
		top + (available.y - board.y) * 0.5)


func _inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 \
		and cell.x < _columns() and cell.y < _rows()


func _cell_centre(cell: Vector2i) -> Vector2:
	return _origin + (Vector2(cell) + Vector2(0.5, 0.5)) * _cell


func _cell_at(pos: Vector2) -> Vector2i:
	var local := pos - _origin
	var cell := Vector2i(floori(local.x / _cell), floori(local.y / _cell))
	return cell if _inside(cell) else Vector2i(-1, -1)


func _key_pressed(keycode: int) -> bool:
	match keycode:
		KEY_LEFT, KEY_A:
			_cursor.x = maxi(0, _cursor.x - 1)
		KEY_RIGHT, KEY_D:
			_cursor.x = mini(_columns() - 1, _cursor.x + 1)
		KEY_UP, KEY_W:
			_cursor.y = maxi(0, _cursor.y - 1)
		KEY_DOWN, KEY_S:
			_cursor.y = mini(_rows() - 1, _cursor.y + 1)
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_reveal(_cursor)
		KEY_F:
			_toggle_flag(_cursor)
		_:
			return false
	return true


func _pointer_moved(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	if _inside(cell):
		_cursor = cell


func _pointer_clicked(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	if _inside(cell):
		_cursor = cell
		_reveal(cell)


func _pointer_secondary_clicked(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	if _inside(cell):
		_cursor = cell
		_toggle_flag(cell)


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	var inset := CELL_GAP * 0.5 * _scale
	var board_size := Vector2(float(_columns()), float(_rows())) * _cell
	draw_rect(Rect2(_origin, board_size), PetStyle.GAME_MINES_GRID, true)
	for y in _rows():
		for x in _columns():
			var cell := Vector2i(x, y)
			var rect := Rect2(
				_origin + Vector2(float(x), float(y)) * _cell,
				Vector2.ONE * _cell).grow(-inset)
			var opened := _open.has(cell)
			var fill := PetStyle.GAME_MINES_OPEN if opened \
				else PetStyle.GAME_MINES_CLOSED
			draw_rect(rect, fill, true)

			if opened and _mines.has(cell):
				_draw_mine(rect.get_center())
			elif _flags.has(cell):
				_draw_flag(rect)
			elif opened:
				var number := int(_numbers.get(cell, 0))
				if number > 0:
					_draw_number(number, rect.get_center())

	if _lost:
		for mine in _mines:
			if not _open.has(mine):
				_draw_mine(_cell_centre(mine), 0.62)
	if is_playing():
		var cursor_rect := Rect2(
			_origin + Vector2(_cursor) * _cell,
			Vector2.ONE * _cell).grow(-inset)
		draw_rect(cursor_rect, PetStyle.ACCENT, false,
			maxf(1.0, 2.0 * _scale))
	_draw_counter()


func _draw_flag(rect: Rect2) -> void:
	var pole_x := rect.position.x + rect.size.x * 0.43
	var top := rect.position.y + rect.size.y * 0.23
	var bottom := rect.position.y + rect.size.y * 0.76
	draw_line(Vector2(pole_x, top), Vector2(pole_x, bottom),
		PetStyle.GAME_ITEM_INK, maxf(1.0, 2.0 * _scale))
	draw_colored_polygon(PackedVector2Array([
		Vector2(pole_x, top),
		Vector2(rect.position.x + rect.size.x * 0.78, rect.position.y + rect.size.y * 0.38),
		Vector2(pole_x, rect.position.y + rect.size.y * 0.49),
	]), PetStyle.GAME_MINES_FLAG)
	draw_line(
		Vector2(rect.position.x + rect.size.x * 0.28, bottom),
		Vector2(rect.position.x + rect.size.x * 0.64, bottom),
		PetStyle.GAME_ITEM_INK, maxf(1.0, 2.0 * _scale))


func _draw_mine(centre: Vector2, alpha := 1.0) -> void:
	var radius := _cell * 0.20
	var color := Color(PetStyle.GAME_MINES_DANGER, alpha)
	for direction in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		draw_line(centre + direction * radius * 0.62,
			centre + direction * radius * 1.55,
			color, maxf(1.0, 2.0 * _scale), true)
	draw_circle(centre, radius, color)
	draw_circle(centre - Vector2.ONE * radius * 0.30,
		radius * 0.22, Color(1.0, 1.0, 1.0, alpha * 0.72))


func _draw_number(number: int, centre: Vector2) -> void:
	var colors := [
		PetStyle.GAME_VOLLEY_RIVAL,
		PetStyle.GAME_BREAKOUT_GREEN,
		PetStyle.GAME_MINES_DANGER,
		PetStyle.GAME_BREAKOUT_PERSIMMON,
	]
	var color: Color = colors[mini(number - 1, colors.size() - 1)]
	var font := ThemeDB.fallback_font
	var font_size := maxi(9, roundi(_cell * 0.48))
	var text := str(number)
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(font, centre + Vector2(-text_size.x * 0.5, text_size.y * 0.33),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_counter() -> void:
	var left := _mine_count() - _flags.size()
	var font := ThemeDB.fallback_font
	var font_size := maxi(9, roundi(12.0 * _scale))
	draw_string(font,
		Vector2(BOARD_PAD_X * _scale, size.y - PET_STRIP * _scale + 18.0 * _scale),
		"剩 %d 面旗" % left, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
		PetStyle.NIGHT_MUTED)
