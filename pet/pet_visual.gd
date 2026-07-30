extends Node2D
class_name PetVisual

## The pet's body. Plays logical states ("idle", "walk", …) without callers
## needing to know whether a Codex pet pack is loaded or the emergency
## procedural fallback is in use.

## Logical state -> spritesheet row.
##
## Legacy packs declare no row semantics and the two ecosystems that use them
## disagree, so their defaults are based on real sheets. V2 packs use the
## current stable contract below.
##
## Correct it per pet without touching code by adding to user://config.cfg:
##     [pet_rows]
##     frieren-maplestory={"happy": 6, "sleep": 4}
## Use the calibration mode in the right-click menu to see which row is which.
const DEFAULT_STATE_ROWS := {
	&"idle": 0,
	&"walk": 1,
	&"run": 2,
	&"wave": 3,
	&"talk": 4,
	&"sad": 5,
	## Nothing sleeps in these packs; row 6 is usually the calmest, eyes-closed
	## loop, which is the closest stand-in.
	&"sleep": 6,
	&"excited": 7,
	&"happy": 8,
}
## Current Codex Pets v2 rows have stable meanings. More app states than atlas
## rows exist, so emotional states intentionally reuse the closest standard
## action instead of inventing a second, incompatible built-in layout.
const V2_STATE_ROWS := {
	&"idle": 0,
	&"walk": 1,
	&"run": 7,
	&"wave": 3,
	&"talk": 8,
	&"sad": 5,
	&"sleep": 6,
	&"excited": 4,
	&"happy": 3,
}

## Padding added around the character's bounding box when building the hit region.
const HIT_MARGIN := 8.0
const CALIBRATION_STEP := 2.5

## How tall the resting character should be drawn, as a fraction of its cell.
##
## Packs fill their cell to wildly different degrees — of the four to hand, the
## idle silhouette runs from 76% of the cell height (cute-rem) to 95% (yoshi) —
## so one shared size factor leaves one pet visibly bigger than the next. Each
## pack is scaled to put the *character* at a consistent height instead, and the
## user's size choice multiplies that.
##
## Height rather than width or area: these characters stand on the ground, so
## height is what reads as size, and a genuinely wide one (Pikachu, 182x180)
## should look wide rather than be shrunk to fit.
const NOMINAL_HEIGHT_RATIO := 0.9

## Bounds on that correction, so a mis-detected idle row — a blank one, or one
## holding a prop rather than the character — can't produce an enormous pet.
const PACK_SCALE_RANGE := Vector2(0.6, 1.6)

## How the pet notices the cursor: a lean and a perk that fade in over this
## radius and peak right next to the pet, kept well under HIT_MARGIN and close
## to the already-shipped squash magnitudes (-0.08 grab, 0.12 tap) so nothing
## it draws strays outside the hit region that's built from the same silhouette.
const CURSOR_NOTICE_RADIUS := 260.0   # design px, scaled by get_ui_scale() at use
const CURSOR_LEAN_MAX := 3.0          # sprite-local px, same space as _base_offset
const CURSOR_PERK_MAX := 0.035        # squash-amount units, same scale as set_squash()
const CURSOR_REACT_RATE := 10.0       # exponential per-second catch-up, not a snap
const CURSOR_FACING_DEADZONE := 24.0  # design px, hysteresis so facing doesn't flicker
const LOOK_STEP_DEGREES := 22.5
const LOOK_ROW_START := 9
const LOOK_DIRECTIONS_PER_ROW := 8

@onready var _sprite: AnimatedSprite2D = $Sprite
@onready var _fallback: Node2D = $Fallback
@onready var _label: Label = $CalibrationLabel

var _pack: PetPack = null
## Per-pack correction that evens out how big the character looks. Applied by the
## composition root along with the display scale and the user's size choice.
var _pack_scale := 1.0
var _state_rows := DEFAULT_STATE_ROWS.duplicate()
var _state := &"idle"
var _base_offset := Vector2.ZERO
var _hit_polygon := PackedVector2Array()

