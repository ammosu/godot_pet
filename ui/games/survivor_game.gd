extends MiniGame
class_name SurvivorGame

## 怪潮倖存 — a compact auto-attacking survival game.
##
## Movement is the player's only continuous action. The pet automatically fires
## at the closest monster; defeated monsters leave experience sparks, and every
## level pauses the field for one of three upgrades. Survive the full clock or
## lose all three hearts. The fixed ending keeps a run suitable for a desktop
## mini-game while kills and survival time still make the high score meaningful.

const LEVELS: Array[Dictionary] = [
	{"spawn": 0.82, "speed": 54.0, "health": 0.85, "damage_grace": 1.20},
	{"spawn": 0.62, "speed": 68.0, "health": 1.00, "damage_grace": 1.00},
	{"spawn": 0.44, "speed": 84.0, "health": 1.20, "damage_grace": 0.82},
]

const RUN_DURATION := 75.0
const HUD_HEIGHT := 46.0
const PLAYER_SPEED := 215.0
const SHOT_SPEED := 470.0
const BASE_FIRE_INTERVAL := 0.72
const BASE_DAMAGE := 1.0
const BASE_COLLECTION_RADIUS := 58.0
## Contact damage deliberately uses a compact body circle rather than the pet
## animation's full silhouette. Ears, tails and transparent corners must not
## make a visually open lane unsafe.
const PLAYER_COLLISION_RADIUS := 10.0
const MAX_ENEMIES := 90
const MAX_PICKUPS := 70
const UPGRADE_CARD_HEIGHT := 126.0
const REACTION_TIME := 0.34
const ENEMY_CELL_SIZE := 16.0
const AURA_BASE_DAMAGE := 0.42
const AURA_BASE_RADIUS := 76.0
const AURA_BASE_INTERVAL := 1.65
const AURA_PULSE_TIME := 0.42
const MAX_AURA_LEVEL := 5

## CC0 sprites from Pixel-Boy and AAA's Ninja Adventure asset pack. Keep the
## player as the installed desktop pet; these three sheets only replace the
## procedural circles that used to stand in for the approaching monsters.
const ENEMY_PIG: Texture2D = preload(
	"res://assets/third_party/ninja_adventure/pig.png")
const ENEMY_SAMURAI: Texture2D = preload(
	"res://assets/third_party/ninja_adventure/samurai_green.png")
const ENEMY_NINJA: Texture2D = preload(
	"res://assets/third_party/ninja_adventure/ninja_blue.png")

const UPGRADES: Array[Dictionary] = [
	{"id": &"power", "title": "光點增幅", "description": "每發傷害 +1"},
	{"id": &"cadence", "title": "快速詠唱", "description": "自動攻擊更快"},
	{"id": &"multishot", "title": "分裂光點", "description": "每次多發射 1 枚"},
	{"id": &"speed", "title": "輕盈腳步", "description": "移動速度 +15%"},
	{"id": &"magnet", "title": "拾光磁場", "description": "吸取範圍 +24"},
	{"id": &"pierce", "title": "穿透星芒", "description": "光點多穿透 1 隻"},
	{"id": &"aura_unlock", "title": "月輪靈氣", "description": "解鎖低傷害範圍波動"},
	{"id": &"aura_power", "title": "靈氣共鳴", "description": "範圍 +10，傷害 +0.2"},
	{"id": &"vitality", "title": "暖心飯糰", "description": "回復 1 顆愛心"},
]

