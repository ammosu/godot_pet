extends MiniGame
class_name OneStrokeGame

## 一筆畫 — guide the pet over every line exactly once.
##
## The graph is the board and the pet is the pen. A click chooses the next node;
## keyboard players move a cursor with the arrows and confirm with Space. Edges
## may share nodes but may never be reused. Every puzzle is stored as one valid
## Euler trail, then exposed only as unordered edges, so the data itself proves
## that at least one solution exists without giving that route to the player.

const PUZZLES: Array = [
	[
		{
			"points": [Vector2(0.18, 0.22), Vector2(0.76, 0.22),
				Vector2(0.50, 0.62), Vector2(0.50, 0.93)],
			"path": [0, 1, 2, 0, 3],
		},
		{
			"points": [Vector2(0.18, 0.20), Vector2(0.82, 0.20),
				Vector2(0.82, 0.70), Vector2(0.18, 0.70),
				Vector2(0.50, 0.94)],
			"path": [0, 1, 2, 3, 0, 2, 4],
		},
		{
			"points": [Vector2(0.50, 0.08), Vector2(0.90, 0.38),
				Vector2(0.75, 0.88), Vector2(0.25, 0.88),
				Vector2(0.10, 0.38)],
			"path": [0, 1, 2, 3, 4, 0, 2, 4, 1, 3],
		},
	],
	[
		{
			"points": [Vector2(0.50, 0.06), Vector2(0.86, 0.25),
				Vector2(0.86, 0.72), Vector2(0.50, 0.94),
				Vector2(0.14, 0.72), Vector2(0.14, 0.25)],
			"path": [0, 1, 2, 3, 4, 5, 0, 3, 1, 4, 2, 5],
		},
		{
			"points": [Vector2(0.12, 0.15), Vector2(0.50, 0.15),
				Vector2(0.88, 0.15), Vector2(0.12, 0.78),
				Vector2(0.50, 0.78), Vector2(0.88, 0.78)],
			"path": [0, 1, 2, 5, 4, 3, 0, 4, 1, 5, 3, 2],
		},
		{
			"points": [Vector2(0.50, 0.05), Vector2(0.85, 0.22),
				Vector2(0.92, 0.62), Vector2(0.68, 0.92),
				Vector2(0.32, 0.92), Vector2(0.08, 0.62),
				Vector2(0.15, 0.22)],
			"path": [0, 1, 2, 3, 4, 5, 0, 3, 6, 1, 4, 2, 5, 6],
		},
	],
	[
		{
			"points": [Vector2(0.50, 0.04), Vector2(0.80, 0.16),
				Vector2(0.95, 0.45), Vector2(0.84, 0.78),
				Vector2(0.54, 0.94), Vector2(0.20, 0.82),
				Vector2(0.05, 0.50), Vector2(0.17, 0.18)],
			"path": [0, 1, 2, 3, 4, 5, 6, 7, 0, 4, 1, 5, 2, 6, 3, 7,
				4, 2, 0, 6, 4],
		},
		{
			"points": [Vector2(0.50, 0.03), Vector2(0.77, 0.12),
				Vector2(0.94, 0.36), Vector2(0.90, 0.68),
				Vector2(0.66, 0.92), Vector2(0.34, 0.92),
				Vector2(0.10, 0.68), Vector2(0.06, 0.36),
				Vector2(0.23, 0.12)],
			"path": [0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 4, 1, 5, 2, 6, 3,
				7, 4, 8, 5, 0, 6, 1, 7, 2, 8, 3],
		},
		{
			"points": [Vector2(0.50, 0.05), Vector2(0.84, 0.20),
				Vector2(0.94, 0.58), Vector2(0.72, 0.91),
				Vector2(0.28, 0.91), Vector2(0.06, 0.58),
				Vector2(0.16, 0.20)],
			"path": [0, 1, 2, 3, 4, 5, 6, 0, 3, 6, 2, 5, 1, 4, 0, 2,
				4, 6, 1, 3, 5, 0],
		},
	],
]

const BOARD_PAD_X := 44.0
const BOARD_PAD_TOP := 30.0
const PET_STRIP := 72.0
const NODE_RADIUS := 9.0
const HIT_RADIUS := 28.0
const LINE_WIDTH := 5.0
const NEXT_PUZZLE_DELAY := 0.72
const CLEAR_POINTS := 100
const MISTAKE_PENALTY := 10
const MIN_CLEAR_POINTS := 25
const REACTION_TIME := 0.44

