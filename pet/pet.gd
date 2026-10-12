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
	COMPANION_STATUS,
	SPEECH_INPUT,
}

@onready var _window_ctl: WindowController = $WindowController
@onready var _brain: PetBrain = $Brain
@onready var _visual: PetVisual = $Visual
@onready var _chat: ChatPanel = $Chat
@onready var _menu: PopupMenu = $Menu
@onready var _consent: ConfirmationDialog = $Consent
@onready var _presence_consent: ConfirmationDialog = $PresenceConsent
@onready var _model_settings: ModelSettingsDialog = $ModelSettings
@onready var _voice_settings: VoiceSettingsDialog = $VoiceSettings
@onready var _prompt_settings: PromptSettingsDialog = $PromptSettings
## Where every key and the service address are typed.
@onready var _entry: EntryDialog = $SecretEntry
## Everything between picking a workspace and a job's result. Not a Window, so
## it can sit anywhere; the dialogs it drives stay direct children of Pet.
@onready var _work_flow: WorkFlow = $WorkFlow
@onready var _speech_consent: ConfirmationDialog = $SpeechConsent
@onready var _memory: MemoryPanel = $Memory
@onready var _chat_log: ChatLogPanel = $ChatLog
@onready var _game: GamePanel = $Game
@onready var _outbox: OutboxPanel = $Outbox
@onready var _work: WorkPanel = $Work
@onready var _monitor: MonitorPanel = $Monitor
@onready var _companion_status: CompanionStatusPanel = $CompanionStatus

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
## What the entry window collects besides `Config` secret names: the one thing
## it asks for that is not a secret. The window is one node serving four
## settings, so each ask says which — otherwise the handler could only ever store
## one, and the rest would quietly land under its name.
const URL_ENTRY := "voxcpm_url"
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
	_chat.work_submitted.connect(_work_flow.submit)
	TTSService.backend_checked.connect(_on_backend_checked)
	TTSService.voice_library_refreshed.connect(_on_voice_library_refreshed)
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
	EventBus.bond_stage_reached.connect(_on_bond_stage_reached)
	EventBus.screen_look_requested.connect(_on_screen_look_requested)
	EventBus.resource_alert.connect(_on_resource_alert)
	_setup_consent_dialog()
	_setup_presence_consent_dialog()
	var ui_scale := _window_ctl.get_ui_scale()
	_model_settings.setup(ui_scale)
	_model_settings.applied.connect(_build_menu)
	_voice_settings.setup(ui_scale)
	_prompt_settings.setup(ui_scale)
	_entry.setup(ui_scale)
	_entry.submitted.connect(_on_entry_submitted)
	_work_flow.setup(ui_scale, $WorkConsent, $WorkOffer, $DirtyWarning, $CodexLogin)
	_work_flow.said.connect(_on_pet_nudged)
	_work_flow.wants_input.connect(_chat.ask_what_to_do)
	_work_flow.job_ended.connect(_work.refresh_if_open)
	RecorderService.tick.connect(_on_recording_tick)
	RecorderService.saved.connect(_on_recording_saved)
	RecorderService.failed.connect(_on_recording_failed)
	_chat.holding_action_pressed.connect(_on_holding_action_pressed)
	_chat.hit_region_changed.connect(_refresh_mask)
	TTSService.remarked.connect(_on_voice_remarked)
	# The row names the voice in use, and every one of these changes it.
	TTSService.voice_changed.connect(_build_menu)
	TTSService.prerender_progress.connect(_on_prerender_progress)
	SpeechInputService.tick.connect(_on_speech_input_tick)
	SpeechInputService.transcribing.connect(_on_speech_transcribing)
	SpeechInputService.transcribed.connect(_on_speech_transcribed)
	SpeechInputService.failed.connect(_on_speech_input_failed)
	_speech_consent.confirmed.connect(_start_speech_input)
	_register_window_frame_rates()

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
	_welcome_back()


## The bubble grows as the reply types itself out and shifts as the pet walks, so
## a mask that clips rendering has to follow it. set_hit_region() drops a region
## that hasn't actually changed, so a still bubble costs nothing.
func _process(_delta: float) -> void:
	# Mouse motion events belong to the native pet window. While the body trails
	# the cursor, a quick drag can carry the cursor outside that window between
	# frames, and no further motion event is guaranteed to arrive. Polling the
	# desktop cursor while held keeps the window underneath it, so dragging is
	# limited by the desktop bounds rather than by the window's invisible rect.
	if _pressed:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_update_drag()
		else:
			# A release outside the old window may not reach _unhandled_input.
			_end_press()
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


