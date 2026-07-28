extends Node

## The pet making a file, by handing the job to the Codex CLI.
##
## **Deliberately not a chat backend.** Measured on this machine: a plain chat
## turn through `codex exec` costs ~15.7k input tokens and 5-6 seconds and
## arrives with **no token-level streaming at all** — the JSONL event stream
## carries one `item.completed` holding the finished reply. That breaks the three
## things the bubble depends on (text typing itself out, the mood tag arriving in
## the first few tokens, TTSService speaking sentence by sentence), and the 14k of
## agent scaffolding buys nothing a chat turn uses. The identical costs are fine
## here — making something is expected to take a moment, and the agent loop is
## precisely what is being paid for. Chat stays on OpenAIProvider.
##
## No OAuth and no token handling of our own. `codex login` already did that, and
## `~/.codex/auth.json` is the CLI's own file, which nothing here reads. Same
## shape as SecretStore shelling out to `security` / `secret-tool` / `powershell`:
## call the vendor's binary and let it use its own credentials.

## Files land in OutboxService's folder and nowhere else — Codex is given that as
## its workspace root and its own sandbox enforces it. Verified: asked to write
## outside the root it refuses and no file appears.
signal finished(files: PackedStringArray, message: String)
signal failed(reason: String)

## Never inherit `~/.codex/config.toml`. That file pins whatever model the user
## last chose for their own work — on this machine a `gpt-5.2-codex` the current
## CLI rejects outright — and the failure surfaces as a model error with no
## visible connection to the pet.
##
## The id is not guessable: there is no plain `gpt-5.6`; that generation is
## `-sol` / `-luna` / `-terra`. Read off the CLI's own model list.
const MODEL := "gpt-5.6-sol"

## Give up and kill it. A successful run measured ~9s; a run that fights its
## sandbox took 50s before admitting defeat.
const TIMEOUT := 120.0

## Where `codex exec -o` leaves the agent's closing line.
const MESSAGE_PATH := "user://maker_last_message.txt"

const CONSENT_KEY := "consented"

var _pid := -1
var _elapsed := 0.0
## What was in the outbox before the run, so the difference is what got made.
## Codex reports file_change events on stdout, which this deliberately doesn't
## read — see _start() for why.
var _before := {}
var _request := ""


func _ready() -> void:
	set_process(false)


## Same reason CodexCli kills its own child: `OS.create_process` children outlive
## the app, and an abandoned agent still holds a workspace-write sandbox.
func _exit_tree() -> void:
	if _pid != -1:
		OS.kill(_pid)


## Whether the CLI is here at all. Having an *account* is a separate question and
## a recoverable one — see CodexCli.is_logged_in(), which pet.gd checks so it can
## offer to log in rather than refusing.
func is_supported() -> bool:
	return CodexCli.is_available()


func is_busy() -> bool:
	return _pid != -1


func has_consented() -> bool:
	return bool(Config.get_value("maker", CONSENT_KEY, false))


func grant_consent() -> void:
	Config.set_value("maker", CONSENT_KEY, true)


## Ask the agent to make something. Returns false when it couldn't even be
## started, so the caller can say so instead of waiting for a signal that isn't
## coming.
func make(request: String) -> bool:
	if is_busy() or not is_supported() or not OutboxService.ensure_folder():
		return false
	var trimmed := request.strip_edges()
	if trimmed.is_empty():
		return false
	_request = trimmed
	return _start(trimmed)


