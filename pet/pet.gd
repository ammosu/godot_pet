extends Node2D

## Composition root: owns the window, the body, and the brain, and turns raw
## mouse input into EventBus signals. Deliberately holds no behaviour of its own.

## How far the mouse must travel before a click counts as a drag.
const DRAG_THRESHOLD := 4.0

## Menu ids above these offsets select an installed pet pack / a body size.
const PET_ID_BASE := 100
const SIZE_BASE := 200

## Multipliers on the display scale. Pixel art prefers integers, but on a 2x
## display the odd ones land on a whole physical pixel often enough to look fine.
const SIZE_CHOICES: Array[Dictionary] = [
	{"label": "小", "factor": 0.5},
	{"label": "中", "factor": 0.75},
	{"label": "大", "factor": 1.0},
	{"label": "特大", "factor": 1.5},
]
const DEFAULT_SIZE_FACTOR := 0.75

enum MenuId { FALLBACK, ROAM, CALIBRATE, RECENTRE, QUIT }

@onready var _window_ctl: WindowController = $WindowController
@onready var _brain: PetBrain = $Brain
@onready var _visual: PetVisual = $Visual
@onready var _menu: PopupMenu = $Menu

var _installed_pets := PackedStringArray()
var _size_factor := DEFAULT_SIZE_FACTOR
var _pressed := false
var _dragging := false
var _press_pos := Vector2i.ZERO
var _grab_offset := Vector2i.ZERO


func _ready() -> void:
	_size_factor = float(Config.get_value("pet", "size_factor", DEFAULT_SIZE_FACTOR))
	_layout_visual()
	_load_selected_pack()
	_scale_menu_theme()
	_build_menu()
	_window_ctl.park_at_default_spot()

	_brain.state_changed.connect(_on_brain_state)
	_brain.facing_changed.connect(_visual.set_facing)
	_brain.set_roaming(bool(Config.get_value("pet", "roaming", true)))
	_brain.setup(_window_ctl)

	EventBus.pet_grabbed.connect(_on_grabbed)
	EventBus.pet_released.connect(_on_released)
	EventBus.pet_tapped.connect(_on_tapped)


## Centre the pet in the window and match the display's DPI scale, so it looks
## the same physical size on a Retina and a non-Retina screen, then apply the
## user's chosen body size on top.
func _layout_visual() -> void:
	_visual.scale = Vector2.ONE * _window_ctl.get_ui_scale() * _size_factor
	_visual.position = _window_ctl.get_window_anchor()


## Push the visual's silhouette to the window as the click-through mask. The
## visual's transform maps its local space to viewport pixels, which is what
## DisplayServer expects.
func _refresh_hit_region() -> void:
	var points := PackedVector2Array()
	for p in _visual.get_hit_polygon():
		points.append(_visual.transform * p)
	_window_ctl.set_hit_region(points)


# --- Pet packs ----------------------------------------------------------------

func _load_selected_pack() -> void:
	_installed_pets = PetPack.list_installed()
	var wanted: String = Config.get_value("pet", "id", "")
	# First run with something installed: adopt it rather than showing the blob.
	if wanted.is_empty() and not _installed_pets.is_empty():
		wanted = _installed_pets[0]
	_apply_pack(wanted)


func _apply_pack(pet_id: String) -> void:
	var pack: PetPack = null
	if not pet_id.is_empty():
		pack = PetPack.load_installed(pet_id)
		if pack == null:
			push_warning("Pet: '%s' failed to load, falling back to default art" % pet_id)
	_visual.load_pack(pack)
	_refresh_hit_region()
	Config.set_value("pet", "id", pack.id if pack != null else "")


# --- Brain --------------------------------------------------------------------

func _on_brain_state(state: StringName) -> void:
	# The brain's "drag" isn't an animation any pack provides; reuse idle.
	_visual.play_state(&"idle" if state == &"drag" else state)


# --- Input --------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_press()
			else:
				_end_press()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_open_menu()
	elif event is InputEventMouseMotion and _pressed:
		_update_drag()


func _begin_press() -> void:
	_pressed = true
	_dragging = false
	_press_pos = DisplayServer.mouse_get_position()
	_grab_offset = _press_pos - _window_ctl.get_pet_screen_position()
	_window_ctl.suspend_passthrough()


func _update_drag() -> void:
	var mouse := DisplayServer.mouse_get_position()
	if not _dragging and Vector2(mouse - _press_pos).length() > DRAG_THRESHOLD:
		_dragging = true
		EventBus.pet_grabbed.emit()
	if _dragging:
		_window_ctl.set_pet_screen_position(mouse - _grab_offset)


func _end_press() -> void:
	if not _pressed:
		return
	_pressed = false
	_window_ctl.resume_passthrough()
	if _dragging:
		_dragging = false
		EventBus.pet_released.emit()
	else:
		EventBus.pet_tapped.emit()


