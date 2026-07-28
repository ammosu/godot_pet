extends Node2D

## Composition root: owns the window, the body, and the brain, and turns raw
## mouse input into EventBus signals. Deliberately holds no behaviour of its own.

## How far the mouse must travel before a click counts as a drag.
const DRAG_THRESHOLD := 4.0

## Menu ids above these offsets select an installed pet pack / a body size /
## an LLM backend.
const PET_ID_BASE := 100
const SIZE_BASE := 200
const PROVIDER_BASE := 300

## Multipliers on the display scale. Pixel art prefers integers, but on a 2x
## display the odd ones land on a whole physical pixel often enough to look fine.
const SIZE_CHOICES: Array[Dictionary] = [
	{"label": "小", "factor": 0.5},
	{"label": "中", "factor": 0.75},
	{"label": "大", "factor": 1.0},
	{"label": "特大", "factor": 1.5},
]
const DEFAULT_SIZE_FACTOR := 0.75

## The mood the model reports -> the animation to play while it talks.
const EMOTION_STATES := {
	&"neutral": &"talk",
	&"happy": &"happy",
	&"excited": &"excited",
	&"sad": &"sad",
	&"greeting": &"wave",
	&"sleepy": &"sleep",
}

const OPENAI_KEY := "OPENAI_API_KEY"

## Where the sprite packs come from. No artwork ships with this project — see
## pets/pet_pack.gd for why.
const PET_GALLERY_URL := "https://codex-pets.net/"

enum MenuId {
	FALLBACK, GET_PETS, FEED, NUDGES, SPEAK, ROAM, CALIBRATE, RECENTRE,
	SET_KEY, MEMORY, LOOK, QUIT,
}

@onready var _window_ctl: WindowController = $WindowController
@onready var _brain: PetBrain = $Brain
@onready var _visual: PetVisual = $Visual
@onready var _chat: ChatPanel = $Chat
@onready var _menu: PopupMenu = $Menu
@onready var _consent: ConfirmationDialog = $Consent
@onready var _memory: MemoryPanel = $Memory

var _installed_pets := PackedStringArray()
## Submenus, kept between rebuilds — PopupMenu.clear() empties the items but
## leaves child nodes alone, so these are created once and refilled.
var _submenus := {}
## Which menu each item id ended up in, so a checkbox can be ticked in place
## without hunting through the tree for it.
var _item_menus := {}
var _size_factor := DEFAULT_SIZE_FACTOR
## The pet's silhouette relative to where it stands. Measured only when the pet
## itself changes, so re-pushing the mask stays cheap.
var _pet_shape := PackedVector2Array()
## The same silhouette in viewport pixels, and its bounding box — what the mask
## and the chat panel work in.
var _pet_polygon := PackedVector2Array()
var _pet_box := Rect2()
var _pressed := false
var _dragging := false
var _press_pos := Vector2i.ZERO
var _grab_offset := Vector2i.ZERO


func _ready() -> void:
	_size_factor = float(Config.get_value("pet", "size_factor", DEFAULT_SIZE_FACTOR))
	_layout_visual()
	_load_selected_pack()
	_style_menu()
	_build_menu()
	_memory.memories_changed.connect(_on_memories_changed)

	_brain.state_changed.connect(_on_brain_state)
	_brain.facing_changed.connect(_visual.set_facing)
	_brain.set_roaming(bool(Config.get_value("pet", "roaming", true)))

	EventBus.pet_grabbed.connect(_on_grabbed)
	EventBus.pet_released.connect(_on_released)
	EventBus.pet_tapped.connect(_on_tapped)
	# How much of the window is on screen changes as the pet walks, and the chat
	# UI has to stay inside it.
	EventBus.pet_moved.connect(_on_pet_moved)

	_chat.submitted.connect(_on_chat_submitted)
	_chat.secret_submitted.connect(_on_secret_submitted)
	_chat.input_toggled.connect(_on_input_toggled)
	_chat.bubble_hidden.connect(_on_bubble_hidden)
	EventBus.reply_chunk.connect(_on_reply_chunk)
	EventBus.reply_finished.connect(_on_reply_finished)
	EventBus.reply_failed.connect(_on_reply_failed)
	EventBus.emotion_changed.connect(_on_emotion_changed)
	EventBus.pet_nudged.connect(_on_pet_nudged)
	EventBus.screen_look_requested.connect(_on_screen_look_requested)
	_setup_consent_dialog()

	# Only worth ticking where the mask clips rendering; elsewhere the bubble is
	# outside it by design and moving is free.
	set_process(WindowController.passthrough_clips_rendering())
	# The bubble decides its own size and position in its _process; ours reads the
	# result. Without this the mask trails it by a frame, which shows up as the
	# growing edge of a streaming reply being shaved off.
	_chat.process_priority = -1

	# Park last: it moves the window, and _on_pet_moved has to be listening for
	# the chat UI to learn how much of the window ended up on screen.
	_window_ctl.park_at_default_spot()
	_brain.setup(_window_ctl)
	_warn_if_keyless()


