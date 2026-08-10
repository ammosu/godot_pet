extends Node
class_name PetBrain

## Autonomous behaviour. Decides what the pet is doing and where it should be;
## announces the result as a logical state name and lets the visual worry about
## which animation that is.
##
## Sleep is driven by PetState's energy rather than by a timer, so naps line up
## with what the pet tells the user about itself.

signal state_changed(state: StringName)
signal facing_changed(facing: int)
## How far the body is still lagging behind the grab point, in sprite-local px
## — PetVisual.set_drag_lean's counterpart. Zero outside DRAG/SETTLE.
signal drag_lean_changed(amount: float)

enum Mode { IDLE, WALK, SLEEP, DRAG, TALK, SETTLE, AMBIENT }

## Design-unit pixels per second; scaled by the display's DPI at runtime.
const WALK_SPEED := 45.0
const IDLE_SECONDS := Vector2(3.0, 9.0)
## Length of a single stroll.
const WALK_DISTANCE := Vector2(40.0, 130.0)
## The pet stays within this much of "home" — the corner it was parked at, or
## wherever it was last dropped — instead of roaming the whole desktop.
const HOME_RANGE := 200.0
## Give up on a walk that somehow never arrives.
const WALK_TIMEOUT := 25.0
## Wake up regardless after this long, in case energy never climbs.
const SLEEP_TIMEOUT := 30.0 * 60.0
## How long a tired pet stays up after being poked awake.
const WAKE_GRACE_SECONDS := 90.0
## Ambient emotes stay occasional. They should make an idle glance feel alive,
## not keep the character permanently performing at the edge of the screen.
const AMBIENT_CHANCE := 0.22

## Per-second exponential catch-up for the dragged body chasing the cursor;
## higher = lighter/snappier. Deliberately not 1:1 — the whole point is lag.
const DRAG_FOLLOW_RATE := 18.0
## Design px of lag that reaches full lean.
const DRAG_LEAN_REFERENCE := 60.0
## Sprite-local px, same space as PetVisual.CURSOR_LEAN_MAX.
const DRAG_LEAN_MAX := 6.0
## Design px; below this the body counts as having arrived at the drop point.
const SETTLE_DONE_DISTANCE := 2.0

var _window: WindowController
var _mode := Mode.IDLE
var _timer := 0.0
var _facing := 1
var _paused := false
var _roaming := true
var _home_x := 0.0
var _wake_grace := 0.0

## Tracked as a float so slow walks don't stall on integer window positions.
var _walk_x := 0.0
var _target_x := 0.0

## Where the body is chasing during DRAG/SETTLE — the raw, unclamped cursor-
## derived point, not a live read of the window (which is still mid-catch-up).
var _drag_target := Vector2i.ZERO
var _ambient_state: StringName = &"idle"


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
	_wake_grace = maxf(0.0, _wake_grace - delta)
	match _mode:
		Mode.IDLE:
			if _timer <= 0.0:
				_finish_idle()
		Mode.WALK:
			_step_walk(delta)
		Mode.SLEEP:
			if PetState.is_rested() or _timer <= 0.0:
				_enter(Mode.IDLE)
		Mode.DRAG:
			_step_drag(delta)
		Mode.SETTLE:
			var before := _window.get_pet_screen_position()
			var after := _step_drag(delta)
			# Finish on arrival *or* on stalling. The drop point is a raw
			# cursor-derived position and can be somewhere the pet is not
			# allowed to stand — let go of it in the desktop corner with the
			# cursor past the edge and the clamped position never closes the
			# gap. Distance alone therefore never fired, which left the brain
			# out of IDLE for the rest of the run (no walking, no sleeping),
			# the lean frozen part-way, and pet_moved emitting every frame.
			var gap := Vector2(_drag_target - after).length()
			if gap < SETTLE_DONE_DISTANCE * _window.get_ui_scale() or after == before:
				_finish_settle()
		Mode.TALK:
			pass
		Mode.AMBIENT:
			if _timer <= 0.0:
				_enter(Mode.IDLE)


# --- External nudges ----------------------------------------------------------

func on_grabbed() -> void:
	_drag_target = _window.get_pet_screen_position()
	_enter(Mode.DRAG)


## Fed on every mouse-motion event while dragging, instead of the window being
## teleported there directly — _step_drag() is what actually moves it, with lag.
func set_drag_target(pos: Vector2i) -> void:
	_drag_target = pos


func on_released() -> void:
	# Provisional: the raw cursor-derived drop point, not set_home_here()'s live
	# read, because at the instant of release the window is still mid-catch-up
	# towards it. _finish_settle() replaces it with where the pet really landed;
	# this one only has to cover a chat opening before the settle finishes.
	_home_x = float(_drag_target.x)
	_enter(Mode.SETTLE)