var _enemies: Array[Dictionary] = []
var _projectiles: Array[Dictionary] = []
var _pickups: Array[Dictionary] = []
var _player_position := Vector2.ZERO
var _pointer_target := Vector2.ZERO
var _pointer_position := Vector2.ZERO
var _using_pointer := false
var _needs_layout := true
var _time_left := RUN_DURATION
var _spawn_left := 0.0
var _attack_left := 0.0
var _survival_score_left := 1.0
var _invincible_left := 0.0
var _reaction_left := 0.0
var _enemy_serial := 0
var _spawned_count := 0
var _experience := 0
var _experience_needed := 8
var _survivor_level := 1
var _choosing_upgrade := false
var _upgrade_choices: Array[Dictionary] = []
var _damage := BASE_DAMAGE
var _fire_interval := BASE_FIRE_INTERVAL
var _shot_count := 1
var _move_speed := PLAYER_SPEED
var _collection_radius := BASE_COLLECTION_RADIUS
var _pierce := 0
var _animation_time := 0.0
var _aura_level := 0
var _aura_left := 0.0
var _aura_pulse_left := 0.0


func design_size() -> Vector2i:
	return Vector2i(660, 660)


func ready_hint() -> String:
	return "方向鍵 ／ W A S D 或點擊移動，角色保持置中\n攻擊會自動瞄準，收集青色光點升級\n每次升級按 1／2／3 選能力，撐過 75 秒"


func level_labels() -> PackedStringArray:
	return PackedStringArray(["薄霧", "怪潮", "惡夢"])


func pet_design_height() -> float:
	return 62.0


func _prepare() -> void:
	_enemies.clear()
	_projectiles.clear()
	_pickups.clear()
	_upgrade_choices.clear()
	_needs_layout = true
	_time_left = RUN_DURATION
	_spawn_left = 0.28
	_attack_left = 0.32
	_survival_score_left = 1.0
	_invincible_left = 0.0
	_reaction_left = 0.0
	_enemy_serial = 0
	_spawned_count = 0
	_experience = 0
	_experience_needed = experience_needed_for(1)
	_survivor_level = 1
	_choosing_upgrade = false
	_damage = BASE_DAMAGE
	_fire_interval = BASE_FIRE_INTERVAL
	_shot_count = 1
	_move_speed = PLAYER_SPEED
	_collection_radius = BASE_COLLECTION_RADIUS
	_pierce = 0
	_animation_time = 0.0
	_aura_level = 0
	_aura_left = 0.0
	_aura_pulse_left = 0.0
	_using_pointer = false
	if _pet != null:
		_pet.visible = true
		_pet.set_state(&"idle")
		_pet.set_squash(0.0)


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	if _needs_layout and size.x > 0.0 and size.y > 0.0:
		# Gameplay positions live in an unbounded world. The player's world position
		# starts at the origin but is always projected to the viewport centre.
		_player_position = Vector2.ZERO
		_pointer_target = _player_position
		_pointer_position = _screen_centre()
		_needs_layout = false

	if _needs_layout:
		return
	if not is_playing():
		_place_pet(Vector2.ZERO)
		return

	if _choosing_upgrade:
		_place_pet(Vector2.ZERO)
		return

	_animation_time += delta
	_time_left = maxf(0.0, _time_left - delta)
	_survival_score_left -= delta
	while _survival_score_left <= 0.0:
		_survival_score_left += 1.0
		_add_score(1)
	if _time_left <= 0.0:
		_finish()
		return

	_invincible_left = maxf(0.0, _invincible_left - delta)
	_reaction_left = maxf(0.0, _reaction_left - delta)
	var movement := _step_player(delta)
	_step_spawning(delta)
	_step_enemies(delta)
	if not is_playing():
		_place_pet(movement)
		return
	_step_attack(delta)
	_step_projectiles(delta)
	_step_aura(delta)
	_step_pickups(delta)
	_place_pet(movement)


func _step_player(delta: float) -> Vector2:
	var movement := _movement_axis()
	if movement != Vector2.ZERO:
		_using_pointer = false
	elif _using_pointer:
		var offset := _pointer_target - _player_position
		if offset.length() > 6.0 * _scale:
			movement = offset.normalized()
		else:
			_using_pointer = false

	var travel := movement * _move_speed * _scale * delta
	if _using_pointer and travel.length_squared() \
			>= _player_position.distance_squared_to(_pointer_target):
		_player_position = _pointer_target
		_using_pointer = false
	else:
		_player_position += travel
	return movement


