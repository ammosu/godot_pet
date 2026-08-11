extends MiniGame
class_name CatchGame

## 接東西 — the pet stands on the ground and you steer it into what falls.
##
## The positioning game of the three: what it asks is *where*, continuously, and
## the only real decision in it is whether a three-point bonus is worth leaving
## the side of the field you are already on.
##
## Keyboard and mouse drive the same single axis, and whichever was touched last
## wins. Both, rather than one: the window is opened from a right-click menu, so
## the mouse is already in your hand — and then it gets held for a minute, which
## is when the arrow keys start being the comfortable option.
##
## Everything falling is drawn in one _draw() rather than being a node. They are
## a handful of polygons each, created and destroyed constantly, and a scene tree
## churning that fast costs more than it explains.

## The three that are simply food. Drawn from at random, so no one of them means
## anything the others don't — variety is the whole job.
const TREATS: Array[int] = [GameArt.Item.RICE, GameArt.Item.APPLE, GameArt.Item.FISH]
const STAR_POINTS := 3
const STAR_CHANCE := 0.09

## `fall` is the starting descent in design px/s, `gap` the seconds between
## spawns, `bad` the share of items that are chillies, and `ramp` how much is
## added to the fall speed per minute survived.
##
## Spaced so the top one is genuinely a different game rather than the middle one
## with the numbers nudged: at 手忙腳亂 a quarter of what falls has to be dodged,
## which changes what you are doing, not just how fast.
const LEVELS: Array[Dictionary] = [
	{"fall": 165.0, "gap": Vector2(0.80, 1.25), "bad": 0.10, "ramp": 0.30},
	{"fall": 225.0, "gap": Vector2(0.55, 0.90), "bad": 0.18, "ramp": 0.45},
	{"fall": 300.0, "gap": Vector2(0.36, 0.62), "bad": 0.26, "ramp": 0.65},
]

const PET_SPEED := 430.0
const ITEM_RADIUS := 15.0
## How fast the pointer is chased. Not a snap: a pet that teleports onto the
## cursor isn't being played with, it's a cursor wearing a face.
const MOUSE_RATE := 16.0
## Below this the pet is standing still, not walking. Guards the walk animation
## from flickering on the sub-pixel drift the mouse easing leaves behind.
const MOVE_EPSILON := 8.0
## How long the pet wears its reaction to a catch or a drop.
const REACT_TIME := 0.55
## Ceiling on the speed ramp. Past this the run stops testing reflexes and starts
## testing luck.
const MAX_SPEEDUP := 2.2

var _items: Array[Dictionary] = []
var _spawn_in := 0.0
var _pet_x := 0.0
var _pet_vel := 0.0
## Recentres once the Control has been given a size. Nothing is laid out yet when
## setup() runs, so `size` is still zero there.
var _needs_centre := true
var _react_left := 0.0
var _react_good := true
var _using_mouse := false
var _mouse_x := 0.0


func ready_hint() -> String:
	return "空白鍵或點一下開始\n← → 或滑鼠左右移動\n紅色的別接，漏三個就結束"


func _prepare() -> void:
	_items.clear()
	_pet_vel = 0.0
	_react_left = 0.0
	_needs_centre = true
	# A beat before the first thing arrives, so a run never opens with something
	# already halfway down.
	_spawn_in = 0.5


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	# Move first so the collision uses the pet players see this frame rather than
	# yesterday's pointer/key position.
	_step_pet(delta)
	if is_playing():
		_fall(delta)
	_pet.stand_on(_ground_y(), _pet_x)