var _points := PackedVector2Array()
var _edges: Array[Dictionary] = []
var _used: Array[bool] = []
var _puzzle_index := 0
var _current_node := -1
var _cursor := 0
var _goal_node := -1
var _mistakes := 0
var _next_puzzle_left := 0.0
var _pending_finish := false
var _reaction_left := 0.0
var _reaction_good := true
var _squash := 0.0
var _board_rect := Rect2()


func design_size() -> Vector2i:
	return Vector2i(540, 610)


func ready_hint() -> String:
	return "點節點連線，或方向鍵移動、空白鍵確認\n每條線只能走一次，中途不能跳到別處\n走錯按 R・完成三題就結束"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["四角起步", "交叉路線", "線團挑戰"])


func uses_lives() -> bool:
	return false


func pet_design_height() -> float:
	return 34.0


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


# --- Puzzle state -------------------------------------------------------------

func _puzzle() -> Dictionary:
	return PUZZLES[_level][_puzzle_index]


func _load_puzzle() -> void:
	_points.clear()
	for point in _puzzle()["points"]:
		_points.append(Vector2(point))
	_edges.clear()
	_used.clear()
	var path: Array = _puzzle()["path"]
	for i in path.size() - 1:
		_edges.append({"a": int(path[i]), "b": int(path[i + 1])})
		_used.append(false)
	_current_node = -1
	_cursor = int(path[0])
	_goal_node = int(path[-1])
	_mistakes = 0


func _choose_node(node: int) -> void:
	if not is_playing() or _next_puzzle_left > 0.0 \
			or node < 0 or node >= _points.size():
		return
	_cursor = node
	if _current_node < 0:
		var path: Array = _puzzle()["path"]
		var start := int(path[0])
		var finish := int(path[-1])
		if node != start and node != finish:
			_mistake()
			return
		_current_node = node
		_goal_node = finish if node == start else start
		_react(true, 0.12)
		return
	if node == _current_node:
		return

	var edge_index := _edge_between(_current_node, node)
	if edge_index < 0:
		_mistake()
		return
	_used[edge_index] = true
	var direction := _points[node].x - _points[_current_node].x
	if not is_zero_approx(direction):
		_pet.set_facing(1 if direction > 0.0 else -1)
	_current_node = node
	_react(true, 0.14)
	if _used_count() == _edges.size():
		_complete_puzzle()


func _edge_between(a: int, b: int) -> int:
	for i in _edges.size():
		if _used[i]:
			continue
		var edge: Dictionary = _edges[i]
		if (int(edge["a"]) == a and int(edge["b"]) == b) \
				or (int(edge["a"]) == b and int(edge["b"]) == a):
			return i
	return -1


func _used_count() -> int:
	var count := 0
	for used in _used:
		if used:
			count += 1
	return count


func _complete_puzzle() -> void:
	_add_score(maxi(
		MIN_CLEAR_POINTS,
		CLEAR_POINTS - _mistakes * MISTAKE_PENALTY))
	_react(true, 0.22)
	_next_puzzle_left = NEXT_PUZZLE_DELAY
	_pending_finish = _puzzle_index >= PUZZLES[_level].size() - 1


func _mistake() -> void:
	_mistakes += 1
	_react(false)


func _restart_puzzle() -> void:
	if not is_playing() or _next_puzzle_left > 0.0:
		return
	_load_puzzle()
	_react(false)


func _is_stuck() -> bool:
	if _current_node < 0 or _used_count() == _edges.size():
		return false
	for i in _edges.size():
		if _used[i]:
			continue
		var edge: Dictionary = _edges[i]
		if int(edge["a"]) == _current_node or int(edge["b"]) == _current_node:
			return false
	return true


# --- Frame and geometry -------------------------------------------------------

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
	elif _is_stuck():
		_pet.set_state(&"sad")
	else:
		_pet.set_state(&"idle")
	var target := 0.0
	if _reaction_left > 0.0:
		target = _squash * clampf(_reaction_left / REACTION_TIME, 0.0, 1.0)
	_squash = lerpf(_squash, target, clampf(delta * 14.0, 0.0, 1.0))
	_pet.set_squash(_squash)

	var pet_node := _current_node if _current_node >= 0 else _cursor
	var point := _point_position(pet_node)
	_pet.stand_on(point.y + 20.0 * _scale, point.x)