func _movement_axis() -> Vector2:
	var window := get_window()
	if window != null and not window.has_focus():
		return Vector2.ZERO
	var axis := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		axis.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		axis.x += 1.0
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
		axis.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
		axis.y += 1.0
	return axis.normalized() if axis != Vector2.ZERO else Vector2.ZERO


func _step_spawning(delta: float) -> void:
	_spawn_left -= delta
	var progress := 1.0 - _time_left / RUN_DURATION
	var interval := float(LEVELS[_level]["spawn"]) * lerpf(1.0, 0.52, progress)
	while _spawn_left <= 0.0 and _enemies.size() < MAX_ENEMIES:
		_spawn_left += interval
		_spawn_enemy(progress)


func _spawn_enemy(progress: float) -> void:
	var margin := 28.0 * _scale
	var half_view := size * 0.5
	var position := _player_position
	match randi() % 4:
		0:
			position += Vector2(
				randf_range(-half_view.x, half_view.x), -half_view.y - margin)
		1:
			position += Vector2(
				half_view.x + margin, randf_range(-half_view.y, half_view.y))
		2:
			position += Vector2(
				randf_range(-half_view.x, half_view.x), half_view.y + margin)
		_:
			position += Vector2(
				-half_view.x - margin, randf_range(-half_view.y, half_view.y))

	_spawned_count += 1
	_enemy_serial += 1
	var brute := progress > 0.48 and _spawned_count % 13 == 0
	var elite := not brute and progress > 0.18 and _spawned_count % 9 == 0
	var radius := (22.0 if brute else (16.0 if elite else 12.5)) * _scale
	var collision_radius := (14.0 if brute else (10.0 if elite else 8.0)) * _scale
	var health_scale := float(LEVELS[_level]["health"])
	var health := ceilf((4.5 if brute else (2.4 if elite else 1.0))
		* health_scale * lerpf(1.0, 2.1, progress))
	var speed_scale := 0.72 if brute else (1.08 if elite else randf_range(0.88, 1.12))
	_enemies.append({
		"id": _enemy_serial,
		"position": position,
		"radius": radius,
		"collision_radius": collision_radius,
		"health": health,
		"max_health": health,
		"speed": float(LEVELS[_level]["speed"])
			* lerpf(1.0, 1.52, progress) * speed_scale * _scale,
		"kind": 2 if brute else (1 if elite else 0),
		"points": 8 if brute else (4 if elite else 1),
		"experience": 4 if brute else (2 if elite else 1),
	})


func _step_enemies(delta: float) -> void:
	for i in range(_enemies.size() - 1, -1, -1):
		var enemy: Dictionary = _enemies[i]
		var position: Vector2 = enemy["position"]
		var offset := _player_position - position
		if offset != Vector2.ZERO:
			position += offset.normalized() * float(enemy["speed"]) * delta
		enemy["position"] = position
		_enemies[i] = enemy
		if circles_overlap(position, float(enemy["collision_radius"]),
				_player_position, PLAYER_COLLISION_RADIUS * _scale):
			_enemies.remove_at(i)
			_take_hit()
			if not is_playing():
				return


func _step_attack(delta: float) -> void:
	_attack_left -= delta
	if _attack_left > 0.0 or _enemies.is_empty():
		return
	_attack_left += _fire_interval
	var target_index := nearest_point_index(_player_position, _enemy_positions())
	if target_index < 0:
		return
	var target: Vector2 = _enemies[target_index]["position"]
	var base := (_player_position.direction_to(target)
		if target != _player_position else Vector2.UP)
	var spread := deg_to_rad(11.0)
	for i in _shot_count:
		var centred := float(i) - float(_shot_count - 1) * 0.5
		_projectiles.append({
			"position": _player_position,
			"velocity": base.rotated(centred * spread) * SHOT_SPEED * _scale,
			"damage": _damage,
			"pierce_left": _pierce,
			"hits": [] as Array[int],
		})
	_reaction_left = REACTION_TIME


