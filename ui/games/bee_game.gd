extends MiniGame
class_name BeeGame

## 小蜜蜂 — a compact fixed shooter with a marching, diving formation.
##
## The pet is the player's ship. Bees sway across the top, drop closer whenever
## the formation reaches an edge, peel away into smooth dives, and return fire.
## Clearing a formation starts a faster wave, so the shared high-score model
## remains meaningful instead of every win ending on the same number.

const LEVELS: Array[Dictionary] = [
	{
		"rows": 4, "columns": 7, "march": 48.0, "fire": 1.65,
		"dive": 3.10, "enemy_shot": 180.0, "max_divers": 1,
	},
	{
		"rows": 5, "columns": 8, "march": 62.0, "fire": 1.14,
		"dive": 2.35, "enemy_shot": 225.0, "max_divers": 2,
	},
	{
		"rows": 5, "columns": 9, "march": 78.0, "fire": 0.82,
		"dive": 1.72, "enemy_shot": 275.0, "max_divers": 3,
	},
]

const PLAYER_SPEED := 420.0
const POINTER_RATE := 14.0
const PLAYER_SHOT_SPEED := 660.0
const PLAYER_SHOT_RADIUS := 4.0
const ENEMY_SHOT_RADIUS := 5.0
const ENEMY_RADIUS := 15.0
const FORMATION_SPACING_X := 48.0
const FORMATION_SPACING_Y := 40.0
const FORMATION_TOP := 72.0
const FORMATION_DROP := 10.0
const FIELD_MARGIN := 24.0
const FIRE_COOLDOWN := 0.20
const MAX_PLAYER_SHOTS := 4
const DIVE_DURATION := 2.25
const DIVE_DEPTH_MARGIN := 54.0
const DIVE_SWERVE := 64.0
const NEXT_WAVE_DELAY := 0.88
const RESPAWN_GRACE := 1.25
const REACTION_TIME := 0.40
const CHIP_LIFE := 0.38
const CHIP_SPEED := 92.0
const MAX_WAVE_SPEEDUP := 1.85

var _enemies: Array[Dictionary] = []
var _player_shots: Array[Vector2] = []
var _enemy_shots: Array[Dictionary] = []
var _chips: Array[Dictionary] = []
var _player_x := 0.0
var _mouse_x := 0.0
var _using_mouse := false
var _needs_layout := true
var _formation_x := 0.0
var _formation_y := 0.0
var _formation_direction := 1.0
var _fire_left := 0.0
var _enemy_fire_left := 0.0
var _dive_left := 0.0
var _invincible_left := 0.0
var _next_wave_left := 0.0
var _reaction_left := 0.0
var _reaction_good := true
var _wave := 0


func design_size() -> Vector2i:
	return Vector2i(580, 640)


func ready_hint() -> String:
	return "← → ／ A D 或滑鼠移動\n空白鍵／點一下發射光點\n躲開俯衝與花粉彈，失手三次就結束"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["巡航", "蜂群", "暴走"])


func pet_design_height() -> float:
	return 68.0


func _prepare() -> void:
	_enemies.clear()
	_player_shots.clear()
	_enemy_shots.clear()
	_chips.clear()
	_needs_layout = true
	_formation_direction = 1.0
	_fire_left = 0.0
	_enemy_fire_left = 0.8
	_dive_left = 1.4
	_invincible_left = 0.0
	_next_wave_left = 0.0
	_reaction_left = 0.0
	_reaction_good = true
	_wave = 0
	if _pet != null:
		_pet.visible = true
		_pet.set_state(&"idle")
		_pet.set_squash(0.0)


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	if _needs_layout and size.x > 0.0 and size.y > 0.0:
		_player_x = size.x * 0.5
		_mouse_x = _player_x
		_build_wave()
		_needs_layout = false

	_step_player(delta)
	_step_chips(delta)
	if is_playing():
		_fire_left = maxf(0.0, _fire_left - delta)
		_invincible_left = maxf(0.0, _invincible_left - delta)
		if _next_wave_left > 0.0:
			_next_wave_left -= delta
			if _next_wave_left <= 0.0:
				_wave += 1
				_build_wave()
		else:
			_step_formation(delta)
			_step_divers(delta)
			_step_enemy_actions(delta)
		_step_player_shots(delta)
		_step_enemy_shots(delta)
		_check_invasion()
	_pose(delta)
	_pet.stand_on(_ground_y(), _player_x)


