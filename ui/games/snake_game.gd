extends MiniGame
class_name SnakeGame

## 貪吃小蛇 — the installed pet is the snake's head, not a mascot beside it.
##
## One queued turn is accepted between steps, which keeps quick corner inputs
## dependable without allowing a 180-degree turn through the body. Running into
## the wall or the trail costs one life and restarts the same board.

const LEVELS: Array[Dictionary] = [
	{"columns": 12, "rows": 12, "step": 0.235},
	{"columns": 15, "rows": 15, "step": 0.170},
	{"columns": 18, "rows": 18, "step": 0.120},
]
const BOARD_PAD := 22.0
const CELL_GAP := 2.0
const FOOD_POINTS := 5
const CRASH_DELAY := 0.62

var _snake: Array[Vector2i] = []
var _direction := Vector2i.RIGHT
var _queued_direction := Vector2i.RIGHT
var _food := Vector2i.ZERO
var _step_left := 0.0
var _crash_left := 0.0
var _crashed := false
var _cell := 20.0
var _origin := Vector2.ZERO


func design_size() -> Vector2i:
	return Vector2i(540, 600)


func ready_hint() -> String:
	return "方向鍵 ／ W A S D 轉彎\n讓寵物帶著身體吃到飯糰\n撞牆或撞到自己三次就結束"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["慢慢爬", "經典", "飛快"])


func pet_design_height() -> float:
	# The actual fit is corrected to the measured cell in _place_pet().
	return 34.0


func _prepare() -> void:
	_direction = Vector2i.RIGHT
	_queued_direction = _direction
	_step_left = float(LEVELS[_level]["step"])
	_crash_left = 0.0
	_crashed = false
	_reset_snake()
	if _pet != null:
		_pet.visible = true
		_pet.set_state(&"idle")
		_pet.set_squash(0.0)


func _reset_snake() -> void:
	_snake.clear()
	var centre := Vector2i(_columns() / 2, _rows() / 2)
	for offset in 4:
		_snake.append(centre - Vector2i(offset, 0))
	_direction = Vector2i.RIGHT
	_queued_direction = _direction
	_step_left = float(LEVELS[_level]["step"])
	_spawn_food()


func _columns() -> int:
	return int(LEVELS[_level]["columns"])


func _rows() -> int:
	return int(LEVELS[_level]["rows"])


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	_measure()
	if is_playing():
		if _crashed:
			_crash_left -= delta
			if _crash_left <= 0.0:
				_crashed = false
				_reset_snake()
		else:
			_step_left -= delta
			while _step_left <= 0.0 and is_playing() and not _crashed:
				_step_left += float(LEVELS[_level]["step"])
				_advance()
	_place_pet()


func _advance() -> void:
	_direction = _queued_direction
	var next := _snake[0] + _direction
	var grows := next == _food
	if hits_wall(next, Vector2i(_columns(), _rows())) \
			or hits_body(next, _snake, grows):
		_crash()
		return

	_snake.push_front(next)
	if grows:
		_add_score(FOOD_POINTS)
		_spawn_food()
		_pet.set_state(&"happy")
		_pet.set_squash(0.12)
	else:
		_snake.pop_back()
		_pet.set_state(&"walk")
		_pet.set_squash(0.0)


func _crash() -> void:
	_crashed = true
	_crash_left = CRASH_DELAY
	_pet.set_state(&"sad")
	_pet.set_squash(-0.12)
	_lose_one()


func _spawn_food() -> void:
	var empty: Array[Vector2i] = []
	for y in _rows():
		for x in _columns():
			var cell := Vector2i(x, y)
			if not _snake.has(cell):
				empty.append(cell)
	if empty.is_empty():
		_finish()
		return
	_food = empty.pick_random()


static func hits_wall(cell: Vector2i, board_size: Vector2i) -> bool:
	return cell.x < 0 or cell.y < 0 \
		or cell.x >= board_size.x or cell.y >= board_size.y