func _enemy_positions() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	for enemy: Dictionary in _enemies:
		positions.append(enemy["position"])
	return positions


func _step_projectiles(delta: float) -> void:
	var radius := 4.5 * _scale
	for i in range(_projectiles.size() - 1, -1, -1):
		var shot: Dictionary = _projectiles[i]
		var start: Vector2 = shot["position"]
		var finish := start + Vector2(shot["velocity"]) * delta
		shot["position"] = finish
		var consumed := false
		for enemy_index in range(_enemies.size() - 1, -1, -1):
			var enemy: Dictionary = _enemies[enemy_index]
			var hits: Array[int] = shot["hits"]
			if hits.has(int(enemy["id"])):
				continue
			if not segment_hits_circle(start, finish,
					Vector2(enemy["position"]), float(enemy["radius"]) + radius):
				continue
			hits.append(int(enemy["id"]))
			shot["hits"] = hits
			enemy["health"] = float(enemy["health"]) - float(shot["damage"])
			if float(enemy["health"]) <= 0.0:
				_defeat_enemy(enemy_index)
			else:
				_enemies[enemy_index] = enemy
			shot["pierce_left"] = int(shot["pierce_left"]) - 1
			if int(shot["pierce_left"]) < 0:
				consumed = true
				break
		var projectile_limit := maxf(size.x, size.y) * 0.86
		if consumed or finish.distance_to(_player_position) > projectile_limit:
			_projectiles.remove_at(i)
		else:
			_projectiles[i] = shot


## The aura trades single-target strength for coverage. At level one it deals
## less than half of one basic bolt, but applies that amount once to every body
## inside the circle. Repeated upgrades grow both reach and damage slowly.
func _step_aura(delta: float) -> void:
	if _aura_level <= 0:
		return
	_aura_pulse_left = maxf(0.0, _aura_pulse_left - delta)
	_aura_left -= delta
	if _aura_left > 0.0:
		return
	_aura_left += aura_interval_for(_aura_level)
	_trigger_aura()


func _trigger_aura() -> void:
	var radius := aura_radius_for(_aura_level) * _scale
	var damage := aura_damage_for(_aura_level)
	for i in range(_enemies.size() - 1, -1, -1):
		var enemy: Dictionary = _enemies[i]
		if not circles_overlap(_player_position, radius,
				Vector2(enemy["position"]), float(enemy["collision_radius"])):
			continue
		enemy["health"] = float(enemy["health"]) - damage
		if float(enemy["health"]) <= 0.0:
			_defeat_enemy(i)
		else:
			_enemies[i] = enemy
	_aura_pulse_left = AURA_PULSE_TIME
	_reaction_left = maxf(_reaction_left, REACTION_TIME)


func _defeat_enemy(index: int) -> void:
	var enemy: Dictionary = _enemies[index]
	_enemies.remove_at(index)
	_add_score(int(enemy["points"]))
	if _pickups.size() >= MAX_PICKUPS:
		_gain_experience(int(enemy["experience"]))
	else:
		_pickups.append({
			"position": enemy["position"],
			"value": enemy["experience"],
			"phase": randf() * TAU,
		})


func _step_pickups(delta: float) -> void:
	for i in range(_pickups.size() - 1, -1, -1):
		var pickup: Dictionary = _pickups[i]
		var position: Vector2 = pickup["position"]
		var distance := position.distance_to(_player_position)
		if distance <= 14.0 * _scale:
			_pickups.remove_at(i)
			_gain_experience(int(pickup["value"]))
			if _choosing_upgrade:
				return
			continue
		if distance < _collection_radius * _scale and distance > 0.0:
			var pull := lerpf(145.0, 430.0,
				1.0 - distance / (_collection_radius * _scale)) * _scale
			position += position.direction_to(_player_position) * pull * delta
			pickup["position"] = position
		pickup["phase"] = float(pickup["phase"]) + delta * 4.0
		_pickups[i] = pickup


