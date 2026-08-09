extends Node2D

## Composition root: owns the window, the body, and the brain, and turns raw
## mouse input into EventBus signals. Deliberately holds no behaviour of its own.

## How far the mouse must travel before a click counts as a drag.
const DRAG_THRESHOLD := 4.0

## Named so the release tween can start from the exact value _on_grabbed applies
## instead of a second -0.08 literal drifting out of sync with it.
const GRAB_SQUASH := -0.08
const TAP_BOUNCE_SQUASH := 0.12
const TAP_BOUNCE_DURATION := 0.25
## A quick punch past rest on landing, then the same elastic settle as a tap —
## just retuned larger/longer, since a drop reads as a harder impact than a poke.
const DRAG_IMPACT_SQUASH := 0.14
const DRAG_IMPACT_DURATION := 0.06
const DRAG_LANDING_DURATION := 0.28

## Menu ids above these offsets select an installed pet pack / a body size /
## an LLM backend / a mini-game / a workspace to go and work in.
##
## Every test against these in `_on_menu_pressed` is "at or above", so they must
## be checked highest-first — a workspace id at 600 also satisfies every range
## test below it.
const PET_ID_BASE := 100
const SIZE_BASE := 200
const PROVIDER_BASE := 300
const GAME_BASE := 400
const WORKSPACE_BASE := 600
const VOICE_BASE := 700

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

## Community sprite packs come from the gallery. The project-owned default uses
## the same format from res://pets/default.
const PET_GALLERY_URL := "https://codex-pets.net/"
const DEFAULT_PET_SELECTION := "__default__"

enum MenuId {
	FALLBACK, GET_PETS, FEED, NUDGES, PRESENCE, MONITOR, SPEAK, ROAM, CALIBRATE,
	RECENTRE, SET_KEY, SET_ELEVEN_KEY, SET_VOXCPM_KEY, SET_VOXCPM_URL,
	CHAT_LOG, MEMORY, OUTBOX, LOOK, WORK, ADD_SPACE, LOAD,
	RECORD, PRERENDER, REFRESH_VOICES, MODEL_SETTINGS, QUIT,
	VOICE_SETTINGS, PROMPT_DEFAULT, PROMPT_CURRENT,
}

@onready var _window_ctl: WindowController = $WindowController
@onready var _brain: PetBrain = $Brain
@onready var _visual: PetVisual = $Visual
@onready var _chat: ChatPanel = $Chat
@onready var _menu: PopupMenu = $Menu
@onready var _consent: ConfirmationDialog = $Consent
@onready var _presence_consent: ConfirmationDialog = $PresenceConsent
@onready var _work_consent: ConfirmationDialog = $WorkConsent
@onready var _work_offer: ConfirmationDialog = $WorkOffer
@onready var _dirty_warning: ConfirmationDialog = $DirtyWarning
@onready var _model_settings: ConfirmationDialog = $ModelSettings
@onready var _model_settings_current: Label = $ModelSettings/Box/Current
@onready var _model_picker: OptionButton = $ModelSettings/Box/Grid/Model
@onready var _reasoning_picker: OptionButton = $ModelSettings/Box/Grid/Reasoning
@onready var _model_settings_hint: Label = $ModelSettings/Box/Hint
@onready var _voice_settings: ConfirmationDialog = $VoiceSettings
@onready var _voice_settings_current: Label = $VoiceSettings/Box/Current
@onready var _voice_picker: OptionButton = $VoiceSettings/Box/Grid/Voice
@onready var _prompt_settings: ConfirmationDialog = $PromptSettings
@onready var _prompt_settings_current: Label = $PromptSettings/Box/Current
@onready var _prompt_override: CheckBox = $PromptSettings/Box/Override
@onready var _prompt_editor: TextEdit = $PromptSettings/Box/Editor
@onready var _prompt_settings_hint: Label = $PromptSettings/Box/Hint
## Where every key and the service address are typed. One window reused rather
## than four, because they differ only in what they are called and whether the
## characters are hidden — and four near-identical dialogs is four places for a
## theme or a button style to drift.
@onready var _secret_entry: ConfirmationDialog = $SecretEntry
@onready var _secret_field: LineEdit = $SecretEntry/Box/Field
## The explanation, as a label of our own rather than `dialog_text`.
## **`AcceptDialog` gives every Control child the same content rect**, so the
## built-in label and the field were drawn on top of each other — measured on
## screen, the blurb struck through the middle of the text being typed. One child
## is the only arrangement that lays out, so both live in a VBox.
@onready var _secret_blurb: Label = $SecretEntry/Box/Blurb
@onready var _codex_login: ConfirmationDialog = $CodexLogin
@onready var _memory: MemoryPanel = $Memory
@onready var _chat_log: ChatLogPanel = $ChatLog
@onready var _game: GamePanel = $Game
@onready var _outbox: OutboxPanel = $Outbox
@onready var _work: WorkPanel = $Work
@onready var _monitor: MonitorPanel = $Monitor

var _installed_pets := PackedStringArray()
## Submenus, kept between rebuilds — PopupMenu.clear() empties the items but
## leaves child nodes alone, so these are created once and refilled.
var _submenus := {}
## Which menu each item id ended up in, so a checkbox can be ticked in place
## without hunting through the tree for it.
var _item_menus := {}
var _size_factor := DEFAULT_SIZE_FACTOR
## The recording waiting for a name. Cleared as soon as the name arrives, so a
## dismissed field cannot leave one primed for whatever is typed next.
## The voice names the 說話 submenu was last drawn with. See _open_menu().
var _listed_voices := PackedStringArray()
## How many pre-rendered lines are still outstanding, so the menu row can say so
## and refuse to start a second batch on top of the first.
var _prerender_left := 0
## What the entry window is collecting: a `Config` secret name, or `URL_ENTRY`
## for the one thing it asks for that is not a secret. The window is one node
## serving four settings, so the asker has to say which — otherwise the handler
## could only ever store one, and the rest would quietly land under its name.
const URL_ENTRY := "voxcpm_url"
var _pending_entry := OPENAI_KEY
## Whether the next discovery result is one the user is waiting on. Discovery
## re-runs on every menu open, so without this the pet would report the state of
## the voice service every time the menu is touched for anything at all.
var _awaiting_url_check := false
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
## The tap-bounce and the release-landing tweens drive the same squash channel,
## so only one may be alive at a time — see _stop_squash_tween().
var _squash_tween: Tween = null
## Set once the user has been told a login is still in flight, so the next click
## on the same entry cancels it instead of repeating the message.
var _login_cancel_armed := false
## The workspace a job is being set up for, carried across the consent dialog, the
## uncommitted-work warning and the login prompt — any of which can interrupt the
## walk from "幫我做事" to a typed request.
var _pending_space := {}
## When the pet may next say something while a job runs. Reset per job; the point
## is one reassuring line every couple of minutes, not a running commentary.
var _work_chatter_at := 0.0
## A job the model proposed, held while the user decides.
var _pending_work := {}
## A request the user has already typed, so the walk through _begin_work's gates
## ends by starting the job rather than asking them to type it a second time.
var _queued_request := ""
## Empty means the shared default; every concrete value is a pet selection id.
## The draft survives turning inheritance off and back on before applying.
var _prompt_target_id := ""
var _prompt_inherited_text := ""
var _prompt_draft := ""


func _ready() -> void:
	# No ordering dependency, unlike _brain.setup() below, which must run after
	# park_at_default_spot().
	_visual.setup(_window_ctl)
	_size_factor = float(Config.get_value("pet", "size_factor", DEFAULT_SIZE_FACTOR))
	_layout_visual()
	_load_selected_pack()
	_style_menu()
	_build_menu()
	_memory.memories_changed.connect(_on_memories_changed)
	_chat_log.conversation_cleared.connect(_on_conversation_cleared)
	_chat_log.exported.connect(_on_exported)
	_game.played.connect(_on_game_played)
	# The panel is where a workspace is added or dropped, and the 幫我做事 submenu
	# is built off that list.
	_work.workspaces_changed.connect(_build_menu)

	_brain.state_changed.connect(_on_brain_state)
	_brain.facing_changed.connect(_visual.set_facing)
	_brain.drag_lean_changed.connect(_visual.set_drag_lean)
	_brain.set_roaming(bool(Config.get_value("pet", "roaming", true)))

	EventBus.pet_grabbed.connect(_on_grabbed)
	EventBus.pet_released.connect(_on_released)
	EventBus.pet_tapped.connect(_on_tapped)
	# How much of the window is on screen changes as the pet walks, and the chat
	# UI has to stay inside it.
	EventBus.pet_moved.connect(_on_pet_moved)
	EventBus.files_dropped_on_window.connect(_on_files_dropped_on_window)

	_chat.submitted.connect(_on_chat_submitted)
	_chat.work_submitted.connect(_on_work_submitted)
	TTSService.backend_checked.connect(_on_backend_checked)
	TTSService.voice_library_refreshed.connect(_on_voice_library_refreshed)
	WorkService.finished.connect(_on_work_finished)
	WorkService.failed.connect(_on_work_failed)
	WorkService.progress.connect(_on_work_progress)
	_chat.input_toggled.connect(_on_input_toggled)
	# The field is sized to what's typed in it now, so the mask has to follow it
	# on the platforms where it's only pushed on discrete events.
	_chat.input_resized.connect(_refresh_mask)
	_chat.bubble_hidden.connect(_on_bubble_hidden)
	EventBus.reply_chunk.connect(_on_reply_chunk)
	EventBus.reply_finished.connect(_on_reply_finished)
	EventBus.reply_failed.connect(_on_reply_failed)
	EventBus.emotion_changed.connect(_on_emotion_changed)
	EventBus.pet_nudged.connect(_on_pet_nudged)
	EventBus.screen_look_requested.connect(_on_screen_look_requested)
	EventBus.work_requested.connect(_on_work_requested)
	EventBus.resource_alert.connect(_on_resource_alert)
	_setup_consent_dialog()
	_setup_presence_consent_dialog()
	_setup_work_consent_dialog()
	_setup_work_offer_dialog()
	_setup_dirty_warning_dialog()
	_setup_model_settings_dialog()
	_setup_voice_settings_dialog()
	_setup_prompt_settings_dialog()
	_setup_entry_dialog()
	_setup_codex_login_dialog()
	CodexCli.login_finished.connect(_on_codex_login_finished)
	CodexCli.login_hint.connect(_on_codex_login_hint)
	RecorderService.tick.connect(_on_recording_tick)
	RecorderService.saved.connect(_on_recording_saved)
	RecorderService.failed.connect(_on_recording_failed)
	_chat.holding_action_pressed.connect(_on_recording_stop_pressed)
	_chat.hit_region_changed.connect(_refresh_mask)
	TTSService.remarked.connect(_on_voice_remarked)
	# The row names the voice in use, and every one of these changes it.
	TTSService.voice_changed.connect(_build_menu)
	TTSService.prerender_progress.connect(_on_prerender_progress)

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
	# First run with something installed: adopt it. Otherwise use the bundled
	# v2 pet; later explicit default selections persist as DEFAULT_PET_SELECTION.
	if wanted.is_empty() and not _installed_pets.is_empty():
		wanted = _installed_pets[0]
	elif wanted.is_empty():
		wanted = DEFAULT_PET_SELECTION
	_apply_pack(wanted)


