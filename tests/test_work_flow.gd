extends Node

## WorkFlow's contract with pet.gd: it speaks only through `said`, never records,
## answers the user even with the input open, and asks for the input rather than
## opening it. Nothing here launches an agent or reaches a model.

var _failures := 0
var _checks := 0
var _finished: Array[String] = []
var _said: Array[Array] = []
var _inputs: PackedStringArray = []
var _ended := 0


func _ready() -> void:
	var tests := {
		"abandoning clears the walk": _test_abandoning_clears_the_walk,
		"input is asked for, not opened": _test_input_is_asked_for,
		"chatter is the one unprompted line": _test_chatter_flags,
		"a failed job reports and ends": _test_failed_job,
	}
	for name: String in tests:
		_said.clear()
		_inputs.clear()
		_ended = 0
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("WorkFlow: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("WorkFlow: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("WorkFlow: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


## A flow wired the way pet.gd wires it, minus the pet. setup() is skipped on
## purpose: it connects to the live WorkService and CodexCli autoloads.
func _flow() -> WorkFlow:
	var flow := WorkFlow.new()
	add_child(flow)
	flow.said.connect(func(emotion: String, text: String, record: bool, unprompted: bool) -> void:
		_said.append([emotion, text, record, unprompted]))
	flow.wants_input.connect(func(placeholder: String) -> void: _inputs.append(placeholder))
	flow.job_ended.connect(func() -> void: _ended += 1)
	return flow


func _test_abandoning_clears_the_walk() -> void:
	var flow := _flow()
	flow._pending_space = {"name": "proj", "path": "/tmp/proj", "level": "edit"}
	flow._abandon_pending_work("好，那我不動你的資料夾。")
	_expect(flow._pending_space.is_empty(), "abandoning left the workspace stashed")
	_expect(flow._queued_request.is_empty(), "abandoning left a queued request")
	_expect(_said.size() == 1, "abandoning said %d lines, not one" % _said.size())
	if _said.size() == 1:
		_expect(not _said[0][2], "a work-flow line was recorded into history")
		_expect(not _said[0][3],
			"the refusal was unprompted, so an open input would swallow it")
	flow.free()
	_done("abandoning clears the walk")


func _test_input_is_asked_for() -> void:
	var flow := _flow()
	flow._open_work_input({"name": "proj", "path": "/tmp/no-such-proj", "level": "read"})
	_expect(_inputs.size() == 1, "opening the input emitted %d requests" % _inputs.size())
	if _inputs.size() == 1:
		_expect(_inputs[0].contains("proj") and _inputs[0].contains("只能看"),
			"the placeholder lost the folder name or its level: %s" % _inputs[0])
	_expect(flow._pending_space.get("name") == "proj",
		"the workspace was not kept for the request that comes back")
	flow.free()
	_done("input is asked for, not opened")


func _test_chatter_flags() -> void:
	var flow := _flow()
	flow._say("neutral", "還在弄，別急。", true)
	flow._say("happy", "弄完了！")
	_expect(_said.size() == 2, "expected two lines")
	if _said.size() == 2:
		_expect(_said[0][3], "the still-working line would talk over an open input")
		_expect(not _said[1][3], "an answer line was left unprompted")
	flow.free()
	_done("chatter is the one unprompted line")


func _test_failed_job() -> void:
	var flow := _flow()
	flow._on_work_failed("咦，壞掉了。")
	_expect(_said.size() == 1 and _said[0][0] == "sad", "a failure did not say so")
	_expect(_ended == 1, "a failed job did not tell the panel to refresh")
	flow.free()
	_done("a failed job reports and ends")
