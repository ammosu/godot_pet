extends Node

## Cheap, content-free signals about the user's rhythm, so Nudger can decide
## WHEN to speak rather than guessing off a plain timer. Modelled on
## VisionService: nothing is sampled until the user agrees, and what's
## collected is kept deliberately thin.
##
## Two things only: the foreground app's name (an opaque, per-platform
## identifier — WM_CLASS's class field on Linux, the process name on macOS —
## never a window title, which is where documents, messages and URLs actually
## live), and how long it's held focus. Never logged, never written to disk;
## the only places either value goes are EventBus and the two in-memory vars
## below.
##
## Consent and enablement are two separate config keys. `consented` is sticky
## once granted, so turning the menu switch back on after turning it off
## doesn't re-ask something already agreed to — the same durability
## VisionService's "always" has. `enabled` is the live on/off state.

## Chosen for the same reason Nudger checks every 20s rather than every
## frame: there's no benefit to finer-grained timing than the minutes-scale
## decisions built on top of it, and it keeps the (cheap, but not free)
## subprocess spawns infrequent.
const POLL_INTERVAL := 30.0

## Guards a hung child process, exactly like SecretStore's writes do. Two
## budgets, because the two calls are not the same risk.
##
## Every sample after the first runs unattended on a repeating timer, and the
## wait blocks the main thread — so a hung tool freezes the pet. Four seconds of
## that is a dead pet, not a hitch, and nothing on this path is worth waiting
## four seconds for: a sample that doesn't come back in time is simply skipped
## and the next tick tries again.
##
## The first sample after consent is the exception. On macOS the very first
## `osascript` against System Events raises the Automation permission dialog,
## and the call does not return until the user has answered it.
const PROC_TIMEOUT_MS := 400
const FIRST_PROC_TIMEOUT_MS := 4000
## Poll granularity, which is also the floor on what a sample costs: `xprop`
## returns in about 3ms, and at 10ms the two Linux calls rounded a ~6ms sample
## up to a ~20ms stall — a visible frame drop every POLL_INTERVAL.
const PROC_POLL_MS := 2

const LINUX_XPROP_PATHS := ["/usr/bin/xprop", "/usr/local/bin/xprop", "/bin/xprop"]
const MACOS_OSASCRIPT := "/usr/bin/osascript"
const MACOS_SCRIPT := \
	'tell application "System Events" to name of first process whose frontmost is true'

var _enabled := false
var _consented := false
var _current_app := ""
var _changed_at := 0.0
var _linux_tool := ""
var _timer: Timer
## Cleared by the first completed sample. Only that one gets the long timeout.
var _first_sample := true


func _ready() -> void:
	_consented = bool(Config.get_value("presence", "consented", false))
	_enabled = _consented and bool(Config.get_value("presence", "enabled", false))
	if OS.get_name() == "Linux":
		_linux_tool = _first_existing(LINUX_XPROP_PATHS)

	_timer = Timer.new()
	_timer.wait_time = POLL_INTERVAL
	_timer.timeout.connect(_poll)
	add_child(_timer)
	if _enabled:
		_timer.start()
		_poll()


func is_supported() -> bool:
	match OS.get_name():
		"Linux":
			return not _linux_tool.is_empty()
		"macOS":
			return FileAccess.file_exists(MACOS_OSASCRIPT)
		_:
			# Windows: no cheap built-in exists. Reading the foreground window
			# needs GetForegroundWindow(), and reaching it from PowerShell means
			# Add-Type-compiling a P/Invoke declaration on every fresh
			# powershell.exe process — the same "most of a second, every single
			# time" cost CLAUDE.md documents for CredRead, except this would run
			# on an unattended timer for as long as the app is open, where
			# SecretStore only pays it once per key thanks to its cache. Report
			# unknown rather than risk a periodic stall.
			return false


func has_consented() -> bool:
	return _consented


func is_enabled() -> bool:
	return _enabled


## Called once, by pet.gd, after the consent dialog is accepted. Samples
## immediately rather than waiting for the timer — partly so the switch
## visibly does something the moment it's turned on, and partly because on
## macOS this first call is the one that can surface the "Godot Pet wants to
## control System Events" permission prompt, which had better happen while
## the user is still looking at the window, not on some unattended tick.
func grant_consent() -> void:
	_consented = true
	Config.set_value("presence", "consented", true)
	set_enabled(true)


