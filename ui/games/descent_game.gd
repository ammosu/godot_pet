extends MiniGame
class_name DescentGame

## 下樓梯 — keep descending through a shaft that never stops rising.
##
## There is no jump button. The decision is when to walk off the platform under
## the pet and which one below to aim for. Staying put reaches the ceiling
## spikes; missing everything reaches the bottom. Normal platforms recover one
## mistake, while spikes, springs, moving ledges and crumbling ledges make the
## route less automatic without changing the two-button rule.

enum PlatformKind { NORMAL, SPIKE, SPRING, MOVING, CRUMBLE }

const LEVELS: Array[Dictionary] = [
	{
		"scroll": 48.0, "gap": Vector2(72.0, 84.0), "width": 122.0,
		"spike": 0.07, "spring": 0.06, "moving": 0.10, "crumble": 0.06,
	},
	{
		"scroll": 66.0, "gap": Vector2(68.0, 82.0), "width": 104.0,
		"spike": 0.12, "spring": 0.09, "moving": 0.15, "crumble": 0.10,
	},
	{
		"scroll": 86.0, "gap": Vector2(64.0, 78.0), "width": 88.0,
		"spike": 0.18, "spring": 0.12, "moving": 0.20, "crumble": 0.14,
	},
]

const PLAYER_SPEED := 270.0
const MOUSE_RATE := 11.0
const GRAVITY := 1120.0
const MAX_FALL_SPEED := 560.0
const SPRING_SPEED := 515.0
const SPRING_ANIM_TIME := 0.34
const SPRING_COIL_HEIGHT := 25.0
const SPRING_ARM_DISTANCE := 78.0
const SPIKE_BOUNCE := 260.0
const CEILING_DEPTH := 30.0
const PLATFORM_HEIGHT := 9.0
const PLATFORM_MARGIN := 20.0
const MOVING_RANGE := 48.0
const MOVING_RATE := 1.55
const CRUMBLE_TIME := 0.42
const RESPAWN_DELAY := 0.48
const INVINCIBLE_TIME := 0.85
const REACTION_TIME := 0.48
const MAX_SPEEDUP := 1.65
const SAFE_START_Y := 205.0
const HORIZONTAL_REACH := 132.0

var _platforms: Array[Dictionary] = []
var _next_id := 0
var _standing_id := -1
var _last_landed_id := -1
var _player_x := 0.0
var _player_feet := 0.0
var _player_vy := 0.0
var _player_vx := 0.0
var _mouse_x := 0.0
var _using_mouse := false
var _needs_layout := true
var _scroll_distance := 0.0
var _active := true
var _respawn_left := 0.0
var _invincible_left := 0.0
var _reaction_left := 0.0
var _reaction_bad := false
var _squash := 0.0
var _last_spawn_x := 0.0
var _last_spawn_kind := PlatformKind.NORMAL


func design_size() -> Vector2i:
	return Vector2i(470, 610)


func ready_hint() -> String:
	return "← → ／ A D 移動\n踩著不走會碰到頂端・沒踩到會掉出去\n普通平台可以回復一格"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["慢慢下", "腳步快", "深不見底"])


func pet_design_height() -> float:
	return 72.0


func uses_lives() -> bool:
	# The shared dots sit inside this game's ceiling spikes. Draw the same state
	# just below them in _paint() where it stays readable.
	return false


func _prepare() -> void:
	_platforms.clear()
	_next_id = 0
	_standing_id = -1
	_last_landed_id = -1
	_player_vy = 0.0
	_player_vx = 0.0
	_needs_layout = true
	_scroll_distance = 0.0
	_active = true
	_respawn_left = 0.0
	_invincible_left = 0.0
	_reaction_left = 0.0
	_reaction_bad = false
	_squash = 0.0
	_last_spawn_kind = PlatformKind.NORMAL
	if _pet != null:
		_pet.visible = true
		_pet.set_squash(0.0)


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	if _needs_layout and size.x > 0.0:
		_build_shaft()
		_needs_layout = false

	if is_playing():
		_invincible_left = maxf(0.0, _invincible_left - delta)
		_reaction_left = maxf(0.0, _reaction_left - delta)
		_step_platforms(delta)
		if _active:
			_step_player(delta)
		else:
			_step_respawn(delta)
	else:
		_player_vx = 0.0

	if _active:
		_pet.stand_on(_player_feet, _player_x)
	_pose(delta)