## The bubble grows as the reply types itself out and shifts as the pet walks, so
## a mask that clips rendering has to follow it. set_hit_region() drops a region
## that hasn't actually changed, so a still bubble costs nothing.
func _process(_delta: float) -> void:
	if _chat.is_showing():
		_refresh_mask()


## An exported build can't see the project's .env, so a machine that works fine
## from source silently drops to canned replies once packaged. Say so rather
## than letting it look broken.
func _warn_if_keyless() -> void:
	if LLMService.get_provider_name() != "mock" or Config.has_secret(OPENAI_KEY):
		return
	await get_tree().create_timer(2.0).timeout
	_on_pet_nudged("neutral", "我還沒有 API key，現在只會講罐頭台詞。右鍵選單可以設定。")


## Centre the pet in the window and match the display's DPI scale, so it looks
## the same physical size on a Retina and a non-Retina screen, then even out how
## much of its cell this particular pack's character fills, then apply the user's
## chosen body size on top.
func _layout_visual() -> void:
	_visual.scale = Vector2.ONE * _window_ctl.get_ui_scale() \
		* _visual.get_pack_scale() * _size_factor
	_visual.position = _window_ctl.get_window_anchor()


## Measure the visual's silhouette, hand it to the window and the chat panel, and
## push the click-through mask. Measured relative to the pet rather than through
## the visual's full transform, because where the pet stands in the window is no
## longer fixed; _place_pet_shape() converts to the viewport pixels DisplayServer
## expects.
func _refresh_hit_region() -> void:
	_pet_shape = PackedVector2Array()
	for p in _visual.get_hit_polygon():
		_pet_shape.append(p * _visual.scale)
	_window_ctl.set_content_bounds(_bounding_box(_pet_shape))

	_place_pet_shape()
	_chat.configure(_window_ctl.get_ui_scale(), _window_ctl.get_window_size(), _pet_box)
	_chat.set_safe_area(_window_ctl.get_visible_area())
	_refresh_mask()


## Put the measured silhouette where the pet is currently standing. Split from
## measuring it because the pet can move without changing: where the window
## manager won't let the window hang off the desktop edge, the last stretch into
## the corner is the pet sliding across the window instead.
func _place_pet_shape() -> void:
	var anchor := _window_ctl.get_window_anchor()
	_pet_polygon = PackedVector2Array()
	for p in _pet_shape:
		_pet_polygon.append(p + anchor)
	_pet_box = _bounding_box(_pet_polygon)


## Just the mask. Split out because where it clips rendering it has to keep up
## with the bubble frame by frame, and the rest of the work above — restyling the
## bubble, relaying out the input — must not run every frame.
func _refresh_mask() -> void:
	# Where the mask only shapes input, the bubble is display-only and can stay
	# click-through; only the input has to be reachable. Where it also clips
	# rendering, everything the panel draws has to be inside it or the pet talks
	# in an invisible bubble.
	var extra := _chat.get_chrome_rect() if WindowController.passthrough_clips_rendering() \
		else _chat.get_input_rect()

	# Passthrough takes a single polygon, so a disjoint pet-plus-UI region isn't
	# expressible: fall back to one box around both.
	var points := _pet_polygon
	if extra.has_area():
		points = _rect_points(_pet_box.merge(extra))
	_window_ctl.set_hit_region(points)


func _bounding_box(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var box := Rect2(points[0], Vector2.ZERO)
	for p in points:
		box = box.expand(p)
	return box


func _rect_points(box: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		box.position,
		Vector2(box.end.x, box.position.y),
		box.end,
		Vector2(box.position.x, box.end.y),
	])


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
	# The pack carries its own size correction, so the scale has to be reapplied
	# before anything is measured off the visual.
	_layout_visual()
	_refresh_hit_region()
	Config.set_value("pet", "id", pack.id if pack != null else "")