func _welcome_back() -> void:
	var greeting := CompanionProfile.return_greeting(PetState.offline_minutes())
	if greeting.is_empty():
		return
	# Let startup warnings and window placement settle first. If another visible
	# interaction has already started, silence beats talking over it.
	await get_tree().create_timer(4.0).timeout
	if _chat.is_showing() or _chat.is_input_open() or LLMService.is_busy():
		return
	_on_pet_nudged(str(greeting.get("emotion", "greeting")),
		str(greeting.get("text", "")), true, true)


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
	CompanionProfile.apply_pack(pack)
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
	# On macOS and Linux this node normally does not process every frame; keep it
	# awake for the global-cursor polling above until the button is released.
	set_process(true)


## Keep the native window directly under the held cursor. Letting the window
## itself trail the pointer creates an input dead zone: once the pointer outruns
## the only OS window that can receive it, vertical dragging appears confined to
## the window's old rectangle. The brain still receives the target so release
## and home-position state stay unchanged.
func _update_drag() -> void:
	var mouse := DisplayServer.mouse_get_position()
	if not _dragging and Vector2(mouse - _press_pos).length() > DRAG_THRESHOLD:
		_dragging = true
		EventBus.pet_grabbed.emit()
	if _dragging:
		var target := mouse - _grab_offset
		_brain.set_drag_target(target)
		if target != _window_ctl.get_pet_screen_position():
			_window_ctl.set_pet_screen_position(target)


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
	# Windows needs continuous processing for its render-clipping passthrough
	# mask. Other platforms can go idle again once drag polling is no longer used.
	set_process(WindowController.passthrough_clips_rendering())


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


## Every panel, game and dialog in this scene is a real OS window, and all of them
## share one main loop with the pet — so an open one inherits whatever the pet is
## doing, which at idle is six frames a second. Each says what it needs instead.
##
## Walked rather than named, for the reason CLAUDE.md already gives about the
## right-click menu: the panels are the group that grows, and a registration step
## someone has to remember is a seventh panel that scrolls at 6 fps. The right-click
## PopupMenu is a Window too and is deliberately included — a menu is something
## you are looking at.
func _register_window_frame_rates() -> void:
	for child in get_children():
		var win := child as Window
		if win == null:
			continue
		var fps: int = FrameBudget.GAME_FPS if win is GamePanel else FrameBudget.PANEL_FPS
		var key := StringName("window:%s" % win.name)
		win.visibility_changed.connect(
			func() -> void:
				if win.visible:
					FrameBudget.request(key, fps)
				else:
					FrameBudget.release(key))
		if win.visible:
			FrameBudget.request(key, fps)


func _on_input_toggled(open: bool) -> void:
	# The input needs clicks, so the passthrough mask has to grow to include it.
	_refresh_hit_region()
	# The chat input is the one typing surface that is *not* its own OS window, so
	# _register_window_frame_rates() cannot see it. It also outlives TALK: a drag
	# knocks the brain back to IDLE with the field still up, and at IDLE's 6 fps
	# that is someone typing into a field redrawing six times a second.
	if open:
		FrameBudget.request(&"chat-input", FrameBudget.PANEL_FPS)
	else:
		FrameBudget.release(&"chat-input")
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
	# Through WorkFlow.begin(), never straight to the input. Going direct skipped every
	# gate at once — the consent dialog, the busy check, the Codex login prompt and
	# the uncommitted-work warning — which made dropping a folder the one way to
	# reach an agent without ever being asked.
	_work_flow.begin(space)


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
		unprompted := true, speak := true) -> void:
	if unprompted and (_chat.is_showing() or _chat.is_input_open()):
		return
	_brain.on_talk_started()
	_chat.begin_reply()
	_on_emotion_changed(emotion)
	_chat.append_reply(text)
	_chat.end_reply()
	if speak:
		TTSService.speak_line(text)
	if record:
		LLMService.note_pet_said(text)