func _step_player(delta: float) -> void:
	var before := _player_x
	var axis := _held_axis()
	if not is_zero_approx(axis):
		_using_mouse = false
	if _using_mouse:
		_player_x = lerpf(_player_x, _mouse_x,
			clampf(delta * POINTER_RATE, 0.0, 1.0))
	else:
		_player_x += axis * PLAYER_SPEED * _scale * delta
	var half := _pet.half_width()
	_player_x = clampf(_player_x, FIELD_MARGIN * _scale + half,
		size.x - FIELD_MARGIN * _scale - half)
	if absf(_player_x - before) > 0.3 * _scale:
		_pet.set_facing(1 if _player_x > before else -1)


func _step_formation(delta: float) -> void:
	var travel := _march_speed() * _formation_direction * delta
	_formation_x += travel
	var half_width := _formation_half_width()
	var margin := FIELD_MARGIN * _scale
	if _formation_x - half_width < margin:
		_formation_x = margin + half_width
		_formation_direction = 1.0
		_formation_y += FORMATION_DROP * _scale
	elif _formation_x + half_width > size.x - margin:
		_formation_x = size.x - margin - half_width
		_formation_direction = -1.0
		_formation_y += FORMATION_DROP * _scale

	for enemy in _enemies:
		if not bool(enemy["diving"]):
			enemy["previous_position"] = Vector2(enemy["position"])
			enemy["position"] = _formation_position(
				int(enemy["row"]), int(enemy["column"]))


func _step_divers(delta: float) -> void:
	for enemy in _enemies:
		if not bool(enemy["diving"]):
			continue
		enemy["previous_position"] = Vector2(enemy["position"])
		var progress := float(enemy["dive_progress"]) + delta / DIVE_DURATION
		enemy["dive_progress"] = progress
		var home := _formation_position(int(enemy["row"]), int(enemy["column"]))
		if progress >= 1.0:
			enemy["diving"] = false
			enemy["position"] = home
			continue
		enemy["position"] = dive_position(
			Vector2(enemy["dive_start"]), home, float(enemy["dive_target_x"]),
			progress, _ground_y() - DIVE_DEPTH_MARGIN * _scale,
			DIVE_SWERVE * _scale * float(enemy["dive_side"]))


func _step_enemy_actions(delta: float) -> void:
	_enemy_fire_left -= delta
	if _enemy_fire_left <= 0.0 and not _enemies.is_empty():
		_enemy_fire_left = float(LEVELS[_level]["fire"]) \
			/ minf(MAX_WAVE_SPEEDUP, 1.0 + float(_wave) * 0.08)
		_enemy_fire()

	_dive_left -= delta
	if _dive_left <= 0.0:
		_dive_left = float(LEVELS[_level]["dive"]) \
			/ minf(MAX_WAVE_SPEEDUP, 1.0 + float(_wave) * 0.07)
		_start_dive()


func _step_player_shots(delta: float) -> void:
	for i in range(_player_shots.size() - 1, -1, -1):
		var previous := _player_shots[i]
		var shot := previous
		shot.y -= PLAYER_SHOT_SPEED * _scale * delta
		_player_shots[i] = shot
		if shot.y < -12.0 * _scale:
			_player_shots.remove_at(i)
			continue
		var enemy_index := _enemy_crossed_by(
			previous, shot, PLAYER_SHOT_RADIUS * _scale)
		if enemy_index >= 0:
			_player_shots.remove_at(i)
			_destroy_enemy(enemy_index)


func _step_enemy_shots(delta: float) -> void:
	var pet_rect := _pet.collision_rect(_player_x, _ground_y())
	for i in range(_enemy_shots.size() - 1, -1, -1):
		var shot: Dictionary = _enemy_shots[i]
		shot["position"] = Vector2(shot["position"]) \
			+ Vector2(shot["velocity"]) * delta
		var position: Vector2 = shot["position"]
		if position.y > size.y + 12.0 * _scale \
				or position.x < -12.0 * _scale or position.x > size.x + 12.0 * _scale:
			_enemy_shots.remove_at(i)
		elif _invincible_left <= 0.0 and GamePet.circle_hits_rect(
				position, ENEMY_SHOT_RADIUS * _scale, pet_rect):
			_enemy_shots.remove_at(i)
			_damage_player()
			# _damage_player() clears the whole volley. Continuing the backwards
			# loop would address indices that no longer exist.
			return