# --- Brain --------------------------------------------------------------------

func _on_brain_state(state: StringName) -> void:
	# The brain's "drag" isn't an animation any pack provides; reuse idle.
	_visual.play_state(&"idle" if state == &"drag" else state)
	EventBus.pet_activity_changed.emit(state)


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
	# Being picked up drops the brain out of TALK, so without this the pet strolls
	# off the moment it's put down — dragging the field the user is typing into
	# along with it.
	if _chat.is_input_open() or _chat.is_showing():
		_brain.on_talk_started()


func _on_tapped() -> void:
	_brain.on_tapped()
	var tween := create_tween()
	tween.tween_method(_visual.set_squash, 0.12, 0.0, 0.25) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_chat.toggle_input()


# --- Conversation -------------------------------------------------------------

## Moving changes how much of the window is on screen, and the chat UI is laid
## out inside that slice — so walking towards a screen edge slides the bubble and
## the input sideways *within* the window.
##
## The mask has to follow them. It doesn't get that for free: _process only
## refreshes it while a bubble is up, so an open input would keep the region it
## had when it opened, and where the mask clips rendering that region shears off
## whichever side the field just moved towards. Dragging the pet is the reliable
## way to see it — a drag also drops the brain out of TALK, so the pet then walks
## off with the input still open and the stale mask trailing behind.
##
## Cheap to call on every walk step: set_hit_region() drops a region identical to
## the one already pushed, which is the common case.
func _on_pet_moved(_screen_position: Vector2i) -> void:
	# Where the window has run out of room to travel, the pet carries on *inside*
	# it, so the sprite and everything measured off it move too. An ordinary walk
	# step leaves the anchor alone, which keeps this as cheap as it was.
	if _visual.position != _window_ctl.get_window_anchor():
		_layout_visual()
		_place_pet_shape()
		_chat.configure(_window_ctl.get_ui_scale(), _window_ctl.get_window_size(), _pet_box)
	_chat.set_safe_area(_window_ctl.get_visible_area())
	_refresh_mask()


func _on_input_toggled(open: bool) -> void:
	# The input needs clicks, so the passthrough mask has to grow to include it.
	_refresh_hit_region()
	if open:
		_brain.on_talk_started()
	elif not _chat.is_showing():
		_brain.on_talk_ended()


func _on_chat_submitted(text: String) -> void:
	_chat.begin_reply()
	_brain.on_talk_started()
	EventBus.user_said.emit(text)


func _on_reply_chunk(text: String) -> void:
	_chat.append_reply(text)


## Hold the mood for the whole reply; it reads better than flicking back to a
## neutral talking loop halfway through a sentence.
func _on_emotion_changed(emotion: String) -> void:
	_visual.play_state(EMOTION_STATES.get(StringName(emotion), &"talk"))


func _on_reply_finished(_full_text: String) -> void:
	_chat.end_reply()


func _on_reply_failed(message: String) -> void:
	_chat.show_notice("（我剛剛斷線了：%s）" % message)


## The pet speaking up on its own. Same presentation as a reply, but the text is
## canned rather than generated — see nudger.gd for why.
func _on_pet_nudged(emotion: String, text: String) -> void:
	if _chat.is_showing() or _chat.is_input_open():
		return
	_brain.on_talk_started()
	_chat.begin_reply()
	_on_emotion_changed(emotion)
	_chat.append_reply(text)
	_chat.end_reply()
	LLMService.note_pet_said(text)


## Wait for the bubble to clear rather than for the stream to end — the text is
## still typing itself out for a while after the last token lands.
func _on_bubble_hidden() -> void:
	# _process stops tracking the bubble the moment it's gone, so the mask it
	# left behind has to be shrunk back here.
	_refresh_mask()
	if not _chat.is_input_open():
		_brain.on_talk_ended()


# --- Menu ---------------------------------------------------------------------

## The menu is a native OS window (subwindow embedding is off), and Godot sizes
## native windows in physical pixels — so the stock theme renders undersized on
## anything above 100%. Scale the theme rather than the window, so reset_size()
## still computes a min size that fits.
func _style_menu() -> void:
	_menu.theme = PetStyle.menu_theme(_window_ctl.get_ui_scale())


