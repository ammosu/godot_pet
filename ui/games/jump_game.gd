extends MiniGame
class_name JumpGame

## 跳過去 — the ground slides past, chillies come at you, one button gets over
## them.
##
## The timing game of the three. 接東西 asks *where* continuously; this asks
## *when*, once, and then takes the answer away from you for the three quarters
## of a second the jump lasts. That is the whole design: there is exactly one
## input and no way to change your mind mid-air, which is what makes a jump you
## judged right feel like something you did rather than something you held.
##
## No double jump, deliberately. A second jump turns every mistimed first one
## into a recoverable one, and then the game stops being about the decision.
##
## Space, ↑, W or a click all jump — the same four things a person tries without
## being told, and the ready banner only has room to name two of them.

## `speed` is how fast the ground moves in design px/s, `gap` the seconds between
## obstacles, `ramp` what is added to the speed per minute survived, and `star`
## the chance an obstacle arrives with a bonus floating over it.
##
## The gap is in *seconds*, not pixels, so raising the speed doesn't secretly
## also crowd the field — the two are separate dials and the levels move both on
## purpose.
const LEVELS: Array[Dictionary] = [
	{"speed": 250.0, "gap": Vector2(1.25, 1.90), "ramp": 0.30, "star": 0.30},
	{"speed": 330.0, "gap": Vector2(0.95, 1.45), "ramp": 0.45, "star": 0.35},
	{"speed": 420.0, "gap": Vector2(0.75, 1.10), "ramp": 0.60, "star": 0.40},
]

## Where the pet runs, as a fraction across the field. Well left of centre: what
## you need to see is what is *coming*, and everything behind the pet is already
## decided.
const PET_AT := 0.26
const JUMP_SPEED := 640.0
const GRAVITY := 1800.0
## Peak of that arc is roughly 114 design px, against a 44px obstacle — enough
## that a jump taken at the right moment is never lost to the numbers.
const OBSTACLE_HEIGHT := 44.0
const OBSTACLE_HALF := 15.0
const STAR_RADIUS := 15.0
const STAR_POINTS := 3
## How far above the ground the bonus floats: over the obstacle, and only
## reachable near the top of a jump.
const STAR_HEIGHT := 128.0
const MAX_SPEEDUP := 2.1
## How long the pet sulks after a hit, and how long it is intangible for. The
## same window, so one obstacle can never cost two lives.
const STUN_TIME := 0.55
## Marks on the ground, so speed is visible even when nothing is coming.
const DASH_SPACING := 58.0
const DASH_LENGTH := 22.0


var _obstacles: Array[Dictionary] = []
var _spawn_in := 0.0
var _air := 0.0
var _vy := 0.0
var _stun_left := 0.0
var _scroll := 0.0
## GamePet takes a squash and doesn't hand it back, so the eased value lives
## here. One owner, like PetVisual's — a hit sets it and _pose() is the only
## thing that moves it afterwards.
var _squash := 0.0


func design_size() -> Vector2i:
	# Wide and short. A runner is read horizontally — the vertical half of a
	# 440x560 window would be empty sky.
	return Vector2i(540, 440)


func ready_hint() -> String:
	return "空白鍵或點一下開始\n空白鍵 ／ ↑ ／ 點一下 = 跳\n撞到三次就結束"


func pet_design_height() -> float:
	# Smaller than in 接東西: the jump arc has to be visibly taller than the pet
	# in a window that is only 440 design px high.
	return 78.0


func _prepare() -> void:
	_obstacles.clear()
	_air = 0.0
	_vy = 0.0
	_stun_left = 0.0
	_scroll = 0.0
	_squash = 0.0
	# Long enough to see the ground moving before the first thing to jump.
	_spawn_in = 1.1
	if _pet != null:
		_pet.set_facing(1)
		_pet.set_squash(0.0)


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	var ground := _ground_y()
	if is_playing():
		_scroll += _speed() * delta
		_step_jump(delta)
		_advance(delta)
	_pet.stand_on(ground - _air, _pet_x())
	_pose(delta)


func _pet_x() -> float:
	return size.x * PET_AT


func _speed() -> float:
	var level: Dictionary = LEVELS[_level]
	var ramp := 1.0 + float(level["ramp"]) * _elapsed / 60.0
	return float(level["speed"]) * _scale * minf(ramp, MAX_SPEEDUP)


func _step_jump(delta: float) -> void:
	if _air <= 0.0 and _vy <= 0.0:
		return
	_vy -= GRAVITY * _scale * delta
	_air += _vy * delta
	if _air <= 0.0:
		_air = 0.0
		_vy = 0.0


func _jump() -> void:
	# Only from the ground. See the note about double jumps at the top.
	if _air > 0.0 or not is_playing():
		return
	_vy = JUMP_SPEED * _scale