func _apply_pack(pet_id: String) -> void:
	var pack: PetPack = null
	var selection := pet_id
	if pet_id.is_empty() or pet_id == DEFAULT_PET_SELECTION:
		selection = DEFAULT_PET_SELECTION
		pack = PetPack.load_builtin()
		if pack == null:
			push_warning("Pet: bundled default art failed to load, using emergency blob")
	else:
		pack = PetPack.load_installed(pet_id)
		if pack == null:
			push_warning("Pet: '%s' failed to load, falling back to bundled default art" % pet_id)
			selection = DEFAULT_PET_SELECTION
			pack = PetPack.load_builtin()
	_visual.load_pack(pack)
	# The pack carries its own size correction, so the scale has to be reapplied
	# before anything is measured off the visual.
	_layout_visual()
	_refresh_hit_region()
	# The taskbar should show whoever is on the desktop. Takes the *resolved* idle
	# row for the same reason the mini-game does — this file is the only place the
	# per-pet row corrections have already been applied.
	AppIcon.apply(pack, int(_visual.state_rows().get(&"idle", 0)))
	Config.set_value("pet", "id", selection)
	LLMService.select_persona_for_pet(selection)


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


## Feeds the brain a target rather than moving the window directly, so the body
## can lag behind the cursor instead of teleporting onto it — PetBrain._step_drag()
## is what actually moves the window now, every frame while Mode.DRAG.
func _update_drag() -> void:
	var mouse := DisplayServer.mouse_get_position()
	if not _dragging and Vector2(mouse - _press_pos).length() > DRAG_THRESHOLD:
		_dragging = true
		EventBus.pet_grabbed.emit()
	if _dragging:
		_brain.set_drag_target(mouse - _grab_offset)


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


## Whoever is about to write the squash channel gets it to themselves. The
## release landing runs for a third of a second, and grabbing the pet again
## inside that window used to leave the old tween easing the squash back to
## zero underneath the new grab — which both un-squashed a pet that was being
## held and re-armed PetVisual's cursor reaction, gated on a zero squash, in the
## middle of a drag.
func _stop_squash_tween() -> void:
	if _squash_tween != null and _squash_tween.is_valid():
		_squash_tween.kill()
	_squash_tween = null


func _on_grabbed() -> void:
	_brain.on_grabbed()
	_stop_squash_tween()
	_visual.set_squash(GRAB_SQUASH)


## A quick punch to a landing peak, then the same elastic settle shape already
## shipped for a tap — bounce and squash on release, not an instant snap to rest.
func _on_released() -> void:
	_stop_squash_tween()
	var tween := create_tween()
	_squash_tween = tween
	tween.tween_method(_visual.set_squash, GRAB_SQUASH, DRAG_IMPACT_SQUASH, DRAG_IMPACT_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(_visual.set_squash, DRAG_IMPACT_SQUASH, 0.0, DRAG_LANDING_DURATION) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_brain.on_released()
	# Being picked up drops the brain out of TALK, so without this the pet strolls
	# off the moment it's put down — dragging the field the user is typing into
	# along with it.
	if _chat.is_input_open() or _chat.is_showing():
		_brain.on_talk_started()


func _on_tapped() -> void:
	_brain.on_tapped()
	_stop_squash_tween()
	var tween := create_tween()
	_squash_tween = tween
	tween.tween_method(_visual.set_squash, TAP_BOUNCE_SQUASH, 0.0, TAP_BOUNCE_DURATION) \
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


## OS drag-and-drop reaches the whole window regardless of the passthrough
## mask (see WindowController._on_files_dropped), so a drop anywhere in the
## mostly-transparent, overhanging window rect fires this — including well
## past the pet, over whatever desktop icons the corner happens to overhang.
## Only take it if it actually landed on the pet's own hit box (the same one
## clicks/taps/drags use); otherwise dragging a file toward the desktop
## corner this window overhangs would randomly get hijacked.
func _on_files_dropped_on_window(files: PackedStringArray, at: Vector2) -> void:
	if files.is_empty() or not _pet_box.has_point(at):
		return
	# A dropped *folder* is not something to read out, it is somewhere to work.
	# FileDropService's own answer to one is 「你應該打不開」, which was true when
	# reading files was all the pet could do with a path.
	if DirAccess.dir_exists_absolute(files[0].replace("\\", "/")):
		_offer_workspace(files[0])
		return
	# One turn at a time, same as typing — extra files in the same drop are
	# silently ignored rather than queued or concatenated.
	_chat.begin_reply()
	_brain.on_talk_started()
	FileDropService.handle_drop(files[0])


## Dropping a folder on the pet is the shortest path from "I want help with this
## project" to the pet being allowed to touch it, so it adds the workspace
## outright rather than opening a dialog about it — adding one changes nothing on
## its own, and the level it lands at is visible and reversible in the panel.
##
## The refusals still have to be spoken. WorkspaceService turns down a hidden
## folder or the whole home directory for good reasons, and a drop that silently
## did nothing would read as the pet failing to notice.
func _offer_workspace(path: String) -> void:
	var reason := WorkspaceService.add(path)
	if not reason.is_empty():
		_on_pet_nudged("sad", reason, false, false)
		return
	var space := WorkspaceService.get_space(path)
	_build_menu()
	_work.refresh_if_open()
	_on_pet_nudged("excited", "好，「%s」我記下來了，你要我在裡面做什麼？"
		% str(space.get("name", "")), false, false)
	# Through _begin_work, never straight to the input. Going direct skipped every
	# gate at once — the consent dialog, the busy check, the Codex login prompt and
	# the uncommitted-work warning — which made dropping a folder the one way to
	# reach an agent without ever being asked.
	_begin_work(space)


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
##
## `record` exists for the lines that acknowledge a *clear*. Everything the pet
## says normally goes into history so its next real reply doesn't contradict it,
## but a line confirming the history was just emptied would be the one thing left
## in it — leaving the count at 1 and the list looking like the clear only half
## worked. That line is feedback about the app, not conversation.
## `unprompted` is what the guard below is for, and it is not the same question as
## `record`. A line the pet volunteers must never talk over what the user is
## doing. A line answering something they just asked for has to appear even then,
## or it is simply lost — which is exactly what happened to the maker path, whose
## flow *opens the input itself*, so the guard was still true when both the "give
## me a moment" line and the result ten seconds later tried to speak.
func _on_pet_nudged(emotion: String, text: String, record := true,
		unprompted := true) -> void:
	if unprompted and (_chat.is_showing() or _chat.is_input_open()):
		return
	_brain.on_talk_started()
	_chat.begin_reply()
	_on_emotion_changed(emotion)
	_chat.append_reply(text)
	_chat.end_reply()
	if record:
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


## Reused between rebuilds. Submenus have to exist under the menu that points at
## them before add_submenu_node_item() can use them. Most belong to the root;
## nested advanced settings pass their immediate parent explicitly.
func _submenu(key: String, parent: PopupMenu = null) -> PopupMenu:
	var owner := _menu if parent == null else parent
	if _submenus.has(key):
		var existing: PopupMenu = _submenus[key]
		existing.clear()
		if existing.get_parent() != owner:
			existing.reparent(owner)
		return existing
	var menu := PopupMenu.new()
	menu.name = key
	menu.theme = _menu.theme
	menu.id_pressed.connect(_on_menu_pressed)
	owner.add_child(menu)
	_submenus[key] = menu
	return menu


## Four setting groups behind submenus, then the verbs worth reaching in one
## click, then one door to the windows. Flat, the menu ran to twenty rows — every
## setting the app has, at the same weight as "餵食", which is the one people
## actually came for.
##
## The panels were folded away second, for a different reason than the settings
## were. Measured at seventeen rows: 476px on a 1080p desktop, which Godot had to
## shove upward to fit on screen at all, and ~595px at 125%. Five of those rows
## were the same shape as each other — a window listing something the pet holds —
## and they are the group that *grows*, since every feature since has added one.
## The verbs don't: there are only so many things to ask a pet to do.
func _build_menu() -> void:
	_menu.clear()
	_item_menus.clear()
	var current: PetPack = _visual.get_pack()

	_menu.add_submenu_node_item("造型", _build_looks_menu(current))
	_menu.add_submenu_node_item("大小", _build_size_menu())
	_menu.add_submenu_node_item("語言模型", _build_model_menu())
	# Next to 語言模型 because they are the same question asked twice: which model
	# thinks, and which one speaks. A fifth setting group rather than another row
	# in 行為, because speech stopped being one switch — there is now a backend, a
	# voice, and the on/off, and three questions is what a submenu is for. It also
	# takes a row *out* of 行為, where the one naming a voice never fitted among
	# rows describing what the pet does.
	_menu.add_submenu_node_item("說話", _build_speech_menu())
	_menu.add_submenu_node_item("行為", _build_behaviour_menu(current))

	_menu.add_separator()
	_menu.add_item("餵食", MenuId.FEED)
	# Down here with 餵食 rather than up with the four setting groups: these are
	# things you do *with* the pet, not things you do to the app.
	_menu.add_submenu_node_item("遊戲", _build_games_menu())
	_menu.add_item("看一下我的螢幕…", MenuId.LOOK)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.LOOK), not VisionService.is_supported())
	# A submenu rather than an item, because "做事" always has a *where*, and
	# picking it up front is what keeps the pet from having to guess between
	# however many projects the user keeps.
	_menu.add_submenu_node_item("幫我做事", _build_work_menu())
	# Disabled rather than hidden: an entry that vanishes on a machine without the
	# CLI is a feature nobody discovers exists, the same call the 依你的節奏搭話
	# row makes where PresenceService reports unsupported.
	_menu.set_item_disabled(_menu.get_item_count() - 1, not WorkService.is_supported())
	# The sixth verb, which CLAUDE.md names as the point to stop and think. The
	# thinking: 錄音 is something you ask the pet to do *for* you and the result is
	# something it then holds — the same shape as 幫我做事, not the shape of a
	# window. It could have been a button in 我做的東西's footer, one group along
	# and free of charge, but then you would be talking to a window rather than
	# handing something to the pet, which is the entire premise of the app. So it
	# is a verb, and it is one row rather than two because the row carries its own
	# stop. Measured: 14 rows, 392px on this 1080p desktop — still short of the
	# 476px that forced Godot to shove the flat menu upward.
	_menu.add_item(_record_label(), MenuId.RECORD)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.RECORD),
		not RecorderService.is_supported())
	_menu.add_item("回到角落", MenuId.RECENTRE)

	# Its own block, because it is a different kind of thing from everything above
	# it: those are verbs, this is a door. No ellipsis — in this menu "…" means
	# "opens something further", which a submenu arrow already says.
	_menu.add_separator()
	_menu.add_submenu_node_item("查看", _build_panels_menu())

	_menu.add_separator()
	_menu.add_item("結束", MenuId.QUIT)

	_index_items(_menu)
	if not _menu.id_pressed.is_connected(_on_menu_pressed):
		_menu.id_pressed.connect(_on_menu_pressed)