func _measure() -> void:
	var x_pad := BOARD_PAD_X * _scale
	var top := BOARD_PAD_TOP * _scale
	_board_rect = Rect2(
		Vector2(x_pad, top),
		Vector2(
			maxf(1.0, size.x - x_pad * 2.0),
			maxf(1.0, size.y - top - PET_STRIP * _scale)))


func _point_position(index: int) -> Vector2:
	if index < 0 or index >= _points.size():
		return _board_rect.get_center()
	var point := _points[index]
	return _board_rect.position + point * _board_rect.size


func _node_at(pos: Vector2) -> int:
	var nearest := -1
	var distance := HIT_RADIUS * _scale
	for i in _points.size():
		var candidate := pos.distance_to(_point_position(i))
		if candidate <= distance:
			distance = candidate
			nearest = i
	return nearest


func _move_cursor(direction: Vector2) -> void:
	var from := _point_position(_cursor)
	var best := -1
	var best_score := INF
	for i in _points.size():
		if i == _cursor:
			continue
		var delta := _point_position(i) - from
		var distance := delta.length()
		if distance <= 0.0:
			continue
		var alignment := delta.normalized().dot(direction)
		if alignment < 0.32:
			continue
		var score := distance / (alignment * alignment)
		if score < best_score:
			best_score = score
			best = i
	if best >= 0:
		_cursor = best


func _react(good: bool, amount := -0.10) -> void:
	_reaction_good = good
	_reaction_left = REACTION_TIME
	_squash = amount if good else -0.12


# --- Input --------------------------------------------------------------------

func _key_pressed(keycode: int) -> bool:
	match keycode:
		KEY_LEFT, KEY_A:
			_move_cursor(Vector2.LEFT)
		KEY_RIGHT, KEY_D:
			_move_cursor(Vector2.RIGHT)
		KEY_UP, KEY_W:
			_move_cursor(Vector2.UP)
		KEY_DOWN, KEY_S:
			_move_cursor(Vector2.DOWN)
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_choose_node(_cursor)
		KEY_R:
			_restart_puzzle()
		_:
			return false
	return true


func _pointer_moved(pos: Vector2) -> void:
	var node := _node_at(pos)
	if node >= 0:
		_cursor = node


func _pointer_clicked(pos: Vector2) -> void:
	var node := _node_at(pos)
	if node >= 0:
		_choose_node(node)


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	for i in _edges.size():
		if _used[i]:
			continue
		_draw_edge(i, PetStyle.GAME_ONE_STROKE_UNUSED)
	for i in _edges.size():
		if _used[i]:
			_draw_edge(i, PetStyle.GAME_ONE_STROKE_USED)

	var path: Array = _puzzle()["path"]
	var start := int(path[0])
	var finish := int(path[-1])
	for i in _points.size():
		var position := _point_position(i)
		var endpoint := i == start or i == finish
		var color := PetStyle.GAME_ONE_STROKE_ENDPOINT \
			if endpoint else PetStyle.GAME_ONE_STROKE_NODE
		draw_circle(position, NODE_RADIUS * _scale, color)
		draw_circle(position, NODE_RADIUS * 0.42 * _scale, PetStyle.GAME_FIELD)

	if _goal_node >= 0:
		GameArt.draw_item(self, GameArt.Item.RICE,
			_point_position(_goal_node), NODE_RADIUS * 0.82 * _scale)
	if is_playing():
		var cursor_color := PetStyle.GAME_DESCENT_DANGER \
			if _is_stuck() else PetStyle.ACCENT
		draw_arc(_point_position(_cursor), NODE_RADIUS * 1.65 * _scale,
			0.0, TAU, 24, cursor_color, maxf(1.0, 2.0 * _scale), true)
	_draw_progress()


func _draw_progress() -> void:
	var radius := 4.0 * _scale
	var origin := Vector2(16.0 * _scale + radius, 16.0 * _scale + radius)
	for i in PUZZLES[_level].size():
		var color := PetStyle.GAME_LIFE_SPENT
		if i < _puzzle_index:
			color = PetStyle.GAME_ONE_STROKE_USED
		elif i == _puzzle_index:
			color = PetStyle.GAME_ONE_STROKE_ENDPOINT
		draw_circle(origin + Vector2(float(i) * radius * 3.2, 0.0), radius, color)


func _draw_edge(index: int, color: Color) -> void:
	var edge: Dictionary = _edges[index]
	draw_line(
		_point_position(int(edge["a"])),
		_point_position(int(edge["b"])),
		color, LINE_WIDTH * _scale, true)