## Reused between rebuilds. Submenus have to exist as child nodes before
## add_submenu_node_item() can point at them, and the theme doesn't reach a
## popup that isn't parented yet, so it's set here.
func _submenu(key: String) -> PopupMenu:
	if _submenus.has(key):
		var existing: PopupMenu = _submenus[key]
		existing.clear()
		return existing
	var menu := PopupMenu.new()
	menu.name = key
	menu.theme = _menu.theme
	menu.id_pressed.connect(_on_menu_pressed)
	_menu.add_child(menu)
	_submenus[key] = menu
	return menu


## Four groups behind submenus, then the handful of things worth reaching in one
## click. Flat, the menu ran to twenty rows — every setting the app has, at the
## same weight as "餵食", which is the one people actually came for.
func _build_menu() -> void:
	_menu.clear()
	_item_menus.clear()
	var current: PetPack = _visual.get_pack()

	_menu.add_submenu_node_item("造型", _build_looks_menu(current))
	_menu.add_submenu_node_item("大小", _build_size_menu())
	_menu.add_submenu_node_item("語言模型", _build_model_menu())
	_menu.add_submenu_node_item("行為", _build_behaviour_menu(current))

	_menu.add_separator()
	_menu.add_item("餵食", MenuId.FEED)
	_menu.add_item("看一下我的螢幕…", MenuId.LOOK)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.LOOK), not VisionService.is_supported())
	_menu.add_item("回到角落", MenuId.RECENTRE)
	_menu.add_item("記憶與資料…", MenuId.MEMORY)

	_menu.add_separator()
	_menu.add_item("結束", MenuId.QUIT)

	_index_items(_menu)
	if not _menu.id_pressed.is_connected(_on_menu_pressed):
		_menu.id_pressed.connect(_on_menu_pressed)


func _build_looks_menu(current: PetPack) -> PopupMenu:
	var menu := _submenu("Looks")
	var current_id := current.id if current != null else ""
	for i in _installed_pets.size():
		var pet_id := _installed_pets[i]
		menu.add_radio_check_item(pet_id, PET_ID_BASE + i)
		menu.set_item_checked(menu.get_item_index(PET_ID_BASE + i), pet_id == current_id)
	menu.add_radio_check_item("預設造型", MenuId.FALLBACK)
	menu.set_item_checked(menu.get_item_index(MenuId.FALLBACK), current_id.is_empty())
	menu.add_separator()
	menu.add_item("找更多造型…", MenuId.GET_PETS)
	if _installed_pets.is_empty():
		menu.add_separator("裝好後再開一次選單就會出現")
	_index_items(menu)
	return menu


func _build_size_menu() -> PopupMenu:
	var menu := _submenu("Size")
	for i in SIZE_CHOICES.size():
		var choice := SIZE_CHOICES[i]
		menu.add_radio_check_item(choice["label"], SIZE_BASE + i)
		menu.set_item_checked(menu.get_item_index(SIZE_BASE + i),
			is_equal_approx(float(choice["factor"]), _size_factor))
	_index_items(menu)
	return menu


func _build_model_menu() -> PopupMenu:
	var menu := _submenu("Model")
	var providers := LLMService.list_providers()
	for i in providers.size():
		var provider := providers[i]
		menu.add_radio_check_item(LLMService.provider_label(provider), PROVIDER_BASE + i)
		menu.set_item_checked(menu.get_item_index(PROVIDER_BASE + i),
			provider == LLMService.get_provider_name())
	menu.add_separator()
	menu.add_item(_api_key_label(), MenuId.SET_KEY)
	_index_items(menu)
	return menu


func _build_behaviour_menu(current: PetPack) -> PopupMenu:
	var menu := _submenu("Behaviour")
	# Four switches people flip together — closing the menu after each one turns
	# a ten-second job into four trips.
	menu.hide_on_checkable_item_selection = false
	menu.add_check_item("主動說話", MenuId.NUDGES)
	menu.set_item_checked(menu.get_item_index(MenuId.NUDGES), Nudger.is_enabled())
	menu.add_check_item(_voice_label(), MenuId.SPEAK)
	menu.set_item_checked(menu.get_item_index(MenuId.SPEAK), TTSService.is_enabled())
	menu.set_item_disabled(menu.get_item_index(MenuId.SPEAK), not TTSService.is_available())
	menu.add_check_item("自由走動", MenuId.ROAM)
	menu.set_item_checked(menu.get_item_index(MenuId.ROAM), _brain.is_roaming())
	menu.add_separator()
	menu.add_check_item("校準動畫列", MenuId.CALIBRATE)
	menu.set_item_disabled(menu.get_item_index(MenuId.CALIBRATE), current == null)
	menu.set_item_checked(menu.get_item_index(MenuId.CALIBRATE), _visual.is_calibrating())
	_index_items(menu)
	return menu