func _build_looks_menu(_current: PetPack) -> PopupMenu:
	var menu := _submenu("Looks")
	var current_id: String = Config.get_value("pet", "id", DEFAULT_PET_SELECTION)
	for i in _installed_pets.size():
		var pet_id := _installed_pets[i]
		menu.add_radio_check_item(pet_id, PET_ID_BASE + i)
		menu.set_item_checked(menu.get_item_index(PET_ID_BASE + i), pet_id == current_id)
	menu.add_radio_check_item("預設造型（芽尾）", MenuId.FALLBACK)
	menu.set_item_checked(menu.get_item_index(MenuId.FALLBACK),
		current_id.is_empty() or current_id == DEFAULT_PET_SELECTION)
	menu.add_separator()
	menu.add_item("編輯這個造型的個性…", MenuId.PROMPT_CURRENT)
	menu.add_item("編輯預設個性…", MenuId.PROMPT_DEFAULT)
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

	if LLMService.get_provider_name() == "openai":
		menu.add_separator()
		menu.add_item("目前：%s · 推理 %s" % [
			LLMService.get_model(), LLMService.get_reasoning_effort()])
		menu.set_item_disabled(menu.item_count - 1, true)
		menu.add_item("更換模型與推理程度…", MenuId.MODEL_SETTINGS)

	menu.add_separator()
	menu.add_item(_api_key_label(), MenuId.SET_KEY)
	_index_items(menu)
	return menu


## The id is what matters, so it leads; the note is a parenthetical and only some
## models have one.
func _model_label(model: Dictionary) -> String:
	var note := str(model.get("note", ""))
	if note.is_empty():
		return str(model["id"])
	return "%s（%s）" % [model["id"], note]


func _reasoning_label(effort: Dictionary) -> String:
	return "%s（%s）" % [effort["label"], effort["id"]]


## Which voice, whether to use it, and — once there is a local engine — whose it
## is. The row still names the voice rather than hiding it behind a picker, which
## is the one thing that would have made the Afrikaans bug visible: it said
## 說話出聲（Afrikaans）for weeks and was never read.
func _build_speech_menu() -> PopupMenu:
	var menu := _submenu("Speech")
	menu.add_check_item(_voice_label(), MenuId.SPEAK)
	var speak := menu.get_item_index(MenuId.SPEAK)
	menu.set_item_checked(speak, TTSService.is_enabled())
	menu.set_item_disabled(speak, not TTSService.is_available())
	if not TTSService.is_available():
		menu.set_item_tooltip(speak, TTSService.unavailable_reason())

	menu.add_separator()
	var backends := TTSService.list_backends()
	for i in backends.size():
		var backend := backends[i]
		menu.add_radio_check_item(TTSService.backend_label(backend), VOICE_BASE + i)
		var index := menu.get_item_index(VOICE_BASE + i)
		menu.set_item_checked(index, backend == TTSService.get_backend_name())
		# Disabled with the reason *on the row*, rather than a bare unavailable
		# entry. What is missing here is one path or one package, which is
		# something the user can act on — and a local model is exactly the kind of
		# dependency that is present on the machine it was built on and nowhere
		# else, so this row is unavailable more often than it is available.
		var reason := TTSService.backend_unavailable_reason(backend)
		menu.set_item_disabled(index, not reason.is_empty())
		menu.set_item_tooltip(index, reason)
	# Keep repair controls in this submenu rather than a third popup. Native
	# Windows menus may open that popup back across the first-level menu near a
	# screen edge; crossing it then changes the hovered first-level item and makes
	# the key row effectively unreachable.
	_append_speech_connection_settings(menu)

	# Voice libraries are allowed to grow without growing this menu. Report the
	# active character here, then open the complete list only when the user asks
	# to change it — the same staged pattern used by language-model settings.
	var voices := TTSService.list_voices()
	_listed_voices = voices
	if not voices.is_empty():
		_append_voice_summary(menu, voices, TTSService.active_voice())
		# Under the voices because it renders *all of them*, not the ticked one —
		# so it belongs beside the picker rather than inside it. The count is in
		# the label for the same reason: without it the row reads as being about
		# the current voice, which is what it used to be.
		menu.add_item(_prerender_label(voices.size()), MenuId.PRERENDER)
		menu.set_item_disabled(menu.get_item_index(MenuId.PRERENDER), _prerender_left > 0)
	_index_items(menu)
	return menu


## Keep the everyday menu constant-size even when a service supplies dozens of
## characters. The disabled line is status; the verb below it is the only path
## to the full picker.
func _append_voice_summary(menu: PopupMenu, voices: PackedStringArray,
		active: String) -> void:
	if voices.is_empty():
		return
	var shown := active if not active.is_empty() else voices[0]
	menu.add_separator()
	menu.add_item("目前角色：%s" % shown)
	menu.set_item_disabled(menu.item_count - 1, true)
	menu.add_item("更換角色…", MenuId.VOICE_SETTINGS)


func _append_speech_connection_settings(menu: PopupMenu) -> void:
	menu.add_separator()
	# Always reachable, even when VoxCPM is down: a wrong address or key is exactly
	# what makes the backend unavailable, so hiding its repair controls would make
	# the failure permanent from inside the app.
	menu.add_item("服務位置…（%s）" % TTSService.voxcpm_url(), MenuId.SET_VOXCPM_URL)
	menu.add_item("%s VoxCPM 金鑰…"
		% ["更換" if Config.has_secret(VoxCPMVoice.KEY_NAME) else "設定"],
		MenuId.SET_VOXCPM_KEY)
	# A working ElevenLabs backend already has everything it needs; this is only a
	# repair row, matching the previous first-level behaviour.
	if not TTSService.backend_is_available(TTSService.BACKEND_ELEVEN):
		menu.add_item("設定 ElevenLabs 金鑰…", MenuId.SET_ELEVEN_KEY)
	menu.add_separator()
	menu.add_item("正在重新整理聲音庫…" if TTSService.is_voice_library_refreshing()
		else "重新整理聲音庫", MenuId.REFRESH_VOICES)
	menu.set_item_disabled(menu.get_item_index(MenuId.REFRESH_VOICES),
		TTSService.is_voice_library_refreshing())


## The fixed lines are the ones the pet says most often and the ones whose
## wording never changes, so they are the only ones that can be made ahead of
## time at all — every other line is written fresh by the model.
func _prerender_label(voices: int) -> String:
	if _prerender_left > 0:
		return "先錄好固定台詞（還剩 %d 段）" % _prerender_left
	return "先錄好固定台詞（%d 個聲音）" % voices if voices > 1 else "先錄好固定台詞"


func _build_behaviour_menu(current: PetPack) -> PopupMenu:
	var menu := _submenu("Behaviour")
	# Several switches people flip together — closing the menu after each one turns
	# a ten-second job into several trips.
	menu.hide_on_checkable_item_selection = false
	menu.add_check_item("主動說話", MenuId.NUDGES)
	menu.set_item_checked(menu.get_item_index(MenuId.NUDGES), Nudger.is_enabled())
	menu.add_check_item("依你的節奏搭話", MenuId.PRESENCE)
	menu.set_item_checked(menu.get_item_index(MenuId.PRESENCE), PresenceService.is_enabled())
	menu.set_item_disabled(menu.get_item_index(MenuId.PRESENCE), not PresenceService.is_supported())
	menu.add_check_item("留意電腦負載", MenuId.MONITOR)
	menu.set_item_checked(menu.get_item_index(MenuId.MONITOR), MonitorService.is_enabled())
	menu.set_item_disabled(menu.get_item_index(MenuId.MONITOR), not MonitorService.is_supported())
	# The one non-obvious consequence, said where the switch is rather than in a
	# dialog: the scan itself never leaves this machine, but the line the pet says
	# about it is an ordinary thing the pet said, and goes into the conversation
	# like any other — which means the model sees it on the next turn.
	menu.set_item_tooltip(menu.get_item_index(MenuId.MONITOR),
		"%s 每 20 分鐘看一次系統負載，只有異常時才開口。\n那句話會提到程序名稱，並和其他對話一樣留在記錄裡。"
			% MonitorService.hours_label())
	menu.add_check_item("自由走動", MenuId.ROAM)
	menu.set_item_checked(menu.get_item_index(MenuId.ROAM), _brain.is_roaming())
	menu.add_separator()
	menu.add_check_item("校準動畫列", MenuId.CALIBRATE)
	menu.set_item_disabled(menu.get_item_index(MenuId.CALIBRATE), current == null)
	menu.set_item_checked(menu.get_item_index(MenuId.CALIBRATE), _visual.is_calibrating())
	_index_items(menu)
	return menu


## The folders the pet may work in, straight off WorkspaceService — so this menu
## is the allowlist and can't drift from it.
##
## An empty list is the normal first-run state, not an error: nothing is added
## until the user adds it. So the submenu explains itself rather than being
## disabled, and offers the way in.
func _build_work_menu() -> PopupMenu:
	var menu := _submenu("Work")
	var spaces := WorkspaceService.list()
	for i in spaces.size():
		var space := spaces[i]
		menu.add_item("在 %s…" % str(space["name"]), WORKSPACE_BASE + i)
		var index := menu.get_item_index(WORKSPACE_BASE + i)
		# The level belongs on the row that starts the job, since it is the single
		# most important thing about what is about to happen.
		menu.set_item_tooltip(index, "%s ・ %s"
			% [str(space["path"]), WorkspaceService.level_label(str(space["level"]))])
		menu.set_item_disabled(index, not bool(space["exists"]))
	if spaces.is_empty():
		menu.add_separator("還沒指定我可以動的資料夾")
	menu.add_separator()
	menu.add_item("加一個資料夾…", MenuId.ADD_SPACE)
	_index_items(menu)
	return menu


## The five windows that are all the same shape: a list of something the pet
## holds or watches, where each row can be acted on by itself.
##
## Kept in the order they were added to the flat menu, which is also shallowest
## first — what we just said, then what the pet has kept, then what it made, then
## what it is doing for you, then what your machine is doing.
##
## The last two are the ones that show something happening *now*, and burying
## them costs a click at exactly the moment you want them. Taken anyway: the pet
## says "還在弄" on its own while a job runs, so the menu is not how you find out
## it is still alive — and a group with an exception in it has no honest name.
func _build_panels_menu() -> PopupMenu:
	var menu := _submenu("Panels")
	menu.add_item("對話記錄…", MenuId.CHAT_LOG)
	menu.add_item("記憶與資料…", MenuId.MEMORY)
	menu.add_item("我做的東西…", MenuId.OUTBOX)
	menu.add_item("工作…", MenuId.WORK)
	menu.add_item("電腦狀況…", MenuId.LOAD)
	# Disabled rather than hidden, the same call every other unsupported row here
	# makes: an entry that vanishes is a feature nobody discovers exists.
	menu.set_item_disabled(menu.get_item_index(MenuId.LOAD), not MonitorService.is_supported())
	_index_items(menu)
	return menu


## Ids come off GAME_BASE rather than the enum, so the list is whatever
## GamePanel says it is — adding another game touches no code here at all.
func _build_games_menu() -> PopupMenu:
	var menu := _submenu("Games")
	for i in GamePanel.game_count():
		menu.add_item("%s…" % GamePanel.game_title(i), GAME_BASE + i)
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


## Same, for a row whose label is state rather than a name.
func _set_item_text(id: int, text: String) -> void:
	var menu: PopupMenu = _item_menus.get(id)
	if menu == null:
		return
	var index := menu.get_item_index(id)
	if index >= 0:
		menu.set_item_text(index, text)


