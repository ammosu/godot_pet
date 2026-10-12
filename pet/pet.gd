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

const MenuId := PetMenu.MenuId

@onready var _window_ctl: WindowController = $WindowController
@onready var _brain: PetBrain = $Brain
@onready var _visual: PetVisual = $Visual
@onready var _chat: ChatPanel = $Chat
@onready var _menu: PetMenu = $Menu
@onready var _model_settings: ModelSettingsDialog = $ModelSettings
@onready var _voice_settings: VoiceSettingsDialog = $VoiceSettings
@onready var _prompt_settings: PromptSettingsDialog = $PromptSettings
## Everything between picking a workspace and a job's result. Not a Window, so
## it can sit anywhere; the dialogs it drives stay direct children of Pet.
@onready var _work_flow: WorkFlow = $WorkFlow
@onready var _senses: SensesFlow = $SensesFlow
@onready var _settings: SettingsFlow = $SettingsFlow
@onready var _microphone: MicrophoneFlow = $MicrophoneFlow
@onready var _memory: MemoryPanel = $Memory
@onready var _chat_log: ChatLogPanel = $ChatLog
@onready var _game: GamePanel = $Game
@onready var _outbox: OutboxPanel = $Outbox
@onready var _work: WorkPanel = $Work
@onready var _monitor: MonitorPanel = $Monitor
@onready var _companion_status: CompanionStatusPanel = $CompanionStatus

## Mirrored into the menu on every write, for the ticked row in 大小.
var _size_factor := DEFAULT_SIZE_FACTOR:
	set(value):
		_size_factor = value
		if _menu != null:
			_menu.size_factor = value
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
	_menu.size_factor = _size_factor
	_menu.setup(_window_ctl.get_ui_scale(), _visual, _brain, DEFAULT_PET_SELECTION)
	_menu.action.connect(_on_menu_action)
	_menu.pack_chosen.connect(_switch_pack)
	_menu.size_chosen.connect(_set_size_factor)
	_menu.game_chosen.connect(func(index: int) -> void:
		_game.open(_window_ctl.get_ui_scale(), _visual.get_pack(),
			_visual.state_rows(), index))
	_menu.workspace_chosen.connect(func(space: Dictionary) -> void: _work_flow.begin(space))
	_memory.memories_changed.connect(_on_memories_changed)
	_chat_log.conversation_cleared.connect(_on_conversation_cleared)
	_chat_log.exported.connect(_on_exported)
	_game.played.connect(_on_game_played)
	# The panel is where a workspace is added or dropped, and the 幫我做事 submenu
	# is built off that list.
	_work.workspaces_changed.connect(_menu.rebuild)

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
	var ui_scale := _window_ctl.get_ui_scale()
	_senses.setup(ui_scale, $Consent, $PresenceConsent)
	_senses.said.connect(_on_pet_nudged)
	_senses.check_changed.connect(_menu.set_checked)
	_model_settings.setup(ui_scale)
	_model_settings.applied.connect(_menu.rebuild)
	_voice_settings.setup(ui_scale)
	_prompt_settings.setup(ui_scale)
	($SecretEntry as EntryDialog).setup(ui_scale)
	_settings.setup($SecretEntry)
	_settings.said.connect(_on_pet_nudged)
	_settings.check_changed.connect(_menu.set_checked)
	_settings.menu_stale.connect(_menu.rebuild)
	_settings.prerender_changed.connect(func(left: int) -> void: _menu.prerender_left = left)
	_work_flow.setup(ui_scale, $WorkConsent, $WorkOffer, $DirtyWarning, $CodexLogin)
	_work_flow.said.connect(_on_pet_nudged)
	_work_flow.wants_input.connect(_chat.ask_what_to_do)
	_work_flow.job_ended.connect(_work.refresh_if_open)
	_microphone.setup(ui_scale, $SpeechConsent)
	_microphone.said.connect(_on_pet_nudged)
	_microphone.holding.connect(_chat.show_holding)
	_microphone.holding_ended.connect(_chat.hide_bubble)
	_microphone.attending.connect(_brain.on_talk_started)
	_microphone.transcribed.connect(_on_chat_submitted)
	_microphone.saved.connect(_outbox.refresh_if_open)
	_chat.holding_action_pressed.connect(_microphone.on_holding_action_pressed)
	_companion_status.care_requested.connect(_feed)
	_companion_status.recentre_requested.connect(_recentre)
	_setup_quit_confirm(ui_scale)
	_chat.hit_region_changed.connect(_refresh_mask)
	# The row names the voice in use, and every one of these changes it.
	TTSService.voice_changed.connect(_menu.rebuild)
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
	var installed := PetPack.list_installed()
	var wanted: String = Config.get_value("pet", "id", "")
	# First run with something installed: adopt it. Otherwise use the bundled
	# v2 pet; later explicit default selections persist as DEFAULT_PET_SELECTION.
	if wanted.is_empty() and not installed.is_empty():
		wanted = installed[0]
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
			_menu.open_at_mouse()
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
	_menu.rebuild()
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

