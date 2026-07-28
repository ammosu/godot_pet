extends Node

## Everything this app knows about the Codex CLI: where the binary is, whether it
## has an account, and how to give it one. MakerService drives the work; this owns
## the account.
##
## **No OAuth is implemented here and no token is ever read.** Both login paths
## launch the vendor's own `codex login`, which either takes a key on stdin or
## opens the user's browser on OpenAI's own domain and runs the exchange itself.
## `~/.codex/auth.json` is the CLI's file; nothing here opens it. That is the same
## line the rest of this project draws — forging the Codex client id to spend
## ChatGPT entitlement is still out of bounds, and none of this comes near it.

## Emitted once a login attempt settles, either way.
signal login_finished(ok: bool, message: String)
## Something worth saying while a browser login is still in flight.
signal login_hint(message: String)

## Long enough for a person to find the browser window, pick an account and get
## through a 2FA prompt. The code itself expires in 15 minutes.
const BROWSER_TIMEOUT := 240.0

## How often to look for the code while it hasn't appeared yet.
const CODE_POLL := 0.5

## `codex login --with-api-key` only writes a local file, so this is generous.
const KEY_LOGIN_TIMEOUT_MS := 15000
const KEY_LOGIN_POLL_MS := 50

## Where `codex login`'s own output goes. A **regular file, never a pipe**: a
## pipe's read blocks until a byte arrives, which would stall `_process`, and an
## undrained pipe eventually blocks the child. Reading a regular file does
## neither, so this is also how the authorization URL gets back to us.
const LOG_PATH := "user://codex_login.log"

var _path := ""
var _path_looked_up := false
## `codex login status` costs ~60-90ms, which is a visible hitch if it runs every
## time the menu opens. Cached, and dropped by every login attempt — the only
## thing it can go stale against is a login made outside the app.
var _logged_in := false
var _logged_in_known := false

var _pid := -1
var _elapsed := 0.0
var _since_check := 0.0
## Set once the code has been found and handed to the user, so the log is only
## parsed until then.
var _code_shown := false
var _ansi: RegEx = null
var _code_pattern: RegEx = null


func _ready() -> void:
	set_process(false)


## `OS.create_process` children outlive us, and this one is holding a local HTTP
## server on a fixed port — an orphan would make the next run's login fail to
## bind with nothing on screen explaining why.
func _exit_tree() -> void:
	if _pid != -1:
		OS.kill(_pid)


## Absolute path to the `codex` binary, or empty.
##
## Walked out of PATH rather than guessed from a fixed list the way SecretStore
## does for `secret-tool`: this one is installed by npm, so it lives under
## whatever node version manager the user happens to have, and no list would
## find it.
func path() -> String:
	if _path_looked_up:
		return _path
	_path_looked_up = true
	# Windows would need a different launcher for the browser flow below, and the
	# CLI isn't realistically installed there for this purpose.
	if OS.get_name() == "Windows":
		return _path
	for dir in OS.get_environment("PATH").split(":", false):
		var candidate := dir.path_join("codex")
		if FileAccess.file_exists(candidate):
			_path = candidate
			break
	return _path


func is_available() -> bool:
	return not path().is_empty()


func is_logged_in(force := false) -> bool:
	if _logged_in_known and not force:
		return _logged_in
	_logged_in_known = true
	_logged_in = is_available() and _status_ok()
	return _logged_in


func forget_login_state() -> void:
	_logged_in_known = false


## Exit code only. The human-readable line it prints ("Logged in using ChatGPT")
## is not parsed — it is wording, and wording changes between releases.
func _status_ok() -> bool:
	var out := []
	return OS.execute(path(), ["login", "status"], out, true) == 0


func is_logging_in() -> bool:
	return _pid != -1


# --- API key login ------------------------------------------------------------

## Log the CLI in with a key the user has already given this app.
##
## The key goes over **stdin**, never argv — `ps` exposes another process's
## arguments to anything running as the same user, which is the reason
## SecretStore pipes secrets too. This is the shape `--with-api-key` documents.
##
## Blocking, but only for as long as the CLI takes to write a local file. Same
## trade SecretStore._run_with_stdin() already makes for a one-shot.
func login_with_api_key(key: String) -> bool:
	if not is_available() or key.strip_edges().is_empty():
		return false
	forget_login_state()

	var process := OS.execute_with_pipe(path(), PackedStringArray(["login", "--with-api-key"]))
	if process.is_empty():
		push_warning("CodexCli: cannot run codex login")
		return false

	var stdio: FileAccess = process["stdio"]
	stdio.store_string(key.strip_edges())
	# Closing the write end is what tells the CLI the key is complete.
	stdio.close()

	var pid: int = process["pid"]
	var waited := 0
	while OS.is_process_running(pid) and waited < KEY_LOGIN_TIMEOUT_MS:
		OS.delay_msec(KEY_LOGIN_POLL_MS)
		waited += KEY_LOGIN_POLL_MS
	if OS.is_process_running(pid):
		OS.kill(pid)
		push_warning("CodexCli: login --with-api-key did not finish")
		return false
	# Verified by asking, not by trusting the exit code — the same readback
	# discipline SecretStore.write() applies for the same reason.
	return OS.get_process_exit_code(pid) == 0 and is_logged_in(true)


