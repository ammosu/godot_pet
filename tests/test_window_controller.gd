extends Node

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"platform window policy": _test_platform_window_policy,
		"display rounding": _test_display_rounding_is_not_window_confinement,
		"window confinement": _test_large_correction_is_window_confinement,
	}
	for name: String in tests:
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("WindowController: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("WindowController display handling: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("WindowController display handling: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _test_platform_window_policy() -> void:
	_expect(WindowController.platform_confines_window("Windows"),
		"Windows was allowed to leave the native window outside its work area")
	_expect(WindowController.platform_confines_window("macOS"),
		"macOS drag confinement no longer falls back to moving the pet anchor")
	_expect(not WindowController.platform_confines_window("Linux"),
		"Linux skipped its measured window-manager confinement probe")
	_done("platform window policy")


## macOS converts Godot's physical-pixel positions through native point
## coordinates. On a Retina desktop, a requested odd x can therefore return one
## pixel lower without the window manager having confined the window at all.
func _test_display_rounding_is_not_window_confinement() -> void:
	var controller := WindowController.new()
	var window := Window.new()
	controller._win = window
	controller._ui_scale = 2.0
	controller._wm_probe_want = Vector2i(2345, 338)
	controller._wm_probe_frames = WindowController.WM_PROBE_FRAMES - 1
	window.position = Vector2i(2344, 338)

	controller._process(0.0)

	_expect(not controller._wm_confines_window,
		"one pixel of Retina coordinate rounding was mistaken for window confinement")
	window.free()
	controller.free()
	_done("display rounding")


func _test_large_correction_is_window_confinement() -> void:
	var controller := WindowController.new()
	var window := Window.new()
	controller._win = window
	controller._ui_scale = 2.0
	controller._wm_probe_want = Vector2i(2345, 338)
	controller._wm_probe_frames = WindowController.WM_PROBE_FRAMES - 1
	window.position = Vector2i(2060, 320)

	controller._process(0.0)

	_expect(controller._wm_confines_window,
		"a real window-manager correction was ignored as display rounding")
	window.free()
	controller.free()
	_done("window confinement")