func _open_menu() -> void:
	# Packs are installed by an external CLI while the app is running, so rescan
	# on every open rather than making the user restart to see a new pet.
	var found := PetPack.list_installed()
	var stale := found != _installed_pets
	_installed_pets = found

	# The same argument for the voice engine, one step sharper. The disabled row
	# says to write a path into config.cfg — and its own cached answer was what
	# kept it disabled after the user did exactly that. Rediscovering here is what
	# makes that instruction true, and the menu is only rebuilt when the answer
	# actually moved, so the ordinary open still costs a few `file_exists`.
	var could_speak := TTSService.backend_is_available(TTSService.BACKEND_VOXCPM)
	TTSService.rediscover()
	var can_speak := TTSService.backend_is_available(TTSService.BACKEND_VOXCPM)
	stale = stale or can_speak != could_speak

	# And the voices themselves, for the reason 管理聲音… exists: that row opens
	# the folder and invites the user to rename or delete files in it, and a menu
	# that then went on listing what used to be there would be lying about the
	# one thing it just sent them off to change. A voice shipped by an update
	# lands the same way. Cloning does not need this — it emits voice_changed.
	# Unconditional now: the list belongs to whichever backend is speaking, and
	# the local service's arrives asynchronously after a health check, so gating
	# it on one backend being available would leave the menu showing an empty
	# list for as long as it stayed open.
	var voices := TTSService.list_voices()
	stale = stale or voices != _listed_voices

	if stale:
		_build_menu()
	# The only row whose text changes without anything rebuilding the menu, so it
	# is refreshed here rather than by making every open pay for a full rebuild.
	# Missing this left the row reading 錄一段話 while the pet was visibly
	# recording — following the indicator's own instruction did nothing, which is
	# the one failure a stop control cannot have. The clock in it is a snapshot
	# taken as the menu opens; the live one is the bubble, which the menu covers.
	_set_item_text(MenuId.RECORD, _record_label())
	_menu.reset_size()
	_menu.popup(Rect2i(DisplayServer.mouse_get_position(), _menu.size))


func _on_menu_pressed(id: int) -> void:
	# Highest base first: every one of these tests is "at or above", so a game id
	# at 400 also satisfies the provider test at 300.
	if id >= VOICE_BASE:
		# No _build_menu() here: select_backend emits voice_changed, which is
		# already wired to it, and a second rebuild in the same frame would drop
		# the submenu node this call arrived from.
		TTSService.select_backend(TTSService.list_backends()[id - VOICE_BASE])
		return
	if id >= WORKSPACE_BASE:
		var spaces := WorkspaceService.list()
		var index := id - WORKSPACE_BASE
		if index < spaces.size():
			_begin_work(spaces[index])
		return
	if id >= GAME_BASE:
		_game.open(_window_ctl.get_ui_scale(), _visual.get_pack(),
			_visual.state_rows(), id - GAME_BASE)
		return
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
			_switch_pack(DEFAULT_PET_SELECTION)
		MenuId.GET_PETS:
			OS.shell_open(PET_GALLERY_URL)
		MenuId.FEED:
			_feed()
		MenuId.NUDGES:
			_toggle_nudges()
		MenuId.PRESENCE:
			_toggle_presence()
		MenuId.MONITOR:
			_toggle_monitor()
		MenuId.SPEAK:
			_toggle_speech()
		MenuId.PRERENDER:
			_start_prerender()
		MenuId.REFRESH_VOICES:
			_refresh_voice_library()
		MenuId.ROAM:
			_toggle_roaming()
		MenuId.CALIBRATE:
			_toggle_calibration()
		MenuId.RECORD:
			_toggle_recording()
		MenuId.RECENTRE:
			_window_ctl.park_at_default_spot()
			_brain.set_home_here()
		MenuId.MODEL_SETTINGS:
			_open_model_settings()
		MenuId.VOICE_SETTINGS:
			_open_voice_settings()
		MenuId.PROMPT_DEFAULT:
			_open_prompt_settings(false)
		MenuId.PROMPT_CURRENT:
			_open_prompt_settings(true)
		MenuId.SET_KEY:
			_ask_for_entry(OPENAI_KEY, "OpenAI API key",
				"用來聊天跟看螢幕的。%s" % _entry_storage_note(), true)
		MenuId.SET_ELEVEN_KEY:
			_ask_for_entry(ElevenVoice.KEY_NAME, "ElevenLabs API key",
				"雲端語音要用的。%s" % _entry_storage_note(), true)
		MenuId.SET_VOXCPM_KEY:
			_ask_for_entry(VoxCPMVoice.KEY_NAME, "VoxCPM 服務的 API key",
				"只有在服務開了驗證時才需要。%s" % _entry_storage_note(), true)
		MenuId.SET_VOXCPM_URL:
			# The one entry here that is not a secret, so it is not masked and it
			# opens showing the current value: editing an address is a different
			# act from retyping one from memory, and retyping is how a working
			# setting becomes a typo.
			_ask_for_entry(URL_ENTRY, "VoxCPM 服務位置",
				"語音服務在哪裡。存好之後我會馬上連連看，連不上會跟你說。",
				false, TTSService.voxcpm_url())
		MenuId.LOOK:
			EventBus.screen_look_requested.emit(VisionService.DEFAULT_QUESTION, true)
		MenuId.WORK:
			_work.open(_window_ctl.get_ui_scale())
		MenuId.ADD_SPACE:
			_work.open(_window_ctl.get_ui_scale())
			_work.pick_folder()
		MenuId.CHAT_LOG:
			_chat_log.open(_window_ctl.get_ui_scale())
		MenuId.MEMORY:
			_memory.open(_window_ctl.get_ui_scale())
		MenuId.OUTBOX:
			_outbox.open(_window_ctl.get_ui_scale())
		MenuId.LOAD:
			_monitor.open(_window_ctl.get_ui_scale())
		MenuId.QUIT:
			get_tree().quit()


func _api_key_label() -> String:
	var where := Config.secret_backend_name()
	var suffix := "存進 %s" % where if not where.is_empty() else "無安全儲存，會存成明文"
	return "%s OpenAI API key（%s）" \
		% ["更換" if Config.has_secret(OPENAI_KEY) else "設定", suffix]


## Collect one setting in its own window.
##
## **Not in the speech bubble, which is where all of this used to happen.** Three
## reasons, in the order they matter: a key typed into the pet's own input is
## being typed into the *transparent, click-through* window, behind a passthrough
## mask that has to be kept in step with whatever the field is doing — the one
## surface in this app with a rule about not eating desktop clicks. It is also
## conversation-shaped, and pasting a credential is not something you say to a
## pet. And a bubble fades on a timer, so a dialog that asks a question the user
## has to go and find the answer to could time out mid-paste.
##
## A `ConfirmationDialog` like every other question here, so it is a real OS
## window (subwindow embedding is off project-wide) and touches no mask at all.
func _ask_for_entry(what: String, title: String, blurb: String,
		masked: bool, current := "") -> void:
	_pending_entry = what
	_secret_entry.title = title
	_secret_blurb.text = blurb
	_secret_field.secret = masked
	_secret_field.text = current
	_secret_field.caret_column = current.length()
	_secret_entry.reset_size()
	_secret_entry.popup_centered()
	_secret_field.grab_focus()


func _entry_storage_note() -> String:
	var where := Config.secret_backend_name()
	return "會存進 %s。" % where if not where.is_empty() \
		else "這台機器沒有安全儲存，只能存成明文設定檔。"


func _on_entry_confirmed() -> void:
	var value := _secret_field.text.strip_edges()
	# Cleared straight away rather than on close: the field is one node reused by
	# four settings, and a key left sitting in it is a key the next dialog opens
	# showing — in plain text, if that one happens to be the address.
	_secret_field.text = ""
	if value.is_empty():
		return
	if _pending_entry == URL_ENTRY:
		_on_url_submitted(value)
	else:
		_on_secret_submitted(value)


## A service address the user typed.
##
## Normalised rather than validated: a bare `127.0.0.1:8080` is what people type
## and what every tunnel's own instructions print, and refusing it to teach a
## lesson about schemes helps nobody. Anything genuinely wrong is caught by the
## thing that decides it — the service either answers or it does not — and that
## answer arrives below.
func _on_url_submitted(value: String) -> void:
	var url := value.strip_edges()
	if not url.contains("://"):
		url = "http://" + url
	url = url.rstrip("/")
	_awaiting_url_check = true
	TTSService.set_voxcpm_url(url)
	_build_menu()
	_on_pet_nudged("neutral", "好，我改連 %s，等我看看……" % url, false, false)


## What the service said back, once. Reported here rather than assumed after a
## timer: a tunnel answers slower than localhost, and a fixed wait long enough
## for one is a wait nobody sits through for the other. `TTSService` swaps the
## backend out by itself when this fails, so this only has to say so.
func _on_backend_checked(healthy: bool, reason: String, explained: bool) -> void:
	if not _awaiting_url_check:
		return
	_awaiting_url_check = false
	_build_menu()
	if healthy:
		# Adopted right away, the same way pasting a key is — and here it is what
		# makes the sentence true. A wrong address takes the backend down with it,
		# so by the time the right one is typed the pet is on the OS voice and
		# nothing switches back; 「連上了，有 5 種聲音」 would then be describing a
		# service the pet is not using.
		TTSService.select_backend(TTSService.BACKEND_VOXCPM)
		_on_pet_nudged("happy", "連上了！有 %d 種聲音可以用。"
			% TTSService.list_voices().size(), false, false)
	elif not explained:
		# Only when nothing else did. Where this address belongs to the voice the
		# pet is speaking in, `TTSService` has already said so *and* said what it
		# is falling back to, which is strictly more than this could.
		_on_pet_nudged("sad", reason, false, false)


func _refresh_voice_library() -> void:
	if not TTSService.refresh_voice_library():
		return
	_build_menu()
	_on_pet_nudged("neutral", "好，我重新讀一次聲音庫……", false, false)


func _on_voice_library_refreshed(healthy: bool, reason: String, voices: int,
		explained: bool) -> void:
	_build_menu()
	if healthy:
		_on_pet_nudged("happy", "聲音庫更新好了，現在有 %d 種聲音可以用。" % voices,
			false, false)
	elif not explained:
		_on_pet_nudged("sad", reason, false, false)


func _on_secret_submitted(value: String) -> void:
	# Almost always a stray character from a bad paste — API keys are ASCII, and
	# the Keychain can't round-trip anything else. See SecretStore.write().
	if not SecretStore.is_ascii(value):
		_on_pet_nudged("sad", "這個 key 有奇怪的字元，是不是貼到多餘的東西了？")
		return

	var key := _pending_entry
	var secured := Config.set_secret(key, value)
	# Adopted right away rather than sending the user back to the menu — a key is
	# the only thing standing between the mock and the real thing in both cases.
	# VoxCPM adoption waits for its protected endpoint to accept the new key;
	# selecting synchronously here would still see the previous 401 result.
	if key == VoxCPMVoice.KEY_NAME:
		TTSService.rediscover_and_select(TTSService.BACKEND_VOXCPM)
	elif key == ElevenVoice.KEY_NAME:
		# The backend caches its availability reason, so it has to reconsider the
		# newly stored key before the row can stop being disabled.
		TTSService.rediscover_and_select(TTSService.BACKEND_ELEVEN)
	elif LLMService.get_provider_name() != "openai":
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


# --- Presence (rhythm-based nudging) ------------------------------------------

