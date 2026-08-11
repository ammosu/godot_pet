extends Node

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"frame bounds": _test_frame_bounds,
		"state bounds": _test_state_bounds,
		"edge contact": _test_edge_contact,
		"moving platform": _test_moving_platform_crossing,
		"independent game window": _test_independent_game_window,
	}
	for name: String in tests:
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("GamePet: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("GamePet collision bounds: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("GamePet collision bounds: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _done(name: String) -> void:
	_finished.append(name)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _test_frame_bounds() -> void:
	var pack := PetPack.load_builtin()
	_expect(pack != null, "bundled pack did not load")
	if pack == null:
		return
	var row_box := pack.rect_for_row(0)
	var frame_box := pack.rect_for_frame(0, 1)
	_expect(frame_box.size.x < row_box.size.x,
		"individual frame bounds fell back to the wider row union")
	_done("frame bounds")


func _test_state_bounds() -> void:
	var pack := PetPack.load_builtin()
	if pack == null:
		return
	var pet := GamePet.new()
	add_child(pet)
	pet.build(1.0, pack, PetVisual.V2_STATE_ROWS, 96.0)
	var idle := pet.visual_rect(200.0, 300.0)
	pet.set_state(&"walk")
	var walk := pet.visual_rect(200.0, 300.0)
	_expect(walk.size.x > idle.size.x,
		"walk collision width still used the narrower idle silhouette")
	pet.set_facing(-1)
	var flipped := pet.visual_rect(200.0, 300.0)
	_expect(is_equal_approx(walk.position.x + flipped.end.x, 400.0)
			and is_equal_approx(walk.end.x + flipped.position.x, 400.0),
		"facing flip did not mirror the asymmetric frame bounds")
	pet.set_facing(1)
	pet.set_squash(0.1)
	var squashed := pet.visual_rect(200.0, 300.0)
	_expect(squashed.size.x > walk.size.x,
		"horizontal squash/stretch was absent from collision bounds")
	_expect(squashed.size.y < walk.size.y,
		"vertical squash/stretch was absent from collision bounds")
	pet.queue_free()
	_done("state bounds")


func _test_edge_contact() -> void:
	var rect := Rect2(10.0, 10.0, 20.0, 20.0)
	_expect(GamePet.circle_hits_rect(Vector2(35.0, 20.0), 5.0, rect),
		"a circle touching the character edge was not counted")
	_expect(not GamePet.circle_hits_rect(Vector2(35.1, 20.0), 5.0, rect),
		"a circle beyond the character edge was counted")
	_done("edge contact")


func _test_moving_platform_crossing() -> void:
	# The platform moved from 104 to 96 while the feet moved from 100 to 102.
	# Comparing the old feet only with the new platform (100 <= 96) misses it,
	# but their paths crossed during this frame.
	_expect(DescentGame.platform_crossed(100.0, 102.0, 104.0, 96.0, 0.0),
		"opposing pet/platform motion skipped a real landing")
	_expect(not DescentGame.platform_crossed(106.0, 108.0, 104.0, 96.0, 0.0),
		"a pet already below the platform landed from underneath")
	_expect(DescentGame.platform_crossed(104.5, 105.0, 104.0, 103.0, 1.0),
		"small fractional-scale landing drift ignored the vertical grace")
	_done("moving platform")


func _test_independent_game_window() -> void:
	var panel := GamePanel.new()
	panel.transient = true
	panel.transient_to_focused = true
	panel.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	add_child(panel)
	_expect(not panel.transient and not panel.transient_to_focused,
		"game window kept a native parent relationship and can follow the pet")
	_expect(panel.initial_position == Window.WINDOW_INITIAL_POSITION_ABSOLUTE,
		"game window still delegated its position to the moving main window")
	_expect(GamePanel.centred_position(
		Rect2i(1000, 200, 1200, 800), Vector2i(600, 400)) == Vector2i(1300, 400),
		"independent game window was not centred in its selected screen")
	panel.queue_free()
	_done("independent game window")