func on_tapped() -> void:
	if _mode != Mode.SLEEP:
		return
	# Being poked awake buys a grace period, otherwise the pet — still exhausted —
	# would nod straight off again on the next idle cycle.
	_wake_grace = WAKE_GRACE_SECONDS
	_enter(Mode.IDLE)


## Hold still for the duration of a conversation — a pet that wanders off
## mid-sentence drags its speech bubble along with it.
func on_talk_started() -> void:
	if _mode != Mode.DRAG:
		_enter(Mode.TALK)


func on_talk_ended() -> void:
	if _mode == Mode.TALK:
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
			_timer = SLEEP_TIMEOUT
			state_changed.emit(&"sleep")
		Mode.DRAG:
			state_changed.emit(&"drag")
		Mode.SETTLE:
			state_changed.emit(&"settle")
		Mode.TALK:
			# TALK can be entered straight out of SETTLE (on_talk_started() only
			# guards against interrupting an active DRAG) — without this, a chat
			# opened right as the pet lands would freeze the lean at whatever it
			# was mid-fall, since nothing else would ever tick it back down.
			drag_lean_changed.emit(0.0)
			state_changed.emit(&"talk")
		Mode.AMBIENT:
			state_changed.emit(_ambient_state)


func _finish_idle() -> void:
	if PetState.is_exhausted() and _wake_grace <= 0.0:
		_enter(Mode.SLEEP)
	elif randf() < AMBIENT_CHANCE and _pick_ambient():
		_enter(Mode.AMBIENT)
	elif _roaming:
		_enter(Mode.WALK)
	else:
		_enter(Mode.IDLE)


func _pick_ambient() -> bool:
	var candidates: Array[Dictionary] = []
	var total := 0.0
	for behaviour in CompanionProfile.ambient_behaviours():
		if PetState.get_need(&"bond") < float(behaviour.get("minimumBond", 0.0)):
			continue
		var state := StringName(str(behaviour.get("state", "")))
		var weight := maxf(0.0, float(behaviour.get("weight", 1.0)))
		if state.is_empty() or weight <= 0.0:
			continue
		candidates.append(behaviour)
		total += weight
	if candidates.is_empty() or total <= 0.0:
		return false
	var roll := randf() * total
	for behaviour in candidates:
		roll -= maxf(0.0, float(behaviour.get("weight", 1.0)))
		if roll <= 0.0:
			_ambient_state = StringName(str(behaviour.get("state", "idle")))
			_timer = clampf(float(behaviour.get("duration", 2.0)), 0.4, 10.0)
			return true
	return false


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


## Shared by DRAG and SETTLE: the body chases _drag_target with lag rather than
## teleporting onto it, in both dimensions — unlike walking, which only moves x.
##
## Returns where the pet actually ended up, which is not always where it was
## sent: set_pet_screen_position() clamps to what the window and the anchor can
## between them reach, and the caller needs the real answer to tell converging
## apart from being stuck against a screen edge.
func _step_drag(delta: float) -> Vector2i:
	var current := _window.get_pet_screen_position()
	var target := Vector2(_drag_target)
	var t := clampf(delta * DRAG_FOLLOW_RATE, 0.0, 1.0)
	var lagged := Vector2(current).lerp(target, t)
	var next := Vector2i(roundi(lagged.x), roundi(lagged.y))
	# Every move emits pet_moved, which re-lays-out the chat UI and re-pushes the
	# mask. A pet held still, or one that has already converged, must not pay for
	# a move it isn't making — this runs every frame, unlike a walk step.
	if next != current:
		_window.set_pet_screen_position(next)

	# The still-open gap doubles as the lean signal — no separate velocity to
	# track, and it decays to ~0 by itself as SETTLE converges.
	var lag := target - lagged
	var reference := DRAG_LEAN_REFERENCE * _window.get_ui_scale()
	drag_lean_changed.emit(clampf(lag.x / reference, -1.0, 1.0) * DRAG_LEAN_MAX)
	return _window.get_pet_screen_position()


## Where the pet came to rest is where it lives now. Read off the window rather
## than off _drag_target: that one is the raw cursor position and may be outside
## the area the pet is allowed to occupy, and a home_x off the walkable strip
## makes _wander_bounds() give up and hand back the whole screen.
func _finish_settle() -> void:
	set_home_here()
	drag_lean_changed.emit(0.0)
	_enter(Mode.IDLE)


func _set_facing(facing: int) -> void:
	if facing == _facing:
		return
	_facing = facing
	facing_changed.emit(facing)