func _build_shaft() -> void:
	_platforms.clear()
	_next_id = 0
	_player_x = size.x * 0.5
	_mouse_x = _player_x
	_player_feet = SAFE_START_Y * _scale
	var start := _make_platform(
		_player_x, _player_feet, 142.0 * _scale, PlatformKind.NORMAL)
	_platforms.append(start)
	_standing_id = int(start["id"])
	_last_landed_id = _standing_id
	_last_spawn_x = _player_x

	var y := _player_feet
	var initial := true
	while y < size.y + 60.0 * _scale:
		y += _next_gap()
		var kind := PlatformKind.NORMAL if initial else _choose_kind()
		_spawn_platform(y, kind)
		initial = false


func _step_platforms(delta: float) -> void:
	var travel := _scroll_speed() * delta
	_scroll_distance += travel
	for platform in _platforms:
		platform["y"] = float(platform["y"]) - travel
		if int(platform["kind"]) == PlatformKind.MOVING:
			var phase := float(platform["phase"]) + delta * MOVING_RATE
			platform["phase"] = phase
			platform["x"] = float(platform["base_x"]) \
				+ sin(phase) * MOVING_RANGE * _scale
		if float(platform["break_left"]) > 0.0:
			platform["break_left"] = float(platform["break_left"]) - delta
		if float(platform["spring_anim"]) > 0.0:
			platform["spring_anim"] = maxf(
				0.0, float(platform["spring_anim"]) - delta)

	for i in range(_platforms.size() - 1, -1, -1):
		var platform: Dictionary = _platforms[i]
		if float(platform["y"]) < -24.0 * _scale \
				or (float(platform["break_left"]) < 0.0
					and bool(platform["triggered"])):
			if int(platform["id"]) == _standing_id:
				_standing_id = -1
			_platforms.remove_at(i)

	var bottom := -INF
	for platform in _platforms:
		bottom = maxf(bottom, float(platform["y"]))
	if is_inf(bottom):
		bottom = size.y * 0.5
	while bottom < size.y + 50.0 * _scale:
		bottom += _next_gap()
		_spawn_platform(bottom, _choose_kind())


func _step_player(delta: float) -> void:
	var before_x := _player_x
	var axis := _held_axis()
	if not is_zero_approx(axis):
		_using_mouse = false
	if _using_mouse:
		_player_x = lerpf(_player_x, _mouse_x, clampf(delta * MOUSE_RATE, 0.0, 1.0))
	else:
		_player_x += axis * PLAYER_SPEED * _scale * delta
	var half := _pet.half_width()
	_player_x = clampf(_player_x, half + 4.0 * _scale,
		size.x - half - 4.0 * _scale)
	_player_vx = (_player_x - before_x) / maxf(delta, 0.0001)
	if absf(_player_vx) > 5.0 * _scale:
		_pet.set_facing(1 if _player_vx > 0.0 else -1)

	var standing := _platform_by_id(_standing_id)
	if not standing.is_empty():
		if _over_platform(standing):
			_player_feet = float(standing["y"])
			_player_vy = 0.0
		else:
			_standing_id = -1
			standing = {}

	if standing.is_empty():
		var before_feet := _player_feet
		_player_vy = minf(MAX_FALL_SPEED * _scale,
			_player_vy + GRAVITY * _scale * delta)
		_player_feet += _player_vy * delta
		if _player_vy >= 0.0:
			_try_land(before_feet)

	var head := _player_feet - _pet.height()
	if head <= CEILING_DEPTH * _scale:
		_take_damage(true)
	elif _player_feet > size.y + _pet.height() * 0.45:
		_take_damage(true)