func _advance(delta: float) -> void:
	_spawn_in -= delta
	if _spawn_in <= 0.0:
		_spawn()
		var gap: Vector2 = LEVELS[_level]["gap"]
		_spawn_in = randf_range(gap.x, gap.y)

	if _stun_left > 0.0:
		_stun_left = maxf(0.0, _stun_left - delta)

	var travel := _speed() * delta
	var ground := _ground_y()
	var pet_x := _pet_x()
	var feet := ground - _air
	var pet_rect := _pet.collision_rect(pet_x, feet)

	for i in range(_obstacles.size() - 1, -1, -1):
		var ob: Dictionary = _obstacles[i]
		var x := float(ob["x"]) - travel
		ob["x"] = x

		if bool(ob["star"]) and not bool(ob["taken"]):
			var star_y := ground - STAR_HEIGHT * _scale
			if GamePet.circle_hits_rect(Vector2(x, star_y),
					STAR_RADIUS * _scale, pet_rect):
				ob["taken"] = true
				_add_score(STAR_POINTS)
				_react(true)

		# Behind the pet and never touched. The `hit` test matters: an obstacle
		# you crashed into still slides off the left edge, and without this it
		# paid out a point on the way — so a run that hit everything still
		# scored, which is the opposite of what the number is supposed to mean.
		if not bool(ob["cleared"]) and not bool(ob["hit"]) \
				and x + OBSTACLE_HALF * _scale < pet_rect.position.x:
			ob["cleared"] = true
			_add_score(1)

		var obstacle_rect := Rect2(
			Vector2(x - OBSTACLE_HALF * _scale,
				ground - OBSTACLE_HEIGHT * _scale),
			Vector2(OBSTACLE_HALF * 2.0 * _scale,
				OBSTACLE_HEIGHT * _scale))
		if _stun_left <= 0.0 and not bool(ob["hit"]) \
				and pet_rect.intersects(obstacle_rect, true):
			ob["hit"] = true
			_react(false)
			_stun_left = STUN_TIME
			_lose_one()

		if x < -OBSTACLE_HALF * 3.0 * _scale:
			_obstacles.remove_at(i)


func _spawn() -> void:
	_obstacles.append({
		"x": size.x + OBSTACLE_HALF * 2.0 * _scale,
		"star": randf() < float(LEVELS[_level]["star"]),
		"taken": false,
		"cleared": false,
		"hit": false,
	})


func _react(good: bool) -> void:
	_squash = 0.12 if good else -0.14


func _pose(delta: float) -> void:
	if _stun_left > 0.0:
		_pet.set_state(&"sad")
	else:
		# No pack has a jump row, so the airborne pose is the run with a stretch
		# on it — which is what a body leaving the ground does anyway.
		_pet.set_state(&"run" if is_playing() else &"idle")

	var target := 0.0
	if _stun_left > 0.0:
		target = -0.14 * (_stun_left / STUN_TIME)
	elif _air > 0.0:
		target = clampf(_air / (110.0 * _scale), 0.0, 1.0) * -0.10
	_squash = lerpf(_squash, target, clampf(delta * 14.0, 0.0, 1.0))
	_pet.set_squash(_squash)


# --- Input --------------------------------------------------------------------

func _key_pressed(keycode: int) -> bool:
	if keycode == KEY_SPACE or keycode == KEY_UP or keycode == KEY_W \
			or keycode == KEY_ENTER or keycode == KEY_KP_ENTER:
		_jump()
		return true
	return false


func _pointer_clicked(_pos: Vector2) -> void:
	_jump()


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	_draw_ground()
	_draw_dashes()
	var ground := _ground_y()
	for ob in _obstacles:
		var x := float(ob["x"])
		if bool(ob["star"]) and not bool(ob["taken"]):
			GameArt.draw_item(self, GameArt.Item.STAR,
				Vector2(x, ground - STAR_HEIGHT * _scale), STAR_RADIUS * _scale)
		if bool(ob["hit"]):
			continue
		GameArt.draw_item(self, GameArt.Item.CHILLI,
			Vector2(x, ground - OBSTACLE_HEIGHT * 0.5 * _scale),
			OBSTACLE_HALF * 1.35 * _scale)


## Ground marks sliding backwards. Without them a run at a steady speed with
## nothing on screen looks paused, and the speed ramp is invisible until the
## next obstacle arrives too fast.
func _draw_dashes() -> void:
	var ground := _ground_y()
	var spacing := DASH_SPACING * _scale
	var length := DASH_LENGTH * _scale
	var y := ground + 7.0 * _scale
	var offset := fmod(_scroll, spacing)
	var x := -offset
	while x < size.x:
		draw_line(Vector2(x, y), Vector2(x + length, y),
			PetStyle.GAME_LIFE_SPENT, maxf(1.0, 2.0 * _scale))
		x += spacing
