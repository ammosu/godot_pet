extends Node

## Stopping a job has to stop what the agent started, not just the agent.

const WorkServiceScript := preload("res://autoload/work_service.gd")

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"kill tree takes the children": _test_kill_tree_takes_the_children,
	}
	for name: String in tests:
		await (tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("WorkService: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("WorkService: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("WorkService: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _alive(pid: int) -> bool:
	# A killed child stays a zombie until reaped, and `kill -0` still succeeds
	# on a zombie — so ask for the state instead.
	var out := []
	if OS.execute("ps", ["-o", "stat=", "-p", str(pid)], out, true) != 0:
		return false
	var state := str(out[0]).strip_edges()
	return not state.is_empty() and not state.begins_with("Z")


## The shape of an agent running a test suite: it has children of its own, and
## those are what `OS.kill()` alone used to leave behind.
func _test_kill_tree_takes_the_children() -> void:
	if OS.get_name() == "Windows":
		_done("kill tree takes the children")
		return
	var root := OS.create_process("/bin/sh", ["-c", "sleep 60 & sleep 60 & wait"])
	_expect(root > 0, "could not start the stand-in agent")
	await get_tree().create_timer(0.5).timeout

	var children: PackedInt32Array = WorkServiceScript._descendants(root)
	_expect(children.size() == 2, "expected the stand-in's two children, found %d" % children.size())

	WorkServiceScript.kill_tree(root)
	await get_tree().create_timer(0.3).timeout
	_expect(not _alive(root), "the agent itself survived kill_tree")
	for child in children:
		_expect(not _alive(child), "child %d survived its agent being stopped" % child)
	_done("kill tree takes the children")