func _step_chips(delta: float) -> void:
	for i in range(_chips.size() - 1, -1, -1):
		var chip: Dictionary = _chips[i]
		chip["life"] = float(chip["life"]) - delta
		if float(chip["life"]) <= 0.0:
			_chips.remove_at(i)
			continue
		chip["position"] = Vector2(chip["position"]) \
			+ Vector2(chip["velocity"]) * delta


# --- Formation and combat -----------------------------------------------------

func _build_wave() -> void:
	_enemies.clear()
	_player_shots.clear()
	_enemy_shots.clear()
	_formation_x = size.x * 0.5
	_formation_y = FORMATION_TOP * _scale
	_formation_direction = 1.0 if _wave % 2 == 0 else -1.0
	var rows := int(LEVELS[_level]["rows"])
	var columns := int(LEVELS[_level]["columns"])
	for row in rows:
		for column in columns:
			var position := _formation_position(row, column)
			_enemies.append({
				"row": row,
				"column": column,
				"position": position,
				"previous_position": position,
				"diving": false,
				"dive_progress": 0.0,
				"dive_start": Vector2.ZERO,
				"dive_target_x": 0.0,
				"dive_side": 1.0,
			})
	_enemy_fire_left = 0.72
	_dive_left = 1.25


func _formation_position(row: int, column: int) -> Vector2:
	var columns := int(LEVELS[_level]["columns"])
	var x := _formation_x \
		+ (float(column) - float(columns - 1) * 0.5) * FORMATION_SPACING_X * _scale
	var y := _formation_y + float(row) * FORMATION_SPACING_Y * _scale
	return Vector2(x, y)


func _formation_half_width() -> float:
	var columns := int(LEVELS[_level]["columns"])
	return (float(columns - 1) * FORMATION_SPACING_X * 0.5 + ENEMY_RADIUS) * _scale


func _march_speed() -> float:
	var wave_factor := minf(MAX_WAVE_SPEEDUP, 1.0 + float(_wave) * 0.09)
	# A thinning formation becomes less predictable and more urgent, as in the
	# arcade original, but caps before tracking it becomes unfair.
	var total := int(LEVELS[_level]["rows"]) * int(LEVELS[_level]["columns"])
	var thin_factor := minf(1.55, 1.0 + float(total - _enemies.size()) / float(total))
	return float(LEVELS[_level]["march"]) * wave_factor * thin_factor * _scale


func _start_dive() -> void:
	var active := 0
	var available: Array[int] = []
	for i in _enemies.size():
		if bool(_enemies[i]["diving"]):
			active += 1
		else:
			available.append(i)
	if active >= int(LEVELS[_level]["max_divers"]) or available.is_empty():
		return
	var index: int = available.pick_random()
	var enemy: Dictionary = _enemies[index]
	enemy["diving"] = true
	enemy["dive_progress"] = 0.0
	enemy["dive_start"] = Vector2(enemy["position"])
	enemy["dive_target_x"] = clampf(
		_player_x + randf_range(-52.0, 52.0) * _scale,
		FIELD_MARGIN * _scale, size.x - FIELD_MARGIN * _scale)
	enemy["dive_side"] = -1.0 if randf() < 0.5 else 1.0


func _enemy_fire() -> void:
	var candidates: Array[int] = []
	for i in _enemies.size():
		var position: Vector2 = _enemies[i]["position"]
		if position.y > 0.0 and position.y < _ground_y() - 60.0 * _scale:
			candidates.append(i)
	if candidates.is_empty():
		return
	var enemy: Dictionary = _enemies[candidates.pick_random()]
	var origin: Vector2 = enemy["position"]
	var target := Vector2(_player_x, _ground_y() - _pet.height() * 0.45)
	var direction := origin.direction_to(target)
	var speed := float(LEVELS[_level]["enemy_shot"]) * _scale \
		* minf(1.45, 1.0 + float(_wave) * 0.055)
	_enemy_shots.append({"position": origin, "velocity": direction * speed})


func _shoot() -> void:
	if not is_playing() or _fire_left > 0.0 \
			or _player_shots.size() >= MAX_PLAYER_SHOTS:
		return
	_fire_left = FIRE_COOLDOWN
	_player_shots.append(Vector2(
		_player_x, _ground_y() - _pet.height() - 5.0 * _scale))
	_reaction_good = true
	_reaction_left = REACTION_TIME * 0.52