func _take_hit() -> void:
	if _invincible_left > 0.0:
		return
	_invincible_left = float(LEVELS[_level]["damage_grace"])
	_reaction_left = REACTION_TIME * 2.0
	_lose_one()


func _place_pet(movement: Vector2) -> void:
	if _pet == null:
		return
	var centre := _screen_centre()
	_pet.stand_on(centre.y + _pet.height() * 0.5, centre.x)
	if movement.x != 0.0:
		_pet.set_facing(signi(roundi(movement.x)))
	if _invincible_left > 0.0 and _reaction_left > 0.0:
		_pet.set_state(&"sad")
		_pet.set_squash(-0.10)
	elif _reaction_left > 0.0:
		_pet.set_state(&"excited")
		_pet.set_squash(0.08)
	elif movement != Vector2.ZERO:
		_pet.set_state(&"walk")
		_pet.set_squash(0.0)
	else:
		_pet.set_state(&"idle")
		_pet.set_squash(0.0)
	_pet.modulate.a = 0.38 if _invincible_left > 0.0 \
		and fmod(_invincible_left, 0.14) < 0.07 else 1.0


# --- Experience and upgrades --------------------------------------------------

static func experience_needed_for(level: int) -> int:
	return 5 + maxi(1, level) * 3


static func aura_damage_for(level: int) -> float:
	return 0.0 if level <= 0 else AURA_BASE_DAMAGE + float(level - 1) * 0.20


static func aura_radius_for(level: int) -> float:
	return 0.0 if level <= 0 else AURA_BASE_RADIUS + float(level - 1) * 10.0


static func aura_interval_for(level: int) -> float:
	return maxf(0.95, AURA_BASE_INTERVAL - float(maxi(0, level - 1)) * 0.12)


func _gain_experience(amount: int) -> void:
	_experience += amount
	if _experience < _experience_needed or _choosing_upgrade:
		return
	_experience -= _experience_needed
	_survivor_level += 1
	_experience_needed = experience_needed_for(_survivor_level)
	_open_upgrade_choice()


func _open_upgrade_choice() -> void:
	var candidates: Array[Dictionary] = []
	for upgrade: Dictionary in UPGRADES:
		if _upgrade_available(StringName(upgrade["id"])):
			candidates.append(upgrade)
	candidates.shuffle()
	_upgrade_choices.clear()
	# A new weapon should be discoverable, not buried behind random rolls. Keep
	# the aura unlock in every offer until it is chosen; the other two stay random.
	if _aura_level == 0:
		for candidate: Dictionary in candidates:
			if StringName(candidate["id"]) == &"aura_unlock":
				_upgrade_choices.append(candidate)
				break
	for candidate: Dictionary in candidates:
		if _upgrade_choices.size() >= 3:
			break
		if StringName(candidate["id"]) == &"aura_unlock":
			continue
		_upgrade_choices.append(candidate)
	_choosing_upgrade = not _upgrade_choices.is_empty()


func _upgrade_available(id: StringName) -> bool:
	match id:
		&"cadence":
			return _fire_interval > 0.24
		&"multishot":
			return _shot_count < 5
		&"speed":
			return _move_speed < 390.0
		&"magnet":
			return _collection_radius < 180.0
		&"pierce":
			return _pierce < 4
		&"aura_unlock":
			return _aura_level == 0
		&"aura_power":
			return _aura_level > 0 and _aura_level < MAX_AURA_LEVEL
	return true


func _choose_upgrade(index: int) -> void:
	if not _choosing_upgrade or index < 0 or index >= _upgrade_choices.size():
		return
	var id := StringName(_upgrade_choices[index]["id"])
	match id:
		&"power":
			_damage += 1.0
		&"cadence":
			_fire_interval = maxf(0.22, _fire_interval * 0.82)
		&"multishot":
			_shot_count = mini(5, _shot_count + 1)
		&"speed":
			_move_speed = minf(390.0, _move_speed * 1.15)
		&"magnet":
			_collection_radius = minf(180.0, _collection_radius + 24.0)
		&"pierce":
			_pierce = mini(4, _pierce + 1)
		&"aura_unlock":
			_aura_level = 1
			_aura_left = 0.22
		&"aura_power":
			_aura_level = mini(MAX_AURA_LEVEL, _aura_level + 1)
		&"vitality":
			_recover_one()
	_choosing_upgrade = false
	_upgrade_choices.clear()
	_reaction_left = REACTION_TIME * 1.5
	if _experience >= _experience_needed:
		_gain_experience(0)


