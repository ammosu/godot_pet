extends Node

## The pet doing a job for you, by driving a coding-agent CLI in one of your own
## folders.
##
## The pet is the face; the CLI is the hands. Nothing here decides what the pet
## *says* — it reports what the agent is doing and what changed, and pet.gd turns
## that into a line in character. The detail belongs in the panel, because a
## speech bubble that fills with tool calls has stopped being a pet.
##
## **Nothing is piped, because reading a pipe blocks.**
## `FileAccess.get_line()`/`get_buffer()` on a pipe waits until a byte
## arrives, and an agent thinks for tens of seconds at a stretch, so polling one
## from `_process` would freeze the window; leaving it undrained is worse, since a
## full OS buffer stops the child ever exiting, and Godot offers no readiness test.
##
## What is new here is that this no longer costs us the progress. Measured on this
## machine: `claude -p --output-format stream-json` **flushes line by line as it
## runs** even when stdout is a regular file — the file grew from 21k to 45k in
## eight visible steps across a 16-second job. So the stream goes to a regular
## file and `_process` tails it by byte offset, which never blocks. That is the
## same trick CodexCli uses to find a device code, paying off much harder.
##
## `codex exec` is the other runner and has **no token-level streaming at all**
## (one `item.completed` carries the whole reply), so it reports coarser. That is
## a property of the tool, not of this file.

## One step the agent took, for the panel's live log.
## `kind` is "tool" | "text" | "note"; `text` is already phrased for a human.
signal progress(entry: Dictionary)
## The job ended, well or badly. `result` carries ok / message / changes /
## seconds / cost.
signal finished(result: Dictionary)
## It could not be started, or it died without producing a result.
signal failed(reason: String)
## Started, stopped, or moved on to a new step — anything the panel's header shows.
signal state_changed

const SECTION := "work"
const CONSENT_KEY := "work_consented"
const RUNNER_KEY := "runner"

const RUNNER_CLAUDE := "claude"
const RUNNER_CODEX := "codex"

## Claude's alias, not a dated id: the CLI resolves it to the current model, and
## a pinned one silently rots. Codex's is the opposite and has to be named
## exactly: there is no plain `gpt-5.6`; that generation is `-sol` / `-luna` /
## `-terra`, and a wrong id fails as a misleading account error.
const CLAUDE_MODEL := "sonnet"
const CODEX_MODEL := "gpt-5.6-sol"

## A hard ceiling on one job, in dollars. Only meaningful on an API-billed
## account — a subscription ignores it — but it costs nothing to pass and it is
## the only automatic stop between "幫我看一下" and a runaway loop.
const BUDGET_USD := 2.0

## Real work is not a ten-second errand. Long enough for a genuine multi-file
## change, short enough that a wedged agent doesn't hold a slot forever.
const TIMEOUT := 900.0

## How often to look at the stream. Four times a second is far below the rate the
## deltas arrive at, and the bubble's own typewriter re-paces the text anyway.
const POLL := 0.25

## The live log is for reading, not archiving; an agent that loops would
## otherwise grow it without bound.
const MAX_LOG := 400

## A Bash command or an agent sentence can be arbitrarily long, and this ends up
## in a single-line list row.
const MAX_STEP_LENGTH := 72

const STREAM_PATH := "user://work_stream.jsonl"
const MESSAGE_PATH := "user://work_last_message.txt"

var _pid := -1
var _elapsed := 0.0
var _since_poll := 0.0
var _runner := RUNNER_CLAUDE
var _space := {}
var _request := ""
## Bytes of the stream already consumed, and the partial last line. Split on the
## newline **byte**, never on a decoded string: a read can land mid-character, and
## 0x0A cannot appear inside a UTF-8 sequence, so a byte split is the safe one.
var _offset := 0
var _pending := PackedByteArray()
var _log: Array[Dictionary] = []
## Whatever the agent last said in prose, kept as the closing line for runners
## that have no other way to report one.
var _last_text := ""
var _cost := 0.0
var _reported := false
## The agent conversation this run belongs to, read off the result event and kept
## so the next job in the same folder can carry on from it.
var _session := ""
## Whether this launch passed --resume, which is what makes a zero-turn failure
## worth retrying rather than reporting.
var _resuming := false
## Set when that failure is seen, so _process can start over instead of reporting.
var _session_is_stale := false
var _claude_path := ""
var _claude_looked_up := false


