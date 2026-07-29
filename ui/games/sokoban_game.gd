extends MiniGame
class_name SokobanGame

## 推箱子尋零食 — solve three small warehouse puzzles with the pet.
##
## This is deliberately turn-based. Every accepted key is exactly one move, so
## the game asks for planning rather than the reflexes most of the other games
## already cover. Boxes carry treats and the marked floor tiles are their bowls.
## A completed puzzle is worth up to 100 points; moves beyond the shortest known
## route lower that reward, which makes the existing "higher is better" record
## meaningful without adding a second kind of scoreboard to GamePanel.

const PUZZLES: Array = [
	[
		{
			"map": [
				"#####",
				"# . #",
				"# $ #",
				"# @ #",
				"#####",
			],
			"par": 1,
		},
		{
			"map": [
				"#######",
				"# . . #",
				"# $ $ #",
				"#  @  #",
				"#######",
			],
			"par": 6,
		},
		{
			"map": [
				"#######",
				"# .   #",
				"# $   #",
				"#   $.#",
				"#  @  #",
				"#######",
			],
			"par": 5,
		},
	],
	[
		{
			"map": [
				"#######",
				"# .   #",
				"#  $  #",
				"#  $@ #",
				"# .   #",
				"#######",
			],
			"par": 8,
		},
		{
			"map": [
				"########",
				"#  . . #",
				"#  $ $ #",
				"#   #  #",
				"#  @   #",
				"########",
			],
			"par": 8,
		},
		{
			"map": [
				"########",
				"# .    #",
				"# $$@  #",
				"# .    #",
				"#      #",
				"########",
			],
			"par": 12,
		},
	],
	[
		{
			"map": [
				"#########",
				"# . . . #",
				"#  $$$  #",
				"#       #",
				"#   @   #",
				"#########",
			],
			"par": 12,
		},
		{
			"map": [
				"#########",
				"# .   . #",
				"# $ $ $ #",
				"#   .   #",
				"#   @   #",
				"#       #",
				"#########",
			],
			"par": 12,
		},
		{
			"map": [
				"#########",
				"# . . . #",
				"# $ $ $ #",
				"#  # #  #",
				"#   @   #",
				"#       #",
				"#########",
			],
			"par": 16,
		},
	],
]

const CLEAR_POINTS := 100
const EXTRA_MOVE_PENALTY := 3
const MIN_CLEAR_POINTS := 25
const BOARD_PAD := 20.0
const CELL_CAP := 58.0
const CELL_GAP := 3.0
const NEXT_PUZZLE_DELAY := 0.72
const REACTION_TIME := 0.46

var _walls := {}
var _targets := {}
var _boxes := {}
var _player := Vector2i.ZERO
var _map_size := Vector2i.ONE
var _puzzle_index := 0
var _moves := 0
var _next_puzzle_left := 0.0
var _pending_finish := false
var _reaction_left := 0.0
var _reaction_good := true
var _squash := 0.0
var _cell := 40.0
var _origin := Vector2.ZERO


func design_size() -> Vector2i:
	return Vector2i(540, 610)


func ready_hint() -> String:
	return "方向鍵 ／ W A S D 一次走一格\n把有零食的箱子推到圓形餐盤\nR 重來・完成三關就結束"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["暖身倉庫", "轉個彎", "小心順序"])


func uses_lives() -> bool:
	return false


func pet_design_height() -> float:
	return 38.0


func _prepare() -> void:
	_puzzle_index = 0
	_next_puzzle_left = 0.0
	_pending_finish = false
	_reaction_left = 0.0
	_reaction_good = true
	_squash = 0.0
	_load_puzzle()
	if _pet != null:
		_pet.visible = true
		_pet.set_squash(0.0)


# --- Board state --------------------------------------------------------------

func _puzzle() -> Dictionary:
	return PUZZLES[_level][_puzzle_index]


func _load_puzzle() -> void:
	_walls.clear()
	_targets.clear()
	_boxes.clear()
	_moves = 0
	var lines: Array = _puzzle()["map"]
	_map_size = Vector2i(0, lines.size())
	for y in lines.size():
		var line := str(lines[y])
		_map_size.x = maxi(_map_size.x, line.length())
		for x in line.length():
			var cell := Vector2i(x, y)
			match line.substr(x, 1):
				"#":
					_walls[cell] = true
				".":
					_targets[cell] = true
				"$":
					_boxes[cell] = true
				"*":
					_boxes[cell] = true
					_targets[cell] = true
				"@":
					_player = cell
				"+":
					_player = cell
					_targets[cell] = true


func _try_move(direction: Vector2i) -> void:
	if not is_playing() or _next_puzzle_left > 0.0:
		return
	var destination := _player + direction
	if _walls.has(destination):
		_react(false)
		return
	if _boxes.has(destination):
		var beyond := destination + direction
		if _walls.has(beyond) or _boxes.has(beyond):
			_react(false)
			return
		_boxes.erase(destination)
		_boxes[beyond] = true
		_squash = 0.15
	_player = destination
	_moves += 1
	if direction.x != 0:
		_pet.set_facing(1 if direction.x > 0 else -1)
	if _solved():
		_complete_puzzle()
	else:
		_react(true, 0.12)


func _solved() -> bool:
	if _boxes.size() != _targets.size():
		return false
	for box in _boxes:
		if not _targets.has(box):
			return false
	return true


func _complete_puzzle() -> void:
	var par := int(_puzzle()["par"])
	var extra := maxi(0, _moves - par)
	_add_score(maxi(
		MIN_CLEAR_POINTS,
		CLEAR_POINTS - extra * EXTRA_MOVE_PENALTY))
	_react(true, 0.20)
	_next_puzzle_left = NEXT_PUZZLE_DELAY
	_pending_finish = _puzzle_index >= PUZZLES[_level].size() - 1