func _on_grabbed() -> void:
	_brain.on_grabbed()
	_visual.set_squash(-0.08)


func _on_released() -> void:
	_visual.set_squash(0.0)
	_brain.on_released()


func _on_tapped() -> void:
	_brain.on_tapped()
	var tween := create_tween()
	tween.tween_method(_visual.set_squash, 0.12, 0.0, 0.25) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# --- Menu ---------------------------------------------------------------------

## The menu is a native OS window (subwindow embedding is off), and Godot sizes
## native windows in physical pixels — so on a Retina display the default theme
## renders at half the apparent size. Scale the theme rather than the window, so
## reset_size() still computes a min size that fits.
func _scale_menu_theme() -> void:
	var s := _window_ctl.get_ui_scale()
	if is_equal_approx(s, 1.0):
		return
	_menu.add_theme_font_size_override("font_size", roundi(16.0 * s))
	_menu.add_theme_constant_override("v_separation", roundi(4.0 * s))
	_menu.add_theme_constant_override("h_separation", roundi(4.0 * s))
	_menu.add_theme_constant_override("indent", roundi(10.0 * s))
	_menu.add_theme_constant_override("item_start_padding", roundi(2.0 * s))
	_menu.add_theme_constant_override("item_end_padding", roundi(2.0 * s))
	_menu.add_theme_constant_override("icon_max_width", roundi(16.0 * s))


func _build_menu() -> void:
	_menu.clear()
	var current: PetPack = _visual.get_pack()
	var current_id := current.id if current != null else ""

	for i in _installed_pets.size():
		var pet_id := _installed_pets[i]
		_menu.add_radio_check_item(pet_id, PET_ID_BASE + i)
		_menu.set_item_checked(_menu.get_item_index(PET_ID_BASE + i), pet_id == current_id)
	_menu.add_radio_check_item("預設造型", MenuId.FALLBACK)
	_menu.set_item_checked(_menu.get_item_index(MenuId.FALLBACK), current_id.is_empty())

	if _installed_pets.is_empty():
		_menu.add_separator("用 npx codex-pets add <id> 安裝寵物")

	_menu.add_separator("大小")
	for i in SIZE_CHOICES.size():
		var choice := SIZE_CHOICES[i]
		_menu.add_radio_check_item(choice["label"], SIZE_BASE + i)
		_menu.set_item_checked(_menu.get_item_index(SIZE_BASE + i),
			is_equal_approx(float(choice["factor"]), _size_factor))

	_menu.add_separator()
	_menu.add_check_item("自由走動", MenuId.ROAM)
	_menu.set_item_checked(_menu.get_item_index(MenuId.ROAM), _brain.is_roaming())
	_menu.add_check_item("校準動畫列", MenuId.CALIBRATE)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.CALIBRATE), current == null)
	_menu.add_item("回到角落", MenuId.RECENTRE)
	_menu.add_separator()
	_menu.add_item("結束", MenuId.QUIT)

	if not _menu.id_pressed.is_connected(_on_menu_pressed):
		_menu.id_pressed.connect(_on_menu_pressed)


func _open_menu() -> void:
	_menu.reset_size()
	_menu.popup(Rect2i(DisplayServer.mouse_get_position(), _menu.size))


func _on_menu_pressed(id: int) -> void:
	if id >= SIZE_BASE:
		_set_size_factor(float(SIZE_CHOICES[id - SIZE_BASE]["factor"]))
		return
	if id >= PET_ID_BASE:
		_switch_pack(_installed_pets[id - PET_ID_BASE])
		return
	match id:
		MenuId.FALLBACK:
			_switch_pack("")
		MenuId.ROAM:
			_toggle_roaming()
		MenuId.CALIBRATE:
			_toggle_calibration()
		MenuId.RECENTRE:
			_window_ctl.park_at_default_spot()
			_brain.set_home_here()
		MenuId.QUIT:
			get_tree().quit()


func _toggle_roaming() -> void:
	var roaming := not _brain.is_roaming()
	_brain.set_roaming(roaming)
	Config.set_value("pet", "roaming", roaming)
	_menu.set_item_checked(_menu.get_item_index(MenuId.ROAM), roaming)


func _set_size_factor(factor: float) -> void:
	_size_factor = factor
	Config.set_value("pet", "size_factor", factor)
	_layout_visual()
	_refresh_hit_region()
	_build_menu()


func _switch_pack(pet_id: String) -> void:
	_visual.set_calibrating(false)
	_brain.set_paused(false)
	_apply_pack(pet_id)
	_build_menu()


## Freeze the brain while cycling rows, otherwise it keeps overriding the
## animation we're trying to look at.
func _toggle_calibration() -> void:
	var on := not _visual.is_calibrating()
	_visual.set_calibrating(on)
	_brain.set_paused(on)
	_menu.set_item_checked(_menu.get_item_index(MenuId.CALIBRATE), _visual.is_calibrating())