func _ready() -> void:
	set_process(false)


## Same reason CodexCli kills its own child: `OS.create_process` children outlive
## the app, and an abandoned agent keeps write access to the user's repository.
## Thanks to the `exec` in _command(), this pid is the agent itself rather than a
## shell whose death it would survive.
func _exit_tree() -> void:
	if _pid != -1:
		OS.kill(_pid)


# --- What's available ---------------------------------------------------------

## Which runners this machine can actually use. Empty means the feature is off.
func available_runners() -> PackedStringArray:
	var out := PackedStringArray()
	if not claude_path().is_empty():
		out.append(RUNNER_CLAUDE)
	# Having the binary and having an account are separate questions; CodexCli
	# answers the second one and pet.gd offers to fix it rather than refusing.
	if CodexCli.is_available():
		out.append(RUNNER_CODEX)
	return out


func is_supported() -> bool:
	return not available_runners().is_empty()


## Walked out of PATH for the same reason CodexCli walks it: this is installed by
## a version manager or a user-local script directory, and no fixed list finds it.
func claude_path() -> String:
	if _claude_looked_up:
		return _claude_path
	_claude_looked_up = true
	if OS.get_name() == "Windows":
		return _claude_path
	for dir in OS.get_environment("PATH").split(":", false):
		var candidate := dir.path_join("claude")
		if FileAccess.file_exists(candidate):
			_claude_path = candidate
			break
	return _claude_path


## The chosen runner, falling back to whatever this machine has if the stored
## choice is gone — an uninstalled CLI must not make the feature look broken.
##
## The stored value is a *choice*, so it persists; the fallback never does. That
## is the rule LLMService.set_provider() vs select_provider() already draws, and
## for the same reason: persisting a fallback pins whichever CLI happened to be
## installed on first run and permanently defeats later detection.
func runner() -> String:
	var available := available_runners()
	if available.is_empty():
		return RUNNER_CLAUDE
	var chosen := str(Config.get_value(SECTION, RUNNER_KEY, ""))
	if available.has(chosen):
		return chosen
	return available[0]


func select_runner(name: String) -> void:
	Config.set_value(SECTION, RUNNER_KEY, name)
	state_changed.emit()


func runner_label(name: String) -> String:
	return "Claude Code" if name == RUNNER_CLAUDE else "Codex"


func has_consented() -> bool:
	return bool(Config.get_value(SECTION, CONSENT_KEY, false))


func grant_consent() -> void:
	Config.set_value(SECTION, CONSENT_KEY, true)


# --- Running ------------------------------------------------------------------

func is_busy() -> bool:
	return _pid != -1


## What is running, for the panel's header. Empty when idle.
func current() -> Dictionary:
	if not is_busy():
		return {}
	return {
		"request": _request,
		"space": _space,
		"runner": _runner,
		"seconds": _elapsed,
	}


func log_entries() -> Array[Dictionary]:
	return _log


## What the last job was asked to do, still readable after it stopped. The panel
## needs it to label a cancelled job: `current()` is empty by the time `failed`
## lands, and reusing whatever it displayed before puts the *previous* request
## above the new outcome.
func last_request() -> String:
	return _request


## Start a job. Returns false when it couldn't even be launched, so the caller can
## say so rather than waiting for a signal that isn't coming.
func start(space: Dictionary, request: String) -> bool:
	if is_busy():
		return false
	var trimmed := request.strip_edges()
	if trimmed.is_empty() or space.is_empty():
		return false
	var path := str(space.get("path", ""))
	if not DirAccess.dir_exists_absolute(path):
		return false

	_runner = runner()
	_space = space
	_request = trimmed
	_log.clear()
	return _launch(true)


