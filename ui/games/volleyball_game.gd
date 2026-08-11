extends MiniGame
class_name VolleyballGame

## 排球對決 — a compact one-player arcade volleyball match.
##
## The useful part of the old browser game this takes after is the readable
## three-action rally: get under the ball, jump, and choose whether to drive it
## down. It does not use its characters, art, name or exact court.
##
## The player owns the left court and the rival owns the right. Touching the
## ball returns it automatically; pressing jump again in the air primes a fast
## downward hit. A point on the far court raises the score, while three balls on
## the near court end the run — the same high-score shape as the other reflex
## games, rather than a first-to-seven match whose best score is always seven.

const LEVELS: Array[Dictionary] = [
	{"speed": 190.0, "think": 0.22, "error": 74.0, "jump": 105.0, "smash": 0.12},
	{"speed": 245.0, "think": 0.13, "error": 38.0, "jump": 122.0, "smash": 0.34},
	{"speed": 305.0, "think": 0.07, "error": 14.0, "jump": 142.0, "smash": 0.62},
]

const PLAYER_SPEED := 285.0
const PLAYER_MOUSE_RATE := 11.0
const JUMP_SPEED := 610.0
const PET_GRAVITY := 1800.0
const BALL_GRAVITY := 760.0
const BALL_RADIUS := 13.0
const BALL_RETURN_X := 355.0
const BALL_RETURN_Y := 460.0
const BALL_SMASH_X := 590.0
const BALL_SMASH_Y := 245.0
const BALL_MAX_SPEED := 820.0
const NET_HEIGHT := 118.0
const NET_HALF_WIDTH := 6.0
const COURT_MARGIN := 18.0
const SERVE_DELAY := 0.72
const POINT_PAUSE := 0.95
const HIT_COOLDOWN := 0.14
const SMASH_WINDOW := 0.24
const REACTION_TIME := 0.62

var _rival: GamePet = null
var _player_x := 0.0
var _rival_x := 0.0
var _mouse_x := 0.0
var _using_mouse := false
var _needs_layout := true
var _player_air := 0.0
var _rival_air := 0.0
var _player_vy := 0.0
var _rival_vy := 0.0
var _player_vx := 0.0
var _rival_vx := 0.0
var _player_smash_left := 0.0
var _player_squash := 0.0
var _rival_squash := 0.0

var _ball_pos := Vector2.ZERO
var _ball_vel := Vector2.ZERO
var _ball_active := false
var _serve_left := SERVE_DELAY
var _serve_from_player := true
var _player_hit_left := 0.0
var _rival_hit_left := 0.0

var _ai_target := 0.0
var _ai_think_left := 0.0
var _reaction_left := 0.0
var _player_won_last := false


func design_size() -> Vector2i:
	return Vector2i(700, 470)


func ready_hint() -> String:
	return "← → ／ A D 移動・空白鍵跳躍\n空中再按一次 = 扣球\n自己漏三球就結束"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["友善", "靈活", "狠角色"])


func pet_design_height() -> float:
	return 76.0


func _setup(pack: PetPack, rows: Dictionary) -> void:
	if _rival == null:
		_rival = GamePet.new()
		add_child(_rival)
	_rival.build(_scale, pack, rows, pet_design_height())
	_rival.set_facing(-1)


func _prepare() -> void:
	_needs_layout = true
	_player_air = 0.0
	_rival_air = 0.0
	_player_vy = 0.0
	_rival_vy = 0.0
	_player_vx = 0.0
	_rival_vx = 0.0
	_player_smash_left = 0.0
	_player_squash = 0.0
	_rival_squash = 0.0
	_ball_active = false
	_serve_left = SERVE_DELAY
	_serve_from_player = true
	_player_hit_left = 0.0
	_rival_hit_left = 0.0
	_ai_think_left = 0.0
	_reaction_left = 0.0
	if _pet != null:
		_pet.set_facing(1)
		_pet.set_squash(0.0)
	if _rival != null:
		_rival.set_facing(-1)
		_rival.set_squash(0.0)


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	if _needs_layout and size.x > 0.0:
		_player_x = size.x * 0.25
		_rival_x = size.x * 0.75
		_mouse_x = _player_x
		_ai_target = _rival_x
		_ball_pos = Vector2(size.x * 0.5, _ground_y() - NET_HEIGHT * 1.35 * _scale)
		_needs_layout = false

	_step_reaction(delta)
	if is_playing():
		_step_player(delta)
		_step_rival(delta)
		_step_round(delta)
	else:
		_player_vx = 0.0
		_rival_vx = 0.0

	var ground := _ground_y()
	_pet.stand_on(ground - _player_air, _player_x)
	if _rival != null:
		_rival.stand_on(ground - _rival_air, _rival_x)
	_pose(delta)


