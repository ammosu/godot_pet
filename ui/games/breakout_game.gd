extends MiniGame
class_name BreakoutGame

## 敲磚塊 — the pet carries the paddle and keeps the ball in play.
##
## Where the ball meets the paddle decides its return angle. Moving under the
## ball is only half the decision: catching it near an edge clears the side
## walls faster, while a centred return is safer. Clearing a wall starts another
## one at a slightly higher ball speed, so the shared high score remains useful
## instead of every completed board ending on the same number.

const LEVELS: Array[Dictionary] = [
	{"rows": 5, "columns": 7, "speed": 270.0, "paddle": 132.0, "gap": 6.0},
	{"rows": 6, "columns": 8, "speed": 330.0, "paddle": 112.0, "gap": 5.0},
	{"rows": 7, "columns": 9, "speed": 390.0, "paddle": 94.0, "gap": 4.0},
]

const WALL_INSET := 16.0
const BRICK_SIDE_INSET := 26.0
const BRICK_TOP := 52.0
const BRICK_HEIGHT := 24.0
const BRICK_ROW_GAP := 6.0
const BALL_RADIUS := 8.0
const PADDLE_HEIGHT := 12.0
const PADDLE_HEAD_GAP := 7.0
const PADDLE_SPEED := 440.0
const PADDLE_MOUSE_RATE := 15.0
const SERVE_DELAY := 0.72
const NEXT_WALL_DELAY := 0.58
const MAX_WAVE_SPEEDUP := 1.38
const REACTION_TIME := 0.34
const CHIP_LIFE := 0.34
const CHIP_GRAVITY := 430.0
const TRAIL_LENGTH := 6

var _bricks: Array[Dictionary] = []
var _chips: Array[Dictionary] = []
var _trail := PackedVector2Array()
var _paddle_x := 0.0
var _paddle_velocity := 0.0
var _mouse_x := 0.0
var _using_mouse := false
var _needs_layout := true
var _ball_pos := Vector2.ZERO
var _ball_velocity := Vector2.ZERO
var _ball_active := false
var _serve_left := SERVE_DELAY
var _next_wall_left := 0.0
var _wave := 0
var _reaction_left := 0.0
var _reaction_good := true
var _paddle_squash := 0.0


func design_size() -> Vector2i:
	return Vector2i(560, 620)


func ready_hint() -> String:
	return "← → ／ A D 或滑鼠移動\n用寵物頭上的板子把球打回去\n漏接三球就結束"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["寬球拍", "標準", "高速"])


func pet_design_height() -> float:
	return 66.0


func _prepare() -> void:
	_bricks.clear()
	_chips.clear()
	_trail.clear()
	_ball_active = false
	_ball_velocity = Vector2.ZERO
	_serve_left = SERVE_DELAY
	_next_wall_left = 0.0
	_wave = 0
	_reaction_left = 0.0
	_reaction_good = true
	_paddle_squash = 0.0
	_paddle_velocity = 0.0
	_needs_layout = true
	if _pet != null:
		_pet.visible = true
		_pet.set_squash(0.0)


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	if _needs_layout and size.x > 0.0 and size.y > 0.0:
		_paddle_x = size.x * 0.5
		_mouse_x = _paddle_x
		_build_wall()
		_place_ball()
		_needs_layout = false

	_step_paddle(delta)
	_step_chips(delta)
	if is_playing():
		if _ball_active:
			_step_ball(delta)
		else:
			_step_wait(delta)
	else:
		_place_ball()

	_pet.stand_on(_ground_y(), _paddle_x)
	_pose(delta)


func _step_paddle(delta: float) -> void:
	var before := _paddle_x
	var axis := _held_axis()
	if not is_zero_approx(axis):
		_using_mouse = false
	if _using_mouse:
		_paddle_x = lerpf(_paddle_x, _mouse_x,
			clampf(delta * PADDLE_MOUSE_RATE, 0.0, 1.0))
	else:
		_paddle_x += axis * PADDLE_SPEED * _scale * delta

	var half := _paddle_width() * 0.5
	var wall := WALL_INSET * _scale
	_paddle_x = clampf(_paddle_x, wall + half, size.x - wall - half)
	_paddle_velocity = (_paddle_x - before) / maxf(delta, 0.0001)
	if absf(_paddle_velocity) > 7.0 * _scale:
		_pet.set_facing(1 if _paddle_velocity > 0.0 else -1)