func set_enabled(enabled: bool) -> void:
	if enabled and not _consented:
		return
	_enabled = enabled
	Config.set_value("presence", "enabled", enabled)
	if enabled:
		if _timer.is_stopped():
			_timer.start()
		_poll()
	else:
		_timer.stop()
		_current_app = ""
		_changed_at = 0.0


## Seconds the current foreground app has held focus, or -1.0 when that's not
## knowable — not consented, not supported, or no sample has landed yet.
## Nudger reads this and only this; the app's name never has to leave here
## for the one reason so far that needs a presence signal at all.
func seconds_in_current_app() -> float:
	if not _enabled or _current_app.is_empty():
		return -1.0
	return Time.get_unix_time_from_system() - _changed_at


func _poll() -> void:
	var app := _sample()
	# Spend the long budget once and once only. A failed first sample has
	# already waited it out, and retrying at four seconds a tick would be the
	# freeze the short budget exists to prevent.
	_first_sample = false
	if app.is_empty():
		# Couldn't answer this tick — platform unsupported, no active window,
		# or the child process timed out. Don't treat that as "switched to
		# nothing": a single flaky read must not reset a real streak.
		return
	if app != _current_app:
		_current_app = app
		_changed_at = Time.get_unix_time_from_system()
	EventBus.presence_sampled.emit(_current_app, seconds_in_current_app())


func _sample() -> String:
	match OS.get_name():
		"Linux":
			return _sample_linux()
		"macOS":
			return _sample_macos()
		_:
			return ""


func _sample_linux() -> String:
	if _linux_tool.is_empty():
		return ""
	var root := _run(_linux_tool, PackedStringArray(["-root", "_NET_ACTIVE_WINDOW"]))
	var id := _extract_window_id(root)
	if id.is_empty() or id == "0x0":
		return ""
	var wm_class := _run(_linux_tool, PackedStringArray(["-id", id, "WM_CLASS"]))
	return _parse_wm_class(wm_class)


## "_NET_ACTIVE_WINDOW(WINDOW): window id # 0x200117" — the id is always the
## last whitespace-separated token when the property exists at all.
func _extract_window_id(output: String) -> String:
	var line := output.strip_edges()
	if line.is_empty():
		return ""
	var tokens := line.split(" ", false)
	return tokens[tokens.size() - 1] if not tokens.is_empty() else ""


## "WM_CLASS(STRING) = \"instance\", \"class\"" — the class half is used, not
## the instance half, because it groups every window of the same app under
## one label more reliably (a multi-profile browser still shares one class).
func _parse_wm_class(output: String) -> String:
	var line := output.strip_edges()
	var eq := line.find("=")
	if eq < 0:
		return ""
	var quoted := line.substr(eq + 1).split("\"")
	# ["", instance, ", ", class, ...] when the property looks as expected.
	return quoted[3].strip_edges() if quoted.size() >= 4 else ""


func _sample_macos() -> String:
	return _run(MACOS_OSASCRIPT, PackedStringArray(["-e", MACOS_SCRIPT])).strip_edges()


## Bounded wait on a subprocess, mirroring SecretStore._run_with_stdin() minus
## the stdin write — the one thing this needs to read here, never send.
## Every call but possibly the very first macOS one returns in single-digit
## milliseconds; the timeout exists for that one, where a fresh Automation
## permission prompt can otherwise sit unanswered indefinitely. Explicitly
## closes stdio rather than letting refcounting reclaim it eventually — this
## runs on an indefinite repeating timer, unlike SecretStore's one-shot
## writes, so a leaked pipe handle here is a slow fd leak, not a non-issue.
func _run(tool: String, args: PackedStringArray) -> String:
	var process := OS.execute_with_pipe(tool, args)
	if process.is_empty():
		return ""
	var pid: int = process["pid"]
	var stdio: FileAccess = process["stdio"]
	var budget := FIRST_PROC_TIMEOUT_MS if _first_sample else PROC_TIMEOUT_MS
	var waited := 0
	while OS.is_process_running(pid) and waited < budget:
		OS.delay_msec(PROC_POLL_MS)
		waited += PROC_POLL_MS
	if OS.is_process_running(pid):
		OS.kill(pid)
		stdio.close()
		return ""
	var ok := OS.get_process_exit_code(pid) == 0
	var text := stdio.get_as_text() if ok else ""
	stdio.close()
	return text


func _first_existing(candidates: Array) -> String:
	for path in candidates:
		if FileAccess.file_exists(path):
			return path
	return ""