## Whatever the menu could not do by itself — every row whose effect is the
## pet doing or saying something.
func _on_menu_action(id: int) -> void:
	match id:
		MenuId.GET_PETS:
			OS.shell_open(PET_GALLERY_URL)
		MenuId.FEED:
			_feed()
		MenuId.NUDGES:
			_toggle_nudges()
		MenuId.PRESENCE:
			_senses.toggle_presence()
		MenuId.MONITOR:
			_senses.toggle_monitor()
		MenuId.SPEAK:
			_settings.toggle_speech()
		MenuId.PRERENDER:
			_settings.start_prerender()
		MenuId.REFRESH_VOICES:
			_settings.refresh_voice_library()
		MenuId.ROAM:
			_toggle_roaming()
		MenuId.CALIBRATE:
			_toggle_calibration()
		MenuId.RECORD:
			_microphone.toggle_recording()
		MenuId.SPEECH_INPUT:
			_microphone.toggle_speech_input()
		MenuId.RECENTRE:
			_recentre()
		MenuId.STOP_WORK:
			# cancel() reports what the job had already changed by itself, through
			# WorkFlow's failed line — nothing to say here.
			WorkService.cancel()
		MenuId.MODEL_SETTINGS:
			_model_settings.open()
		MenuId.VOICE_SETTINGS:
			_voice_settings.open()
		MenuId.PROMPT_DEFAULT:
			_open_prompt_settings(false)
		MenuId.PROMPT_CURRENT:
			_open_prompt_settings(true)
		MenuId.SET_KEY, MenuId.SET_ELEVEN_KEY, MenuId.SET_VOXCPM_KEY, MenuId.SET_VOXCPM_URL:
			_settings.ask(id)
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
			_request_quit()


func _recentre() -> void:
	_window_ctl.park_at_default_spot()
	_brain.set_home_here()


func _setup_quit_confirm(ui_scale: float) -> void:
	var dialog: ConfirmationDialog = $QuitConfirm
	dialog.exclusive = false
	dialog.theme = PetStyle.dialog_theme(ui_scale)
	PetStyle.fit_dialog_text(dialog, PetStyle.DIALOG_TEXT_WIDTH, ui_scale)
	# The way out of the dialog is the quiet button; the one that ends something
	# in progress should not be the one an Enter lands on by habit.
	PetStyle.make_ghost_button(dialog.get_ok_button(), ui_scale)
	dialog.confirmed.connect(func() -> void: get_tree().quit())


## Quitting used to be immediate whatever was running. A job is killed by
## WorkService._exit_tree() with its edits left half-made on disk, and nothing
## said so; a recording is saved but cut short. Ask only when one of those is
## true — an idle pet still quits in one click.
func _request_quit() -> void:
	var warning := quit_warning(WorkService.current(), RecorderService.is_recording(),
		SpeechInputService.is_busy())
	if warning.is_empty():
		get_tree().quit()
		return
	var dialog: ConfirmationDialog = $QuitConfirm
	dialog.dialog_text = warning
	PetStyle.popup_fitted(dialog)


## What quitting now would cut short, one line per thing, each saying what
## actually happens to it — not one generic 「會中斷」. Empty when nothing is.
static func quit_warning(job: Dictionary, recording: bool, listening: bool) -> String:
	var lines := PackedStringArray()
	if not job.is_empty():
		lines.append("我還在 %s 做事。現在結束會直接停掉它，已經改過的檔案會留在原地，不會還原。"
			% str(job.get("space", {}).get("name", "")))
	if recording:
		lines.append("錄音還沒停。結束前會先把錄到的部分存進「我做的東西」。")
	if listening:
		lines.append("你跟我說的話還沒變成文字，現在結束這段就沒了。")
	return "\n\n".join(lines)


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


func _toggle_nudges() -> void:
	var enabled := not Nudger.is_enabled()
	Nudger.set_enabled(enabled)
	_menu.set_checked(MenuId.NUDGES, enabled)


func _toggle_roaming() -> void:
	var roaming := not _brain.is_roaming()
	_brain.set_roaming(roaming)
	Config.set_value("pet", "roaming", roaming)
	_menu.set_checked(MenuId.ROAM, roaming)


func _set_size_factor(factor: float) -> void:
	_size_factor = factor
	Config.set_value("pet", "size_factor", factor)
	_layout_visual()
	_refresh_hit_region()
	_menu.rebuild()


func _switch_pack(pet_id: String) -> void:
	_visual.set_calibrating(false)
	_brain.set_paused(false)
	_apply_pack(pet_id)
	_menu.rebuild()


## Freeze the brain while cycling rows, otherwise it keeps overriding the
## animation we're trying to look at.
func _toggle_calibration() -> void:
	var on := not _visual.is_calibrating()
	_visual.set_calibrating(on)
	_brain.set_paused(on)
	_menu.set_checked(MenuId.CALIBRATE, _visual.is_calibrating())
