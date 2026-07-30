extends Node2D
class_name GamePet

## The pet, as the games draw it.
##
## Several games now put the same character on screen, and the awkward part is not
## drawing it — it is that the pack declares nothing. Which row is "happy", how
## much of its cell the character fills, and what to play when a pack has no art
## for a state are all decided by PetVisual for the desktop pet, and all of them
## have to come out the same here or the pet in the game is visibly a different
## size or wearing the wrong expression from the one on the desktop.
##
## So this takes the **resolved** row map (PetVisual.state_rows()) rather than
## working it out again, and fits the character by measuring the idle row's
## height exactly as PetVisual does.
##
## Like PetVisual, one write point: facing, fit and squash all land on the sprite
## in _apply() and nowhere else. They used to be written by whichever setter ran
## last, which is how the facing flip silently undid the squash.

## How tall the character is drawn, in design px, before the display scale.
const DEFAULT_HEIGHT := 96.0

var _sprite: AnimatedSprite2D = null
var _blob: FallbackBlob = null
var _rows := {}
var _row := -1
## Per-pack fit factor and cell-padding correction — PetVisual's two corrections,
## made here for the same reasons.
var _fit := 1.0
var _base_offset := Vector2.ZERO
var _half := 20.0
var _height := 60.0
var _facing := 1
var _squash := 0.0
var _state := &"idle"


## Pass a null pack only for the procedural emergency body. Safe to call again:
## the game window is reopened with whatever pack is current, which may not be
## the one it was built with last time.
func build(ui_scale: float, pack: PetPack, rows: Dictionary,
		design_height := DEFAULT_HEIGHT) -> void:
	if _sprite != null:
		_sprite.queue_free()
		_sprite = null
	if _blob != null:
		_blob.queue_free()
		_blob = null
	_rows = rows
	_row = -1
	_squash = 0.0
	_facing = 1

	var target := design_height * ui_scale
	if pack == null:
		_blob = FallbackBlob.new()
		# The blob puts its ears above its radius and its chin at it, so the
		# silhouette runs a little over two radii tall.
		_blob.radius = target / 2.18
		_height = target
		_half = _blob.radius * 0.94
		add_child(_blob)
		return

	var idle_row := int(_rows.get(&"idle", 0))
	var rest := pack.rect_for_row(idle_row)
	_sprite = AnimatedSprite2D.new()
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR \
		if pack.smooth_filter else CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.sprite_frames = pack.frames
	# Fit the character, never the cell. Packs pad their cells by wildly
	# different amounts — 76% to 95% of the height across the four to hand — so
	# sizing off the cell makes the pet in here a different size from the one on
	# the desktop, for no reason a player could see.
	_fit = target / maxf(1.0, float(rest.size.y))
	_base_offset = Vector2(pack.cell_size) * 0.5 - Vector2(rest.get_center())
	_height = float(rest.size.y) * _fit
	_half = float(rest.size.x) * _fit * 0.5
	add_child(_sprite)
	_play(idle_row)
	_apply()


## Half the drawn character's width — what a game measures its hit tests against.
func half_width() -> float:
	return _half


func height() -> float:
	return _height


## Where the feet are, given where the character's centre has been put.
func stand_on(ground_y: float, x: float) -> void:
	if _sprite != null:
		_sprite.position = Vector2(x, ground_y - _height * 0.5)
	elif _blob != null:
		_blob.position = Vector2(x, ground_y - _blob.radius)


func set_state(state: StringName) -> void:
	if state == _state:
		return
	_state = state
	if _sprite != null:
		_play(int(_rows.get(state, _rows.get(&"idle", 0))))


func set_facing(facing: int) -> void:
	if facing == 0 or facing == _facing:
		return
	_facing = facing
	_apply()


func set_squash(amount: float) -> void:
	if is_equal_approx(amount, _squash):
		return
	_squash = amount
	_apply()


func _play(row: int) -> void:
	if _sprite == null or row == _row:
		return
	_row = row
	_sprite.play(PetPack.row_anim(row))


func _apply() -> void:
	if _blob != null:
		_blob.set_squash(_squash)
		return
	if _sprite == null:
		return
	_sprite.flip_h = _facing < 0
	# flip_h mirrors inside the cell, so the padding correction has to flip with
	# it or the character swings sideways — same trap as PetVisual._apply_pose().
	_sprite.offset = Vector2(
		-_base_offset.x if _sprite.flip_h else _base_offset.x, _base_offset.y)
	_sprite.scale = Vector2(_fit * (1.0 + _squash), _fit * (1.0 - _squash))