## Modelled on the screen-look consent above: nothing is sampled until the
## user agrees, and the one way to agree here already *is* the standing
## consent — there's no "just this once" for a background poll — so the
## accept button gets the quiet treatment the vision dialog reserves for
## "以後都不用問我", not the loud one it gives its one-off "看這一次".
func _setup_presence_consent_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_presence_consent.title = "留意你切換 App 的節奏"
	_presence_consent.dialog_text = "\n".join(PackedStringArray([
		"我想多留意一點你的作息，這樣主動找你聊天才不會挑錯時間。",
		"",
		"・只記錄目前最上層 App 的名稱，還有你留在同一個 App 多久",
		"・不會看視窗標題、內容，或是你打的字",
		"・這些資料只留在這台電腦，不會送出網路，也不會寫進任何檔案",
		"・關掉開關，我就完全不會再讀",
	]))
	_presence_consent.exclusive = false
	_presence_consent.theme = PetStyle.dialog_theme(scale)
	_presence_consent.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_presence_consent.ok_button_text = "好，開始留意"
	_presence_consent.cancel_button_text = "不用了"
	PetStyle.make_ghost_button(_presence_consent.get_ok_button(), scale)
	_presence_consent.confirmed.connect(_on_presence_consent_confirmed)


func _on_presence_consent_confirmed() -> void:
	PresenceService.grant_consent()
	_set_checked(MenuId.PRESENCE, true)


## Consent, once given, is sticky — re-checking the box after turning it off
## doesn't re-ask something already agreed to (same durability as vision's
## "always"). Turning it off needs no dialog at all; it's pure withdrawal.
func _toggle_presence() -> void:
	if PresenceService.is_enabled():
		PresenceService.set_enabled(false)
		_set_checked(MenuId.PRESENCE, false)
	elif PresenceService.has_consented():
		PresenceService.set_enabled(true)
		_set_checked(MenuId.PRESENCE, true)
	else:
		_presence_consent.reset_size()
		_presence_consent.popup_centered()


# --- Watching the machine -----------------------------------------------------

## No consent dialog, unlike the two above, and the difference is what is being
## looked at. A screenshot leaves the machine and a presence poll is a record of
## what *you* were doing; a process list is what the computer is doing, read
## locally, never written down and never sent. The switch being off by default is
## the opt-in, and the row's tooltip carries the one consequence that isn't
## obvious from its name — see _build_behaviour_menu().
func _toggle_monitor() -> void:
	MonitorService.set_enabled(not MonitorService.is_enabled())
	_set_checked(MenuId.MONITOR, MonitorService.is_enabled())


## The service knows the numbers; only the composition root knows how the pet
## reacts to anything — the same split the mini-game scores and the work results
## already use, and the reason MonitorService emits a kind rather than a sentence.
##
## Gated on 主動說話 as well as on its own switch. This is the pet opening its
## mouth without being asked, which is exactly what that switch is for; leaving
## it out would give the one setting that means "don't do that" a hole in it.
func _on_resource_alert(kind: String, detail: Dictionary) -> void:
	if not Nudger.is_enabled():
		return
	var percent := roundi(float(detail.get("percent", 0.0)))
	var name := str(detail.get("name", ""))
	var emotion := "sad"
	var line := ""
	match kind:
		MonitorService.ALERT_MEM_TIGHT:
			line = "記憶體只剩 %d%% 可用了，要不要關掉幾個東西？" % percent
		MonitorService.ALERT_PROC_MEM:
			emotion = "neutral"
			line = "%s 一個就吃掉 %d%% 的記憶體耶。" % [name, percent]
		MonitorService.ALERT_CPU_BUSY:
			emotion = "neutral"
			line = "CPU 現在衝到 %d%%，跑最兇的是 %s。" % [percent, name] if not name.is_empty() \
				else "CPU 現在衝到 %d%%，風扇應該很忙。" % percent
	if line.is_empty():
		return
	_on_pet_nudged(emotion, line)


# --- Doing work ---------------------------------------------------------------

## The third consent shape in this app, and the questions are different again.
## A screenshot's are how much, to whom, how long. A background poll's are what is
## sampled and where it goes. This one's are the ones a folder full of your own
## work raises: which folder, what can it change in there, and can I stop it.
##
## Note what this dialog does *not* promise. The screen-look one can say "只有這
## 一次"; this one cannot, because an agent editing files is exactly the thing that
## has to be allowed to write. So the honest answer is the allowlist itself —
## nothing is touched but the folder you named — plus a stop button that works.
func _setup_work_consent_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_work_consent.dialog_text = "\n".join(PackedStringArray([
		"你可以叫我做事，我會請 %s 實際動手，用你已經登入的那個帳號。"
			% WorkService.runner_label(WorkService.runner()),
		"",
		"・我只在你指定的資料夾裡開工，一次一個，你沒加的資料夾我看不到",
		"・標成「可以改」的，它會真的改檔案、也會執行指令來驗證自己做對了",
		"・執行指令這件事，Codex 有系統層級的沙箱擋住資料夾以外；Claude Code 沒有，靠的是它自己守規矩",
		"・改壞了要靠版本控制救，所以資料夾裡有沒存的東西我會先提醒你",
		"・每個資料夾都能單獨改成「只能看」，那樣它連寫入和執行的工具都沒有",
		"・做到一半隨時可以在「工作」視窗按停下來，做完我會告訴你哪些檔案動過",
		"・這會用掉你的訂閱或 API 額度，一次可能要好幾分鐘",
	]))
	_work_consent.exclusive = false
	_work_consent.theme = PetStyle.dialog_theme(scale)
	_work_consent.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	PetStyle.make_ghost_button(_work_consent.get_ok_button(), scale)
	_work_consent.confirmed.connect(_on_work_consent_confirmed)
	# Declining used to do nothing at all — no line, and `_pending_space` left
	# set. The pet went quiet, the input stayed in chat mode, and the next thing
	# the user typed became an ordinary conversation turn with no sign that the
	# job had been dropped. That is exactly how this feature looked broken.
	_work_consent.canceled.connect(_abandon_pending_work.bind("好，那我不動你的資料夾。"))


## A compact instrument panel for the two settings that shape every reply. The
## right-click menu only reports the live values and opens this native window;
## choices stay staged here until 套用 is pressed.
func _setup_model_settings_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_model_settings.exclusive = false
	_model_settings.theme = PetStyle.dialog_theme(scale)
	_model_settings_current.custom_minimum_size = Vector2(380.0 * scale, 0)
	_model_settings_current.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_model_settings_current.add_theme_font_size_override("font_size", roundi(17.0 * scale))
	_model_settings_hint.custom_minimum_size = Vector2(380.0 * scale, 0)
	_model_settings_hint.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_model_settings_hint.add_theme_font_size_override("font_size", roundi(13.0 * scale))
	_model_picker.custom_minimum_size = Vector2(250.0 * scale, 0)
	_reasoning_picker.custom_minimum_size = Vector2(250.0 * scale, 0)
	($ModelSettings/Box as VBoxContainer).add_theme_constant_override(
		"separation", roundi(14.0 * scale))
	($ModelSettings/Box/Grid as GridContainer).add_theme_constant_override(
		"h_separation", roundi(18.0 * scale))
	($ModelSettings/Box/Grid as GridContainer).add_theme_constant_override(
		"v_separation", roundi(12.0 * scale))
	for label in [$ModelSettings/Box/Grid/ModelLabel,
			$ModelSettings/Box/Grid/ReasoningLabel]:
		(label as Label).add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_model_picker.get_popup().theme = PetStyle.menu_theme(scale)
	_reasoning_picker.get_popup().theme = PetStyle.menu_theme(scale)

	var ok := _model_settings.get_ok_button()
	var primary := PetStyle.primary_button_styles(scale)
	for state in primary:
		ok.add_theme_stylebox_override(state, primary[state])
	ok.add_theme_color_override("font_color", PetStyle.INK)
	ok.add_theme_color_override("font_hover_color", PetStyle.INK)
	ok.add_theme_color_override("font_pressed_color", PetStyle.INK)
	PetStyle.make_ghost_button(_model_settings.get_cancel_button(), scale)

	_model_picker.item_selected.connect(_on_model_settings_model_selected)
	_reasoning_picker.item_selected.connect(_on_model_settings_reasoning_selected)
	_model_settings.confirmed.connect(_apply_model_settings)


func _open_model_settings() -> void:
	var models := LLMService.list_models()
	var efforts := LLMService.list_reasoning_efforts()
	if models.is_empty() or efforts.is_empty():
		return

	_model_picker.clear()
	var current_model := LLMService.get_model()
	var current_index := -1
	for model in models:
		_model_picker.add_item(_model_label(model))
		var index := _model_picker.item_count - 1
		_model_picker.set_item_metadata(index, str(model["id"]))
		if str(model["id"]) == current_model:
			current_index = index
	# Preserve a model entered directly in config instead of silently replacing
	# it merely because the settings window was opened.
	if current_index < 0:
		_model_picker.add_item("%s（自訂）" % current_model)
		current_index = _model_picker.item_count - 1
		_model_picker.set_item_metadata(current_index, current_model)
	_model_picker.select(current_index)

	_reasoning_picker.clear()
	for effort in efforts:
		_reasoning_picker.add_item(_reasoning_label(effort))
		var index := _reasoning_picker.item_count - 1
		_reasoning_picker.set_item_metadata(index, str(effort["id"]))
	_sync_reasoning_picker(LLMService.get_reasoning_effort())
	_model_settings.reset_size()
	_model_settings.popup_centered()


func _selected_picker_value(picker: OptionButton) -> String:
	if picker.selected < 0:
		return ""
	return str(picker.get_item_metadata(picker.selected))


## Keep all six levels visible, but make the selected model's capability
## obvious. A newly incompatible choice is clamped only in the staged UI.
func _sync_reasoning_picker(preferred: String) -> void:
	var model := _selected_picker_value(_model_picker)
	var supported := LLMService.get_supported_reasoning_efforts_for_model(model)
	var effective := LLMService.effective_reasoning_effort_for_model(model, preferred)
	for i in _reasoning_picker.item_count:
		var effort_id := str(_reasoning_picker.get_item_metadata(i))
		_reasoning_picker.set_item_disabled(i, not supported.has(effort_id))
		if effort_id == effective:
			_reasoning_picker.select(i)
	_refresh_model_settings_readout()


func _on_model_settings_model_selected(_index: int) -> void:
	_sync_reasoning_picker(_selected_picker_value(_reasoning_picker))


func _on_model_settings_reasoning_selected(_index: int) -> void:
	_refresh_model_settings_readout()


func _refresh_model_settings_readout() -> void:
	var model := _selected_picker_value(_model_picker)
	var effort := _selected_picker_value(_reasoning_picker)
	var changed := model != LLMService.get_model() \
		or effort != LLMService.get_reasoning_effort()
	_model_settings_current.text = "%s　%s · 推理 %s" % [
		"準備改成" if changed else "現在使用", model, effort]
	var note := ""
	for entry in LLMService.list_reasoning_efforts():
		if str(entry["id"]) == effort:
			note = str(entry.get("note", ""))
			break
	_model_settings_hint.text = "%s%s" % [
		note, "。按「套用」後，下一次對話就會使用新設定。" if changed else "。"]


func _apply_model_settings() -> void:
	var model := _selected_picker_value(_model_picker)
	var effort := _selected_picker_value(_reasoning_picker)
	if model.is_empty() or effort.is_empty():
		return
	LLMService.select_model(model)
	LLMService.select_reasoning_effort(effort)
	_build_menu()