var _window: WindowController = null
## The "held" channel — grab, drag, tap-bounce, release — kept apart from the
## cursor channels below so _apply_pose() can add all three rather than one
## silently overwriting another.
var _squash := 0.0
var _brain_facing := 1
## 0 = no cursor override; else -1/1. Never persists past the frame eligibility
## ends, so the sprite can't get stuck facing the cursor after e.g. a walk starts.
var _cursor_facing_dir := 0
var _cursor_lean := 0.0
var _cursor_perk := 0.0
var _drag_lean := 0.0
## -1 means the normal state animation is active; 0-15 select the two v2 look
## rows clockwise from up.
var _look_index := -1

var _calibrating := false
var _calibration_row := 0
var _calibration_timer := 0.0


func _ready() -> void:
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	_hit_polygon = _fallback.get_hit_polygon()


## Only calls WindowController's public accessors, mirroring how PetBrain gets
## the same reference — never get_window() itself.
func setup(window: WindowController) -> void:
	_window = window


func _process(delta: float) -> void:
	if _calibrating:
		_advance_calibration(delta)
	else:
		_update_cursor_reaction(delta)


## Perks up when the pointer is close, fades out with distance, and eases
## rather than snaps — this is the one place PetVisual reads outside itself,
## since the cursor is a global desktop position and the window is click-through.
func _update_cursor_reaction(delta: float) -> void:
	# Gated to idle: PetBrain aliases DRAG's animation state to "idle" too (no pack
	# provides a drag animation), so the squash channel — nonzero throughout
	# grab/drag/release — is what tells a held pet apart from a genuinely idle one.
	# WALK and SLEEP are excluded outright: reacting mid-stride would fight the
	# walk's own facing decision, and perking up while "asleep" reads as a bug.
	var eligible := _window != null and _state == &"idle" and is_zero_approx(_squash)
	var lean_target := 0.0
	var perk_target := 0.0
	if eligible:
		var scale := _window.get_ui_scale()
		var radius := CURSOR_NOTICE_RADIUS * scale
		var offset := Vector2(DisplayServer.mouse_get_position() - _window.get_pet_screen_position())
		var dist := offset.length()
		if dist < radius:
			# Squared so the reaction concentrates near the pet ("perks up when
			# close") instead of a constant low-level twitch out to the full radius.
			var falloff := pow(1.0 - dist / radius, 2.0)
			lean_target = (offset.x / radius) * CURSOR_LEAN_MAX * falloff
			perk_target = -CURSOR_PERK_MAX * falloff
			if _pack != null and _pack.has_look_directions() \
					and dist > CURSOR_FACING_DEADZONE * scale:
				_cursor_facing_dir = 0
				_show_look_direction(offset)
			elif absf(offset.x) > CURSOR_FACING_DEADZONE * scale:
				_clear_look_direction()
				_cursor_facing_dir = 1 if offset.x > 0.0 else -1
			else:
				_clear_look_direction()
				_cursor_facing_dir = 0
		else:
			_clear_look_direction()
			_cursor_facing_dir = 0
	else:
		var was_overriding := _cursor_facing_dir != 0
		var was_looking := _look_index >= 0
		_cursor_facing_dir = 0
		_clear_look_direction()
		# Walking, talking, asleep or held — where the pet spends most of its
		# life, and where there is nothing to aim at. Once the two channels have
		# finished easing back there is no pose left to write, so don't spend a
		# frame writing the same one again.
		if not was_overriding and not was_looking \
				and is_zero_approx(_cursor_lean) and is_zero_approx(_cursor_perk):
			return

	var t := clampf(delta * CURSOR_REACT_RATE, 0.0, 1.0)
	_cursor_lean = lerpf(_cursor_lean, lean_target, t)
	_cursor_perk = lerpf(_cursor_perk, perk_target, t)
	_apply_pose()


func _show_look_direction(offset: Vector2) -> void:
	# Viewer coordinates: 000 is up and angles advance clockwise, while screen Y
	# grows downward.
	var degrees := fposmod(rad_to_deg(atan2(offset.x, -offset.y)), 360.0)
	var index := roundi(degrees / LOOK_STEP_DEGREES) % 16
	if index == _look_index:
		return
	_look_index = index
	var row := LOOK_ROW_START + index / LOOK_DIRECTIONS_PER_ROW
	_sprite.animation = PetPack.row_anim(row)
	_sprite.frame = index % LOOK_DIRECTIONS_PER_ROW
	_sprite.pause()