func _enemy_crossed_by(start: Vector2, finish: Vector2, shot_radius: float) -> int:
	for i in _enemies.size():
		var enemy: Dictionary = _enemies[i]
		var enemy_finish: Vector2 = enemy["position"]
		var enemy_start: Vector2 = enemy.get("previous_position", enemy_finish)
		if moving_circles_overlap(start, finish, shot_radius,
				enemy_start, enemy_finish, ENEMY_RADIUS * _scale):
			return i
	return -1


func _destroy_enemy(index: int) -> void:
	if index < 0 or index >= _enemies.size():
		return
	var enemy: Dictionary = _enemies[index]
	var row := int(enemy["row"])
	_spawn_chips(Vector2(enemy["position"]), row)
	_enemies.remove_at(index)
	_add_score(20 if row == 0 else (15 if row == 1 else 10))
	_reaction_good = true
	_reaction_left = REACTION_TIME
	if _enemies.is_empty():
		_next_wave_left = NEXT_WAVE_DELAY


func _damage_player() -> void:
	if _invincible_left > 0.0 or not is_playing():
		return
	_reaction_good = false
	_reaction_left = REACTION_TIME * 1.5
	_pet.set_state(&"sad")
	_pet.set_squash(-0.12)
	_enemy_shots.clear()
	_invincible_left = RESPAWN_GRACE
	_lose_one()


func _check_invasion() -> void:
	if _invincible_left > 0.0 or _enemies.is_empty():
		return
	var pet_rect := _pet.collision_rect(_player_x, _ground_y())
	var invasion_line := _ground_y() - _pet.height()
	for enemy in _enemies:
		var position: Vector2 = enemy["position"]
		var formation_landed := not bool(enemy["diving"]) \
			and position.y + ENEMY_RADIUS * _scale >= invasion_line
		if formation_landed or GamePet.circle_hits_rect(
				position, ENEMY_RADIUS * _scale, pet_rect):
			_damage_player()
			if is_playing():
				_build_wave()
			return


func _spawn_chips(origin: Vector2, row: int) -> void:
	var color := PetStyle.GAME_BEE_ELITE if row == 0 else PetStyle.GAME_BEE_GOLD
	for i in 7:
		var angle := TAU * float(i) / 7.0 + randf_range(-0.18, 0.18)
		_chips.append({
			"position": origin,
			"velocity": Vector2.from_angle(angle) * CHIP_SPEED * _scale,
			"life": CHIP_LIFE,
			"color": color,
		})


static func circles_overlap(a: Vector2, a_radius: float,
		b: Vector2, b_radius: float) -> bool:
	var reach := a_radius + b_radius
	return a.distance_squared_to(b) <= reach * reach


## Continuous collision for two objects moving during the same frame. In the
## diving case their relative speed is roughly the sum of both speeds, so their
## end positions can be separate even though the projectile passed through the
## bee between samples.
static func moving_circles_overlap(a_start: Vector2, a_finish: Vector2,
		a_radius: float, b_start: Vector2, b_finish: Vector2,
		b_radius: float) -> bool:
	var relative_start := a_start - b_start
	var relative_finish := a_finish - b_finish
	var travel := relative_finish - relative_start
	var travel_squared := travel.length_squared()
	var closest_time := 0.0
	if travel_squared > 0.000001:
		closest_time = clampf(-relative_start.dot(travel) / travel_squared, 0.0, 1.0)
	var closest := relative_start + travel * closest_time
	var reach := a_radius + b_radius
	return closest.length_squared() <= reach * reach


## A loop that leaves and rejoins the moving formation without teleporting.
## The sine depth aims at the player halfway through; the second sine adds the
## sideways hook that makes a diving bee readable instead of just falling.
static func dive_position(start: Vector2, home: Vector2, target_x: float,
		progress: float, deepest_y: float, swerve: float) -> Vector2:
	var t := clampf(progress, 0.0, 1.0)
	var arc := sin(PI * t)
	var base := start.lerp(home, t)
	var x := lerpf(base.x, target_x, arc) + sin(TAU * t) * swerve
	var y := lerpf(base.y, deepest_y, arc)
	return Vector2(x, y)


# --- Input and pose -----------------------------------------------------------

func _key_pressed(keycode: int) -> bool:
	match keycode:
		KEY_LEFT, KEY_RIGHT, KEY_A, KEY_D:
			pass # Movement is polled; consuming the event prevents focus navigation.
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_shoot()
		_:
			return false
	return true


func _pointer_moved(pos: Vector2) -> void:
	_using_mouse = true
	_mouse_x = clampf(pos.x, 0.0, size.x)


func _pointer_clicked(pos: Vector2) -> void:
	_pointer_moved(pos)
	_shoot()