func _index_items(menu: PopupMenu) -> void:
	for i in menu.item_count:
		var id := menu.get_item_id(i)
		if id >= 0:
			_item_menus[id] = menu


## Tick a checkbox wherever it ended up living.
func _set_checked(id: int, on: bool) -> void:
	var menu: PopupMenu = _item_menus.get(id)
	if menu == null:
		return
	var index := menu.get_item_index(id)
	if index >= 0:
		menu.set_item_checked(index, on)


func _open_menu() -> void:
	# Packs are installed by an external CLI while the app is running, so rescan
	# on every open rather than making the user restart to see a new pet.
	var found := PetPack.list_installed()
	if found != _installed_pets:
		_installed_pets = found
		_build_menu()
	_menu.reset_size()
	_menu.popup(Rect2i(DisplayServer.mouse_get_position(), _menu.size))


func _on_menu_pressed(id: int) -> void:
	if id >= PROVIDER_BASE:
		LLMService.select_provider(LLMService.list_providers()[id - PROVIDER_BASE])
		_build_menu()
		return
	if id >= SIZE_BASE:
		_set_size_factor(float(SIZE_CHOICES[id - SIZE_BASE]["factor"]))
		return
	if id >= PET_ID_BASE:
		_switch_pack(_installed_pets[id - PET_ID_BASE])
		return
	match id:
		MenuId.FALLBACK:
			_switch_pack("")
		MenuId.GET_PETS:
			OS.shell_open(PET_GALLERY_URL)
		MenuId.FEED:
			_feed()
		MenuId.NUDGES:
			_toggle_nudges()
		MenuId.SPEAK:
			_toggle_speech()
		MenuId.ROAM:
			_toggle_roaming()
		MenuId.CALIBRATE:
			_toggle_calibration()
		MenuId.RECENTRE:
			_window_ctl.park_at_default_spot()
			_brain.set_home_here()
		MenuId.SET_KEY:
			_ask_for_api_key()
		MenuId.LOOK:
			EventBus.screen_look_requested.emit(VisionService.DEFAULT_QUESTION, true)
		MenuId.MEMORY:
			_memory.open(_window_ctl.get_ui_scale())
		MenuId.QUIT:
			get_tree().quit()


func _api_key_label() -> String:
	var where := Config.secret_backend_name()
	var suffix := "存進 %s" % where if not where.is_empty() else "無安全儲存，會存成明文"
	return "%s OpenAI API key（%s）" \
		% ["更換" if Config.has_secret(OPENAI_KEY) else "設定", suffix]


func _ask_for_api_key() -> void:
	_chat.ask_for_secret("貼上 OpenAI API key，Enter 儲存")


func _on_secret_submitted(value: String) -> void:
	# Almost always a stray character from a bad paste — API keys are ASCII, and
	# the Keychain can't round-trip anything else. See SecretStore.write().
	if not SecretStore.is_ascii(value):
		_on_pet_nudged("sad", "這個 key 有奇怪的字元，是不是貼到多餘的東西了？")
		return

	var secured := Config.set_secret(OPENAI_KEY, value)
	# A key is the only thing standing between mock and the real model, so adopt
	# it right away rather than making the user go back to the menu.
	if LLMService.get_provider_name() != "openai":
		LLMService.select_provider("openai")
	_build_menu()

	var note := "收到！鑰匙我幫你收在 %s 了。" % Config.secret_backend_name()
	if not secured:
		note = "存好了，不過這台機器沒有安全儲存，我只能放在設定檔裡。"
	_on_pet_nudged("happy", note)


# --- Looking at the screen ----------------------------------------------------

## Screenshots are the one thing here that can hand something private to a
## third party, so nothing is captured until the user says so. "每次都可以"
## exists because being asked every time is how people learn to click through
## the prompt without reading it.
const CONSENT_ALWAYS := "always"

var _pending_look := {}