## Split from start() so a resume that turns out to be stale can be retried
## fresh without the caller ever knowing. `allow_resume` is false on that retry,
## which is also what stops it looping.
func _launch(allow_resume: bool) -> bool:
	var path := str(_space.get("path", ""))
	_offset = 0
	_pending = PackedByteArray()
	_last_text = ""
	_cost = 0.0
	_elapsed = 0.0
	_since_poll = 0.0
	_reported = false
	_session = ""
	# Only claude can resume; the codex path has no equivalent here.
	_resuming = allow_resume and _runner == RUNNER_CLAUDE \
		and not WorkspaceService.get_session(path).is_empty()

	var stream := ProjectSettings.globalize_path(STREAM_PATH)
	var message := ProjectSettings.globalize_path(MESSAGE_PATH)
	DirAccess.remove_absolute(stream)
	DirAccess.remove_absolute(message)

	var command := _command(path, stream, message)
	if command.is_empty():
		return false
	_pid = OS.create_process("/bin/sh", ["-c", command])
	if _pid == -1:
		push_warning("WorkService: could not start %s" % _runner)
		return false
	_note("%s %s" % ["接著上次，在" if _resuming else "在",
		str(_space.get("name", path.get_file())) + ("" if _resuming else " 開工了")])
	set_process(true)
	state_changed.emit()
	return true


## Whether the next job in this workspace would carry the previous one's context.
## Asked by pet.gd so the input can say so before anything is typed.
func would_resume(space: Dictionary) -> bool:
	return runner() == RUNNER_CLAUDE \
		and not WorkspaceService.get_session(str(space.get("path", ""))).is_empty()


func cancel() -> void:
	if _pid == -1:
		return
	OS.kill(_pid)
	# Drain what it managed to write before dying: the steps it had already taken
	# are real, and the files it already changed are on disk either way.
	_drain()
	var path := str(_space.get("path", ""))
	_stop()
	_note("你喊停了")
	# Stopping half way is not the same as nothing having happened. An agent
	# cancelled after it rewrote three files and told the user "好，我停下來了" and
	# nothing else would be the most misleading thing this service could say.
	var changed := WorkspaceService.changes(path).size()
	failed.emit("好，我停下來了。" if changed == 0
		else "好，我停下來了 —— 不過已經動了 %d 個檔案，你要不要看一下。" % changed)
	state_changed.emit()


## `cd` into the workspace rather than relying on a working-directory argument:
## `OS.create_process` has none, and this process's own cwd is shared by the whole
## app. Everything is redirected — stdout to the stream we tail, stderr alongside
## a separate file so a crash message survives, stdin closed so nothing can sit
## waiting on a terminal that never sends EOF.
##
## **`exec` is not decoration.** Without it the pid we keep is the shell's, and the
## agent is its child: `cancel()` then killed the shell and left the agent running
## — orphaned, still spending tokens, still able to write to the repository, with
## its output going to a file nobody is reading any more. Measured exactly that
## way. `exec` replaces the shell with the agent after the `cd` and the
## redirections have been applied, so `_pid` is the thing we actually want to be
## able to stop.
func _command(path: String, stream: String, message: String) -> String:
	var parts := PackedStringArray(["cd", _sh_quote(path), "&&", "exec"])
	if _runner == RUNNER_CLAUDE:
		parts.append_array(_claude_args(message))
	else:
		parts.append_array(_codex_args(path, message))
	# The `.err` has to be inside the quotes: quoting the stream path and then
	# appending would produce `2>'/…/work_stream.jsonl'.err`, which the shell reads
	# as a different filename each time the path contains anything worth quoting.
	parts.append_array(["</dev/null",
		">%s" % _sh_quote(stream),
		"2>%s" % _sh_quote(stream + ".err")])
	return " ".join(parts)


