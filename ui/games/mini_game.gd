extends Control
class_name MiniGame

## What every mini-game is, so GamePanel can host any of them without knowing
## which one it has.
##
## The window around a game is almost all of it: the field, the score, the record
## per difficulty, the banner before and after a run, the pet, and the rule that
## nothing in there may hold focus. Written once here and in GamePanel, a new
## game is a field and a handful of numbers.
##
## Subclasses override the small contract below. The games deliberately ask for
## different things — position in 接東西, timing in 跳過去, memory in 翻翻看,
## movement plus an opponent in 排球對決, and return angles in 敲磚塊 —
## rather than being one reflex game with several coats of paint.

## A run played to its end. `treats` is how much the pet actually ate, which only
## 接東西 can be nonzero for; it is separate from `score` because the bonus is
## worth three and because PetState cares about the food, not the points.
signal finished(score: int, treats: int)
signal score_changed(score: int)
signal started

const LEVEL_COUNT := 3
const DEFAULT_LEVEL := 1
const MISSES_ALLOWED := 3
## Design units, scaled at the point of use like everything else here.
const GROUND_INSET := 20.0

var _scale := 1.0
var _level := DEFAULT_LEVEL
var _playing := false
var _score := 0
var _treats := 0
var _misses := 0
var _elapsed := 0.0
var _field_box: StyleBoxFlat = null
var _pet: GamePet = null


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP


# --- The contract -------------------------------------------------------------
#
# Everything below is meant to be overridden. The defaults are what a game gets
# for free by saying nothing.

## Window size this game wants, in design units. A runner reads horizontally and
## a memory grid vertically; one shared size would waste most of the window for
## both.
func design_size() -> Vector2i:
	return Vector2i(440, 560)


## The lines under the title on the ready banner. Broken by hand — see
## GamePanel._build_banner() for why they must not autowrap.
func ready_hint() -> String:
	return ""


func level_labels() -> PackedStringArray:
	return PackedStringArray(["悠哉", "普通", "手忙腳亂"])


## Whether the three dots that count what got past you mean anything here.
func uses_lives() -> bool:
	return true


func pet_design_height() -> float:
	return GamePet.DEFAULT_HEIGHT


## Extra setup for games that own more than the shared player pet.
func _setup(_pack: PetPack, _rows: Dictionary) -> void:
	pass


## Per-run reset. Called on every reset(), including the one inside start().
func _prepare() -> void:
	pass


## Runs every frame the window is visible, playing or not — a pet that only
## breathes mid-run looks switched off the rest of the time. Check is_playing()
## for the parts that shouldn't tick on the banner.
func _tick(_delta: float) -> void:
	pass


## Drawn over the field box and under the lives.
func _paint() -> void:
	pass


## Keys, but only while a run is going: before one, every key that matters is
## "start", which is handled below. Return true if the key was used.
func _key_pressed(_keycode: int) -> bool:
	return false


func _pointer_moved(_pos: Vector2) -> void:
	pass


func _pointer_clicked(_pos: Vector2) -> void:
	pass


# --- Setup --------------------------------------------------------------------

## `rows` is PetVisual.state_rows(). Called on every open, because the pack can
## have been switched since the last one.
func setup(ui_scale: float, pack: PetPack, rows: Dictionary) -> void:
	_scale = ui_scale
	_field_box = PetStyle.game_field_style(_scale)
	if _pet == null:
		_pet = GamePet.new()
		add_child(_pet)
	_pet.build(_scale, pack, rows, pet_design_height())
	_setup(pack, rows)
	reset()


# --- Run state ----------------------------------------------------------------

func reset() -> void:
	_playing = false
	_score = 0
	_treats = 0
	_misses = 0
	_elapsed = 0.0
	_prepare()
	_report()
	queue_redraw()


func start() -> void:
	reset()
	_playing = true
	started.emit()
	queue_redraw()


## Abandon a run without it counting — the window was closed, or the difficulty
## was changed out from under it. Deliberately not `finish`: a score the player
## didn't play out must never reach the record.
func abandon() -> void:
	if not _playing:
		return
	_playing = false
	reset()


func is_playing() -> bool:
	return _playing


func set_level(index: int) -> void:
	var wanted := clampi(index, 0, LEVEL_COUNT - 1)
	if wanted == _level:
		return
	abandon()
	_level = wanted
	reset()


func get_level() -> int:
	return _level


func _finish() -> void:
	_playing = false
	finished.emit(_score, _treats)
	queue_redraw()


func _add_score(points: int) -> void:
	_score = maxi(0, _score + points)
	_report()


func _lose_one() -> void:
	_misses += 1
	if _misses >= MISSES_ALLOWED:
		_finish()


func _recover_one() -> void:
	_misses = maxi(0, _misses - 1)


func _report() -> void:
	score_changed.emit(_score)


func _ground_y() -> float:
	return size.y - GROUND_INSET * _scale


# --- Frame --------------------------------------------------------------------

func _process(delta: float) -> void:
	# The window stays in the tree while hidden, and so does everything in it.
	# Nothing here is worth a frame when nobody can see it.
	if not is_visible_in_tree():
		return
	if _playing:
		_elapsed += delta
	_tick(delta)
	queue_redraw()


# --- Input --------------------------------------------------------------------

## Space and Enter start a run; once one is going the same keys belong to the
## game (in 跳過去 space *is* the game). Every button in the window is
## FOCUS_NONE, so nothing upstream has swallowed the key by the time it arrives —
## and the arrow keys never turn into focus navigation, which is what would
## otherwise happen the moment someone clicked a difficulty.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if not _playing:
		if key.keycode == KEY_SPACE or key.keycode == KEY_ENTER \
				or key.keycode == KEY_KP_ENTER:
			start()
			get_viewport().set_input_as_handled()
		return
	if _key_pressed(key.keycode):
		get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null:
		_pointer_moved(motion.position)
		accept_event()
		return
	var click := event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		if _playing:
			_pointer_clicked(click.position)
		else:
			start()
		accept_event()


## Held keys are polled rather than driven from events, and gated on the window
## actually having focus. A key held as focus leaves never sends its release, so
## an event-driven version leaves the pet walking into the wall forever — and,
## worse, arrow keys pressed in whatever app you switched to would still be
## steering a game you can no longer see.
func _held_axis() -> float:
	var window := get_window()
	if window != null and not window.has_focus():
		return 0.0
	var axis := 0.0
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		axis -= 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		axis += 1.0
	return axis


# --- Drawing ------------------------------------------------------------------

func _draw() -> void:
	if _field_box != null:
		draw_style_box(_field_box, Rect2(Vector2.ZERO, size))
	_paint()
	if uses_lives():
		_draw_lives()


func _draw_ground() -> void:
	var ground := _ground_y()
	draw_line(Vector2(0.0, ground), Vector2(size.x, ground),
		PetStyle.GAME_GROUND, maxf(1.0, 2.0 * _scale))


## Spent lives stay on screen rather than disappearing, so the row says how many
## there were as well as how many are left.
func _draw_lives() -> void:
	var r := 4.0 * _scale
	var origin := Vector2(15.0 * _scale + r, 15.0 * _scale + r)
	for i in MISSES_ALLOWED:
		draw_circle(origin + Vector2(float(i) * r * 3.2, 0.0), r,
			PetStyle.GAME_LIFE_SPENT if i < _misses else PetStyle.GAME_LIFE)