func _on_bond_stage_reached(stage: Dictionary) -> void:
	var text := str(stage.get("line", "")).strip_edges()
	if text.is_empty():
		return
	_on_pet_nudged(str(stage.get("emotion", "happy")), text, true, false)


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
## setting the app has, at the same weight as the role's primary care action.
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
	if CompanionProfile.care_enabled():
		_menu.add_item(CompanionProfile.care_action_label(), MenuId.FEED)
	# Down here with the role's care action rather than up with the setting groups:
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
	_menu.add_item(_speech_input_label(), MenuId.SPEECH_INPUT)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.SPEECH_INPUT),
		not SpeechInputService.is_supported())
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
	menu.add_item("小夥伴狀態…", MenuId.COMPANION_STATUS)
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
	_set_item_text(MenuId.SPEECH_INPUT, _speech_input_label())
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
			_work_flow.begin(spaces[index])
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
		MenuId.SPEECH_INPUT:
			_toggle_speech_input()
		MenuId.RECENTRE:
			_window_ctl.park_at_default_spot()
			_brain.set_home_here()
		MenuId.MODEL_SETTINGS:
			_model_settings.open()
		MenuId.VOICE_SETTINGS:
			_voice_settings.open()
		MenuId.PROMPT_DEFAULT:
			_open_prompt_settings(false)
		MenuId.PROMPT_CURRENT:
			_open_prompt_settings(true)
		MenuId.SET_KEY:
			_entry.ask(OPENAI_KEY, "OpenAI API key",
				"用來聊天跟看螢幕的。%s" % _entry_storage_note(), true)
		MenuId.SET_ELEVEN_KEY:
			_entry.ask(ElevenVoice.KEY_NAME, "ElevenLabs API key",
				"雲端語音要用的。%s" % _entry_storage_note(), true)
		MenuId.SET_VOXCPM_KEY:
			_entry.ask(VoxCPMVoice.KEY_NAME, "VoxCPM 服務的 API key",
				"只有在服務開了驗證時才需要。%s" % _entry_storage_note(), true)
		MenuId.SET_VOXCPM_URL:
			# The one entry here that is not a secret, so it is not masked and it
			# opens showing the current value: editing an address is a different
			# act from retyping one from memory, and retyping is how a working
			# setting becomes a typo.
			_entry.ask(URL_ENTRY, "VoxCPM 服務位置",
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
		MenuId.COMPANION_STATUS:
			_companion_status.open(_window_ctl.get_ui_scale())
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


func _entry_storage_note() -> String:
	var where := Config.secret_backend_name()
	return "會存進 %s。" % where if not where.is_empty() \
		else "這台機器沒有安全儲存，只能存成明文設定檔。"


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


func _on_entry_submitted(what: String, value: String) -> void:
	if what == URL_ENTRY:
		_on_url_submitted(value)
	else:
		_on_secret_submitted(what, value)


func _on_secret_submitted(key: String, value: String) -> void:
	# Almost always a stray character from a bad paste — API keys are ASCII, and
	# the Keychain can't round-trip anything else. See SecretStore.write().
	if not SecretStore.is_ascii(value):
		_on_pet_nudged("sad", "這個 key 有奇怪的字元，是不是貼到多餘的東西了？")
		return

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


## Which persona the editor opens on is the pet's business — it knows the
## selection and the pack's name; the dialog only edits.
func _open_prompt_settings(for_current_pet: bool) -> void:
	if not for_current_pet:
		_prompt_settings.open("", "")
		return
	var pet_id := str(Config.get_value("pet", "id", DEFAULT_PET_SELECTION))
	if pet_id.is_empty():
		pet_id = DEFAULT_PET_SELECTION
	var pack: PetPack = _visual.get_pack()
	_prompt_settings.open(pet_id, pack.display_name if pack != null else "緊急造型")


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
	PetState.care()
	var reply := CompanionProfile.care_reply()
	_on_pet_nudged(str(reply.get("emotion", "happy")), str(reply.get("text", "")))


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
	# This line exists because speech failed; do not feed it back through the
	# subsystem that just reported the failure.
	_on_pet_nudged("neutral", text, false, false, false)


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


func _speech_input_label() -> String:
	if SpeechInputService.is_listening():
		return "停止聆聽並送出（%s）" % SpeechInputService.elapsed_text()
	if SpeechInputService.is_transcribing():
		return "正在把聲音變成文字…"
	return "用聲音跟我說話…"


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
	if SpeechInputService.is_busy():
		_on_pet_nudged("neutral", "我正在聽你說話，等這次結束再錄音喔。", false, false)
		return
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
func _on_holding_action_pressed() -> void:
	if SpeechInputService.is_listening():
		SpeechInputService.stop_and_transcribe()
	elif RecorderService.is_recording():
		RecorderService.stop()


func _toggle_speech_input() -> void:
	if SpeechInputService.is_listening():
		SpeechInputService.stop_and_transcribe()
		return
	if SpeechInputService.is_transcribing():
		return
	if RecorderService.is_recording():
		_on_pet_nudged("neutral", "我還在錄音，先停下來才能聽你說話。", false, false)
		return
	if not bool(Config.get_value("speech_input", "consented", false)):
		_speech_consent.popup_centered()
		return
	_start_speech_input()


func _start_speech_input() -> void:
	Config.set_value("speech_input", "consented", true)
	if not SpeechInputService.start():
		return
	_brain.on_talk_started()
	_on_speech_input_tick(SpeechInputService.elapsed_text())


func _on_speech_input_tick(elapsed_text: String) -> void:
	_chat.show_holding("● 正在聽 %s\n說完按下面送出" % elapsed_text, "停止並送出")


func _on_speech_transcribing() -> void:
	_chat.show_holding("正在把聲音變成文字…")


func _on_speech_transcribed(text: String) -> void:
	_chat.hide_bubble()
	_on_chat_submitted(text)


func _on_speech_input_failed(reason: String) -> void:
	_chat.hide_bubble()
	_on_pet_nudged("sad", reason, false, false)


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