func _start(request: String) -> bool:
	_before.clear()
	for file in OutboxService.list_files():
		_before[str(file["name"])] = true

	var message_path := ProjectSettings.globalize_path(MESSAGE_PATH)
	DirAccess.remove_absolute(message_path)

	# Launched through `sh -c` so stdout, stderr and stdin can all be redirected.
	# That is not laziness — it is the only shape here that cannot stall the pet:
	#
	# - `FileAccess.get_line()`/`get_buffer()` on a pipe **block** until a byte
	#   arrives, and this agent thinks for seconds at a time, so polling one from
	#   `_process` would freeze the window. Godot offers no readiness test.
	# - Leaving the pipe undrained is worse: once the OS buffer fills, the child
	#   blocks writing and never exits, so the poll below would wait forever.
	# - Closing stdin matters too. The current CLI reads *additional* prompt text
	#   from stdin even when a prompt argument is given, and would sit waiting on
	#   a terminal that never sends EOF.
	#
	# So nothing is piped: the closing line comes from `-o`, and what got made is
	# the outbox difference.
	var command := " ".join(PackedStringArray([
		_sh_quote(CodexCli.path()), "exec",
		"--skip-git-repo-check",
		"-s", "workspace-write",
		"-m", _sh_quote(MODEL),
		"-C", _sh_quote(OutboxService.folder_path()),
		"-o", _sh_quote(message_path),
		"--", _sh_quote(_prompt(request)),
		"</dev/null", ">/dev/null", "2>&1",
	]))

	_pid = OS.create_process("/bin/sh", ["-c", command])
	if _pid == -1:
		push_warning("MakerService: could not start codex")
		return false
	_elapsed = 0.0
	set_process(true)
	return true


## Single quotes, with any embedded quote closed and reopened — the same
## discipline `SecretStore._ps_literal()` applies to PowerShell, for the same
## reason: the request is free text the user typed and must reach the CLI as one
## argument without ever being re-parsed by the shell.
func _sh_quote(text: String) -> String:
	return "'%s'" % text.replace("'", "'\\''")


## The agent is told what it is and what it may produce. The extension list is
## OutboxService's, restated here because the sandbox lets Codex name the file —
## a name that slips through still gets sanitised on the way into the panel, but
## asking for the right thing up front means that rarely has to fire.
func _prompt(request: String) -> String:
	return "\n".join(PackedStringArray([
		"你是一隻住在使用者桌面角落的小寵物，正在幫使用者做一個檔案。",
		"",
		"使用者要的是：%s" % request,
		"",
		"規則：",
		"- 把成品寫在目前的工作目錄裡，就一個檔案",
		"- 副檔名只能是 md、txt、csv、json、svg 其中之一",
		"- 檔名用繁體中文或英文都可以，但不要有路徑分隔符號",
		"- 不要執行跟建立這個檔案無關的指令，也不要讀工作目錄以外的東西",
		"- 做完用繁體中文回一句話說你做了什麼，40 字以內，語氣像朋友不像客服",
	]))


func _process(delta: float) -> void:
	if _pid == -1:
		return
	_elapsed += delta
	if OS.is_process_running(_pid):
		if _elapsed < TIMEOUT:
			return
		OS.kill(_pid)
		_stop()
		failed.emit("等太久了，我先放棄")
		return

	var code := OS.get_process_exit_code(_pid)
	_stop()

	var made := _new_files()
	var message := FileAccess.get_file_as_string(
		ProjectSettings.globalize_path(MESSAGE_PATH)).strip_edges()

	# A non-zero exit with a file anyway is still a success worth reporting: the
	# thing the user asked for exists. Only an empty outbox means nothing happened.
	if made.is_empty():
		failed.emit(_failure_reason(code, message))
		return
	finished.emit(made, message)


## Whatever appeared while it ran. Reading the outbox rather than Codex's
## `file_change` events, because those only exist on the stdout this deliberately
## never reads — and the folder is the actual truth either way.
func _new_files() -> PackedStringArray:
	var made := PackedStringArray()
	for file in OutboxService.list_files():
		var name := str(file["name"])
		if not _before.has(name):
			made.append(name)
	return made


func _failure_reason(code: int, message: String) -> String:
	if not message.is_empty():
		return message
	if code != 0:
		return "做不出來，codex 回報了錯誤（%d）" % code
	return "做不出來，什麼檔案都沒生出來"


func _stop() -> void:
	_pid = -1
	_elapsed = 0.0
	set_process(false)
