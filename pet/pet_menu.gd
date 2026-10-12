class_name PetMenu
extends PopupMenu

## The right-click menu: what is in it, what each row currently says, and which
## row was picked. It decides nothing about what a row *does* beyond changing a
## setting — everything else goes back to pet.gd as a signal, because what the
## pet does and says in response is the composition root's business.
##
## The script on the existing `Menu` node, so it stays a direct child of `Pet`
## and its submenus keep their node names (`Menu/Model`, `Menu/Looks`, …).

## A row with no range of its own was picked.
signal action(id: int)
## A pack was picked — an installed id, or the built-in default's selection id.
signal pack_chosen(pet_id: String)
signal size_chosen(factor: float)
## Index into GamePanel's registry.
signal game_chosen(index: int)
signal workspace_chosen(space: Dictionary)

## Menu ids above these offsets select an installed pet pack / a body size /
## an LLM backend / a mini-game / a workspace to go and work in / a voice.
##
## Every test against these in `_on_id_pressed` is "at or above", so they must
## be checked highest-first — a workspace id at 600 also satisfies every range
## test below it. The constants and the test live in this one file so that rule
## cannot be split from the numbers it is about.
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

const OPENAI_KEY: String = preload("res://llm/providers/openai_provider.gd").KEY_NAME

enum MenuId {
	FALLBACK, GET_PETS, FEED, NUDGES, PRESENCE, MONITOR, SPEAK, ROAM, CALIBRATE,
	RECENTRE, SET_KEY, SET_ELEVEN_KEY, SET_VOXCPM_KEY, SET_VOXCPM_URL,
	CHAT_LOG, MEMORY, OUTBOX, LOOK, WORK, ADD_SPACE, LOAD,
	RECORD, PRERENDER, REFRESH_VOICES, MODEL_SETTINGS, QUIT,
	VOICE_SETTINGS, PROMPT_DEFAULT, PROMPT_CURRENT,
	COMPANION_STATUS,
	SPEECH_INPUT,
}

## The body size currently in use, for the ticked row in 大小. Set by pet.gd,
## which owns the value.
var size_factor := 0.75
## How many pre-rendered lines are still outstanding, so the row can say so and
## refuse to start a second batch on top of the first. Set by pet.gd.
var prerender_left := 0

var _visual: PetVisual
var _brain: PetBrain
## The selection id that means "the built-in pack", owned by pet.gd.
var _default_selection := ""
var _installed_pets := PackedStringArray()
## Submenus, kept between rebuilds — PopupMenu.clear() empties the items but
## leaves child nodes alone, so these are created once and refilled.
var _submenus := {}
## Which menu each item id ended up in, so a checkbox can be ticked in place
## without hunting through the tree for it.
var _item_menus := {}
## The voice names the 說話 submenu was last drawn with. See open_at_mouse().
var _listed_voices := PackedStringArray()


## Called from pet.gd's _ready(). The visual and the brain are only read, for
## the rows that report what the pet is currently doing.
func setup(scale: float, visual: PetVisual, brain: PetBrain,
		default_selection: String) -> void:
	_visual = visual
	_brain = brain
	_default_selection = default_selection
	_installed_pets = PetPack.list_installed()
	_style(scale)
	id_pressed.connect(_on_id_pressed)
	rebuild()


## The menu is a native OS window (subwindow embedding is off), and Godot sizes
## native windows in physical pixels — so the stock theme renders undersized on
## anything above 100%. Scale the theme rather than the window, so reset_size()
## still computes a min size that fits.
func _style(scale: float) -> void:
	theme = PetStyle.menu_theme(scale)