## Voice characters follow the model dialog's staged interaction: opening and
## browsing changes nothing, and the selected character takes effect only after
## 套用. The picker can grow and scroll without making the speech menu taller.
func _setup_voice_settings_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_voice_settings.exclusive = false
	_voice_settings.theme = PetStyle.dialog_theme(scale)
	_voice_settings_current.custom_minimum_size = Vector2(340.0 * scale, 0)
	_voice_settings_current.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_voice_settings_current.add_theme_font_size_override("font_size", roundi(17.0 * scale))
	_voice_picker.custom_minimum_size = Vector2(250.0 * scale, 0)
	($VoiceSettings/Box as VBoxContainer).add_theme_constant_override(
		"separation", roundi(14.0 * scale))
	($VoiceSettings/Box/Grid as GridContainer).add_theme_constant_override(
		"h_separation", roundi(18.0 * scale))
	($VoiceSettings/Box/Grid/VoiceLabel as Label).add_theme_color_override(
		"font_color", PetStyle.NIGHT_MUTED)
	_voice_picker.get_popup().theme = PetStyle.menu_theme(scale)

	var ok := _voice_settings.get_ok_button()
	var primary := PetStyle.primary_button_styles(scale)
	for state in primary:
		ok.add_theme_stylebox_override(state, primary[state])
	ok.add_theme_color_override("font_color", PetStyle.INK)
	ok.add_theme_color_override("font_hover_color", PetStyle.INK)
	ok.add_theme_color_override("font_pressed_color", PetStyle.INK)
	PetStyle.make_ghost_button(_voice_settings.get_cancel_button(), scale)

	_voice_picker.item_selected.connect(_on_voice_settings_selected)
	_voice_settings.confirmed.connect(_apply_voice_settings)


func _open_voice_settings() -> void:
	var voices := TTSService.list_voices()
	if voices.is_empty():
		return
	_fill_voice_picker(voices, TTSService.active_voice())
	_voice_settings.reset_size()
	_voice_settings.popup_centered()


## Separate from opening the window so a large synthetic library can exercise
## the scaling behaviour without depending on voices installed on the machine.
func _fill_voice_picker(voices: PackedStringArray, active: String) -> void:
	_voice_picker.clear()
	var selected := 0
	for i in voices.size():
		_voice_picker.add_item(voices[i])
		_voice_picker.set_item_metadata(i, voices[i])
		if voices[i] == active:
			selected = i
	if not voices.is_empty():
		_voice_picker.select(selected)
	_refresh_voice_settings_readout()


func _on_voice_settings_selected(_index: int) -> void:
	_refresh_voice_settings_readout()


func _refresh_voice_settings_readout() -> void:
	var selected := _selected_picker_value(_voice_picker)
	var changed := not selected.is_empty() and selected != TTSService.active_voice()
	_voice_settings_current.text = "%s　%s" % [
		"準備改成" if changed else "現在使用", selected]


func _apply_voice_settings() -> void:
	var voice := _selected_picker_value(_voice_picker)
	if not voice.is_empty():
		TTSService.select_voice(voice)


## One editor serves both levels of the inheritance chain:
##
##   bundled persona.md <- editable default <- current pet override
##
## Keeping inheritance explicit matters more than saving a click. Copying the
## default into every pet would make a later default edit appear to save while
## most characters quietly kept stale copies.
func _setup_prompt_settings_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_prompt_settings.exclusive = false
	_prompt_settings.theme = PetStyle.dialog_theme(scale)
	_prompt_settings_current.custom_minimum_size = Vector2(620.0 * scale, 0)
	_prompt_settings_current.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_prompt_settings_current.add_theme_font_size_override("font_size", roundi(17.0 * scale))
	_prompt_settings_hint.custom_minimum_size = Vector2(620.0 * scale, 0)
	_prompt_settings_hint.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_prompt_settings_hint.add_theme_font_size_override("font_size", roundi(13.0 * scale))
	_prompt_editor.custom_minimum_size = Vector2(620.0 * scale, 360.0 * scale)
	_prompt_editor.scroll_fit_content_height = false
	_prompt_editor.caret_blink = true
	_prompt_editor.caret_blink_interval = 0.6
	_prompt_editor.add_theme_font_size_override("font_size", roundi(14.0 * scale))
	_prompt_editor.add_theme_constant_override("line_spacing", roundi(4.0 * scale))
	var field_height := 38.0 * scale
	var pad_y := 10.0 * scale
	_prompt_editor.add_theme_stylebox_override("normal",
		PetStyle.input_style(scale, field_height, false, 0.0, pad_y))
	_prompt_editor.add_theme_stylebox_override("read_only",
		PetStyle.input_style(scale, field_height, false, 0.0, pad_y))
	_prompt_editor.add_theme_stylebox_override("focus",
		PetStyle.input_focus_style(scale, field_height, false, 0.0, pad_y))
	_prompt_editor.add_theme_color_override("font_color", PetStyle.INK)
	_prompt_editor.add_theme_color_override("font_readonly_color", PetStyle.INK_SOFT)
	_prompt_editor.add_theme_color_override("caret_color", PetStyle.input_caret_color(false))
	_prompt_editor.add_theme_color_override("selection_color",
		Color(PetStyle.input_caret_color(false), 0.20))
	_prompt_editor.add_theme_color_override("background_color", Color(0, 0, 0, 0))
	_prompt_editor.add_theme_color_override("current_line_color", Color(0, 0, 0, 0))
	_prompt_override.add_theme_color_override("font_color", PetStyle.NIGHT_TEXT)
	_prompt_override.add_theme_color_override("font_hover_color", PetStyle.NIGHT_TEXT)
	($PromptSettings/Box as VBoxContainer).add_theme_constant_override(
		"separation", roundi(12.0 * scale))

	var ok := _prompt_settings.get_ok_button()
	var primary := PetStyle.primary_button_styles(scale)
	for state in primary:
		ok.add_theme_stylebox_override(state, primary[state])
	ok.add_theme_color_override("font_color", PetStyle.INK)
	ok.add_theme_color_override("font_hover_color", PetStyle.INK)
	ok.add_theme_color_override("font_pressed_color", PetStyle.INK)
	PetStyle.make_ghost_button(_prompt_settings.get_cancel_button(), scale)

	_prompt_override.toggled.connect(_on_prompt_override_toggled)
	_prompt_editor.text_changed.connect(_on_prompt_text_changed)
	_prompt_settings.confirmed.connect(_apply_prompt_settings)


func _open_prompt_settings(for_current_pet: bool) -> void:
	if for_current_pet:
		_prompt_target_id = str(Config.get_value(
			"pet", "id", DEFAULT_PET_SELECTION))
		if _prompt_target_id.is_empty():
			_prompt_target_id = DEFAULT_PET_SELECTION
		var pack: PetPack = _visual.get_pack()
		var name := pack.display_name if pack != null else "緊急造型"
		_prompt_settings_current.text = "正在編輯：%s" % name
		_prompt_override.text = "這個造型使用專屬個性與對話方式"
		_prompt_inherited_text = LLMService.get_default_persona()
		_prompt_draft = LLMService.get_persona_for_pet(_prompt_target_id)
		_prompt_override.set_pressed_no_signal(
			LLMService.has_pet_persona_override(_prompt_target_id))
	else:
		_prompt_target_id = ""
		_prompt_settings_current.text = "正在編輯：所有沒有專屬設定的造型"
		_prompt_override.text = "覆寫內建預設個性與對話方式"
		_prompt_inherited_text = LLMService.get_bundled_persona()
		_prompt_draft = LLMService.get_default_persona()
		_prompt_override.set_pressed_no_signal(
			LLMService.has_default_persona_override())

	_prompt_editor.editable = _prompt_override.button_pressed
	_prompt_editor.text = _prompt_draft if _prompt_editor.editable \
		else _prompt_inherited_text
	_refresh_prompt_settings()
	_prompt_settings.reset_size()
	_prompt_settings.popup_centered()
	if _prompt_editor.editable:
		_prompt_editor.call_deferred("grab_focus")


func _on_prompt_override_toggled(enabled: bool) -> void:
	if not enabled and _prompt_editor.editable:
		_prompt_draft = _prompt_editor.text
	_prompt_editor.editable = enabled
	_prompt_editor.text = _prompt_draft if enabled else _prompt_inherited_text
	_refresh_prompt_settings()
	if enabled:
		_prompt_editor.call_deferred("grab_focus")


func _on_prompt_text_changed() -> void:
	if _prompt_editor.editable:
		_prompt_draft = _prompt_editor.text
	_refresh_prompt_settings()


func _refresh_prompt_settings() -> void:
	var custom := _prompt_override.button_pressed
	_prompt_settings.get_ok_button().disabled = custom \
		and _prompt_editor.text.strip_edges().is_empty()
	var source := "內建預設" if _prompt_target_id.is_empty() else "目前的預設個性"
	_prompt_settings_hint.text = "%s。按「套用」後，下一次對話就會生效。\n這裡只調整個性、語氣與常見對話；情緒標記、看螢幕和做事等功能規則由所有造型共用。" \
		% ["正在編輯自訂內容" if custom else "目前繼承%s；勾選後可修改" % source]


func _apply_prompt_settings() -> void:
	var custom := _prompt_override.button_pressed
	if _prompt_target_id.is_empty():
		if custom:
			LLMService.set_default_persona(_prompt_editor.text)
		else:
			LLMService.reset_default_persona()
	elif custom:
		LLMService.set_persona_for_pet(_prompt_target_id, _prompt_editor.text)
	else:
		LLMService.reset_persona_for_pet(_prompt_target_id)


## The entry window. `register_text_enter` is what makes Enter save, which is
## what everyone will try first — a settings field that only accepts a mouse
## click on 儲存 reads as broken to anyone who has ever used a password box.
func _setup_entry_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_secret_entry.exclusive = false
	_secret_entry.theme = PetStyle.dialog_theme(scale)
	# The primary treatment, not the ghost one: saving is the whole reason this
	# window opened, and ghosting it makes the main action look disabled — the
	# mistake ChatLogPanel's 關閉 button and the Codex login dialog both record.
	var ok := _secret_entry.get_ok_button()
	var primary := PetStyle.primary_button_styles(scale)
	for state in primary:
		ok.add_theme_stylebox_override(state, primary[state])
	# The fill is the persimmon accent, so the label has to be ink on all three
	# states or it stays near-white and vanishes into it.
	ok.add_theme_color_override("font_color", PetStyle.INK)
	ok.add_theme_color_override("font_hover_color", PetStyle.INK)
	ok.add_theme_color_override("font_pressed_color", PetStyle.INK)
	PetStyle.make_ghost_button(_secret_entry.get_cancel_button(), scale)
	_secret_blurb.custom_minimum_size = Vector2(300.0 * scale, 0)
	_secret_blurb.add_theme_font_size_override("font_size", roundi(13.0 * scale))
	_secret_field.custom_minimum_size = Vector2(300.0 * scale, 0)
	($SecretEntry/Box as VBoxContainer).add_theme_constant_override(
		"separation", roundi(10.0 * scale))
	_secret_entry.register_text_enter(_secret_field)
	_secret_entry.confirmed.connect(_on_entry_confirmed)
	# Not left to sit in the field: a cancelled paste is still a credential in a
	# node that stays alive for the life of the app.
	_secret_entry.canceled.connect(func() -> void: _secret_field.text = "")


## The one guard that stands between the level the user chose — edit in place —
## and losing work git can't get back. Deliberately a question, not a notice: a
## warning you can't act on is noise, and this one has an obvious action.
##
## Per job rather than per folder, because the answer changes every time. It is
## only asked where it means something: an editable workspace, in a git repo, with
## something uncommitted in it.
func _setup_dirty_warning_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_dirty_warning.exclusive = false
	_dirty_warning.theme = PetStyle.dialog_theme(scale)
	_dirty_warning.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	PetStyle.make_ghost_button(_dirty_warning.get_ok_button(), scale)
	_dirty_warning.confirmed.connect(_on_dirty_warning_confirmed)
	_dirty_warning.canceled.connect(
		_abandon_pending_work.bind("好，那你先去存，弄好再叫我。"))