func _step_respawn(delta: float) -> void:
	_respawn_left -= delta
	if _respawn_left > 0.0:
		return
	var target := _safe_respawn_platform()
	if target.is_empty():
		_player_x = size.x * 0.5
		_player_feet = size.y * 0.35
		_standing_id = -1
		_last_landed_id = -1
	else:
		_player_x = float(target["x"])
		_player_feet = float(target["y"]) - 34.0 * _scale
		_standing_id = -1
		# The rescue platform is a checkpoint, not a fresh descent: otherwise
		# its normal-platform recovery refunds the mistake that caused the
		# respawn and standing still can never end a run.
		_last_landed_id = int(target["id"])
	_player_vy = 60.0 * _scale
	_mouse_x = _player_x
	_active = true
	_invincible_left = INVINCIBLE_TIME
	_pet.visible = true


# --- Platforms ---------------------------------------------------------------

func _try_land(before_feet: float) -> void:
	var candidate := {}
	var candidate_y := INF
	for platform in _platforms:
		if bool(platform["triggered"]) \
				and int(platform["kind"]) == PlatformKind.CRUMBLE:
			continue
		var y := float(platform["y"])
		if before_feet <= y and _player_feet >= y and _over_platform(platform) \
				and y < candidate_y:
			candidate = platform
			candidate_y = y
	if candidate.is_empty():
		return
	_land(candidate)


func _land(platform: Dictionary) -> void:
	_player_feet = float(platform["y"])
	_player_vy = 0.0
	var id := int(platform["id"])
	var first_visit := id != _last_landed_id
	_last_landed_id = id
	if first_visit:
		_add_score(1)
		_reaction_bad = false
		_reaction_left = REACTION_TIME

	match int(platform["kind"]):
		PlatformKind.SPIKE:
			_standing_id = -1
			_player_vy = -SPIKE_BOUNCE * _scale
			_take_damage(false)
		PlatformKind.SPRING:
			_standing_id = -1
			_player_vy = -SPRING_SPEED * _scale
			_squash = 0.20
			platform["spring_anim"] = SPRING_ANIM_TIME
		PlatformKind.CRUMBLE:
			_standing_id = id
			if not bool(platform["triggered"]):
				platform["triggered"] = true
				platform["break_left"] = CRUMBLE_TIME
		_:
			_standing_id = id
			if first_visit:
				_recover_one()
				_squash = 0.08


func _spawn_platform(y: float, kind: int) -> void:
	var width := float(LEVELS[_level]["width"]) * _scale
	if kind == PlatformKind.SPIKE:
		width *= 0.92
	elif kind == PlatformKind.SPRING:
		# The whole gold top plate is the contact surface. Keeping it narrower
		# than an ordinary ledge makes that surface readable at a glance.
		width *= 0.82
	elif kind == PlatformKind.MOVING:
		width *= 0.88
	var min_x := PLATFORM_MARGIN * _scale + width * 0.5
	var max_x := size.x - PLATFORM_MARGIN * _scale - width * 0.5
	if kind == PlatformKind.MOVING:
		min_x += MOVING_RANGE * _scale
		max_x -= MOVING_RANGE * _scale
	var x := clampf(_last_spawn_x
		+ randf_range(-HORIZONTAL_REACH, HORIZONTAL_REACH) * _scale,
		min_x, max_x)
	var platform := _make_platform(x, y, width, kind)
	_platforms.append(platform)
	_last_spawn_x = x
	_last_spawn_kind = kind


func _make_platform(x: float, y: float, width: float, kind: int) -> Dictionary:
	var platform := {
		"id": _next_id,
		"x": x,
		"base_x": x,
		"y": y,
		"width": width,
		"kind": kind,
		"phase": randf_range(0.0, TAU),
		"triggered": false,
		"break_left": 0.0,
		"spring_anim": 0.0,
	}
	_next_id += 1
	return platform


