extends Node
class_name PetBrain

## Autonomous behaviour. Decides what the pet is doing and where it should be;
## announces the result as a logical state name and lets the visual worry about
## which animation that is.
##
## Phase 6 replaces the timers here with the needs system (hunger/energy/mood).

signal state_changed(state: StringName)
signal facing_changed(facing: int)

enum Mode { IDLE, WALK, SLEEP, DRAG, TALK }

## Design-unit pixels per second; scaled by the display's DPI at runtime.
const WALK_SPEED := 45.0
const IDLE_SECONDS := Vector2(3.0, 9.0)
## Length of a single stroll.
const WALK_DISTANCE := Vector2(40.0, 130.0)
## The pet stays within this much of "home" — the corner it was parked at, or
## wherever it was last dropped — instead of roaming the whole desktop.
const HOME_RANGE := 200.0
## Consecutive idle spells before the pet nods off.
const IDLES_BEFORE_SLEEP := 5
const SLEEP_SECONDS := 30.0
## Give up on a walk that somehow never arrives.
const WALK_TIMEOUT := 25.0

var _window: WindowController
var _mode := Mode.IDLE
var _timer := 0.0
var _facing := 1
var _idle_streak := 0
var _paused := false
var _roaming := true
var _home_x := 0.0

## Tracked as a float so slow walks don't stall on integer window positions.
var _walk_x := 0.0
var _target_x := 0.0


func setup(window: WindowController) -> void:
	_window = window
	set_home_here()
	_enter(Mode.IDLE)


func set_paused(paused: bool) -> void:
	_paused = paused


func set_roaming(roaming: bool) -> void:
	_roaming = roaming
	if not roaming and _mode == Mode.WALK:
		_enter(Mode.IDLE)


func is_roaming() -> bool:
	return _roaming


## Anchor the wander range to wherever the pet is now.
func set_home_here() -> void:
	if _window != null:
		_home_x = float(_window.get_pet_screen_position().x)


func _process(delta: float) -> void:
	if _window == null or _paused:
		return
	_timer -= delta
	match _mode:
		Mode.IDLE:
			if _timer <= 0.0:
				_finish_idle()
		Mode.WALK:
			_step_walk(delta)
		Mode.SLEEP:
			if _timer <= 0.0:
				_enter(Mode.IDLE)
		Mode.DRAG, Mode.TALK:
			pass


# --- External nudges ----------------------------------------------------------

func on_grabbed() -> void:
	_enter(Mode.DRAG)


func on_released() -> void:
	_idle_streak = 0
	# Dropping the pet somewhere is how you tell it where to live.
	set_home_here()
	_enter(Mode.IDLE)


func on_tapped() -> void:
	# Being poked wakes the pet up and buys it another few minutes.
	_idle_streak = 0
	if _mode == Mode.SLEEP:
		_enter(Mode.IDLE)


# --- Transitions --------------------------------------------------------------

func _enter(mode: Mode) -> void:
	_mode = mode
	match mode:
		Mode.IDLE:
			_timer = randf_range(IDLE_SECONDS.x, IDLE_SECONDS.y)
			state_changed.emit(&"idle")
		Mode.WALK:
			_pick_walk_target()
			state_changed.emit(&"walk")
		Mode.SLEEP:
			_timer = SLEEP_SECONDS
			state_changed.emit(&"sleep")
		Mode.DRAG:
			state_changed.emit(&"drag")
		Mode.TALK:
			state_changed.emit(&"talk")


func _finish_idle() -> void:
	_idle_streak += 1
	if _idle_streak >= IDLES_BEFORE_SLEEP:
		_idle_streak = 0
		_enter(Mode.SLEEP)
	elif _roaming:
		_enter(Mode.WALK)
	else:
		_enter(Mode.IDLE)


func _pick_walk_target() -> void:
	var scale := _window.get_ui_scale()
	var bounds := _wander_bounds(scale)
	_walk_x = float(_window.get_pet_screen_position().x)

	var distance := randf_range(WALK_DISTANCE.x, WALK_DISTANCE.y) * scale
	var direction := 1.0 if randf() < 0.5 else -1.0
	_target_x = clampf(_walk_x + distance * direction, bounds.x, bounds.y)
	# Hit the edge and barely moved? Turn around instead of shuffling in place.
	if absf(_target_x - _walk_x) < 8.0 * scale:
		_target_x = clampf(_walk_x - distance * direction, bounds.x, bounds.y)

	_timer = WALK_TIMEOUT
	_set_facing(1 if _target_x >= _walk_x else -1)


## The strip the pet is willing to wander: HOME_RANGE either side of home, minus
## whatever falls off the screen.
func _wander_bounds(scale: float) -> Vector2:
	var screen := _window.get_walk_bounds()
	var reach := HOME_RANGE * scale
	var low := maxf(screen.x, _home_x - reach)
	var high := minf(screen.y, _home_x + reach)
	# Home ended up outside the walkable strip (screen changed, say) — fall back
	# to the screen so the pet isn't stuck.
	return Vector2(low, high) if low <= high else screen


func _step_walk(delta: float) -> void:
	var step := WALK_SPEED * _window.get_ui_scale() * delta
	var remaining := _target_x - _walk_x
	if absf(remaining) <= step or _timer <= 0.0:
		_move_to(_target_x)
		_enter(Mode.IDLE)
		return
	_walk_x += signf(remaining) * step
	_move_to(_walk_x)


func _move_to(x: float) -> void:
	var pos := _window.get_pet_screen_position()
	_window.set_pet_screen_position(Vector2i(roundi(x), pos.y))


func _set_facing(facing: int) -> void:
	if facing == _facing:
		return
	_facing = facing
	facing_changed.emit(facing)