func _clear_look_direction() -> void:
	if _look_index < 0:
		return
	_look_index = -1
	if _pack != null and not _calibrating:
		_sprite.play(PetPack.row_anim(_playback_row(_state)))


func _display_facing() -> int:
	return _cursor_facing_dir if _cursor_facing_dir != 0 else _brain_facing


## The single place that writes to the sprite/fallback transforms, so facing,
## the cursor lean/perk and the held squash never overwrite one another —
## whichever last called set_facing()/set_squash() used to just clobber the rest.
##
## Deliberately scale (squash) and offset (lean) only, never rotation, on either
## the sprite or this node. pet.gd::_refresh_hit_region() measures the hit
## polygon as `p * _visual.scale`, which can't see a rotation — and it's only
## re-run on discrete triggers (pack switch, size change, anchor change), never
## per frame, so a continuously-varying rotation would go unmeasured regardless
## of whether that formula learned to read one.
func _apply_pose() -> void:
	var facing := _display_facing()
	# V2 supplies explicit left/right locomotion and look art. Mirroring either
	# would reverse the semantic direction a generated frame was drawn for.
	var uses_directional_art := _look_index >= 0 \
		or (_pack != null and _pack.sprite_version_number >= 2 and _state == &"walk")
	var flipped := facing < 0 and not uses_directional_art
	_sprite.flip_h = flipped
	# flip_h mirrors within the drawn rect, so an off-centre offset would swing
	# the character sideways. Negate it to keep them planted; lean is a plain
	# screen-space nudge, not a padding correction, so it is never negated.
	var lean := _cursor_lean + _drag_lean
	_sprite.offset = Vector2((-_base_offset.x if flipped else _base_offset.x) + lean, _base_offset.y)
	_fallback.position = Vector2(lean, 0.0)

	var total_squash := _squash + _cursor_perk
	if _pack == null:
		_fallback.set_squash(total_squash)
	else:
		_sprite.scale = Vector2(1.0 + total_squash, 1.0 - total_squash)


# --- Pack ---------------------------------------------------------------------

## Pass null only when no selected or bundled pack could be loaded.
func load_pack(pack: PetPack) -> void:
	_pack = pack
	_look_index = -1
	if pack == null:
		_sprite.visible = false
		_sprite.sprite_frames = null
		_fallback.visible = true
		_hit_polygon = _fallback.get_hit_polygon()
		# The blob is drawn to the size it wants to be; nothing to even out.
		_pack_scale = 1.0
		return

	_state_rows = V2_STATE_ROWS.duplicate() \
		if pack.sprite_version_number >= 2 else DEFAULT_STATE_ROWS.duplicate()
	var overrides: Dictionary = Config.get_value("pet_rows", pack.id, {})
	for state in overrides:
		_state_rows[StringName(state)] = int(overrides[state])

	_sprite.sprite_frames = pack.frames
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR \
		if pack.smooth_filter else CanvasItem.TEXTURE_FILTER_NEAREST
	# Measure the resting pose, not the whole sheet. Action frames fling limbs and
	# props well outside the idle silhouette, and sizing off those would leave the
	# pet hovering a long way from any screen edge with an oversized click box.
	var rest := pack.rect_for_row(int(_state_rows.get(&"idle", 0)))
	_pack_scale = _normalised_scale(pack, rest)
	# Centre the *character* in the window rather than the cell, since packs pad
	# their cells unevenly.
	_base_offset = Vector2(pack.cell_size) * 0.5 - Vector2(rest.get_center())
	_sprite.offset = _base_offset
	_sprite.visible = true
	_fallback.visible = false

	var half := Vector2(rest.size) * 0.5 + Vector2(HIT_MARGIN, HIT_MARGIN)
	_hit_polygon = PackedVector2Array([
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y),
	])
	play_state(_state)


func get_pack() -> PetPack:
	return _pack


## Multiplier that brings this pack's resting character to the same height as
## every other pack's, so switching pets doesn't change how big the pet looks.
func get_pack_scale() -> float:
	return _pack_scale