# --- Geometry and input -------------------------------------------------------

static func nearest_point_index(origin: Vector2, points: Array[Vector2]) -> int:
	var closest := -1
	var closest_distance := INF
	for i in points.size():
		var distance := origin.distance_squared_to(points[i])
		if distance < closest_distance:
			closest_distance = distance
			closest = i
	return closest


static func segment_hits_circle(start: Vector2, finish: Vector2,
		centre: Vector2, radius: float) -> bool:
	var segment := finish - start
	var length_squared := segment.length_squared()
	var t := 0.0 if is_zero_approx(length_squared) else clampf(
		(centre - start).dot(segment) / length_squared, 0.0, 1.0)
	return centre.distance_squared_to(start + segment * t) <= radius * radius


static func circles_overlap(a: Vector2, a_radius: float,
		b: Vector2, b_radius: float) -> bool:
	var combined := a_radius + b_radius
	return a.distance_squared_to(b) <= combined * combined


## Convert an unbounded world point to the finite game window. Keeping this
## explicit prevents gameplay code from accidentally clamping world positions
## back to the viewport when adding future weapons or enemies.
static func project_to_screen(world: Vector2, camera: Vector2,
		viewport_size: Vector2) -> Vector2:
	return world - camera + viewport_size * 0.5


func _screen_centre() -> Vector2:
	return size * 0.5


func _world_to_screen(world: Vector2) -> Vector2:
	return project_to_screen(world, _player_position, size)


func _key_pressed(keycode: int) -> bool:
	if _choosing_upgrade:
		match keycode:
			KEY_1, KEY_KP_1:
				_choose_upgrade(0)
			KEY_2, KEY_KP_2:
				_choose_upgrade(1)
			KEY_3, KEY_KP_3:
				_choose_upgrade(2)
			_:
				return false
		return true
	return keycode in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN,
		KEY_A, KEY_D, KEY_W, KEY_S]


func _pointer_moved(pos: Vector2) -> void:
	_pointer_position = pos


func _pointer_clicked(pos: Vector2) -> void:
	if _choosing_upgrade:
		var cards := _upgrade_card_rects()
		for i in cards.size():
			if cards[i].has_point(pos):
				_choose_upgrade(i)
				return
		return
	_pointer_target = _player_position + pos - _screen_centre()
	_using_pointer = true


func _upgrade_card_rects() -> Array[Rect2]:
	var rects: Array[Rect2] = []
	var gap := 12.0 * _scale
	var side := 22.0 * _scale
	var width := (size.x - side * 2.0 - gap * 2.0) / 3.0
	var height := UPGRADE_CARD_HEIGHT * _scale
	var y := (size.y - height) * 0.5
	for i in 3:
		rects.append(Rect2(side + float(i) * (width + gap), y, width, height))
	return rects


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	_draw_arena_grid()
	_draw_aura()
	for pickup: Dictionary in _pickups:
		_draw_pickup(pickup)
	for shot: Dictionary in _projectiles:
		var position := _world_to_screen(Vector2(shot["position"]))
		draw_circle(position, 8.0 * _scale, Color(PetStyle.GAME_SURVIVOR_SHOT, 0.14))
		draw_circle(position, 4.0 * _scale, PetStyle.GAME_SURVIVOR_SHOT)
	for enemy: Dictionary in _enemies:
		_draw_enemy(enemy)
	_draw_hud()
	if _using_pointer and not _choosing_upgrade:
		draw_arc(_world_to_screen(_pointer_target), 8.0 * _scale, 0.0, TAU, 16,
			Color(PetStyle.GAME_SURVIVOR_XP, 0.48), maxf(1.0, _scale), true)
	if _choosing_upgrade:
		_draw_upgrade_choice()