func _pose(delta: float) -> void:
	if _invincible_left > 0.0:
		_pet.visible = fmod(_invincible_left, 0.16) > 0.07
	else:
		_pet.visible = true
	if _reaction_left > 0.0:
		_reaction_left = maxf(0.0, _reaction_left - delta)
		_pet.set_state(&"happy" if _reaction_good else &"sad")
		_pet.set_squash((0.10 if _reaction_good else -0.10)
			* _reaction_left / REACTION_TIME)
	elif absf(_held_axis()) > 0.0:
		_pet.set_state(&"walk")
		_pet.set_squash(0.0)
	else:
		_pet.set_state(&"idle")
		_pet.set_squash(0.0)


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	_draw_stars()
	for enemy in _enemies:
		_draw_bee(Vector2(enemy["position"]), int(enemy["row"]),
			bool(enemy["diving"]))
	for shot in _player_shots:
		draw_line(shot + Vector2(0.0, 7.0 * _scale),
			shot - Vector2(0.0, 7.0 * _scale),
			PetStyle.GAME_BEE_PLAYER_SHOT, maxf(2.0, 3.0 * _scale), true)
	for shot in _enemy_shots:
		var position: Vector2 = shot["position"]
		draw_circle(position, ENEMY_SHOT_RADIUS * _scale,
			PetStyle.GAME_BEE_ENEMY_SHOT)
		draw_circle(position, ENEMY_SHOT_RADIUS * 0.36 * _scale,
			PetStyle.GAME_BEE_WING)
	for chip in _chips:
		var alpha := clampf(float(chip["life"]) / CHIP_LIFE, 0.0, 1.0)
		draw_circle(Vector2(chip["position"]), 3.0 * _scale,
			Color(Color(chip["color"]), alpha))
	_draw_ground()
	_draw_wave()


func _draw_stars() -> void:
	for i in 34:
		var x := fmod(float(i * 97 + 31), 541.0) / 541.0 * size.x
		var y := fmod(float(i * 53 + 17), 389.0) / 389.0 \
			* (_ground_y() - 18.0 * _scale)
		var alpha := 0.10 + float(i % 3) * 0.045
		draw_circle(Vector2(x, y), (1.0 + float(i % 2)) * _scale,
			Color(PetStyle.GAME_BEE_WING, alpha))


func _draw_bee(position: Vector2, row: int, diving: bool) -> void:
	var s := _scale * (1.08 if row == 0 else 1.0)
	var wing_offset := 10.5 * s
	var wing_y := -2.0 * s if diving else 0.0
	draw_circle(position + Vector2(-wing_offset, wing_y), 7.0 * s,
		PetStyle.GAME_BEE_WING)
	draw_circle(position + Vector2(wing_offset, wing_y), 7.0 * s,
		PetStyle.GAME_BEE_WING)
	var body_color := PetStyle.GAME_BEE_ELITE if row == 0 \
		else PetStyle.GAME_BEE_GOLD
	draw_circle(position, 10.0 * s, body_color)
	draw_line(position + Vector2(-8.0, -1.5) * s,
		position + Vector2(8.0, -1.5) * s,
		PetStyle.GAME_BEE_INK, maxf(1.0, 3.0 * s), true)
	draw_line(position + Vector2(-6.0, 4.5) * s,
		position + Vector2(6.0, 4.5) * s,
		PetStyle.GAME_BEE_INK, maxf(1.0, 2.5 * s), true)
	draw_circle(position + Vector2(-3.4, -5.0) * s, 1.6 * s,
		PetStyle.GAME_BEE_INK)
	draw_circle(position + Vector2(3.4, -5.0) * s, 1.6 * s,
		PetStyle.GAME_BEE_INK)
	draw_line(position + Vector2(-4.0, -8.0) * s,
		position + Vector2(-7.5, -14.0) * s,
		body_color, maxf(1.0, 1.5 * s), true)
	draw_line(position + Vector2(4.0, -8.0) * s,
		position + Vector2(7.5, -14.0) * s,
		body_color, maxf(1.0, 1.5 * s), true)


func _draw_wave() -> void:
	var font := ThemeDB.fallback_font
	var font_size := maxi(9, roundi(12.0 * _scale))
	var text := "第 %d 波" % (_wave + 1)
	var width := font.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font,
		Vector2(size.x - FIELD_MARGIN * _scale - width, 24.0 * _scale),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, PetStyle.NIGHT_MUTED)