func _fall(delta: float) -> void:
	_spawn_in -= delta
	if _spawn_in <= 0.0:
		_spawn()
		var gap: Vector2 = LEVELS[_level]["gap"]
		_spawn_in = randf_range(gap.x, gap.y) * _gap_factor()

	var ground := _ground_y()
	var pet_rect := _pet.collision_rect(_pet_x, ground)
	var gone := ground + ITEM_RADIUS * _scale
	# Backwards, so removing an item doesn't skip the one behind it.
	for i in range(_items.size() - 1, -1, -1):
		var item: Dictionary = _items[i]
		var y := float(item["y"]) + float(item["speed"]) * delta
		item["y"] = y
		if GamePet.circle_hits_rect(Vector2(float(item["x"]), y),
				ITEM_RADIUS * _scale, pet_rect):
			_items.remove_at(i)
			_collect(int(item["kind"]))
		elif y > gone:
			_items.remove_at(i)
			_drop(int(item["kind"]))


func _spawn() -> void:
	var kind := GameArt.Item.CHILLI
	if randf() >= float(LEVELS[_level]["bad"]):
		kind = GameArt.Item.STAR if randf() < STAR_CHANCE \
			else TREATS[randi() % TREATS.size()]
	var margin := ITEM_RADIUS * 1.6 * _scale
	_items.append({
		"x": randf_range(margin, maxf(margin, size.x - margin)),
		"y": -ITEM_RADIUS * _scale,
		"kind": kind,
		# The bonus falls faster than it is worth. Three points should be a
		# decision about leaving where you are, not a gift.
		"speed": _fall_speed() * (1.25 if kind == GameArt.Item.STAR else 1.0),
	})


func _fall_speed() -> float:
	var level: Dictionary = LEVELS[_level]
	var ramp := 1.0 + float(level["ramp"]) * _elapsed / 60.0
	return float(level["fall"]) * _scale * minf(ramp, MAX_SPEEDUP)


## Spawns close up as a run goes on, but only so far: past a point the field is
## simply full, and more of it stops being difficulty and starts being noise.
func _gap_factor() -> float:
	return maxf(0.45, 1.0 - _elapsed / 150.0)


func _collect(kind: int) -> void:
	if kind == GameArt.Item.CHILLI:
		_react(false)
		_lose_one()
		return
	_treats += 1
	_add_score(STAR_POINTS if kind == GameArt.Item.STAR else 1)
	_react(true)


func _drop(kind: int) -> void:
	# Letting a chilli through is the correct move, so it costs nothing. Nothing
	# in the field should ever punish playing it right.
	if kind == GameArt.Item.CHILLI:
		return
	_react(false)
	_lose_one()


func _react(good: bool) -> void:
	_react_left = REACT_TIME
	_react_good = good


# --- The pet ------------------------------------------------------------------

func _step_pet(delta: float) -> void:
	if _needs_centre and size.x > 0.0:
		_pet_x = size.x * 0.5
		_mouse_x = _pet_x
		_needs_centre = false

	var before := _pet_x
	var axis := _held_axis()
	if not is_zero_approx(axis):
		_using_mouse = false
	if _using_mouse:
		_pet_x = lerpf(_pet_x, _mouse_x, clampf(delta * MOUSE_RATE, 0.0, 1.0))
	else:
		_pet_x += axis * PET_SPEED * _scale * delta
	var half := _pet.half_width()
	_pet_x = clampf(_pet_x, half, maxf(half, size.x - half))

	_pet_vel = (_pet_x - before) / maxf(delta, 0.0001)
	if absf(_pet_vel) > MOVE_EPSILON * _scale:
		_pet.set_facing(1 if _pet_vel > 0.0 else -1)
	if _react_left > 0.0:
		_react_left = maxf(0.0, _react_left - delta)
		var ease_out := _react_left / REACT_TIME
		_pet.set_state(&"happy" if _react_good else &"sad")
		_pet.set_squash((0.13 if _react_good else -0.09) * ease_out)
	else:
		_pet.set_state(&"walk" if absf(_pet_vel) > MOVE_EPSILON * _scale else &"idle")
		_pet.set_squash(0.0)


func _pointer_moved(pos: Vector2) -> void:
	_using_mouse = true
	_mouse_x = pos.x


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	_draw_ground()
	var r := ITEM_RADIUS * _scale
	for item in _items:
		GameArt.draw_item(self, int(item["kind"]),
			Vector2(float(item["x"]), float(item["y"])), r)