func _choose_kind() -> int:
	var roll := randf()
	var level: Dictionary = LEVELS[_level]
	var kind := PlatformKind.NORMAL
	if roll < float(level["spike"]):
		kind = PlatformKind.SPIKE
	elif roll < float(level["spike"]) + float(level["spring"]):
		kind = PlatformKind.SPRING
	elif roll < float(level["spike"]) + float(level["spring"]) \
			+ float(level["moving"]):
		kind = PlatformKind.MOVING
	elif roll < float(level["spike"]) + float(level["spring"]) \
			+ float(level["moving"]) + float(level["crumble"]):
		kind = PlatformKind.CRUMBLE
	# Two damaging platforms in a row can form a route with no correct answer.
	if kind == PlatformKind.SPIKE and _last_spawn_kind == PlatformKind.SPIKE:
		kind = PlatformKind.NORMAL
	return kind


func _next_gap() -> float:
	var gap: Vector2 = LEVELS[_level]["gap"]
	return randf_range(gap.x, gap.y) * _scale


func _scroll_speed() -> float:
	var ramp := minf(MAX_SPEEDUP, 1.0 + _elapsed / 95.0)
	return float(LEVELS[_level]["scroll"]) * _scale * ramp


func _platform_by_id(id: int) -> Dictionary:
	if id < 0:
		return {}
	for platform in _platforms:
		if int(platform["id"]) == id:
			return platform
	return {}


func _over_platform(platform: Dictionary) -> bool:
	var pet_reach := _pet.half_width() * 0.72
	if int(platform["kind"]) == PlatformKind.SPRING:
		# A spring fires from its top plate, not from the pet's full body width.
		# The smaller foot allowance keeps the visible plate and actual trigger
		# in agreement at both edges.
		pet_reach = minf(8.0 * _scale, _pet.half_width() * 0.34)
	var reach := float(platform["width"]) * 0.5 + pet_reach
	return absf(_player_x - float(platform["x"])) <= reach


func _safe_respawn_platform() -> Dictionary:
	var wanted := size.y * 0.34
	var best := {}
	var best_distance := INF
	for platform in _platforms:
		if int(platform["kind"]) == PlatformKind.SPIKE \
				or bool(platform["triggered"]):
			continue
		var y := float(platform["y"])
		if y < CEILING_DEPTH * _scale + _pet.height() + 20.0 * _scale \
				or y > size.y * 0.72:
			continue
		var distance := absf(y - wanted)
		if distance < best_distance:
			best = platform
			best_distance = distance
	return best


# --- Damage and pose ----------------------------------------------------------

func _take_damage(respawn: bool) -> void:
	if _invincible_left > 0.0 or not is_playing():
		return
	_invincible_left = INVINCIBLE_TIME
	_reaction_bad = true
	_reaction_left = REACTION_TIME
	_squash = -0.13
	_lose_one()
	if not is_playing():
		return
	if respawn:
		_active = false
		_respawn_left = RESPAWN_DELAY
		_standing_id = -1
		_pet.visible = false


func _pose(delta: float) -> void:
	if _reaction_left > 0.0 and _reaction_bad:
		_pet.set_state(&"sad")
	elif is_playing() and _active and absf(_player_vx) > 5.0 * _scale:
		_pet.set_state(&"walk")
	else:
		_pet.set_state(&"idle")
	var target := -0.07 if _active and _standing_id < 0 else 0.0
	_squash = lerpf(_squash, target, clampf(delta * 11.0, 0.0, 1.0))
	_pet.set_squash(_squash)


# --- Input --------------------------------------------------------------------

func _pointer_moved(pos: Vector2) -> void:
	_using_mouse = true
	_mouse_x = pos.x


func _pointer_clicked(pos: Vector2) -> void:
	_using_mouse = true
	_mouse_x = pos.x


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	_draw_depth_lines()
	_draw_ceiling()
	_draw_health()
	for platform in _platforms:
		_draw_platform(platform)