func _step_player(delta: float) -> void:
	var before := _player_x
	var axis := _held_axis()
	if not is_zero_approx(axis):
		_using_mouse = false
	if _using_mouse:
		_player_x = lerpf(_player_x, _mouse_x,
			clampf(delta * PLAYER_MOUSE_RATE, 0.0, 1.0))
	else:
		_player_x += axis * PLAYER_SPEED * _scale * delta
	var half := _pet.half_width()
	_player_x = clampf(_player_x, COURT_MARGIN * _scale + half,
		size.x * 0.5 - NET_HALF_WIDTH * _scale - half)
	_player_vx = (_player_x - before) / maxf(delta, 0.0001)
	_step_air(delta, true)
	_player_smash_left = maxf(0.0, _player_smash_left - delta)


func _step_rival(delta: float) -> void:
	_ai_think_left -= delta
	if _ai_think_left <= 0.0:
		_choose_ai_target()
		_ai_think_left = float(LEVELS[_level]["think"])

	var before := _rival_x
	var speed := float(LEVELS[_level]["speed"]) * _scale
	_rival_x = move_toward(_rival_x, _ai_target, speed * delta)
	var half := _rival.half_width()
	_rival_x = clampf(_rival_x, size.x * 0.5 + NET_HALF_WIDTH * _scale + half,
		size.x - COURT_MARGIN * _scale - half)
	_rival_vx = (_rival_x - before) / maxf(delta, 0.0001)

	if _ball_active and _rival_air <= 0.0 and _rival_vy <= 0.0 \
			and _ball_pos.x > size.x * 0.5:
		var feet := _ground_y()
		var close := absf(_ball_pos.x - _rival_x) \
			< float(LEVELS[_level]["jump"]) * _scale
		var reachable := _ball_pos.y < feet - _rival.height() * 0.46 \
			and _ball_pos.y > feet - 195.0 * _scale
		if close and reachable:
			_rival_vy = JUMP_SPEED * _scale
	_step_air(delta, false)


func _step_air(delta: float, player: bool) -> void:
	var air := _player_air if player else _rival_air
	var vy := _player_vy if player else _rival_vy
	if air > 0.0 or vy > 0.0:
		vy -= PET_GRAVITY * _scale * delta
		air += vy * delta
		if air <= 0.0:
			air = 0.0
			vy = 0.0
	if player:
		_player_air = air
		_player_vy = vy
	else:
		_rival_air = air
		_rival_vy = vy


func _step_round(delta: float) -> void:
	_player_hit_left = maxf(0.0, _player_hit_left - delta)
	_rival_hit_left = maxf(0.0, _rival_hit_left - delta)
	if not _ball_active:
		_serve_left -= delta
		if _serve_left <= 0.0:
			_serve()
		return

	var previous := _ball_pos
	_ball_vel.y += BALL_GRAVITY * _scale * delta
	_ball_vel = _ball_vel.limit_length(BALL_MAX_SPEED * _scale)
	_ball_pos += _ball_vel * delta
	_bounce_walls()
	_bounce_net(previous)
	_hit_pet(true)
	_hit_pet(false)

	var radius := BALL_RADIUS * _scale
	if _ball_pos.y + radius >= _ground_y():
		_ball_pos.y = _ground_y() - radius
		_point(_ball_pos.x > size.x * 0.5)


func _serve() -> void:
	_ball_active = true
	var x := _player_x if _serve_from_player else _rival_x
	var direction := 1.0 if _serve_from_player else -1.0
	_ball_pos = Vector2(x, _ground_y() - 145.0 * _scale)
	_ball_vel = Vector2(direction * 245.0, -365.0) * _scale


func _point(player_won: bool) -> void:
	_ball_active = false
	_player_won_last = player_won
	_reaction_left = REACTION_TIME
	_serve_from_player = player_won
	if player_won:
		_add_score(1)
		_player_squash = 0.13
		_rival_squash = -0.10
	else:
		_player_squash = -0.12
		_rival_squash = 0.11
		_lose_one()
	if is_playing():
		_serve_left = POINT_PAUSE


# --- Ball contacts ------------------------------------------------------------

func _bounce_walls() -> void:
	var radius := BALL_RADIUS * _scale
	if _ball_pos.x < radius:
		_ball_pos.x = radius
		_ball_vel.x = absf(_ball_vel.x)
	elif _ball_pos.x > size.x - radius:
		_ball_pos.x = size.x - radius
		_ball_vel.x = -absf(_ball_vel.x)
	if _ball_pos.y < radius:
		_ball_pos.y = radius
		_ball_vel.y = absf(_ball_vel.y)


