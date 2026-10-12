extends Node

## PetMenu's id decoding. A standalone menu wired to nothing but these
## listeners — never to a pet — so no row here can change a real setting.

var _failures := 0
var _checks := 0
var _finished: Array[String] = []
var _events: Array[Array] = []
var _stubs: Array[Node] = []


func _ready() -> void:
	var tests := {
		"ranges decode highest first": _test_ranges,
		"plain rows become actions": _test_plain_rows,
		"checkboxes tick in place": _test_set_checked,
		"reasons shorten to their first clause": _test_short_reason,
		"note rows never take an id": _test_note_rows,
		"quit warns only about what it cuts short": _test_quit_warning,
	}
	for name: String in tests:
		_events.clear()
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("PetMenu: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("PetMenu: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("PetMenu: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _menu() -> PetMenu:
	var menu := PetMenu.new()
	add_child(menu)
	# Only read from, and kept out of the tree so their @onready never runs;
	# freed alongside the menu by _release().
	var visual := PetVisual.new()
	var brain := PetBrain.new()
	_stubs.append_array([visual, brain])
	menu.setup(1.0, visual, brain, "__default__")
	menu.action.connect(func(id: int) -> void: _events.append(["action", id]))
	menu.pack_chosen.connect(func(id: String) -> void: _events.append(["pack", id]))
	menu.size_chosen.connect(func(f: float) -> void: _events.append(["size", f]))
	menu.game_chosen.connect(func(i: int) -> void: _events.append(["game", i]))
	menu.workspace_chosen.connect(func(s: Dictionary) -> void: _events.append(["space", s]))
	return menu


func _test_ranges() -> void:
	var menu := _menu()
	menu.id_pressed.emit(PetMenu.SIZE_BASE)
	menu.id_pressed.emit(PetMenu.SIZE_BASE + 3)
	# The last game sits above PROVIDER_BASE + n for any plausible n; decoded in
	# the wrong order it would select a language-model backend instead.
	var last_game := GamePanel.game_count() - 1
	menu.id_pressed.emit(PetMenu.GAME_BASE + last_game)
	menu.id_pressed.emit(PetMenu.MenuId.FALLBACK)
	_expect(_events == [["size", 0.5], ["size", 1.5], ["game", last_game], ["pack", "__default__"]],
		"range decoding produced %s" % [_events])
	_release(menu)
	_done("ranges decode highest first")


func _test_plain_rows() -> void:
	var menu := _menu()
	for id in [PetMenu.MenuId.FEED, PetMenu.MenuId.RECORD, PetMenu.MenuId.QUIT,
			PetMenu.MenuId.STOP_WORK]:
		menu.id_pressed.emit(id)
	_expect(_events == [["action", PetMenu.MenuId.FEED], ["action", PetMenu.MenuId.RECORD],
		["action", PetMenu.MenuId.QUIT], ["action", PetMenu.MenuId.STOP_WORK]],
		"plain rows produced %s" % [_events])
	_release(menu)
	_done("plain rows become actions")


## Rows live in submenus; set_checked has to find them there. Every 行為 row,
## because three of them share an id with a root submenu entry.
func _test_set_checked() -> void:
	var menu := _menu()
	var behaviour: PopupMenu = menu.get_node("Behaviour")
	for id in [PetMenu.MenuId.NUDGES, PetMenu.MenuId.PRESENCE, PetMenu.MenuId.MONITOR,
			PetMenu.MenuId.ROAM, PetMenu.MenuId.CALIBRATE]:
		var index := behaviour.get_item_index(id)
		var before := behaviour.is_item_checked(index)
		menu.set_checked(id, not before)
		_expect(behaviour.is_item_checked(index) == not before,
			"set_checked(%s) did not reach its row in 行為" % PetMenu.MenuId.find_key(id))
	_release(menu)
	_done("checkboxes tick in place")


## The real reasons the backends give, cut to what fits a row. The address and
## the instructions stay in the tooltip.
func _test_short_reason() -> void:
	var cases := {
		"還沒有 ElevenLabs 的金鑰。用下面那列「設定 ElevenLabs 金鑰…」貼上，或把 X 放進環境變數。":
			"還沒有 ElevenLabs 的金鑰",
		"連不上語音服務（https://voice.example）。檢查網址對不對。": "連不上語音服務",
		"連不上 VoxCPM 語音服務（錯誤 7），先用系統語音。": "連不上 VoxCPM 語音服務",
		"這台機器的語音都不會讀中文。": "這台機器的語音都不會讀中文",
		"沒有標點": "沒有標點",
	}
	for reason: String in cases:
		_expect(PetMenu.short_reason(reason) == cases[reason],
			"short_reason(%s) gave %s" % [reason, PetMenu.short_reason(reason)])
	_expect(PetMenu.short_backend_label(TTSService.BACKEND_VOXCPM) == "VoxCPM",
		"VoxCPM's short label is %s" % PetMenu.short_backend_label(TTSService.BACKEND_VOXCPM))
	_expect(PetMenu.short_backend_label(TTSService.BACKEND_ELEVEN) == "ElevenLabs",
		"ElevenLabs' short label is %s" % PetMenu.short_backend_label(TTSService.BACKEND_ELEVEN))
	_done("reasons shorten to their first clause")


## An explanatory row added without an id would take its index, which is some
## real row's id. Every disabled row in 說話 that is not a choice must be a NOTE,
## and SPEAK must still tick its own row.
func _test_note_rows() -> void:
	var menu := _menu()
	var speech: PopupMenu = menu.get_node("Speech")
	for i in speech.item_count:
		if speech.get_item_text(i).begins_with("　"):
			_expect(speech.get_item_id(i) == PetMenu.MenuId.NOTE,
				"reason row %s has id %d" % [speech.get_item_text(i), speech.get_item_id(i)])
	var speak := speech.get_item_index(PetMenu.MenuId.SPEAK)
	var before := speech.is_item_checked(speak)
	menu.set_checked(PetMenu.MenuId.SPEAK, not before)
	_expect(speech.is_item_checked(speak) == not before, "set_checked(SPEAK) missed its row")
	_release(menu)
	_done("note rows never take an id")


func _test_quit_warning() -> void:
	var pet: GDScript = preload("res://pet/pet.gd")
	_expect(str(pet.quit_warning({}, false, false)).is_empty(),
		"an idle pet must quit without asking")
	var job := {"space": {"name": "pet-playground"}, "seconds": 133}
	var text := str(pet.quit_warning(job, true, false))
	_expect(text.contains("pet-playground") and text.contains("不會還原"),
		"the job line must name the folder and say edits stay: %s" % text)
	_expect(text.contains("存進"), "the recording line must say it is saved: %s" % text)
	_expect(not text.contains("沒了"), "nothing was being said, yet: %s" % text)
	_expect(str(pet.quit_warning({}, false, true)).contains("沒了"),
		"a voice turn in flight is lost and must say so")
	_done("quit warns only about what it cuts short")


func _release(menu: PetMenu) -> void:
	menu.free()
	for stub in _stubs:
		stub.free()
	_stubs.clear()
