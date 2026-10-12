extends Node

## The failure paths of a conversation and of the workspace allowlist: each one
## was a silent bug, so each one is pinned here. Nothing in this file touches the
## running autoloads' state — every store is a fresh instance pointed at /tmp.

const MemoryStoreScript := preload("res://autoload/memory_store.gd")
const WorkspaceScript := preload("res://autoload/workspace_service.gd")
const OpenAIProviderScript := preload("res://llm/providers/openai_provider.gd")

const SCRATCH := "/tmp/godot_pet_test_conversation_safety"

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	OS.execute("rm", ["-rf", SCRATCH])
	DirAccess.make_dir_recursive_absolute(SCRATCH)
	var tests := {
		"failed fold releases the store": _test_failed_fold_releases_the_store,
		"failed save stays dirty": _test_failed_save_stays_dirty,
		"truncated stream is not complete": _test_truncated_stream_is_not_complete,
		"workspace scope": _test_workspace_scope,
	}
	for name: String in tests:
		(tests[name] as Callable).call()
	OS.execute("rm", ["-rf", SCRATCH])
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("ConversationSafety: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("ConversationSafety: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("ConversationSafety: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _store(file: String) -> Node:
	var store: Node = MemoryStoreScript.new()
	store._path = SCRATCH.path_join(file)
	return store


## A background request that fails now answers with an empty reply. That must
## release `_condensing`, or no fold is ever attempted again this run.
func _test_failed_fold_releases_the_store() -> void:
	var store := _store("fold.json")
	for i in 4:
		store.append("user", "問題 %d" % i)
	store._condensing = true
	store._on_condensed("", 2, store._epoch)
	_expect(not store._condensing, "a failed fold left the store condensing forever")
	_expect(store.history().size() == 4, "a failed fold discarded turns")
	store.free()
	_done("failed fold releases the store")


func _test_failed_save_stays_dirty() -> void:
	var store := _store("missing-dir/memory.json")
	store.append("user", "記得我")
	store._save_if_dirty()
	_expect(store._dirty, "a save that could not open its file was marked clean")

	store._path = SCRATCH.path_join("memory.json")
	store._save_if_dirty()
	_expect(not store._dirty, "the retry after a failed save did not clear dirty")
	_expect(FileAccess.get_file_as_string(store._path).contains("記得我"),
		"the retry did not write what the failed save held")
	store.free()
	_done("failed save stays dirty")


## The completion signal comes from the stream itself; text alone is not it.
func _test_truncated_stream_is_not_complete() -> void:
	var provider: Node = OpenAIProviderScript.new()
	provider._handle_event('data: {"choices":[{"delta":{"content":"[happy] 我想"}}]}')
	_expect(not provider._saw_done and not provider._saw_finish,
		"a half reply already counts as a finished stream")

	provider._handle_event('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}')
	_expect(provider._saw_finish, "finish_reason did not mark the stream complete")
	provider._saw_finish = false
	provider._handle_event("data: [DONE]")
	_expect(provider._saw_done, "[DONE] did not mark the stream complete")
	provider.free()
	_done("truncated stream is not complete")


func _test_workspace_scope() -> void:
	var spaces: Node = WorkspaceScript.new()
	var home := OS.get_environment("HOME")

	_expect(spaces.normalise("/a//b///c/") == "/a/b/c", "repeated slashes survived normalise")
	_expect(not spaces.rejection_reason(home.replace("/", "//")).is_empty(),
		"a doubled-slash spelling of the home directory was accepted")

	var project := SCRATCH.path_join("project")
	DirAccess.make_dir_recursive_absolute(project)
	_expect(spaces.rejection_reason(project).is_empty(),
		"an ordinary project folder was refused: %s" % spaces.rejection_reason(project))

	var hidden := SCRATCH.path_join(".secrets")
	DirAccess.make_dir_recursive_absolute(hidden)
	var alias := SCRATCH.path_join("notes")
	OS.execute("ln", ["-s", hidden, alias])
	_expect(not spaces.rejection_reason(alias).is_empty(),
		"a symlink to a hidden folder was accepted")

	var home_alias := SCRATCH.path_join("everything")
	OS.execute("ln", ["-s", home, home_alias])
	_expect(not spaces.rejection_reason(home_alias).is_empty(),
		"a symlink to the home directory was accepted")
	spaces.free()
	_done("workspace scope")