func _bounce_net(previous: Vector2) -> void:
	var centre := size.x * 0.5
	var radius := BALL_RADIUS * _scale
	var half := NET_HALF_WIDTH * _scale
	var top := _ground_y() - NET_HEIGHT * _scale
	if _ball_pos.y + radius < top:
		return

	# Crossing the post from either side. Previous position is used so a fast
	# smash cannot tunnel from one court to the other through the net.
	if previous.x + radius <= centre - half and _ball_pos.x + radius > centre - half:
		_ball_pos.x = centre - half - radius
		_ball_vel.x = -absf(_ball_vel.x) * 0.78
	elif previous.x - radius >= centre + half and _ball_pos.x - radius < centre + half:
		_ball_pos.x = centre + half + radius
		_ball_vel.x = absf(_ball_vel.x) * 0.78
	elif absf(_ball_pos.x - centre) <= half + radius \
			and previous.y + radius <= top and _ball_pos.y + radius > top:
		_ball_pos.y = top - radius
		_ball_vel.y = -absf(_ball_vel.y) * 0.82


func _hit_pet(player: bool) -> void:
	if (player and _player_hit_left > 0.0) \
			or (not player and _rival_hit_left > 0.0):
		return
	var actor := _pet if player else _rival
	var x := _player_x if player else _rival_x
	var air := _player_air if player else _rival_air
	var feet := _ground_y() - air
	var rect := actor.collision_rect(x, feet)
	if not GamePet.circle_hits_rect(_ball_pos, BALL_RADIUS * _scale, rect):
		return

	var direction := 1.0 if player else -1.0
	var runner_vx := _player_vx if player else _rival_vx
	var smash := false
	if player:
		smash = _player_smash_left > 0.0 and _player_air > 8.0 * _scale
	else:
		smash = _rival_air > 20.0 * _scale \
			and randf() < float(LEVELS[_level]["smash"])

	# A downward drive is only useful while the ball is already clear of the
	# tape. Below that height it becomes a harder upward save instead.
	var clears_net := _ball_pos.y < _ground_y() - NET_HEIGHT * _scale \
		- BALL_RADIUS * _scale
	if smash and clears_net:
		_ball_vel = Vector2(direction * BALL_SMASH_X, BALL_SMASH_Y) * _scale
	else:
		var offset := clampf((_ball_pos.x - x) /
			maxf(1.0, actor.half_width() + BALL_RADIUS * _scale), -1.0, 1.0)
		_ball_vel = Vector2(
			(direction * BALL_RETURN_X + offset * 95.0) * _scale + runner_vx * 0.20,
			-BALL_RETURN_Y * _scale)

	var clear_x := x + direction \
		* (actor.half_width() + BALL_RADIUS * _scale + 1.0)
	var centre := size.x * 0.5
	# Standing against the post must not let the contact correction teleport a
	# low ball through the net before _bounce_net() gets another frame to see it.
	if player:
		_ball_pos.x = minf(clear_x,
			centre - (NET_HALF_WIDTH + BALL_RADIUS) * _scale)
	else:
		_ball_pos.x = maxf(clear_x,
			centre + (NET_HALF_WIDTH + BALL_RADIUS) * _scale)
	if player:
		_player_hit_left = HIT_COOLDOWN
		_player_smash_left = 0.0
		_player_squash = 0.14 if smash else 0.08
	else:
		_rival_hit_left = HIT_COOLDOWN
		_rival_squash = 0.14 if smash else 0.08


# --- Rival --------------------------------------------------------------------

func _choose_ai_target() -> void:
	var home := size.x * 0.75
	if not _ball_active or (_ball_pos.x < size.x * 0.5 and _ball_vel.x <= 0.0):
		_ai_target = home
		return
	var target := _predict_landing_x()
	var error := float(LEVELS[_level]["error"]) * _scale
	target += randf_range(-error, error)
	var half := _rival.half_width()
	_ai_target = clampf(target,
		size.x * 0.5 + NET_HALF_WIDTH * _scale + half,
		size.x - COURT_MARGIN * _scale - half)


func _predict_landing_x() -> float:
	var ground := _ground_y() - BALL_RADIUS * _scale
	var gravity := BALL_GRAVITY * _scale
	var c := _ball_pos.y - ground
	var discriminant := _ball_vel.y * _ball_vel.y - 2.0 * gravity * c
	if discriminant <= 0.0:
		return _ball_pos.x
	var seconds := (-_ball_vel.y + sqrt(discriminant)) / gravity
	var raw := _ball_pos.x + _ball_vel.x * maxf(0.0, seconds)
	var left := BALL_RADIUS * _scale
	var right := size.x - left
	var span := right - left
	var folded := fposmod(raw - left, span * 2.0)
	return right - (folded - span) if folded > span else left + folded


# --- Pose and input -----------------------------------------------------------

func _step_reaction(delta: float) -> void:
	_reaction_left = maxf(0.0, _reaction_left - delta)