func _claude_args(_message: String) -> PackedStringArray:
	var read_only := str(_space.get("level", WorkspaceService.LEVEL_READ)) \
		!= WorkspaceService.LEVEL_EDIT
	var args := PackedStringArray([
		_sh_quote(claude_path()),
		"-p",
		"--output-format", "stream-json",
		"--include-partial-messages",
		# stream-json refuses to emit without it.
		"--verbose",
		"--model", _sh_quote(CLAUDE_MODEL),
		"--max-budget-usd", str(BUDGET_USD),
		# The pet's jobs run on the *project's* configuration, never the user's own.
		#
		# Measured: without these two, a one-line fix pulled in whatever the user has
		# installed globally — the run loaded their plugins and called
		# `Skill(superpowers:systematic-debugging)` on a two-line file, and cost
		# $0.21. With them it used Read/Edit/Glob/Bash and cost $0.11. Their personal
		# hooks and MCP servers are theirs; a pet running errands must not be a way
		# to fire them. The repo's own CLAUDE.md still applies, which is what makes
		# the agent useful *in* their project rather than a stranger to it.
		"--strict-mcp-config",
		"--setting-sources", "project,local",
	])
	if read_only:
		# Enforced by capability, not by mode: with no Write, Edit or Bash there is
		# nothing that can change the folder, whatever the agent decides to do.
		# `--permission-mode plan` alone would leave it able to ask, and a job
		# nobody is watching must never be waiting on an answer.
		args.append_array(["--tools", _sh_quote("Read,Grep,Glob"),
			"--permission-mode", "acceptEdits"])
	else:
		# `acceptEdits` covers file edits and **not** Bash. Without the explicit
		# allow list, the agent fixed the bug and was then refused when it tried to
		# run the file to check itself — "This command requires approval", to a
		# terminal with no one at it. An assistant that cannot verify its own work
		# is worth much less than one that can, so the list is passed rather than
		# leaving the mode to imply it.
		#
		# Note what this does *not* buy: unlike `codex exec -s workspace-write`,
		# which is an OS-level sandbox, nothing here confines a shell command to the
		# workspace. Claude's discipline is the only thing keeping it in — see the
		# consent dialog, which says so rather than promising otherwise.
		args.append_array(["--permission-mode", "acceptEdits",
			"--allowed-tools", _sh_quote("Read,Edit,Write,Grep,Glob,Bash")])
	# Carry on from the last job in this folder. Verified headlessly: a second turn
	# answered a question about the first without re-reading anything, which is the
	# whole point — every follow-up used to pay to read the project again.
	if _resuming:
		args.append_array(["--resume",
			_sh_quote(WorkspaceService.get_session(str(_space.get("path", ""))))])
	args.append_array(["--", _sh_quote(_prompt())])
	return args


func _codex_args(path: String, message: String) -> PackedStringArray:
	var read_only := str(_space.get("level", WorkspaceService.LEVEL_READ)) \
		!= WorkspaceService.LEVEL_EDIT
	return PackedStringArray([
		_sh_quote(CodexCli.path()), "exec",
		"--skip-git-repo-check",
		"--json",
		"-s", "read-only" if read_only else "workspace-write",
		# Never inherited from ~/.codex/config.toml, which pins whatever model the
		# user last chose for their own work: a stale one is rejected as
		# "not supported when using Codex with a ChatGPT account", which reads as a
		# billing problem and has no visible connection to the pet.
		"-m", _sh_quote(CODEX_MODEL),
		"-C", _sh_quote(path),
		"-o", _sh_quote(message),
		"--", _sh_quote(_prompt()),
	])


## What the agent is told. Short on character and long on constraint: the pet's
## personality lives in the bubble, and an agent asked to be cute writes cute
## code.
func _prompt() -> String:
	var read_only := str(_space.get("level", WorkspaceService.LEVEL_READ)) \
		!= WorkspaceService.LEVEL_EDIT
	var rules := PackedStringArray([
		"- 只在目前的工作目錄裡做事，不要碰外面的東西",
		"- 做完用繁體中文回一句話說你做了什麼，40 字以內",
	])
	if read_only:
		rules.insert(0, "- 這次只能看，不要修改任何檔案")
	var lines := PackedStringArray([
		"使用者透過一隻桌面寵物請你幫忙。你負責實際動手，寵物只負責轉達結果。",
		"",
		"使用者要的是：%s" % _request,
		"",
		"規則：",
	])
	lines.append_array(rules)
	return "\n".join(lines)


func _sh_quote(text: String) -> String:
	return "'%s'" % text.replace("'", "'\\''")


# --- Watching -----------------------------------------------------------------

func _process(delta: float) -> void:
	if _pid == -1:
		return
	_elapsed += delta
	_since_poll += delta

	if _since_poll >= POLL:
		_since_poll = 0.0
		_drain()

	if OS.is_process_running(_pid):
		if _elapsed < TIMEOUT:
			return
		OS.kill(_pid)
		# Drain once more: whatever it managed to do before being killed is still
		# worth reporting, and the changes are on disk either way.
		_drain()
		_finish(false, "做太久了，我先停下來。")
		return

	# The child is gone, but the last few lines may still be unread.
	_drain()

	# The context we tried to carry on from is no longer there. Drop it and do the
	# job from scratch — silently, because "the CLI expired a session file" is not
	# something the user asked about or can act on.
	if _session_is_stale:
		_session_is_stale = false
		WorkspaceService.clear_session(str(_space.get("path", "")))
		_pid = -1
		set_process(false)
		_note("上次的脈絡不見了，我重來一次")
		if _launch(false):
			return
		_finish(false, "做不成，重試也起不來。")
		return

	_finish(true, "")


