extends Node

## SettingsFlow's lines, and the one flag only it sets: a notice from the voice
## layer is shown but never spoken, since it is often about speech having just
## broken. Only paths that write no config and reach no service are exercised.

var _failures := 0
var _checks := 0
var _finished: Array[String] = []
var _said: Array[Array] = []
var _left: Array[int] = []


func _ready() -> void:
	var tests := {
		"a voice notice is not spoken": _test_voice_notice,
		"a bad paste is refused before storing": _test_bad_paste,
		"an unawaited health check is silent": _test_unawaited_check,
		"pre-rendering reports its end": _test_prerender_end,
	}
	for name: String in tests:
		_said.clear()
		_left.clear()
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("SettingsFlow: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("SettingsFlow: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("SettingsFlow: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


## Not set up: setup() connects to the live TTSService.
func _flow() -> SettingsFlow:
	var flow := SettingsFlow.new()
	add_child(flow)
	flow.said.connect(func(emotion: String, text: String, record: bool, unprompted: bool,
			speak: bool) -> void: _said.append([emotion, text, record, unprompted, speak]))
	flow.prerender_changed.connect(func(left: int) -> void: _left.append(left))
	return flow


func _test_voice_notice() -> void:
	var flow := _flow()
	flow._on_voice_remarked("語音服務連不上，先改用系統語音。")
	_expect(_said == [["neutral", "語音服務連不上，先改用系統語音。", false, false, false]],
		"a voice notice changed shape: %s" % [_said])
	flow.free()
	_done("a voice notice is not spoken")


func _test_bad_paste() -> void:
	var flow := _flow()
	flow._on_secret_submitted("OPENAI_API_KEY_TEST_ONLY", "sk-金鑰")
	_expect(_said.size() == 1 and _said[0][0] == "sad", "a non-ASCII key was not refused")
	if _said.size() == 1:
		_expect(_said[0][2] and _said[0][3], "the refusal lost the gate's default flags")
	flow.free()
	_done("a bad paste is refused before storing")


## Discovery re-runs on every menu open; only a check the user is waiting on
## may be reported.
func _test_unawaited_check() -> void:
	var flow := _flow()
	flow._on_backend_checked(false, "連不上", false)
	_expect(_said.is_empty(), "an unawaited health check spoke: %s" % [_said])
	flow.free()
	_done("an unawaited health check is silent")


func _test_prerender_end() -> void:
	var flow := _flow()
	flow._on_prerender_progress(2, 3)
	_expect(_said.is_empty(), "pre-rendering spoke before it finished")
	flow._on_prerender_progress(5, 0)
	_expect(_left == [3, 0], "the menu was not told what is left: %s" % [_left])
	_expect(_said.size() == 1 and _said[0][0] == "happy" and not _said[0][3],
		"the end of pre-rendering was not answered: %s" % [_said])
	flow.free()
	_done("pre-rendering reports its end")