func _draw_aura() -> void:
	if _aura_level <= 0:
		return
	var centre := _screen_centre()
	var full_radius := aura_radius_for(_aura_level) * _scale
	# The faint resting ring makes the weapon's actual reach learnable without
	# turning the whole arena into a permanent bright disc.
	draw_arc(centre, full_radius, 0.0, TAU, 64,
		Color(PetStyle.GAME_SURVIVOR_AURA, 0.12), maxf(1.0, _scale), true)
	if _aura_pulse_left <= 0.0:
		return
	var progress := 1.0 - _aura_pulse_left / AURA_PULSE_TIME
	var pulse_radius := lerpf(full_radius * 0.28, full_radius, progress)
	var alpha := (1.0 - progress) * 0.72
	draw_circle(centre, pulse_radius,
		Color(PetStyle.GAME_SURVIVOR_AURA, alpha * 0.08))
	draw_arc(centre, pulse_radius, 0.0, TAU, 64,
		Color(PetStyle.GAME_SURVIVOR_AURA, alpha),
		maxf(2.0, 3.0 * _scale), true)


func _draw_arena_grid() -> void:
	var step := 52.0 * _scale
	var color := Color(PetStyle.GAME_GROUND, 0.32)
	var centre := _screen_centre()
	var x := fposmod(centre.x - fposmod(_player_position.x, step), step) - step
	while x < size.x + step:
		draw_line(Vector2(x, HUD_HEIGHT * _scale), Vector2(x, size.y), color,
			maxf(1.0, _scale))
		x += step
	var y := fposmod(centre.y - fposmod(_player_position.y, step), step) - step
	while y < size.y + step:
		if y >= HUD_HEIGHT * _scale:
			draw_line(Vector2(0.0, y), Vector2(size.x, y), color,
				maxf(1.0, _scale))
		y += step


func _draw_enemy(enemy: Dictionary) -> void:
	var world_position: Vector2 = enemy["position"]
	var position := _world_to_screen(world_position)
	var radius := float(enemy["radius"])
	var kind := int(enemy["kind"])
	var texture := ENEMY_PIG if kind == 0 else (
		ENEMY_SAMURAI if kind == 1 else ENEMY_NINJA)
	var frame_count := 2 if kind == 0 else 4
	var frame := (floori(_animation_time * 6.0) + int(enemy["id"])) % frame_count
	var direction := _player_position - world_position
	var row := 0
	if kind > 0:
		if absf(direction.x) > absf(direction.y):
			row = 1
		elif direction.y < 0.0:
			row = 2
	var source := Rect2(
		Vector2(float(frame), float(row)) * ENEMY_CELL_SIZE,
		Vector2.ONE * ENEMY_CELL_SIZE)
	var draw_size := radius * (2.55 if kind == 0 else 2.65)
	# A quiet shadow anchors sprites whose transparent cells leave their feet at
	# slightly different heights. It stays procedural because it is geometry,
	# not replacement artwork.
	draw_set_transform(position + Vector2(0.0, draw_size * 0.30), 0.0,
		Vector2(draw_size * 0.030, draw_size * 0.012))
	draw_circle(Vector2.ZERO, 1.0, Color(PetStyle.NIGHT_EDGE, 0.48))
	var flip := direction.x < 0.0 and absf(direction.x) > absf(direction.y)
	draw_set_transform(position, 0.0, Vector2(-1.0 if flip else 1.0, 1.0))
	draw_texture_rect_region(
		texture, Rect2(Vector2.ONE * -draw_size * 0.5, Vector2.ONE * draw_size),
		source)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var health := float(enemy["health"])
	var max_health := float(enemy["max_health"])
	if health < max_health:
		var bar := Rect2(position + Vector2(-radius, -draw_size * 0.5 - 7.0 * _scale),
			Vector2(radius * 2.0, 3.0 * _scale))
		draw_rect(bar, Color(PetStyle.NIGHT_EDGE, 0.8), true)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * health / max_health, bar.size.y)),
			PetStyle.GAME_SURVIVOR_XP, true)


