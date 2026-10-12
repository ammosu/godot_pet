extends Node

## SensesFlow's lines keep the presentation gate's defaults — recorded, and held
## back while the user is typing — because both are the pet volunteering
## something. Nothing here writes config, captures the screen or calls a model.

var _failures := 0
var _checks := 0
var _finished: Array[String] = []
var _said: Array[Array] = []


func _ready() -> void:
	var tests := {
		"a menu refusal is volunteered": _test_menu_refusal,
		"nothing pending says nothing": _test_nothing_pending,
		"a load alert obeys 主動說話": _test_load_alert,
	}
	for name: String in tests:
		_said.clear()
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("SensesFlow: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("SensesFlow: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("SensesFlow: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


## Not set up: setup() connects to the live EventBus.
func _flow() -> SensesFlow:
	var flow := SensesFlow.new()
	add_child(flow)
	flow.said.connect(func(emotion: String, text: String, record: bool, unprompted: bool) -> void:
		_said.append([emotion, text, record, unprompted]))
	return flow


func _test_menu_refusal() -> void:
	var flow := _flow()
	# From the menu: `record` true means the question was never put in history.
	flow._pending_look = {"question": "看一下", "record": true}
	flow._resolve_look(false, false)
	_expect(_said == [["neutral", "好啦，那我不看。", true, true]],
		"the menu refusal changed shape: %s" % [_said])
	_expect(flow._pending_look.is_empty(), "the refused look stayed pending")
	flow.free()
	_done("a menu refusal is volunteered")


## The dialog can fire twice (confirm, then the close that follows); the second
## must not say anything or look again.
func _test_nothing_pending() -> void:
	var flow := _flow()
	flow._resolve_look(false, false)
	_expect(_said.is_empty(), "resolving with nothing pending said %s" % [_said])
	flow.free()
	_done("nothing pending says nothing")


func _test_load_alert() -> void:
	var flow := _flow()
	flow._on_resource_alert(MonitorService.ALERT_MEM_TIGHT, {"percent": 4.2})
	if Nudger.is_enabled():
		_expect(_said.size() == 1 and _said[0][2] and _said[0][3],
			"a load alert was not said as a volunteered line: %s" % [_said])
		if _said.size() == 1:
			_expect(str(_said[0][1]).contains("4%"), "the percentage was lost: %s" % _said[0][1])
	else:
		_expect(_said.is_empty(), "a load alert spoke with 主動說話 off")
	flow.free()
	_done("a load alert obeys 主動說話")