func _step_wait(delta: float) -> void:
	if _next_wall_left > 0.0:
		_next_wall_left -= delta
		if _next_wall_left <= 0.0:
			_build_wall()
			_serve_left = SERVE_DELAY
		_place_ball()
		return
	_place_ball()
	_serve_left -= delta
	if _serve_left <= 0.0:
		_serve()


func _step_ball(delta: float) -> void:
	# Split fast frames into pieces smaller than the ball. That keeps a high-wave
	# ball from crossing a whole brick or the thin paddle between two samples.
	var distance := _ball_velocity.length() * delta
	var step_limit := maxf(2.0 * _scale, BALL_RADIUS * 0.72 * _scale)
	var steps := maxi(1, ceili(distance / step_limit))
	var step_delta := delta / float(steps)
	for _step in steps:
		var previous := _ball_pos
		_ball_pos += _ball_velocity * step_delta
		_bounce_walls()
		if _bounce_paddle(previous):
			_react(true, 0.11)
		_hit_brick(previous)
		if not _ball_active:
			break
		if _ball_pos.y - BALL_RADIUS * _scale > _ground_y() + 8.0 * _scale:
			_miss()
			break

	if _ball_active:
		_trail.append(_ball_pos)
		while _trail.size() > TRAIL_LENGTH:
			_trail.remove_at(0)


func _step_chips(delta: float) -> void:
	for i in range(_chips.size() - 1, -1, -1):
		var chip: Dictionary = _chips[i]
		chip["life"] = float(chip["life"]) - delta
		if float(chip["life"]) <= 0.0:
			_chips.remove_at(i)
			continue
		var velocity: Vector2 = chip["velocity"]
		velocity.y += CHIP_GRAVITY * _scale * delta
		chip["velocity"] = velocity
		chip["position"] = Vector2(chip["position"]) + velocity * delta


func _serve() -> void:
	_ball_active = true
	_trail.clear()
	_place_ball()
	var lean := randf_range(-0.52, 0.52)
	if absf(lean) < 0.18:
		lean = 0.18 if randf() >= 0.5 else -0.18
	_ball_velocity = Vector2(lean, -1.0).normalized() * _ball_speed()


func _miss() -> void:
	_ball_active = false
	_trail.clear()
	_reaction_good = false
	_reaction_left = REACTION_TIME * 1.7
	_paddle_squash = -0.12
	_lose_one()
	if is_playing():
		_serve_left = SERVE_DELAY * 1.25
		_place_ball()


func _wall_cleared() -> void:
	_ball_active = false
	_trail.clear()
	_wave += 1
	_next_wall_left = NEXT_WALL_DELAY
	_react(true, 0.18)


# --- Board --------------------------------------------------------------------

func _build_wall() -> void:
	_bricks.clear()
	var level: Dictionary = LEVELS[_level]
	var rows := int(level["rows"])
	var columns := int(level["columns"])
	var gap := float(level["gap"]) * _scale
	var usable := size.x - BRICK_SIDE_INSET * 2.0 * _scale
	var brick_width := (usable - gap * float(columns - 1)) / float(columns)
	var top := BRICK_TOP * _scale
	var height := BRICK_HEIGHT * _scale
	for row in rows:
		for column in columns:
			var x := BRICK_SIDE_INSET * _scale \
				+ float(column) * (brick_width + gap)
			var y := top + float(row) * (height + BRICK_ROW_GAP * _scale)
			_bricks.append({
				"rect": Rect2(Vector2(x, y), Vector2(brick_width, height)),
				"color": _brick_color(row),
			})


func _brick_color(row: int) -> Color:
	match row % 5:
		0:
			return PetStyle.GAME_BREAKOUT_CREAM
		1:
			return PetStyle.GAME_BREAKOUT_TEAL
		2:
			return PetStyle.GAME_BREAKOUT_GOLD
		3:
			return PetStyle.GAME_BREAKOUT_PERSIMMON
		_:
			return PetStyle.GAME_BREAKOUT_GREEN