## The logical-state -> row map this pack ended up with, per-pet overrides and
## missing-row fallbacks already applied.
##
## Exists for the mini-game, which draws the *same* character from the *same*
## pack in a window of its own. It takes the resolved map rather than the pack
## because the two things this file knows and the pack doesn't — the user's
## `[pet_rows]` corrections, and which row to borrow when a pack simply has no
## art for a state — are exactly the two the game would otherwise get wrong,
## and getting them wrong there means the pet grinning when it drops something.
func state_rows() -> Dictionary:
	var resolved := {}
	if _pack == null:
		return resolved
	for state in _state_rows:
		resolved[state] = _resolve_row(state)
	return resolved


static func _normalised_scale(pack: PetPack, rest: Rect2i) -> float:
	if rest.size.y <= 0 or pack.cell_size.y <= 0:
		return 1.0
	return clampf(NOMINAL_HEIGHT_RATIO * float(pack.cell_size.y) / float(rest.size.y),
		PACK_SCALE_RANGE.x, PACK_SCALE_RANGE.y)


# --- Playback -----------------------------------------------------------------

func play_state(state: StringName) -> void:
	_state = state
	_look_index = -1
	# Re-sync facing/lean/squash for the new state's eligibility on the transition
	# frame itself, not just the next _process() tick — closing a one-callback-order
	# race where PetBrain's facing_changed can fire one line before state_changed.
	_apply_pose()
	if _pack == null or _calibrating:
		return
	_sprite.play(PetPack.row_anim(_playback_row(state)))


func _playback_row(state: StringName) -> int:
	if state == &"walk" and _pack != null and _pack.sprite_version_number >= 2:
		var directional_row := 1 if _brain_facing >= 0 else 2
		if _pack.has_row(directional_row):
			return directional_row
	return _resolve_row(state)


## Fall back to idle when a pack simply doesn't have art for a state.
func _resolve_row(state: StringName) -> int:
	var row: int = _state_rows.get(state, -1)
	if _pack.has_row(row):
		return row
	var idle_row: int = _state_rows.get(&"idle", 0)
	return idle_row if _pack.has_row(idle_row) else 0


func set_facing(facing: int) -> void:
	_brain_facing = facing
	if _pack != null and _pack.sprite_version_number >= 2 and _state == &"walk" \
			and not _calibrating:
		_sprite.play(PetPack.row_anim(_playback_row(_state)))
	_apply_pose()


## The "held" channel — grab/tap/release — as opposed to the cursor-perk channel,
## which _apply_pose() adds on top rather than one silently overwriting the other.
func set_squash(amount: float) -> void:
	_squash = amount
	_apply_pose()


## Counterpart to PetBrain.drag_lean_changed: the body trailing the grab point
## during a drag reads as lag, not just position catch-up, once it also leans.
func set_drag_lean(amount: float) -> void:
	_drag_lean = amount
	_apply_pose()


## Region that should catch mouse clicks, in this node's local space.
func get_hit_polygon() -> PackedVector2Array:
	return _hit_polygon


# --- Calibration --------------------------------------------------------------

## Cycles through every spritesheet row with its index on screen, so the row ->
## state mapping can be checked against a pet whose author never declared one.
func set_calibrating(on: bool) -> void:
	_calibrating = on and _pack != null
	_label.visible = _calibrating
	if _calibrating:
		_calibration_row = -1
		_calibration_timer = 0.0
		# Otherwise the row preview would be skewed by whatever lean/perk happened
		# to be mid-flight when calibration started.
		_cursor_lean = 0.0
		_cursor_perk = 0.0
		_apply_pose()
	else:
		play_state(_state)


func is_calibrating() -> bool:
	return _calibrating


func _advance_calibration(delta: float) -> void:
	_calibration_timer -= delta
	if _calibration_timer > 0.0:
		return
	_calibration_timer = CALIBRATION_STEP
	# Row count varies by pack — 9 on the original sheets, 11 on v2 — so ask the
	# pack rather than assuming.
	var rows := _pack.row_count()
	if rows <= 0:
		return
	for _i in rows:
		_calibration_row = (_calibration_row + 1) % rows
		if _pack.has_row(_calibration_row):
			break
	_sprite.play(PetPack.row_anim(_calibration_row))
	_label.text = "row %d · %d 幀" % [_calibration_row, _pack.row_frame_counts[_calibration_row]]
