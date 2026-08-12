extends Node

## FrameBudget decides one process-wide number from several callers' needs, and
## the failure it exists to prevent is silent: a mini-game inheriting the idle
## pet's 6 fps still runs, it just becomes unplayable.
##
## Built with .new() and kept out of the tree, so _ready() never runs and the
## instance never connects to EventBus a second time — the same shape
## test_window_controller.gd uses.

var _failures := 0
var _checks := 0
var _finished: Array[String] = []
var _saved_max_fps := 0


func _ready() -> void:
	# request() writes Engine.max_fps, which is a real engine global shared with
	# whatever runs this. Put it back or test order starts to matter.
	_saved_max_fps = Engine.max_fps
	var tests := {
		"highest wins": _test_highest_requirement_wins,
		"release restores": _test_release_restores_the_next_highest,
		"same key replaces": _test_same_key_replaces_rather_than_stacks,
		"empty leaves engine alone": _test_empty_table_leaves_engine_alone,
		"ambient states": _test_unknown_state_takes_the_fallback,
		"idle is below the cliff": _test_idle_is_below_the_measured_cliff,
	}
	for name: String in tests:
		(tests[name] as Callable).call()
	Engine.max_fps = _saved_max_fps
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("FrameBudget: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("FrameBudget: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("FrameBudget: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _budget() -> Node:
	return preload("res://autoload/frame_budget.gd").new()


## The whole point: an open game must not inherit the idle pet's rate.
func _test_highest_requirement_wins() -> void:
	var budget := _budget()
	budget.request(&"pet", 6)
	budget.request(&"window:Game", 60)

	_expect(budget.current() == 60,
		"an open mini-game inherited the idle pet's frame rate")
	_expect(Engine.max_fps == 60,
		"the highest requirement was computed but never reached the engine")
	budget.free()
	_done("highest wins")


func _test_release_restores_the_next_highest() -> void:
	var budget := _budget()
	budget.request(&"pet", 6)
	budget.request(&"window:Game", 60)
	budget.release(&"window:Game")

	_expect(budget.current() == 6,
		"closing the game left the whole process pinned at its frame rate")
	_expect(Engine.max_fps == 6,
		"the drop back to the pet's own rate never reached the engine")
	budget.free()
	_done("release restores")


## A caller whose need changes must not have to release first, or a missed
## release pins the process at the old rate for the rest of the run.
func _test_same_key_replaces_rather_than_stacks() -> void:
	var budget := _budget()
	budget.request(&"pet", 60)
	budget.request(&"pet", 6)

	_expect(budget.current() == 6,
		"re-requesting under one key stacked instead of replacing")
	budget.free()
	_done("same key replaces")


## Nobody has asked yet, so project.godot's own max_fps is still the answer.
## Inventing one here would make this file own the startup frame rate too.
func _test_empty_table_leaves_engine_alone() -> void:
	var budget := _budget()
	Engine.max_fps = 144
	budget.release(&"never-requested")

	_expect(budget.current() == 0, "an empty table reported a requirement")
	_expect(Engine.max_fps == 144,
		"an empty table overwrote the max_fps project.godot had set")

	# Releasing the *last* requirement leaves the last number in force rather
	# than snapping back, because there is nothing to snap back to.
	budget.request(&"pet", 6)
	budget.release(&"pet")
	_expect(Engine.max_fps == 6,
		"releasing the last requirement invented a rate instead of holding still")
	budget.free()
	_done("empty leaves engine alone")


## Mode.AMBIENT emits whatever StringName the skin's companion.json chose, so the
## fallback is that path's ordinary route, not a guard against typos.
func _test_unknown_state_takes_the_fallback() -> void:
	var budget := _budget()
	budget._on_pet_activity(&"stretch-and-yawn")

	_expect(budget.current() == FrameBudget.DEFAULT_STATE_FPS,
		"a skin-defined ambient state did not fall back to the default rate")
	budget.free()
	_done("ambient states")


## The measured cliff is between 6 and 12: at 12 fps opening a 238-item folder
## still costs +3.38s against no pet at all, and at 6 fps it costs +0.39s. A
## well-meaning "12 is smoother and still low" edit gives back 88% of the saving.
func _test_idle_is_below_the_measured_cliff() -> void:
	_expect(int(FrameBudget.STATE_FPS[&"idle"]) <= 6,
		"idle rose above the measured 6/12 fps cliff, which costs +3s per folder")
	_expect(int(FrameBudget.STATE_FPS[&"sleep"]) <= int(FrameBudget.STATE_FPS[&"idle"]),
		"a sleeping pet asked for more frames than an idle one")
	_expect(int(FrameBudget.GAME_FPS) > int(FrameBudget.PANEL_FPS),
		"the mini-games stopped asking for more than a scrolling panel")
	_done("idle is below the cliff")