func _restart_puzzle() -> void:
	if not is_playing() or _next_puzzle_left > 0.0:
		return
	_load_puzzle()
	_react(false)


# --- Frame and layout ---------------------------------------------------------

func _tick(delta: float) -> void:
	_measure()
	if _next_puzzle_left > 0.0:
		_next_puzzle_left -= delta
		if _next_puzzle_left <= 0.0:
			if _pending_finish:
				_finish()
			else:
				_puzzle_index += 1
				_load_puzzle()

	if _reaction_left > 0.0:
		_reaction_left = maxf(0.0, _reaction_left - delta)
		_pet.set_state(&"happy" if _reaction_good else &"sad")
	else:
		_pet.set_state(&"idle")
	var target := 0.0
	if _reaction_left > 0.0:
		target = _squash * clampf(_reaction_left / REACTION_TIME, 0.0, 1.0)
	_squash = lerpf(_squash, target, clampf(delta * 14.0, 0.0, 1.0))
	_pet.set_squash(_squash)

	var rect := _cell_rect(_player)
	_pet.stand_on(rect.end.y - CELL_GAP * 0.5 * _scale, rect.get_center().x)


func _measure() -> void:
	var pad := BOARD_PAD * _scale
	var avail := Vector2(size.x - pad * 2.0, size.y - pad * 2.0)
	_cell = minf(
		CELL_CAP * _scale,
		minf(avail.x / float(_map_size.x), avail.y / float(_map_size.y)))
	var board := Vector2(_map_size) * _cell
	_origin = (size - board) * 0.5


func _cell_rect(cell: Vector2i) -> Rect2:
	var gap := CELL_GAP * _scale
	return Rect2(
		_origin + Vector2(cell) * _cell + Vector2.ONE * gap * 0.5,
		Vector2.ONE * (_cell - gap))


func _cell_at(pos: Vector2) -> Vector2i:
	var local := pos - _origin
	if local.x < 0.0 or local.y < 0.0:
		return Vector2i(-1, -1)
	var cell := Vector2i(floori(local.x / _cell), floori(local.y / _cell))
	if cell.x >= _map_size.x or cell.y >= _map_size.y:
		return Vector2i(-1, -1)
	return cell


func _react(good: bool, amount := -0.10) -> void:
	_reaction_good = good
	_reaction_left = REACTION_TIME
	_squash = amount if good else -0.12


# --- Input --------------------------------------------------------------------

func _key_pressed(keycode: int) -> bool:
	match keycode:
		KEY_LEFT, KEY_A:
			_try_move(Vector2i.LEFT)
		KEY_RIGHT, KEY_D:
			_try_move(Vector2i.RIGHT)
		KEY_UP, KEY_W:
			_try_move(Vector2i.UP)
		KEY_DOWN, KEY_S:
			_try_move(Vector2i.DOWN)
		KEY_R:
			_restart_puzzle()
		_:
			return false
	return true


func _pointer_clicked(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	var delta := cell - _player
	if absi(delta.x) + absi(delta.y) == 1:
		_try_move(delta)


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	for y in _map_size.y:
		for x in _map_size.x:
			var cell := Vector2i(x, y)
			var rect := _cell_rect(cell)
			if _walls.has(cell):
				_draw_wall(rect)
			else:
				_draw_floor(rect, (x + y) % 2 == 0)
				if _targets.has(cell):
					_draw_target(rect)
				if _boxes.has(cell):
					_draw_box(rect, _targets.has(cell))
	_draw_progress()


func _draw_progress() -> void:
	var radius := 4.0 * _scale
	var origin := Vector2(16.0 * _scale + radius, 16.0 * _scale + radius)
	for i in PUZZLES[_level].size():
		var color := PetStyle.GAME_LIFE_SPENT
		if i < _puzzle_index:
			color = PetStyle.GAME_SOKOBAN_BOX_DONE
		elif i == _puzzle_index:
			color = PetStyle.ACCENT
		draw_circle(origin + Vector2(float(i) * radius * 3.2, 0.0), radius, color)


func _draw_floor(rect: Rect2, alternate: bool) -> void:
	var color := PetStyle.GAME_SOKOBAN_FLOOR_ALT \
		if alternate else PetStyle.GAME_SOKOBAN_FLOOR
	draw_rect(rect, color)


func _draw_wall(rect: Rect2) -> void:
	draw_rect(rect, PetStyle.GAME_SOKOBAN_WALL)
	var inset := maxf(2.0, 4.0 * _scale)
	draw_rect(rect.grow(-inset), PetStyle.GAME_SOKOBAN_WALL_INNER, false,
		maxf(1.0, 2.0 * _scale))


func _draw_target(rect: Rect2) -> void:
	var centre := rect.get_center()
	var radius := rect.size.x * 0.27
	draw_circle(centre, radius, PetStyle.GAME_SOKOBAN_TARGET)
	draw_circle(centre, radius * 0.62, PetStyle.GAME_FIELD)


func _draw_box(rect: Rect2, placed: bool) -> void:
	var inset := maxf(3.0, 6.0 * _scale)
	var box := rect.grow(-inset)
	var color := PetStyle.GAME_SOKOBAN_BOX_DONE \
		if placed else PetStyle.GAME_SOKOBAN_BOX
	draw_rect(box, color)
	var edge := maxf(1.0, 2.0 * _scale)
	draw_line(box.position + Vector2(edge, edge),
		Vector2(box.end.x - edge, box.position.y + edge),
		Color(1.0, 1.0, 1.0, 0.28), edge)
	GameArt.draw_item(self, GameArt.Item.RICE, box.get_center(), box.size.x * 0.20)