## The tail is allowed to vacate on a normal move. When food is eaten it stays,
## so moving into that same cell really is a collision.
static func hits_body(cell: Vector2i, body: Array[Vector2i], grows: bool) -> bool:
	var count := body.size() if grows else maxi(0, body.size() - 1)
	for i in count:
		if body[i] == cell:
			return true
	return false


# --- Geometry and input -------------------------------------------------------

func _measure() -> void:
	var pad := BOARD_PAD * _scale
	_cell = maxf(8.0, minf(
		(size.x - pad * 2.0) / float(_columns()),
		(size.y - pad * 2.0) / float(_rows())))
	var board := Vector2(float(_columns()), float(_rows())) * _cell
	_origin = (size - board) * 0.5


func _cell_centre(cell: Vector2i) -> Vector2:
	return _origin + (Vector2(cell) + Vector2(0.5, 0.5)) * _cell


func _cell_at(pos: Vector2) -> Vector2i:
	var local := pos - _origin
	var cell := Vector2i(floori(local.x / _cell), floori(local.y / _cell))
	return cell if not hits_wall(cell, Vector2i(_columns(), _rows())) \
		else Vector2i(-1, -1)


func _place_pet() -> void:
	if _snake.is_empty():
		return
	var centre := _cell_centre(_snake[0])
	_pet.stand_on(centre.y + _pet.height() * 0.5, centre.x)
	if _direction.x != 0:
		_pet.set_facing(_direction.x)


func _turn(wanted: Vector2i) -> void:
	if _crashed or wanted == Vector2i.ZERO:
		return
	if wanted + _direction == Vector2i.ZERO:
		return
	_queued_direction = wanted


func _key_pressed(keycode: int) -> bool:
	match keycode:
		KEY_LEFT, KEY_A:
			_turn(Vector2i.LEFT)
		KEY_RIGHT, KEY_D:
			_turn(Vector2i.RIGHT)
		KEY_UP, KEY_W:
			_turn(Vector2i.UP)
		KEY_DOWN, KEY_S:
			_turn(Vector2i.DOWN)
		_:
			return false
	return true


func _pointer_clicked(pos: Vector2) -> void:
	if _snake.is_empty():
		return
	var target := _cell_at(pos)
	if target.x < 0:
		return
	var delta := target - _snake[0]
	if absi(delta.x) > absi(delta.y):
		_turn(Vector2i(signi(delta.x), 0))
	elif delta.y != 0:
		_turn(Vector2i(0, signi(delta.y)))


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	var inset := CELL_GAP * 0.5 * _scale
	for y in _rows():
		for x in _columns():
			var rect := Rect2(
				_origin + Vector2(float(x), float(y)) * _cell,
				Vector2.ONE * _cell).grow(-inset)
			draw_rect(rect, PetStyle.GAME_SNAKE_GRID, true)

	# The head is a child node and draws after this Control. Extend the first body
	# segment underneath it so differently padded pet sprites never look detached.
	if _snake.size() > 1:
		draw_line(_cell_centre(_snake[0]), _cell_centre(_snake[1]),
			PetStyle.GAME_SNAKE_BODY, maxf(2.0, _cell * 0.55), true)
	for i in range(_snake.size() - 1, 0, -1):
		var amount := float(i - 1) / maxf(1.0, float(_snake.size() - 1))
		var color := PetStyle.GAME_SNAKE_BODY.lerp(
			PetStyle.GAME_SNAKE_TAIL, amount * 0.78)
		var centre := _cell_centre(_snake[i])
		draw_circle(centre, _cell * 0.34, color)
		if i < _snake.size() - 1:
			draw_line(centre, _cell_centre(_snake[i + 1]), color,
				maxf(2.0, _cell * 0.55), true)

	GameArt.draw_item(self, GameArt.Item.RICE, _cell_centre(_food), _cell * 0.31)
	var board_size := Vector2(float(_columns()), float(_rows())) * _cell
	draw_rect(Rect2(_origin, board_size), PetStyle.NIGHT_EDGE, false,
		maxf(1.0, 2.0 * _scale))
