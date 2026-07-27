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
	SET_KEY, RECALL, FORGET, QUIT,
}

@onready var _window_ctl: WindowController = $WindowController
@onready var _brain: PetBrain = $Brain
@onready var _visual: PetVisual = $Visual
@onready var _chat: ChatPanel = $Chat
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

	# Park last: it moves the window, and _on_pet_moved has to be listening for
	# the chat UI to learn how much of the window ended up on screen.
	_window_ctl.park_at_default_spot()
	_brain.setup(_window_ctl)
	_warn_if_keyless()


## An exported build can't see the project's .env, so a machine that works fine
## from source silently drops to canned replies once packaged. Say so rather
## than letting it look broken.
func _warn_if_keyless() -> void:
	if LLMService.get_provider_name() != "mock" or Config.has_secret(OPENAI_KEY):
		return
	await get_tree().create_timer(2.0).timeout
	_on_pet_nudged("neutral", "我還沒有 API key，現在只會講罐頭台詞。右鍵選單可以設定。")


## Centre the pet in the window and match the display's DPI scale, so it looks
## the same physical size on a Retina and a non-Retina screen, then apply the
## user's chosen body size on top.
func _layout_visual() -> void:
	_visual.scale = Vector2.ONE * _window_ctl.get_ui_scale() * _size_factor
	_visual.position = _window_ctl.get_window_anchor()


## Push the visual's silhouette to the window as the click-through mask, and
## point the bubble at the top of the pet's head. The visual's transform maps its
## local space to viewport pixels, which is what DisplayServer expects.
func _refresh_hit_region() -> void:
	var points := PackedVector2Array()
	for p in _visual.get_hit_polygon():
		points.append(_visual.transform * p)

	var pet_box := _bounding_box(points)
	_window_ctl.set_content_bounds(pet_box)
	_chat.configure(_window_ctl.get_ui_scale(), _window_ctl.get_window_size(), pet_box)
	_chat.set_safe_area(_window_ctl.get_visible_area())

	# Passthrough takes a single polygon, so a disjoint pet-plus-input region
	# isn't expressible: fall back to one box around both while typing.
	var input_box := _chat.get_input_rect()
	if input_box.has_area():
		points = _rect_points(pet_box.merge(input_box))
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


func _on_tapped() -> void:
	_brain.on_tapped()
	var tween := create_tween()
	tween.tween_method(_visual.set_squash, 0.12, 0.0, 0.25) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_chat.toggle_input()


# --- Conversation -------------------------------------------------------------

func _on_pet_moved(_screen_position: Vector2i) -> void:
	_chat.set_safe_area(_window_ctl.get_visible_area())


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
	if not _chat.is_input_open():
		_brain.on_talk_ended()


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
	_menu.add_item("找更多造型…", MenuId.GET_PETS)
	if _installed_pets.is_empty():
		_menu.add_separator("裝好後直接再開這個選單就會出現")

	_menu.add_separator("大小")
	for i in SIZE_CHOICES.size():
		var choice := SIZE_CHOICES[i]
		_menu.add_radio_check_item(choice["label"], SIZE_BASE + i)
		_menu.set_item_checked(_menu.get_item_index(SIZE_BASE + i),
			is_equal_approx(float(choice["factor"]), _size_factor))

	_menu.add_separator("語言模型")
	var providers := LLMService.list_providers()
	for i in providers.size():
		var provider := providers[i]
		_menu.add_radio_check_item(LLMService.provider_label(provider), PROVIDER_BASE + i)
		_menu.set_item_checked(_menu.get_item_index(PROVIDER_BASE + i),
			provider == LLMService.get_provider_name())
	_menu.add_item(_api_key_label(), MenuId.SET_KEY)
	_menu.add_item("你記得我什麼？", MenuId.RECALL)
	_menu.add_item("全部忘掉", MenuId.FORGET)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.FORGET), not MemoryStore.has_memories())

	_menu.add_separator()
	_menu.add_item("餵食", MenuId.FEED)
	_menu.add_check_item("主動說話", MenuId.NUDGES)
	_menu.set_item_checked(_menu.get_item_index(MenuId.NUDGES), Nudger.is_enabled())
	_menu.add_check_item(_voice_label(), MenuId.SPEAK)
	_menu.set_item_checked(_menu.get_item_index(MenuId.SPEAK), TTSService.is_enabled())
	_menu.set_item_disabled(_menu.get_item_index(MenuId.SPEAK), not TTSService.is_available())
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
		MenuId.RECALL:
			_recall()
		MenuId.FORGET:
			_forget()
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


## Memory that can't be inspected is memory you can't trust, and a pet quietly
## carrying a wrong fact about you is worse than one that forgets.
func _recall() -> void:
	var facts := MemoryStore.facts()
	if facts.is_empty():
		_on_pet_nudged("neutral", "還沒記住什麼欸，多跟我講講話嘛。")
		return
	var lines := PackedStringArray()
	for fact in facts:
		lines.append("· %s" % fact)
	_on_pet_nudged("happy", "我記得這些：\n%s" % "\n".join(lines))


func _forget() -> void:
	MemoryStore.forget_all()
	_build_menu()
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
	_menu.set_item_checked(_menu.get_item_index(MenuId.SPEAK), TTSService.is_enabled())


func _toggle_nudges() -> void:
	var enabled := not Nudger.is_enabled()
	Nudger.set_enabled(enabled)
	_menu.set_item_checked(_menu.get_item_index(MenuId.NUDGES), enabled)


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
