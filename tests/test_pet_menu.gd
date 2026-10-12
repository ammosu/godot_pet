extends Node

## PetMenu's id decoding. A standalone menu wired to nothing but these
## listeners — never to a pet — so no row here can change a real setting.

var _failures := 0
var _checks := 0
var _finished: Array[String] = []
var _events: Array[Array] = []


func _ready() -> void:
	var tests := {
		"ranges decode highest first": _test_ranges,
		"plain rows become actions": _test_plain_rows,
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
	menu.setup(1.0, PetVisual.new(), PetBrain.new(), "__default__")
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
	menu.free()
	_done("ranges decode highest first")


func _test_plain_rows() -> void:
	var menu := _menu()
	for id in [PetMenu.MenuId.FEED, PetMenu.MenuId.RECORD, PetMenu.MenuId.QUIT]:
		menu.id_pressed.emit(id)
	_expect(_events == [["action", PetMenu.MenuId.FEED], ["action", PetMenu.MenuId.RECORD],
		["action", PetMenu.MenuId.QUIT]], "plain rows produced %s" % [_events])
	menu.free()
	_done("plain rows become actions")


## Rows live in submenus; set_checked has to find them there.
func _test_set_checked() -> void:
	var menu := _menu()
	var behaviour: PopupMenu = menu.get_node("Behaviour")
	var index := behaviour.get_item_index(PetMenu.MenuId.ROAM)
	var before := behaviour.is_item_checked(index)
	menu.set_checked(PetMenu.MenuId.ROAM, not before)
	_expect(behaviour.is_item_checked(index) == not before,
		"set_checked did not reach the row in 行為")
	menu.free()
	_done("checkboxes tick in place")