## Read whatever is new, by byte offset. A regular file, so this never blocks —
## the whole reason the stream goes to one.
func _drain() -> void:
	var file := FileAccess.open(ProjectSettings.globalize_path(STREAM_PATH), FileAccess.READ)
	if file == null:
		return
	var length := file.get_length()
	if length <= _offset:
		file.close()
		return
	file.seek(_offset)
	var chunk := file.get_buffer(length - _offset)
	file.close()
	_offset = length
	_pending.append_array(chunk)

	# Only decode up to the last newline. A read can end mid-character, and a
	# half-decoded line would be silently dropped by JSON parsing.
	var last_break := -1
	for i in range(_pending.size() - 1, -1, -1):
		if _pending[i] == 10:
			last_break = i
			break
	if last_break < 0:
		return
	var complete := _pending.slice(0, last_break)
	_pending = _pending.slice(last_break + 1)
	for line in complete.get_string_from_utf8().split("\n", false):
		_handle_line(line)


func _handle_line(line: String) -> void:
	var trimmed := line.strip_edges()
	if trimmed.is_empty():
		return
	var parsed: Variant = JSON.parse_string(trimmed)
	if not (parsed is Dictionary):
		return
	if _runner == RUNNER_CLAUDE:
		_handle_claude(parsed)
	else:
		_handle_codex(parsed)


func _handle_claude(event: Dictionary) -> void:
	match str(event.get("type", "")):
		"assistant":
			var message: Variant = event.get("message", {})
			if message is Dictionary:
				_read_content(message.get("content", []))
		"result":
			_cost = float(event.get("total_cost_usd", 0.0))
			_session = str(event.get("session_id", ""))
			# A resume against a session the CLI no longer has fails instantly:
			# exit 1, is_error, and **zero turns**. That combination is what
			# separates "the context is gone" from "the job genuinely failed",
			# and it has to be caught or a cleaned-up session file would break
			# that workspace permanently.
			if _resuming and bool(event.get("is_error", false)) \
					and int(event.get("num_turns", 0)) == 0:
				_session_is_stale = true
			var text := str(event.get("result", "")).strip_edges()
			if not text.is_empty():
				_last_text = text
		"stream_event":
			# Prose as it is written. Only kept, not announced: the panel shows the
			# closing line, and a bubble fed every delta would never settle.
			var inner: Variant = event.get("event", {})
			if not (inner is Dictionary):
				return
			match str(inner.get("type", "")):
				"message_start":
					# Reset per message, not per job. An agent run is many turns, and
					# accumulating across all of them makes the closing line the
					# whole transcript — which only shows if the job is killed before
					# the `result` event lands to overwrite it.
					_last_text = ""
				"content_block_delta":
					var delta: Variant = inner.get("delta", {})
					if delta is Dictionary and delta.has("text"):
						_last_text += str(delta["text"])


## Tool calls are what a progress log is actually made of — "在讀 X" tells you
## more about where a job is than any amount of the agent's own prose.
func _read_content(content: Variant) -> void:
	if not (content is Array):
		return
	for block in content:
		if not (block is Dictionary):
			continue
		if str(block.get("type", "")) != "tool_use":
			continue
		var step := _describe_tool(str(block.get("name", "")), block.get("input", {}))
		if not step.is_empty():
			_step(step)


func _describe_tool(name: String, input: Variant) -> String:
	var args: Dictionary = input if input is Dictionary else {}
	var file := _short_path(str(args.get("file_path", args.get("path", ""))))
	match name:
		"Read":
			return "讀 %s" % file
		"Write":
			return "寫 %s" % file
		"Edit", "MultiEdit", "NotebookEdit":
			return "改 %s" % file
		"Bash":
			return "跑 %s" % _clip(str(args.get("command", "")))
		"Grep":
			return "找「%s」" % _clip(str(args.get("pattern", "")))
		"Glob":
			return "翻 %s" % _clip(str(args.get("pattern", "")))
		"Task", "Agent":
			return "叫了一個小幫手"
		"WebFetch", "WebSearch":
			return "上網查了一下"
		"TodoWrite":
			return ""
	return _clip(name)