## Every way of backing out of a job, in one place. Two things have to happen
## besides saying so: the stashed workspace goes, or a later menu-driven job
## inherits it, and a request queued from chat goes with it — otherwise the next
## folder the user picks silently runs the sentence they abandoned.
func _abandon_pending_work(line: String) -> void:
	var was_typed := not _queued_request.is_empty()
	_pending_space = {}
	_queued_request = ""
	_on_pet_nudged("neutral", line, false, false)
	if was_typed:
		# Their question is still in history unanswered. Answer it in words.
		LLMService.answer_without_working()


func _on_work_consent_confirmed() -> void:
	WorkService.grant_consent()
	_begin_work(_pending_space)


func _on_dirty_warning_confirmed() -> void:
	var space := _pending_space
	_pending_space = {}
	if not space.is_empty():
		_open_work_input(space)


## The walk from picking a folder to typing a request. Every step that can
## interrupt it stashes the workspace in `_pending_space` and comes back here.
func _begin_work(space: Dictionary) -> void:
	if space.is_empty():
		return
	_pending_space = space

	if not WorkService.has_consented():
		_work_consent.reset_size()
		_work_consent.popup_centered()
		return
	if WorkService.is_busy():
		_on_pet_nudged("neutral", "我還在做上一件事啦，等我弄完。", false, false)
		return

	# Only the codex runner needs an account of its own; claude carries its own
	# login and is either working or not.
	if WorkService.runner() == WorkService.RUNNER_CODEX and not _codex_ready():
		return

	var path := str(space.get("path", ""))
	var editable := str(space.get("level", "")) == WorkspaceService.LEVEL_EDIT
	if editable:
		var dirty := WorkspaceService.dirty_count(path)
		if dirty > 0:
			_dirty_warning.title = "%s 還有沒存進版本控制的東西" % str(space.get("name", ""))
			_dirty_warning.dialog_text = "\n".join(PackedStringArray([
				"「%s」裡有 %d 個檔案改了還沒 commit。" % [str(space.get("name", "")), dirty],
				"",
				"我等一下會直接改這個資料夾裡的檔案。萬一改壞了，已經 commit 的東西 git 救得回來，這 %d 個救不回來。" % dirty,
				"",
				"要先去存一下，還是就這樣開始？",
			]))
			_dirty_warning.ok_button_text = "就這樣開始"
			_dirty_warning.cancel_button_text = "我先去存"
			_dirty_warning.reset_size()
			_dirty_warning.popup_centered()
			return

	_pending_space = {}
	_open_work_input(space)


## Returns false when a login is in the way and has been dealt with — the caller
## stops, and whatever the user does next comes back through _on_codex_login_*.
func _codex_ready() -> bool:
	if CodexCli.is_logging_in():
		# The armed-button idiom the panels already use, in the only place a menu
		# entry can hold it: told once, and acted on the second time. Without this
		# there is no way out of a login the user has abandoned except waiting for
		# CodexCli.BROWSER_TIMEOUT.
		if not _login_cancel_armed:
			_login_cancel_armed = true
			_on_pet_nudged("neutral", "還在等你登入喔。再點一次就取消。", false, false)
			return false
		CodexCli.cancel_browser_login()
		return false
	# Having the CLI is checked when the menu is built; having an *account* is
	# recoverable, so it is asked about here rather than disabling the entry.
	if not CodexCli.is_logged_in():
		_codex_login.reset_size()
		_codex_login.popup_centered()
		return false
	return true


## The end of every route in. When the request is already known — the model
## proposed it and the user agreed — start straight away; making them retype what
## they just typed is the one thing that would make the chat trigger pointless.
func _open_work_input(space: Dictionary) -> void:
	_pending_space = space
	if not _queued_request.is_empty():
		var request := _queued_request
		_queued_request = ""
		_on_work_submitted(request)
		return
	var suffix := "" if str(space.get("level", "")) == WorkspaceService.LEVEL_EDIT \
		else "（只能看）"
	# Whether the last job's context carries over changes what is worth typing —
	# "再改一下" only means anything if it does. The placeholder is the one place
	# that answer is already in front of the user at the moment they need it, so it
	# costs no extra UI.
	var lead := "接著上次，" if WorkService.would_resume(space) else ""
	_chat.ask_what_to_do("%s要我在 %s 做什麼？%s"
		% [lead, str(space.get("name", "")), suffix])


## The model decided a typed message was a job. It is put to the user rather than
## launched: unlike a screenshot, this spends money and can edit files, so a
## misread sentence must not be able to start one on its own.
##
## Naming the workspace and the request back to them is the whole point of the
## dialog — it is the only place they can see what the model concluded before it
## acts on it.
func _on_work_requested(space_name: String, request: String) -> void:
	var space := _resolve_space(space_name)
	if space.is_empty() or request.strip_edges().is_empty():
		# The model named a folder that isn't there. Don't leave the question
		# hanging — answer it in words.
		LLMService.answer_without_working()
		return
	_pending_work = {"space": space, "request": request.strip_edges()}
	_work_offer.title = "要我去做這件事嗎？"
	_work_offer.dialog_text = "\n".join(PackedStringArray([
		"你剛剛說：「%s」" % request.strip_edges(),
		"",
		"這件事我可以請 %s 進「%s」去做（%s）。"
			% [WorkService.runner_label(WorkService.runner()), str(space["name"]),
				WorkspaceService.level_label(str(space["level"]))],
		"",
		"要的話我就開工，可能要幾分鐘；不要的話我就直接用講的回你。",
	]))
	_work_offer.reset_size()
	_work_offer.popup_centered()


## Whichever folder the model named, or the only one there is. An unnamed tag is
## unambiguous exactly when there is a single workspace, which is the common case
## and the one worth not making the user disambiguate.
func _resolve_space(space_name: String) -> Dictionary:
	var spaces := WorkspaceService.list()
	var usable: Array[Dictionary] = []
	for space in spaces:
		if bool(space["exists"]):
			usable.append(space)
	if usable.is_empty():
		return {}
	var wanted := space_name.strip_edges().to_lower()
	if wanted.is_empty():
		return usable[0] if usable.size() == 1 else {}
	for space in usable:
		if str(space["name"]).to_lower() == wanted:
			return space
	# The model tends to paraphrase a name it half-remembers, so fall back to a
	# containment match before giving up.
	for space in usable:
		var name := str(space["name"]).to_lower()
		if wanted.contains(name) or name.contains(wanted):
			return space
	return usable[0] if usable.size() == 1 else {}


func _setup_work_offer_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_work_offer.exclusive = false
	_work_offer.theme = PetStyle.dialog_theme(scale)
	_work_offer.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_work_offer.ok_button_text = "好，去做"
	_work_offer.cancel_button_text = "不用，用講的就好"
	PetStyle.make_ghost_button(_work_offer.get_ok_button(), scale)
	_work_offer.confirmed.connect(_on_work_offer_accepted)
	# Backing out still owes them an answer: the question is already sitting in
	# history, and leaving it there reads as the pet having ignored them.
	_work_offer.canceled.connect(func() -> void:
		_pending_work = {}
		LLMService.answer_without_working())


func _on_work_offer_accepted() -> void:
	var job := _pending_work
	_pending_work = {}
	if job.is_empty():
		return
	# Through _begin_work so the consent dialog, the busy check, the Codex login
	# prompt and the uncommitted-work warning all still apply — this is a second
	# way in, not a way around.
	_queued_request = str(job["request"])
	_begin_work(job["space"])


# --- Codex login --------------------------------------------------------------

## Two ways in, because they answer different questions. The browser signs in a
## ChatGPT account and spends its quota; the API key is the one this app may
## already be holding, costs nothing extra to offer, and bills the API instead.
##
## The key route is only shown when there *is* a key — a button that explains it
## can't do anything is worse than no button.
func _setup_codex_login_dialog() -> void:
	var scale := _window_ctl.get_ui_scale()
	_codex_login.dialog_text = "\n".join(PackedStringArray([
		"要我做東西得先讓 Codex 有個帳號。它是 OpenAI 自己的工具，我只是請它幫忙。",
		"",
		"・用 ChatGPT 帳號登入：我會開登入頁並給你一組一次性代碼，你輸入就好",
		"・登入頁是 OpenAI 自己的網站，我不會經手你的密碼或憑證",
		"・登入結果存在 Codex 自己的檔案裡，我不會去讀它",
		"・走 ChatGPT 帳號會用掉你的訂閱額度；走 API key 則算在 OpenAI 帳單上",
	]))
	_codex_login.exclusive = false
	_codex_login.theme = PetStyle.dialog_theme(scale)
	_codex_login.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# The main action gets the loud treatment, not the ghost one. Ghosting it made
	# both routes read as equally optional and the primary one look disabled —
	# the same mistake ChatLogPanel's 關閉 button already records, where the ghost
	# style hid the thing the window was for.
	var ok := _codex_login.get_ok_button()
	var primary := PetStyle.primary_button_styles(scale)
	for state in primary:
		ok.add_theme_stylebox_override(state, primary[state])
	ok.add_theme_color_override("font_color", PetStyle.INK)
	ok.add_theme_color_override("font_hover_color", PetStyle.INK)
	ok.add_theme_color_override("font_pressed_color", PetStyle.INK)

	# The quieter of the two routes, and only offered when there is a key to use.
	var with_key := _codex_login.add_button("用我存的 API key", false, "apikey")
	PetStyle.make_ghost_button(with_key, scale)
	with_key.visible = Config.has_secret(OPENAI_KEY)

	_codex_login.confirmed.connect(_start_browser_login)
	_codex_login.custom_action.connect(func(action: StringName) -> void:
		if action == &"apikey":
			_codex_login.hide()
			_login_with_stored_key())


func _start_browser_login() -> void:
	if not CodexCli.begin_browser_login():
		_on_pet_nudged("sad", "咦，登入指令叫不起來欸。", false, false)
		return
	# The code takes a second or two to arrive; CodexCli emits it as a hint, and
	# that line is what actually tells the user what to do.
	_on_pet_nudged("neutral", "等我一下，我去拿登入碼。", false, false)


## Blocking, but only for as long as the CLI takes to write a file — see
## CodexCli.login_with_api_key(). Nothing is said before it, because a "稍等"
## that resolves in the same frame just flickers.
func _login_with_stored_key() -> void:
	if CodexCli.login_with_api_key(Config.get_secret(OPENAI_KEY)):
		_on_pet_nudged("happy", "用你的 API key 登好了，那我開始做。", false, false)
		_begin_work(_pending_space)
		return
	_on_pet_nudged("sad", "那把 key 好像不能用來登入 Codex，要不要改用瀏覽器？", false, false)


func _on_codex_login_hint(message: String) -> void:
	_on_pet_nudged("neutral", message, false, false)


func _on_codex_login_finished(ok: bool, message: String) -> void:
	_login_cancel_armed = false
	_on_pet_nudged("happy" if ok else "sad", message, false, false)
	if ok:
		# Straight on to the thing they actually asked for. The line above stays
		# in the bubble; opening the input doesn't clear it.
		_begin_work(_pending_space)