func _setup_consent_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_consent.title = "看一下你的螢幕"
	_consent.dialog_text = ""
	_consent.exclusive = false
	# Native window, laid out in physical pixels, so the stock theme comes out
	# undersized. A Theme on the dialog reaches the label and the buttons alike;
	# per-node font overrides only reach the node they're on.
	_consent.theme = PetStyle.dialog_theme(scale)
	_consent.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# "好" and "不要" said nothing about what was about to happen. Name the action
	# in the button, so the dialog is still readable to someone who skipped the
	# paragraph — which is most people, most of the time.
	_consent.ok_button_text = "好，看這一次"
	_consent.cancel_button_text = "不要"
	var ok := _consent.get_ok_button()
	var primary := PetStyle.primary_button_styles(scale)
	for state in primary:
		ok.add_theme_stylebox_override(state, primary[state])
	ok.add_theme_color_override("font_color", PetStyle.INK)
	ok.add_theme_color_override("font_hover_color", PetStyle.INK)
	ok.add_theme_color_override("font_pressed_color", PetStyle.INK)

	# Standing consent is the one answer here that can't be taken back by simply
	# not clicking it again, so it's the quietest thing in the window.
	var always := _consent.add_button("以後都不用問我", false, "always")
	PetStyle.make_ghost_button(always, scale)

	_consent.confirmed.connect(func() -> void: _resolve_look(true, false))
	_consent.canceled.connect(func() -> void: _resolve_look(false, false))
	_consent.custom_action.connect(func(action: StringName) -> void:
		if action == &"always":
			_consent.hide()
			_resolve_look(true, true))


## The old wording — "畫面會傳給語言模型" — left the three things people actually
## want to know unanswered: how much of the screen, to whom, and for how long.
func _on_screen_look_requested(question: String, record_question: bool) -> void:
	_pending_look = {"question": question, "record": record_question}
	if Config.get_value("vision", "consent", "") == CONSENT_ALWAYS:
		_resolve_look(true, false)
		return

	var lines := PackedStringArray()
	# A look the user asked for by typing: show them which question triggered it,
	# because a dialog appearing out of a normal sentence is startling otherwise.
	if not record_question:
		lines.append("你剛剛問：「%s」\n" % question.strip_edges())
	lines.append("要回答這個，我得把整個螢幕拍成一張圖，傳給 %s 讀。"
		% LLMService.provider_label(LLMService.get_provider_name()))
	lines.append("")
	lines.append("・只有這一次，我不會在背景一直看")
	lines.append("・看到的內容不會寫進我的長期記憶")
	lines.append("・拍的那一瞬間，我會先把自己藏起來")
	_consent.dialog_text = "\n".join(lines)
	_consent.reset_size()
	_consent.popup_centered()


func _resolve_look(allowed: bool, remember: bool) -> void:
	var pending := _pending_look
	_pending_look = {}
	if pending.is_empty():
		return
	if remember:
		Config.set_value("vision", "consent", CONSENT_ALWAYS)
	if allowed:
		VisionService.look(str(pending["question"]), bool(pending["record"]))
	elif bool(pending["record"]):
		# Nobody is waiting on an answer — this came from the menu.
		_on_pet_nudged("neutral", "好啦，那我不看。")
	else:
		# The question is already sitting in history unanswered. Leaving it there
		# would look like the pet ignored it, so answer it blind instead.
		LLMService.answer_without_looking()


## Memory that can't be inspected is memory you can't trust, and a pet quietly
## carrying a wrong fact about you is worse than one that forgets. The list lives
## in its own window (ui/memory_panel.gd) rather than in the bubble, which fades
## on a timer, or in the menu, which can't scroll.
func _on_memories_changed() -> void:
	if not MemoryStore.has_memories():
		_on_pet_nudged("sad", "好……全部清空了，我們重新認識吧。")


func _feed() -> void:
	PetState.feed()
	_on_pet_nudged("happy", "謝謝！這個好吃。")


## Naming the voice saves adding a whole picker just to see which one is in use.
func _voice_label() -> String:
	if not TTSService.is_available():
		return "說話出聲（這台機器沒有語音）"
	return "說話出聲（%s）" % TTSService.get_voice_name()


func _toggle_speech() -> void:
	TTSService.set_enabled(not TTSService.is_enabled())
	_set_checked(MenuId.SPEAK, TTSService.is_enabled())


func _toggle_nudges() -> void:
	var enabled := not Nudger.is_enabled()
	Nudger.set_enabled(enabled)
	_set_checked(MenuId.NUDGES, enabled)


func _toggle_roaming() -> void:
	var roaming := not _brain.is_roaming()
	_brain.set_roaming(roaming)
	Config.set_value("pet", "roaming", roaming)
	_set_checked(MenuId.ROAM, roaming)


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
	_set_checked(MenuId.CALIBRATE, _visual.is_calibrating())