func _draw_depth_lines() -> void:
	var spacing := 72.0 * _scale
	var offset := fmod(_scroll_distance * 0.35, spacing)
	var y := -offset
	while y < size.y:
		draw_line(Vector2(12.0 * _scale, y), Vector2(22.0 * _scale, y),
			PetStyle.GAME_LIFE_SPENT, maxf(1.0, 2.0 * _scale))
		draw_line(Vector2(size.x - 22.0 * _scale, y),
			Vector2(size.x - 12.0 * _scale, y),
			PetStyle.GAME_LIFE_SPENT, maxf(1.0, 2.0 * _scale))
		y += spacing


func _draw_ceiling() -> void:
	var depth := CEILING_DEPTH * _scale
	draw_rect(Rect2(0.0, 0.0, size.x, 7.0 * _scale),
		Color(PetStyle.GAME_DESCENT_DANGER, 0.66))
	var spike_width := 20.0 * _scale
	var x := 0.0
	while x < size.x:
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, 7.0 * _scale),
			Vector2(x + spike_width, 7.0 * _scale),
			Vector2(x + spike_width * 0.5, depth),
		]), Color(PetStyle.GAME_DESCENT_DANGER, 0.78))
		x += spike_width


func _draw_health() -> void:
	var r := 4.0 * _scale
	var origin := Vector2(15.0 * _scale + r, (CEILING_DEPTH + 14.0) * _scale)
	for i in MISSES_ALLOWED:
		draw_circle(origin + Vector2(float(i) * r * 3.2, 0.0), r,
			PetStyle.GAME_LIFE_SPENT if i < _misses else PetStyle.GAME_LIFE)


func _draw_platform(platform: Dictionary) -> void:
	var x := float(platform["x"])
	var y := float(platform["y"])
	var width := float(platform["width"])
	var kind := int(platform["kind"])
	if kind == PlatformKind.SPRING:
		_draw_spring(platform)
		return
	var left := x - width * 0.5
	var color := PetStyle.GAME_DESCENT_PLATFORM
	match kind:
		PlatformKind.MOVING:
			color = PetStyle.GAME_DESCENT_MOVING
		PlatformKind.CRUMBLE:
			color = PetStyle.GAME_DESCENT_BREAK
		PlatformKind.SPIKE:
			color = PetStyle.GAME_DESCENT_DANGER
	draw_rect(Rect2(left, y, width, PLATFORM_HEIGHT * _scale), Color(color, 0.78))
	draw_line(Vector2(left, y), Vector2(left + width, y),
		color, maxf(2.0, 3.0 * _scale))

	if kind == PlatformKind.SPIKE:
		var spike := 12.0 * _scale
		var sx := left
		while sx + spike <= left + width:
			draw_colored_polygon(PackedVector2Array([
				Vector2(sx, y),
				Vector2(sx + spike, y),
				Vector2(sx + spike * 0.5, y - 11.0 * _scale),
			]), color)
			sx += spike
	elif kind == PlatformKind.MOVING:
		draw_colored_polygon(PackedVector2Array([
			Vector2(left + 9.0 * _scale, y + 4.0 * _scale),
			Vector2(left + 17.0 * _scale, y - 2.0 * _scale),
			Vector2(left + 17.0 * _scale, y + 10.0 * _scale),
		]), PetStyle.GAME_FIELD)
		draw_colored_polygon(PackedVector2Array([
			Vector2(left + width - 9.0 * _scale, y + 4.0 * _scale),
			Vector2(left + width - 17.0 * _scale, y - 2.0 * _scale),
			Vector2(left + width - 17.0 * _scale, y + 10.0 * _scale),
		]), PetStyle.GAME_FIELD)
	elif kind == PlatformKind.CRUMBLE:
		for i in 1 if bool(platform["triggered"]) else 3:
			var crack_x := left + width * float(i + 1) / 4.0
			draw_line(Vector2(crack_x - 5.0 * _scale, y),
				Vector2(crack_x + 3.0 * _scale, y + PLATFORM_HEIGHT * _scale),
				PetStyle.GAME_FIELD, maxf(1.0, _scale))