func _on_work_submitted(text: String) -> void:
	var space := _pending_space
	_pending_space = {}
	if space.is_empty():
		return
	if not WorkService.start(space, text):
		_on_pet_nudged("sad", "咦，我叫不動 %s 欸。"
			% WorkService.runner_label(WorkService.runner()), false, false)
		return
	_work_chatter_at = WORK_CHATTER_EVERY
	# The brain would otherwise wander off mid-job, and the line below arrives
	# minutes later with the pet somewhere else entirely.
	_on_pet_nudged("excited", "好，我去弄，可能要一下子。", false, false)


## How long between the pet mentioning that it is still working. Long enough that
## it reads as company rather than as a progress bar with a voice.
const WORK_CHATTER_EVERY := 120.0

const WORK_CHATTER := [
	"還在弄，別急。",
	"這個有點麻煩欸，再等我一下。",
	"快了快了。",
]


## Driven off the progress signal rather than a timer of its own: steps arrive
## continuously while a job runs, so this needs no new process loop.
##
## Left `unprompted`, unlike everything else in this flow — a "still working" line
## has nothing to say that is worth talking over a reply or an open input, which is
## exactly the case the guard in _on_pet_nudged exists for.
func _on_work_progress(_entry: Dictionary) -> void:
	var job := WorkService.current()
	if job.is_empty():
		return
	var seconds := float(job["seconds"])
	if seconds < _work_chatter_at:
		return
	_work_chatter_at = seconds + WORK_CHATTER_EVERY
	_on_pet_nudged("neutral", WORK_CHATTER[randi() % WORK_CHATTER.size()], false)


## Not recorded, for the same reason the export line isn't: this is the pet
## narrating an action rather than answering anything, and a history whose newest
## turn is that would be re-sent with the next real question for nothing.
##
## What changed comes from git, not from the agent's own account of itself. An
## agent that believes it edited a file and didn't is a real failure mode, and the
## working tree is the truth either way.
func _on_work_finished(result: Dictionary) -> void:
	var line := str(result.get("message", ""))
	if line.is_empty():
		line = "弄完了！"
	var changes: PackedStringArray = result.get("changes", PackedStringArray())
	if changes.is_empty():
		line += "（沒有動到檔案）"
	else:
		line += "（動了 %d 個檔案，詳細在「工作」裡）" % changes.size()
	_on_pet_nudged("happy" if bool(result.get("ok", false)) else "sad", line, false, false)
	_work.refresh_if_open()


func _on_work_failed(reason: String) -> void:
	_on_pet_nudged("sad", reason, false, false)
	_work.refresh_if_open()


## Memory that can't be inspected is memory you can't trust, and a pet quietly
## carrying a wrong fact about you is worse than one that forgets. The list lives
## in its own window (ui/memory_panel.gd) rather than in the bubble, which fades
## on a timer, or in the menu, which can't scroll.
func _on_memories_changed() -> void:
	if not MemoryStore.has_memories():
		_on_pet_nudged("sad", "好……全部清空了，我們重新認識吧。", false)


## Clearing the transcript drops the verbatim turns and keeps the facts, so the
## pet says something that matches that — it forgot the conversation, not you.
## Said out loud rather than left as a silently emptied list, because the two
## clears in this app differ only in what they spare, and the line is where the
## difference is visible.
func _on_conversation_cleared() -> void:
	_on_pet_nudged("neutral", "好，剛剛聊的我放下了。要聊點新的嗎？", false)


## The window knows what it wrote; only here is it decided how the pet reacts —
## the same split the mini-games already make.
##
## Not recorded, for the reason a clear isn't: this is the pet narrating an action
## the user just took, and a history whose newest turn is the pet describing the
## export would be re-sent with the next real question for no reason.
func _on_exported(file_name: String) -> void:
	if file_name.is_empty():
		_on_pet_nudged("sad", "欸，寫不出來……資料夾可能沒權限。", false, false)
		return
	_on_pet_nudged("happy", "寫好了！叫「%s」，在「我做的東西」裡面。" % file_name, false, false)
	# The panel can be open while the transcript window exports into it. This used
	# to sit after a `return` in a helper, so it never ran at all.
	_outbox.refresh_if_open()


func _feed() -> void:
	PetState.feed()
	_on_pet_nudged("happy", "謝謝！這個好吃。")


## The pet's side of a finished run. The game window knows the score and the
## record; only this file knows how the pet reacts to anything, which is why the
## panel emits rather than reaching for PetState or the bubble itself.
##
## Recorded like any other line the pet says: unlike the acknowledgement of a
## *clear*, a game the two of them just played is genuine shared history, and
## the pet referring back to it later is the point of having played.
func _on_game_played(game: String, score: int, treats: int, record: bool) -> void:
	PetState.play_session(treats, score)
	var emotion := "happy"
	var line := "%s %d 分！好玩欸，再來一場？" % [game, score]
	if record:
		emotion = "excited"
		line = "%s %d 分，這是我們最好的一次！" % [game, score]
	elif score == 0:
		emotion = "sad"
		line = "零分…下次我認真一點啦。"
	elif score < 5:
		emotion = "sad"
		line = "才 %d 分，今天手有點鈍。" % score
	_on_pet_nudged(emotion, line)


## Naming the voice saves adding a whole picker just to see which one is in use.
## The unavailable case keeps the label short and puts the reason in the row's
## tooltip: it is a sentence now — which model file is missing, which package —
## and a menu row is not where a sentence goes.
func _voice_label() -> String:
	if not TTSService.is_available():
		return "說話出聲（現在沒有可用的聲音）"
	return "說話出聲（%s）" % TTSService.get_voice_name()


func _toggle_speech() -> void:
	TTSService.set_enabled(not TTSService.is_enabled())
	_set_checked(MenuId.SPEAK, TTSService.is_enabled())


## Anything the voice layer has to tell the user: a backend that fell over, a
## machine too slow for it, a cloning attempt that worked or didn't.
##
## A direct call rather than EventBus.pet_nudged, like every other line the pet
## says about itself — these must be *shown*, not spoken. Half of them exist
## precisely because speech just stopped working, and routing them through the
## thing that broke is how a failure notice becomes silence.
func _on_voice_remarked(text: String) -> void:
	_on_pet_nudged("neutral", text, false, false)


## A home-relative path, for somewhere a full one would not fit.
##
## `AcceptDialog` sizes itself to its content and a path has no spaces in it, so
## `AUTOWRAP_WORD_SMART` cannot break one — the dialog just grows. Measured: the
## user:// models path pushed it wider than a 1920px screen, with both buttons
## off the edge. Shortening the string is the fix; widening the wrap mode would
## only move the break to an arbitrary character mid-path.
func _short_path(path: String) -> String:
	var home := OS.get_environment("HOME")
	if not home.is_empty() and path.begins_with(home):
		return "~" + path.substr(home.length())
	return path


## Render every fixed line, in every voice the speaking backend offers.
##
## Speaks its own progress rather than putting a bar anywhere: this takes about
## a second a clip and the pet is standing right there. Both lines go through
## `_on_pet_nudged(…, false, false)` — the pet answering something the user just
## clicked has to appear even while the chat input is open, and must not be
## recorded as something it said.
func _start_prerender() -> void:
	var count := TTSService.prerender_fixed_lines()
	if count < 0:
		_on_pet_nudged("sad", "這個要用本機服務的聲音才行喔。", false, false)
		return
	if count == 0:
		_on_pet_nudged("happy", "都錄好了，不用再錄一次。", false, false)
		return
	_prerender_left = count
	# Naming the voices matters: the number is several times what the user can
	# see in the menu, and 「17 句」 against 「85 段」 otherwise reads as a bug.
	var voices := TTSService.list_voices().size()
	var scope := "（%d 個聲音都錄）" % voices if voices > 1 else ""
	_on_pet_nudged("neutral", "好，我把 %d 段先錄起來%s，等我一下。" % [count, scope],
		false, false)


func _on_prerender_progress(done: int, left: int) -> void:
	_prerender_left = left
	if left > 0:
		return
	# Said only at the end, and only about what actually landed: a batch cut
	# short by the user typing still leaves everything it finished in the cache,
	# so "none" and "some" are different outcomes and claiming the whole set
	# would be a lie the next silence exposes.
	_on_pet_nudged("happy" if done > 0 else "sad",
		"錄好 %d 段了，以後這幾句我馬上就能講。" % done if done > 0
		else "一段都沒錄成，等一下再試試看？", false, false)


# --- Recording ----------------------------------------------------------------

## One row carrying both halves as a backup. The live bubble now has the direct
## stop action, but keeping this label truthful avoids a second start while a
## recording is already active.
func _record_label() -> String:
	if not RecorderService.is_supported():
		return "錄一段話（這台機器不能錄音）"
	if RecorderService.is_recording():
		return "停止錄音（%s）" % RecorderService.elapsed_text()
	return "錄一段話"


## No dialog, and the reasoning is worth keeping because a microphone looks like
## it should have one. The consent dialogs in this app all guard something that
## happens *without* a fresh human action right now: a background poll
## (PresenceService), or something the model asked for (VisionService, the work
## tag). This is none of those — it happens because the user just clicked 錄一段話,
## it announces itself with an indicator that stays up for as long as the
## microphone is open, nothing is sent anywhere, and stopping is one click in the
## place they started it. Asking "are you sure?" about the thing they just chose
## is the shape of consent, not the substance.
##
## What was genuinely missing is *where it went*, and the honest place to answer
## that is when the file exists — see _on_recording_saved().
func _toggle_recording() -> void:
	if RecorderService.is_recording():
		RecorderService.stop()
		return
	if not RecorderService.start():
		return
	# Stand still and attend. TALK is held open by the indicator being up and ends
	# when the closing line finally fades, so nothing has to remember to undo it.
	_brain.on_talk_started()
	_on_recording_tick(RecorderService.elapsed_text())


## The indicator. It has to answer two questions for as long as it is up — that
## the microphone is live, and how to make it stop — because between those two it
## is the only thing on screen saying so.
func _on_recording_tick(elapsed_text: String) -> void:
	_chat.show_holding("● 錄音中 %s" % elapsed_text, "停止錄音")


## Dedicated rather than routed through _toggle_recording(): if the one-hour
## cap ends between the pointer going down and the signal arriving, a late click
## must do nothing instead of immediately starting a new recording.
func _on_recording_stop_pressed() -> void:
	if RecorderService.is_recording():
		RecorderService.stop()


func _on_recording_saved(file_name: String, seconds: float) -> void:
	var line := "錄好了！叫「%s」，在「我做的東西」裡面。" % file_name
	if seconds >= RecorderService.MAX_SECONDS - 1.0:
		# Otherwise a recording that hit the cap reads as the app having crashed
		# out of it.
		line = "錄滿 %d 分鐘我就先停了，存成「%s」，在「我做的東西」裡面。" \
			% [int(RecorderService.MAX_SECONDS / 60.0), file_name]
	if not bool(Config.get_value("recorder", "told_where", false)):
		# Once, at the moment it means something: the file exists and they are
		# about to go looking for it. Not a dialog before the fact, which would be
		# asking a question that has one answer.
		line += "只會存在你自己的電腦，不會送去任何地方喔。"
		Config.set_value("recorder", "told_where", true)
	_on_pet_nudged("happy", line, false, false)
	_outbox.refresh_if_open()


func _on_recording_failed(reason: String) -> void:
	_on_pet_nudged("sad", reason, false, false)


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