## Codex reports coarsely — it has no token-level streaming, so there is nothing
## finer to report even if we wanted it.
func _handle_codex(event: Dictionary) -> void:
	var kind := str(event.get("type", ""))
	if kind == "item.completed":
		var item: Variant = event.get("item", {})
		if item is Dictionary:
			var text := str(item.get("text", "")).strip_edges()
			if not text.is_empty():
				_last_text = text
			var item_type := str(item.get("type", ""))
			if item_type == "command_execution":
				_step("跑 %s" % _clip(str(item.get("command", ""))))
			elif item_type == "file_change":
				_step("改了檔案")
	elif kind == "turn.started":
		_note("開始想了")


## Paths are shown relative to the workspace: the absolute one is mostly the same
## prefix repeated down the whole log, and the leaf is what identifies the file.
func _short_path(path: String) -> String:
	if path.is_empty():
		return "檔案"
	var root := str(_space.get("path", ""))
	if not root.is_empty() and path.begins_with(root):
		var rest := path.substr(root.length())
		return _clip(rest.trim_prefix("/"))
	return _clip(path.get_file())


func _clip(text: String) -> String:
	var flat := text.replace("\n", " ").strip_edges()
	if flat.length() <= MAX_STEP_LENGTH:
		return flat
	return flat.substr(0, MAX_STEP_LENGTH) + "…"


func _step(text: String) -> void:
	_append({"kind": "tool", "text": text})


func _note(text: String) -> void:
	_append({"kind": "note", "text": text})


func _append(entry: Dictionary) -> void:
	_log.append(entry)
	if _log.size() > MAX_LOG:
		_log.remove_at(0)
	progress.emit(entry)


# --- Ending -------------------------------------------------------------------

## `natural` is whether the process exited on its own. Either way the changes are
## already on disk, so what happened is read off the workspace rather than
## inferred from an exit code, and read from git rather than from the agent's own
## account of itself. An agent that believes it edited a file and didn't is a real
## failure mode; the folder is the truth either way.
func _finish(natural: bool, override: String) -> void:
	if _reported:
		return
	_reported = true
	var code := OS.get_process_exit_code(_pid) if natural else -1
	var path := str(_space.get("path", ""))
	var seconds := _elapsed
	var space := _space
	_stop()

	# Remembered only when the run actually got somewhere. Storing the id off a
	# failed launch would hand the next job a session with nothing in it, which
	# resumes fine and helps nobody.
	if natural and code == 0 and not _session.is_empty():
		WorkspaceService.set_session(path, _session)

	var message := override
	if message.is_empty():
		message = _closing_message(code)
	var changes := WorkspaceService.changes(path)
	_note("結束了")
	finished.emit({
		"ok": natural and code == 0,
		"message": message,
		"changes": changes,
		"seconds": seconds,
		"cost": _cost,
		"space": space,
		"request": _request,
	})
	state_changed.emit()


func _closing_message(code: int) -> String:
	# Codex has no result event; its closing line is in the -o file.
	if _runner == RUNNER_CODEX:
		var written := FileAccess.get_file_as_string(
			ProjectSettings.globalize_path(MESSAGE_PATH)).strip_edges()
		if not written.is_empty():
			return written
	var text := _last_text.strip_edges()
	if not text.is_empty():
		return _clip_reply(text)
	if code != 0:
		return "做不完欸，%s 回報了錯誤（%d）。" % [runner_label(_runner), code]
	return "做完了，不過它沒說做了什麼。"


## The agent is asked for one sentence and usually gives one, but nothing enforces
## it — and this goes into a speech bubble.
const MAX_REPLY_LENGTH := 120


func _clip_reply(text: String) -> String:
	var flat := text.replace("\n", " ").strip_edges()
	if flat.length() <= MAX_REPLY_LENGTH:
		return flat
	return flat.substr(0, MAX_REPLY_LENGTH) + "…"


func _stop() -> void:
	_pid = -1
	_elapsed = 0.0
	_since_poll = 0.0
	set_process(false)