func _ball_speed() -> float:
	var base := float(LEVELS[_level]["speed"])
	var wave_factor := minf(MAX_WAVE_SPEEDUP, 1.0 + float(_wave) * 0.065)
	return base * wave_factor * _scale


func _paddle_width() -> float:
	return float(LEVELS[_level]["paddle"]) * _scale


func _paddle_y() -> float:
	return _ground_y() - _pet.height() - PADDLE_HEAD_GAP * _scale


func _paddle_rect() -> Rect2:
	var width := _paddle_width()
	return Rect2(
		Vector2(_paddle_x - width * 0.5, _paddle_y()),
		Vector2(width, PADDLE_HEIGHT * _scale))


func _place_ball() -> void:
	_ball_pos = Vector2(
		_paddle_x,
		_paddle_y() - (BALL_RADIUS + 5.0) * _scale)


# --- Collisions ---------------------------------------------------------------

func _bounce_walls() -> void:
	var radius := BALL_RADIUS * _scale
	var inset := WALL_INSET * _scale
	if _ball_pos.x < inset + radius:
		_ball_pos.x = inset + radius
		_ball_velocity.x = absf(_ball_velocity.x)
	elif _ball_pos.x > size.x - inset - radius:
		_ball_pos.x = size.x - inset - radius
		_ball_velocity.x = -absf(_ball_velocity.x)
	if _ball_pos.y < inset + radius:
		_ball_pos.y = inset + radius
		_ball_velocity.y = absf(_ball_velocity.y)


func _bounce_paddle(previous: Vector2) -> bool:
	if _ball_velocity.y <= 0.0:
		return false
	var radius := BALL_RADIUS * _scale
	var paddle := _paddle_rect()
	var expanded := paddle.grow(radius)
	if not expanded.has_point(_ball_pos) or previous.y > expanded.position.y:
		return false

	_ball_pos.y = paddle.position.y - radius
	var offset := clampf(
		(_ball_pos.x - _paddle_x) / maxf(1.0, paddle.size.x * 0.5),
		-1.0, 1.0)
	var speed := maxf(_ball_velocity.length(), _ball_speed())
	var x_speed := offset * speed * 0.84 + _paddle_velocity * 0.12
	x_speed = clampf(x_speed, -speed * 0.88, speed * 0.88)
	_ball_velocity = Vector2(
		x_speed,
		-sqrt(maxf(1.0, speed * speed - x_speed * x_speed)))
	_paddle_squash = 0.15
	return true


func _hit_brick(previous: Vector2) -> void:
	var radius := BALL_RADIUS * _scale
	for i in _bricks.size():
		var brick: Dictionary = _bricks[i]
		var rect: Rect2 = brick["rect"]
		var expanded := rect.grow(radius)
		if not expanded.has_point(_ball_pos):
			continue

		if previous.y <= expanded.position.y:
			_ball_pos.y = expanded.position.y
			_ball_velocity.y = -absf(_ball_velocity.y)
		elif previous.y >= expanded.end.y:
			_ball_pos.y = expanded.end.y
			_ball_velocity.y = absf(_ball_velocity.y)
		elif previous.x <= expanded.position.x:
			_ball_pos.x = expanded.position.x
			_ball_velocity.x = -absf(_ball_velocity.x)
		elif previous.x >= expanded.end.x:
			_ball_pos.x = expanded.end.x
			_ball_velocity.x = absf(_ball_velocity.x)
		else:
			# A corner can begin inside the expanded box after a resize or an
			# unusually long frame. Resolve along the shallower penetration.
			var x_pen := minf(
				_ball_pos.x - expanded.position.x,
				expanded.end.x - _ball_pos.x)
			var y_pen := minf(
				_ball_pos.y - expanded.position.y,
				expanded.end.y - _ball_pos.y)
			if x_pen < y_pen:
				_ball_velocity.x *= -1.0
			else:
				_ball_velocity.y *= -1.0

		_spawn_chips(rect.get_center(), Color(brick["color"]))
		_bricks.remove_at(i)
		_add_score(1)
		_react(true, 0.08)
		if _bricks.is_empty():
			_wall_cleared()
		return