func _draw_spring(platform: Dictionary) -> void:
	var x := float(platform["x"])
	var y := float(platform["y"])
	var width := float(platform["width"])
	var anim_left := float(platform["spring_anim"])
	var contact := clampf(anim_left / SPRING_ANIM_TIME, 0.0, 1.0)
	var armed := _spring_is_armed(platform)
	var gold := PetStyle.GAME_DESCENT_SPRING
	var dark_gold := gold.darkened(0.38)

	# Fixed collision surface: the pet lands exactly on the bright top plate.
	# A wide translucent under-stroke appears while falling into its real trigger
	# range, so the judgement is visible before contact rather than explained
	# after a surprising bounce.
	var left := x - width * 0.5
	var right := x + width * 0.5
	if armed:
		draw_line(Vector2(left - 5.0 * _scale, y),
			Vector2(right + 5.0 * _scale, y),
			Color(gold, 0.28), maxf(5.0, 8.0 * _scale), true)
		draw_line(Vector2(left, y - 7.0 * _scale),
			Vector2(left, y + 8.0 * _scale),
			Color(gold, 0.62), maxf(1.0, 2.0 * _scale))
		draw_line(Vector2(right, y - 7.0 * _scale),
			Vector2(right, y + 8.0 * _scale),
			Color(gold, 0.62), maxf(1.0, 2.0 * _scale))

	draw_rect(Rect2(left, y, width, 6.0 * _scale), dark_gold)
	draw_line(Vector2(left, y), Vector2(right, y),
		gold.lightened(0.18), maxf(2.0, 3.0 * _scale), true)
	draw_line(Vector2(left + 7.0 * _scale, y + 4.0 * _scale),
		Vector2(right - 7.0 * _scale, y + 4.0 * _scale),
		Color(PetStyle.GAME_VOLLEY_BALL, 0.52), maxf(1.0, _scale))

	# One vertical metal coil between a top plate and a broad fixed foot. On
	# contact the coil is visibly compressed, then opens over a third of a
	# second while the pet travels upward.
	var compression := contact * 10.0 * _scale
	var coil_top := y + 7.0 * _scale
	var coil_bottom := y + SPRING_COIL_HEIGHT * _scale - compression
	var coil_half := minf(width * 0.16, 15.0 * _scale)
	var coil := PackedVector2Array()
	var coil_steps := 6
	for i in coil_steps + 1:
		var t := float(i) / float(coil_steps)
		var px := x
		if i > 0 and i < coil_steps:
			px += coil_half * (-1.0 if i % 2 == 0 else 1.0)
		coil.append(Vector2(px, lerpf(coil_top, coil_bottom, t)))
	draw_polyline(coil, gold, maxf(1.5, 2.4 * _scale), true)

	var base_y := y + (SPRING_COIL_HEIGHT + 2.0) * _scale
	var base_half := width * 0.34
	draw_rect(Rect2(x - base_half, base_y, base_half * 2.0, 5.0 * _scale),
		dark_gold)
	draw_line(Vector2(x - base_half, base_y), Vector2(x + base_half, base_y),
		gold, maxf(1.0, 2.0 * _scale))

	if anim_left > 0.0:
		var progress := 1.0 - contact
		var burst_radius := width * 0.34 + progress * 18.0 * _scale
		draw_arc(Vector2(x, y - 2.0 * _scale), burst_radius,
			PI, TAU, 22, Color(gold, contact * 0.72),
			maxf(1.0, 2.0 * _scale), true)
		for side in [-1.0, 1.0]:
			draw_line(
				Vector2(x + side * width * 0.28, y - 5.0 * _scale),
				Vector2(x + side * (width * 0.40 + progress * 8.0 * _scale),
					y - (13.0 + progress * 9.0) * _scale),
				Color(gold, contact * 0.62), maxf(1.0, 1.6 * _scale))


func _spring_is_armed(platform: Dictionary) -> bool:
	if not is_playing() or not _active or _player_vy <= 0.0:
		return false
	var y := float(platform["y"])
	var distance := y - _player_feet
	return distance >= 0.0 and distance <= SPRING_ARM_DISTANCE * _scale \
		and _over_platform(platform)