func _pose(delta: float) -> void:
	if _reaction_left > 0.0:
		_pet.set_state(&"happy" if _player_won_last else &"sad")
		_rival.set_state(&"sad" if _player_won_last else &"happy")
	else:
		# The pack format does not promise that walk and run share an intrinsic
		# direction. GamePet's facing convention is established against walk
		# (the same row CatchGame uses); at least one real pack draws run facing
		# the opposite way, which made both players turn away from the net.
		_pet.set_state(&"walk" if is_playing() and
			(absf(_player_vx) > 5.0 * _scale or _player_air > 0.0) else &"idle")
		_rival.set_state(&"walk" if is_playing() and
			(absf(_rival_vx) > 5.0 * _scale or _rival_air > 0.0) else &"idle")
	_player_squash = lerpf(_player_squash,
		-0.08 if _player_air > 0.0 else 0.0, clampf(delta * 10.0, 0.0, 1.0))
	_rival_squash = lerpf(_rival_squash,
		-0.08 if _rival_air > 0.0 else 0.0, clampf(delta * 10.0, 0.0, 1.0))
	_pet.set_squash(_player_squash)
	_rival.set_squash(_rival_squash)


func _jump_or_smash() -> void:
	if not is_playing():
		return
	if _player_air <= 0.0 and _player_vy <= 0.0:
		_player_vy = JUMP_SPEED * _scale
	else:
		_player_smash_left = SMASH_WINDOW


func _key_pressed(keycode: int) -> bool:
	if keycode == KEY_SPACE or keycode == KEY_UP or keycode == KEY_W \
			or keycode == KEY_ENTER or keycode == KEY_KP_ENTER:
		_jump_or_smash()
		return true
	if keycode == KEY_DOWN or keycode == KEY_S:
		if _player_air > 0.0:
			_player_smash_left = SMASH_WINDOW
		return true
	return false


func _pointer_moved(pos: Vector2) -> void:
	_using_mouse = true
	_mouse_x = pos.x


func _pointer_clicked(_pos: Vector2) -> void:
	_jump_or_smash()


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	var ground := _ground_y()
	var centre := size.x * 0.5
	draw_rect(Rect2(0.0, 0.0, centre, ground),
		Color(PetStyle.GAME_VOLLEY_PLAYER, 0.035))
	draw_rect(Rect2(centre, 0.0, centre, ground),
		Color(PetStyle.GAME_VOLLEY_RIVAL, 0.035))
	_draw_ground()
	draw_line(Vector2(centre, ground), Vector2(centre, ground - NET_HEIGHT * _scale),
		PetStyle.GAME_VOLLEY_NET, maxf(2.0, NET_HALF_WIDTH * 2.0 * _scale))
	for i in 5:
		var y := ground - NET_HEIGHT * _scale + float(i) * 24.0 * _scale
		draw_line(Vector2(centre - 12.0 * _scale, y),
			Vector2(centre + 12.0 * _scale, y),
			Color(PetStyle.GAME_VOLLEY_NET, 0.48), maxf(1.0, _scale))
	draw_line(Vector2(centre - 17.0 * _scale, ground - NET_HEIGHT * _scale),
		Vector2(centre + 17.0 * _scale, ground - NET_HEIGHT * _scale),
		PetStyle.GAME_VOLLEY_BALL, maxf(2.0, 3.0 * _scale))

	_draw_court_mark(_player_x, ground, PetStyle.GAME_VOLLEY_PLAYER)
	_draw_court_mark(_rival_x, ground, PetStyle.GAME_VOLLEY_RIVAL)
	if _ball_active or not is_playing():
		_draw_ball(_ball_pos)


func _draw_court_mark(x: float, ground: float, color: Color) -> void:
	draw_arc(Vector2(x, ground + 2.0 * _scale), 24.0 * _scale,
		PI, TAU, 18, Color(color, 0.58), maxf(2.0, 3.0 * _scale), true)


func _draw_ball(at: Vector2) -> void:
	var radius := BALL_RADIUS * _scale
	draw_circle(at, radius, PetStyle.GAME_VOLLEY_BALL)
	draw_arc(at, radius * 0.68, -PI * 0.42, PI * 0.42, 12,
		PetStyle.GAME_VOLLEY_SEAM, maxf(1.0, 1.6 * _scale), true)
	draw_arc(at, radius * 0.68, PI * 0.58, PI * 1.42, 12,
		PetStyle.GAME_VOLLEY_SEAM, maxf(1.0, 1.6 * _scale), true)
	draw_line(at + Vector2(0.0, -radius), at + Vector2(0.0, radius),
		Color(PetStyle.GAME_VOLLEY_SEAM, 0.74), maxf(1.0, 1.2 * _scale))