## Reused between rebuilds. Submenus have to exist under the menu that points at
## them before add_submenu_node_item() can use them. Most belong to the root;
## nested advanced settings pass their immediate parent explicitly.
func _submenu(key: String, parent: PopupMenu = null) -> PopupMenu:
	var owner: PopupMenu = self if parent == null else parent
	if _submenus.has(key):
		var existing: PopupMenu = _submenus[key]
		existing.clear()
		if existing.get_parent() != owner:
			existing.reparent(owner)
		return existing
	var menu := PopupMenu.new()
	menu.name = key
	menu.theme = theme
	menu.id_pressed.connect(_on_id_pressed)
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
func rebuild() -> void:
	clear()
	_item_menus.clear()
	var current: PetPack = _visual.get_pack()

	add_submenu_node_item("造型", _build_looks_menu(current))
	add_submenu_node_item("大小", _build_size_menu())
	add_submenu_node_item("語言模型", _build_model_menu())
	# Next to 語言模型 because they are the same question asked twice: which model
	# thinks, and which one speaks. A fifth setting group rather than another row
	# in 行為, because speech stopped being one switch — there is now a backend, a
	# voice, and the on/off, and three questions is what a submenu is for. It also
	# takes a row *out* of 行為, where the one naming a voice never fitted among
	# rows describing what the pet does.
	add_submenu_node_item("說話", build_speech_menu())
	add_submenu_node_item("行為", _build_behaviour_menu(current))

	add_separator()
	if CompanionProfile.care_enabled():
		add_item(CompanionProfile.care_action_label(), MenuId.FEED)
	# Down here with the role's care action rather than up with the setting groups:
	# things you do *with* the pet, not things you do to the app.
	add_submenu_node_item("遊戲", _build_games_menu())
	add_item("看一下我的螢幕…", MenuId.LOOK)
	set_item_disabled(get_item_index(MenuId.LOOK), not VisionService.is_supported())
	# A submenu rather than an item, because "做事" always has a *where*, and
	# picking it up front is what keeps the pet from having to guess between
	# however many projects the user keeps.
	add_submenu_node_item("幫我做事", _build_work_menu())
	# Disabled rather than hidden: an entry that vanishes on a machine without the
	# CLI is a feature nobody discovers exists, the same call the 依你的節奏搭話
	# row makes where PresenceService reports unsupported.
	set_item_disabled(get_item_count() - 1, not WorkService.is_supported())
	# The sixth verb, which CLAUDE.md names as the point to stop and think. The
	# thinking: 錄音 is something you ask the pet to do *for* you and the result is
	# something it then holds — the same shape as 幫我做事, not the shape of a
	# window. It could have been a button in 我做的東西's footer, one group along
	# and free of charge, but then you would be talking to a window rather than
	# handing something to the pet, which is the entire premise of the app. So it
	# is a verb, and it is one row rather than two because the row carries its own
	# stop. Measured: 14 rows, 392px on this 1080p desktop — still short of the
	# 476px that forced Godot to shove the flat menu upward.
	add_item(_record_label(), MenuId.RECORD)
	set_item_disabled(get_item_index(MenuId.RECORD),
		not RecorderService.is_supported())
	add_item(_speech_input_label(), MenuId.SPEECH_INPUT)
	set_item_disabled(get_item_index(MenuId.SPEECH_INPUT),
		not SpeechInputService.is_supported())
	add_item("回到角落", MenuId.RECENTRE)

	# Its own block, because it is a different kind of thing from everything above
	# it: those are verbs, this is a door. No ellipsis — in this menu "…" means
	# "opens something further", which a submenu arrow already says.
	add_separator()
	add_submenu_node_item("查看", _build_panels_menu())

	add_separator()
	add_item("結束", MenuId.QUIT)

	_index_items(self)


func _build_looks_menu(_current: PetPack) -> PopupMenu:
	var menu := _submenu("Looks")
	var current_id: String = Config.get_value("pet", "id", _default_selection)
	for i in _installed_pets.size():
		var pet_id := _installed_pets[i]
		menu.add_radio_check_item(pet_id, PET_ID_BASE + i)
		menu.set_item_checked(menu.get_item_index(PET_ID_BASE + i), pet_id == current_id)
	menu.add_radio_check_item("預設造型（芽尾）", MenuId.FALLBACK)
	menu.set_item_checked(menu.get_item_index(MenuId.FALLBACK),
		current_id.is_empty() or current_id == _default_selection)
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
			is_equal_approx(float(choice["factor"]), size_factor))
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


func _api_key_label() -> String:
	var where := Config.secret_backend_name()
	var suffix := "存進 %s" % where if not where.is_empty() else "無安全儲存，會存成明文"
	return "%s OpenAI API key（%s）" \
		% ["更換" if Config.has_secret(OPENAI_KEY) else "設定", suffix]