# --- Browser login ------------------------------------------------------------

## Start `codex login --device-auth`, which prints a short URL and a one-time
## code and waits for the exchange to complete elsewhere.
##
## **Device auth rather than the default localhost flow, on purpose.** The
## default binds `localhost:1455` and opens a browser on this machine, which is
## exactly the assumption that fails on the remote and headless desktops this pet
## is expected to sit on — the CLI says so itself in its own output. Device auth
## has no such assumption, and what it produces is a short URL and nine
## characters, which is something a speech bubble can actually carry where a
## 400-character OAuth URL is not.
##
## The one thing the default gave us for free was opening the browser, so we do
## that ourselves once the URL is known.
func begin_browser_login() -> bool:
	if not is_available() or is_logging_in():
		return false
	forget_login_state()

	var log_path := ProjectSettings.globalize_path(LOG_PATH)
	DirAccess.remove_absolute(log_path)

	# Through `sh -c` so stdout, stderr and stdin can all be redirected: stdin
	# closed so nothing waits on a terminal, stdout to a regular file for the
	# reason given on LOG_PATH.
	var command := "%s login --device-auth >%s 2>&1 </dev/null" \
		% [_sh_quote(path()), _sh_quote(log_path)]
	_pid = OS.create_process("/bin/sh", ["-c", command])
	if _pid == -1:
		push_warning("CodexCli: could not start codex login")
		return false
	_elapsed = 0.0
	_since_check = 0.0
	_code_shown = false
	set_process(true)
	return true


## The user gave up, or is being torn down. Killing the CLI also drops its local
## HTTP server, so port 1455 is free for the next attempt.
func cancel_browser_login() -> void:
	if _pid == -1:
		return
	OS.kill(_pid)
	_stop()
	login_finished.emit(false, "好，那先不登入。")


func _process(delta: float) -> void:
	if _pid == -1:
		return
	_elapsed += delta

	if OS.is_process_running(_pid):
		if not _code_shown:
			_since_check += delta
			if _since_check >= CODE_POLL:
				_since_check = 0.0
				_look_for_code()
		if _elapsed >= BROWSER_TIMEOUT:
			OS.kill(_pid)
			_stop()
			login_finished.emit(false, "等太久了，先取消登入。要再試一次跟我說。")
		return

	_stop()
	# Asked rather than inferred from the exit code: the CLI can exit 0 on paths
	# that didn't actually leave an account behind.
	if is_logged_in(true):
		login_finished.emit(true, "登好了！")
	else:
		login_finished.emit(false, "登入沒完成欸，要再試一次嗎？")


## The code takes a second or two to appear. Once it does, open the page for the
## user and put the code on the clipboard as well as saying it — nine characters
## is readable in a bubble, but nobody should have to retype what they can paste.
func _look_for_code() -> void:
	var found := _read_device_code()
	if found.is_empty():
		return
	_code_shown = true
	OS.shell_open(found["url"])
	DisplayServer.clipboard_set(found["code"])
	login_hint.emit("我開了登入頁，輸入這組碼就好：%s（已經幫你複製了）" % found["code"])


## Returns {"url", "code"} once both are in the log, or an empty dictionary.
##
## The output is **colourised even when stdout is a regular file**, so the escapes
## have to come out before anything is matched — the code arrives wrapped in them.
## The escape has to be written \x1b. Godot's RegEx is PCRE2, which rejects the
## \u form outright — and an invalid pattern is not loud about it: sub() simply
## returns an empty string, so the code is never found and the pet says nothing
## at all while the login sits there waiting for it.
func _read_device_code() -> Dictionary:
	var text := FileAccess.get_file_as_string(ProjectSettings.globalize_path(LOG_PATH))
	if text.is_empty():
		return {}
	# Compiled once: this runs on a timer for as long as a login is pending.
	if _ansi == null:
		_ansi = RegEx.create_from_string("\\x1b\\[[0-9;]*m")
		_code_pattern = RegEx.create_from_string("^[A-Z0-9]{4}-[A-Z0-9]{4,8}$")

	var url := ""
	var code := ""
	for raw in _ansi.sub(text, "", true).split("\n", false):
		var line := raw.strip_edges()
		if url.is_empty() and line.begins_with("https://auth.openai.com/"):
			url = line
		elif code.is_empty() and _code_pattern.search(line) != null:
			code = line
	if url.is_empty() or code.is_empty():
		return {}
	return {"url": url, "code": code}


## Single quotes with any embedded quote closed and reopened — the same
## discipline SecretStore._ps_literal() applies to PowerShell.
func _sh_quote(text: String) -> String:
	return "'%s'" % text.replace("'", "'\\''")


func _stop() -> void:
	_pid = -1
	_elapsed = 0.0
	set_process(false)