func _draw_pickup(pickup: Dictionary) -> void:
	var position := _world_to_screen(Vector2(pickup["position"]))
	var pulse := 1.0 + sin(float(pickup["phase"])) * 0.14
	var radius := (5.5 if int(pickup["value"]) == 1 else 7.5) * _scale * pulse
	var diamond := PackedVector2Array([
		position + Vector2(0.0, -radius),
		position + Vector2(radius * 0.72, 0.0),
		position + Vector2(0.0, radius),
		position + Vector2(-radius * 0.72, 0.0),
	])
	draw_colored_polygon(diamond, PetStyle.GAME_SURVIVOR_XP)


func _draw_hud() -> void:
	var font := ThemeDB.fallback_font
	var font_size := maxi(10, roundi(13.0 * _scale))
	var seconds := ceili(_time_left)
	var time_text := "%02d:%02d" % [seconds / 60, seconds % 60]
	var time_width := font.get_string_size(
		time_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, Vector2((size.x - time_width) * 0.5, 22.0 * _scale),
		time_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, PetStyle.NIGHT_TEXT)
	var level_text := "Lv.%d" % _survivor_level
	draw_string(font, Vector2(72.0 * _scale, 22.0 * _scale), level_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, PetStyle.NIGHT_MUTED)
	var bar := Rect2(72.0 * _scale, 30.0 * _scale,
		size.x - 92.0 * _scale, 5.0 * _scale)
	draw_rect(bar, Color(PetStyle.NIGHT_EDGE, 0.72), true)
	draw_rect(Rect2(bar.position, Vector2(
		bar.size.x * float(_experience) / maxf(1.0, float(_experience_needed)),
		bar.size.y)), PetStyle.GAME_SURVIVOR_XP, true)


func _draw_upgrade_choice() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(PetStyle.GAME_FIELD, 0.78), true)
	var cards := _upgrade_card_rects()
	var font := ThemeDB.fallback_font
	for i in mini(cards.size(), _upgrade_choices.size()):
		var rect := cards[i]
		var hovered := rect.has_point(_pointer_position)
		draw_rect(rect, PetStyle.GAME_SURVIVOR_CARD, true)
		draw_rect(rect, PetStyle.ACCENT if hovered else PetStyle.NIGHT_EDGE,
			false, maxf(2.0, 2.0 * _scale))
		var choice: Dictionary = _upgrade_choices[i]
		draw_string(font, rect.position + Vector2(12.0, 24.0) * _scale,
			"%d" % (i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1,
			maxi(10, roundi(12.0 * _scale)), PetStyle.ACCENT_TEXT)
		draw_string(font, rect.position + Vector2(12.0, 54.0) * _scale,
			str(choice["title"]), HORIZONTAL_ALIGNMENT_LEFT, -1,
			maxi(12, roundi(16.0 * _scale)), PetStyle.NIGHT_TEXT)
		draw_string(font, rect.position + Vector2(12.0, 83.0) * _scale,
			str(choice["description"]), HORIZONTAL_ALIGNMENT_LEFT, -1,
			maxi(9, roundi(11.0 * _scale)), PetStyle.NIGHT_MUTED)
	var heading := "升級！選一個能力"
	var heading_size := maxi(13, roundi(18.0 * _scale))
	var heading_width := font.get_string_size(
		heading, HORIZONTAL_ALIGNMENT_LEFT, -1, heading_size).x
	draw_string(font, Vector2((size.x - heading_width) * 0.5,
		cards[0].position.y - 22.0 * _scale), heading,
		HORIZONTAL_ALIGNMENT_LEFT, -1, heading_size, PetStyle.NIGHT_TEXT)