## Which voice, whether to use it, and — once there is a local engine — whose it
## is. The row still names the voice rather than hiding it behind a picker, which
## is the one thing that would have made the Afrikaans bug visible: it said
## 說話出聲（Afrikaans）for weeks and was never read.
func build_speech_menu() -> PopupMenu:
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
		append_voice_summary(menu, voices, TTSService.active_voice())
		# Under the voices because it renders *all of them*, not the ticked one —
		# so it belongs beside the picker rather than inside it. The count is in
		# the label for the same reason: without it the row reads as being about
		# the current voice, which is what it used to be.
		menu.add_item(_prerender_label(voices.size()), MenuId.PRERENDER)
		menu.set_item_disabled(menu.get_item_index(MenuId.PRERENDER), prerender_left > 0)
	_index_items(menu)
	return menu


## Naming the voice saves adding a whole picker just to see which one is in use.
## The unavailable case keeps the label short and puts the reason in the row's
## tooltip: it is a sentence now — which model file is missing, which package —
## and a menu row is not where a sentence goes.
func _voice_label() -> String:
	if not TTSService.is_available():
		return "說話出聲（現在沒有可用的聲音）"
	return "說話出聲（%s）" % TTSService.get_voice_name()


## Keep the everyday menu constant-size even when a service supplies dozens of
## characters. The disabled line is status; the verb below it is the only path
## to the full picker.
func append_voice_summary(menu: PopupMenu, voices: PackedStringArray,
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
	if prerender_left > 0:
		return "先錄好固定台詞（還剩 %d 段）" % prerender_left
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


func _index_items(menu: PopupMenu) -> void:
	for i in menu.item_count:
		var id := menu.get_item_id(i)
		if id >= 0:
			_item_menus[id] = menu


## Tick a checkbox wherever it ended up living.
func set_checked(id: int, on: bool) -> void:
	var menu: PopupMenu = _item_menus.get(id)
	if menu == null:
		return
	var index := menu.get_item_index(id)
	if index >= 0:
		menu.set_item_checked(index, on)


## Same, for a row whose label is state rather than a name.
func set_row_text(id: int, text: String) -> void:
	var menu: PopupMenu = _item_menus.get(id)
	if menu == null:
		return
	var index := menu.get_item_index(id)
	if index >= 0:
		menu.set_item_text(index, text)


func open_at_mouse() -> void:
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
		rebuild()
	# The only row whose text changes without anything rebuilding the menu, so it
	# is refreshed here rather than by making every open pay for a full rebuild.
	# Missing this left the row reading 錄一段話 while the pet was visibly
	# recording — following the indicator's own instruction did nothing, which is
	# the one failure a stop control cannot have. The clock in it is a snapshot
	# taken as the menu opens; the live one is the bubble, which the menu covers.
	set_row_text(MenuId.RECORD, _record_label())
	set_row_text(MenuId.SPEECH_INPUT, _speech_input_label())
	reset_size()
	popup(Rect2i(DisplayServer.mouse_get_position(), size))


func _on_id_pressed(id: int) -> void:
	# Highest base first: every one of these tests is "at or above", so a game id
	# at 400 also satisfies the provider test at 300.
	if id >= VOICE_BASE:
		# No rebuild() here: select_backend emits voice_changed, which pet.gd
		# already rebuilds on, and a second rebuild in the same frame would drop
		# the submenu node this call arrived from.
		TTSService.select_backend(TTSService.list_backends()[id - VOICE_BASE])
		return
	if id >= WORKSPACE_BASE:
		var spaces := WorkspaceService.list()
		var index := id - WORKSPACE_BASE
		if index < spaces.size():
			workspace_chosen.emit(spaces[index])
		return
	if id >= GAME_BASE:
		game_chosen.emit(id - GAME_BASE)
		return
	if id >= PROVIDER_BASE:
		LLMService.select_provider(LLMService.list_providers()[id - PROVIDER_BASE])
		rebuild()
		return
	if id >= SIZE_BASE:
		size_chosen.emit(float(SIZE_CHOICES[id - SIZE_BASE]["factor"]))
		return
	if id >= PET_ID_BASE:
		pack_chosen.emit(_installed_pets[id - PET_ID_BASE])
		return
	if id == MenuId.FALLBACK:
		pack_chosen.emit(_default_selection)
		return
	action.emit(id)