func _spawn_chips(at: Vector2, color: Color) -> void:
	for i in 4:
		var direction := Vector2(
			-1.0 + float(i % 2) * 2.0,
			-0.75 + float(i / 2) * 0.55)
		_chips.append({
			"position": at + direction * 3.0 * _scale,
			"velocity": direction * randf_range(42.0, 82.0) * _scale,
			"life": CHIP_LIFE,
			"color": color,
		})


# --- Pet and input ------------------------------------------------------------

func _react(good: bool, squash: float) -> void:
	_reaction_good = good
	_reaction_left = REACTION_TIME
	_paddle_squash = squash


func _pose(delta: float) -> void:
	if _reaction_left > 0.0:
		_reaction_left = maxf(0.0, _reaction_left - delta)
		_pet.set_state(&"happy" if _reaction_good else &"sad")
	else:
		_pet.set_state(&"walk"
			if absf(_paddle_velocity) > 7.0 * _scale else &"idle")
	var target := 0.0
	if _reaction_left > 0.0:
		target = _paddle_squash * (_reaction_left / REACTION_TIME)
	_paddle_squash = lerpf(
		_paddle_squash, target, clampf(delta * 13.0, 0.0, 1.0))
	_pet.set_squash(_paddle_squash)


func _pointer_moved(pos: Vector2) -> void:
	_using_mouse = true
	_mouse_x = pos.x


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	_draw_walls()
	for brick in _bricks:
		_draw_brick(Rect2(brick["rect"]), Color(brick["color"]))
	for chip in _chips:
		var alpha := clampf(float(chip["life"]) / CHIP_LIFE, 0.0, 1.0)
		var color := Color(chip["color"])
		color.a *= alpha
		var chip_size := maxf(2.0, 4.0 * _scale)
		draw_rect(Rect2(
			Vector2(chip["position"]) - Vector2.ONE * chip_size * 0.5,
			Vector2.ONE * chip_size), color)
	_draw_ball()
	_draw_paddle()


func _draw_walls() -> void:
	var inset := WALL_INSET * _scale
	var color := PetStyle.GAME_GROUND
	var width := maxf(1.0, 2.0 * _scale)
	draw_line(Vector2(inset, inset), Vector2(size.x - inset, inset), color, width)
	draw_line(Vector2(inset, inset), Vector2(inset, _paddle_y()), color, width)
	draw_line(Vector2(size.x - inset, inset),
		Vector2(size.x - inset, _paddle_y()), color, width)


func _draw_brick(rect: Rect2, color: Color) -> void:
	draw_rect(rect, color)
	var light := Color(1.0, 1.0, 1.0, 0.22)
	var shade := Color(0.0, 0.0, 0.0, 0.24)
	var edge := maxf(1.0, 2.0 * _scale)
	draw_line(
		rect.position + Vector2(edge, edge),
		Vector2(rect.end.x - edge, rect.position.y + edge),
		light, edge)
	draw_line(
		Vector2(rect.position.x + edge, rect.end.y - edge),
		rect.end - Vector2(edge, edge),
		shade, edge)


func _draw_ball() -> void:
	if not _ball_active and not is_playing():
		return
	var radius := BALL_RADIUS * _scale
	for i in _trail.size():
		var strength := float(i + 1) / float(_trail.size() + 1)
		draw_circle(_trail[i], radius * (0.34 + strength * 0.24),
			Color(PetStyle.GAME_BREAKOUT_BALL, strength * 0.18))
	draw_circle(_ball_pos, radius, PetStyle.GAME_BREAKOUT_BALL)
	draw_circle(
		_ball_pos + Vector2(-2.2, -2.5) * _scale,
		radius * 0.25, Color(1.0, 1.0, 1.0, 0.58))


func _draw_paddle() -> void:
	var paddle := _paddle_rect()
	draw_rect(paddle, PetStyle.GAME_BREAKOUT_PADDLE)
	var edge := maxf(1.0, 2.0 * _scale)
	draw_line(
		paddle.position + Vector2(edge, edge),
		Vector2(paddle.end.x - edge, paddle.position.y + edge),
		Color(1.0, 1.0, 1.0, 0.28), edge)
	draw_line(
		Vector2(paddle.position.x + edge, paddle.end.y - edge),
		paddle.end - Vector2(edge, edge),
		Color(0.0, 0.0, 0.0, 0.30), edge)
