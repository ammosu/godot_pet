extends Node2D
class_name PetVisual

## The pet's body. Plays logical states ("idle", "walk", …) without callers
## needing to know whether a Codex pet pack is loaded or we're falling back to
## the procedural blob.

## Logical state -> spritesheet row.
##
## The format declares no row semantics and the two ecosystems that use it
## disagree, so this is read off a real sheet rather than from any spec. Rows 0-5
## are consistent enough to rely on; 6-8 are whatever the artist felt like, and
## no pack seen so far has a genuine sleep animation.
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

## Padding added around the character's bounding box when building the hit region.
const HIT_MARGIN := 8.0
const CALIBRATION_STEP := 2.5

@onready var _sprite: AnimatedSprite2D = $Sprite
@onready var _fallback: Node2D = $Fallback
@onready var _label: Label = $CalibrationLabel

var _pack: PetPack = null
var _state_rows := DEFAULT_STATE_ROWS.duplicate()
var _state := &"idle"
var _base_offset := Vector2.ZERO
var _hit_polygon := PackedVector2Array()

var _calibrating := false
var _calibration_row := 0
var _calibration_timer := 0.0


func _ready() -> void:
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	_hit_polygon = _fallback.get_hit_polygon()


func _process(delta: float) -> void:
	if _calibrating:
		_advance_calibration(delta)


# --- Pack ---------------------------------------------------------------------

## Pass null to fall back to the procedural blob.
func load_pack(pack: PetPack) -> void:
	_pack = pack
	if pack == null:
		_sprite.visible = false
		_sprite.sprite_frames = null
		_fallback.visible = true
		_hit_polygon = _fallback.get_hit_polygon()
		return

	_state_rows = DEFAULT_STATE_ROWS.duplicate()
	var overrides: Dictionary = Config.get_value("pet_rows", pack.id, {})
	for state in overrides:
		_state_rows[StringName(state)] = int(overrides[state])

	_sprite.sprite_frames = pack.frames
	# Measure the resting pose, not the whole sheet. Action frames fling limbs and
	# props well outside the idle silhouette, and sizing off those would leave the
	# pet hovering a long way from any screen edge with an oversized click box.
	var rest := pack.rect_for_row(int(_state_rows.get(&"idle", 0)))
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


# --- Playback -----------------------------------------------------------------

func play_state(state: StringName) -> void:
	_state = state
	if _pack == null or _calibrating:
		return
	_sprite.play(PetPack.row_anim(_resolve_row(state)))


## Fall back to idle when a pack simply doesn't have art for a state.
func _resolve_row(state: StringName) -> int:
	var row: int = _state_rows.get(state, -1)
	if _pack.has_row(row):
		return row
	var idle_row: int = _state_rows.get(&"idle", 0)
	return idle_row if _pack.has_row(idle_row) else 0


func set_facing(facing: int) -> void:
	var flipped := facing < 0
	_sprite.flip_h = flipped
	# flip_h mirrors within the drawn rect, so an off-centre offset would swing
	# the character sideways. Negate it to keep them planted.
	_sprite.offset = Vector2(-_base_offset.x if flipped else _base_offset.x, _base_offset.y)


func set_squash(amount: float) -> void:
	if _pack == null:
		_fallback.set_squash(amount)
	else:
		_sprite.scale = Vector2(1.0 + amount, 1.0 - amount)


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
	else:
		play_state(_state)


func is_calibrating() -> bool:
	return _calibrating


func _advance_calibration(delta: float) -> void:
	_calibration_timer -= delta
	if _calibration_timer > 0.0:
		return
	_calibration_timer = CALIBRATION_STEP
	for _i in PetPack.ROWS:
		_calibration_row = (_calibration_row + 1) % PetPack.ROWS
		if _pack.has_row(_calibration_row):
			break
	_sprite.play(PetPack.row_anim(_calibration_row))
	_label.text = "row %d · %d 幀" % [_calibration_row, _pack.row_frame_counts[_calibration_row]]
