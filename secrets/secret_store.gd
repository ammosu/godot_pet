extends RefCounted
class_name SecretStore

## Keeps API keys in the OS credential store rather than a file next to the
## project.
##
## Backends are chosen at runtime by looking for the tool:
##   macOS   `security`     — the login Keychain, always present
##   Linux   `secret-tool`  — libsecret / GNOME Keyring, from libsecret-tools
##   Windows `powershell`   — DPAPI, ciphertext in user://secrets/ (see below)
##   other   none, and Config falls back to .env or config.cfg
##
## Secrets are written over the child process's stdin where possible, because
## argv is readable through `ps` by anything running as the same user (and
## through `Win32_Process.CommandLine` on Windows). Every write is read back
## before it's reported as successful — see write().

const SERVICE := "godot-pet"

## Both tools are quick; this is only a guard against a hung prompt.
## PowerShell needs a longer leash: a cold start is most of a second on its own.
const TIMEOUT_MS := 4000
const POLL_MS := 10

enum Backend { NONE, KEYCHAIN, LIBSECRET, DPAPI }

const KEYCHAIN_PATHS := ["/usr/bin/security"]
const LIBSECRET_PATHS := [
	"/usr/bin/secret-tool", "/bin/secret-tool", "/usr/local/bin/secret-tool",
]
## Absolute, not bare `powershell.exe`: this runs with the user's key on stdin,
## and resolving it through PATH would let anything earlier on PATH collect it.
const POWERSHELL_PATHS := [
	"C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe",
]

## Where DPAPI ciphertext goes. Under user://, beside config.cfg — but unlike
## the plaintext fallback in config.cfg, only this Windows account can read it.
const DPAPI_DIR := "user://secrets"

static var _backend := -1
static var _tool := ""

## read() is called on every LLM request, and on Windows each one would
## otherwise pay for a PowerShell start. The store only changes through write()
## and erase(), both of which run in this process and drop the entry, so the
## only thing this can go stale against is an edit made outside the app —
## which a restart picks up.
static var _cache := {}


static func backend() -> Backend:
	if _backend < 0:
		_detect()
	return _backend as Backend


static func is_available() -> bool:
	return backend() != Backend.NONE


static func backend_name() -> String:
	match backend():
		Backend.KEYCHAIN:
			return "Keychain"
		Backend.LIBSECRET:
			return "GNOME Keyring"
		Backend.DPAPI:
			# Both call sites in pet.gd drop this into a Chinese sentence with a
			# space each side, so it has to read as a Latin name like the other
			# two — "收在 Windows 加密儲存 了" leaves a space stranded mid-sentence.
			return "Windows DPAPI"
	return ""


static func _detect() -> void:
	_backend = Backend.NONE
	_tool = ""
	match OS.get_name():
		"macOS":
			_tool = _first_existing(KEYCHAIN_PATHS)
			if not _tool.is_empty():
				_backend = Backend.KEYCHAIN
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			_tool = _first_existing(LIBSECRET_PATHS)
			if not _tool.is_empty():
				_backend = Backend.LIBSECRET
		"Windows":
			_tool = _first_existing(POWERSHELL_PATHS)
			if not _tool.is_empty():
				_backend = Backend.DPAPI


static func is_ascii(value: String) -> bool:
	for i in value.length():
		var code := value.unicode_at(i)
		if code < 0x20 or code > 0x7E:
			return false
	return true


static func _first_existing(candidates: Array) -> String:
	for path in candidates:
		if FileAccess.file_exists(path):
			return path
	return ""


# --- Operations ---------------------------------------------------------------

## Empty string when absent, or when there's no credential store at all.
static func read(key: String) -> String:
	if _cache.has(key):
		return _cache[key]
	var value := _read_uncached(key)
	_cache[key] = value
	return value


## The real read. Kept separate because write() verifies itself through it, and
## a cached answer there would quietly defeat the whole point of the readback.
static func _read_uncached(key: String) -> String:
	var output := []
	var args: Array
	match backend():
		Backend.KEYCHAIN:
			args = ["find-generic-password", "-a", key, "-s", SERVICE, "-w"]
		Backend.LIBSECRET:
			args = ["lookup", "service", SERVICE, "account", key]
		Backend.DPAPI:
			var path := _dpapi_path(key)
			if path.is_empty() or not FileAccess.file_exists(path):
				return ""
			args = _ps_args(
				"$c=[IO.File]::ReadAllText(%s);" % _ps_literal(ProjectSettings.globalize_path(path))
				+ "$b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR("
				+ "(ConvertTo-SecureString $c));"
				+ "[Console]::Out.Write("
				+ "[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b))")
		_:
			return ""
	# Every backend exits non-zero when the item simply isn't there — and DPAPI
	# also when the blob was written by a different Windows account, which is
	# the same answer as far as the caller is concerned: no key.
	if OS.execute(_tool, PackedStringArray(args), output, false) != 0:
		return ""
	return "" if output.is_empty() else String(output[0]).strip_edges()


## Values must be ASCII.
##
## `security find-generic-password -w` prints non-ASCII passwords as a hex dump
## with no marker, and a password of "deadbeef" comes back as "deadbeef" — so
## the hex form can't be told apart from a literal one. Rather than guess on
## read, refuse to store anything that would trigger it. API keys are ASCII by
## definition, so this only ever fires on a mistake.
static func write(key: String, value: String) -> bool:
	if not is_ascii(value):
		push_warning("SecretStore: refusing to store a non-ASCII value for %s" % key)
		return false
	# Drop the cached answer before touching the store, not after: a write that
	# fails half way still has to leave read() telling the truth.
	_cache.erase(key)
	var ok := _write_backend(key, value)
	if ok:
		_cache[key] = value
	return ok


static func _write_backend(key: String, value: String) -> bool:
	match backend():
		Backend.KEYCHAIN:
			# security's prompt truncates at 128 characters, exits 0 and says
			# nothing — and an OpenAI project key is longer than that. So a stdin
			# write is only trusted if it reads back intact, and otherwise gets
			# redone through argv, which has no such limit. A key briefly visible
			# to `ps` is a far smaller problem than one silently cut in half.
			if _keychain_write_via_stdin(key, value) and _read_uncached(key) == value:
				return true
			return _keychain_write_via_argv(key, value) and _read_uncached(key) == value
		Backend.LIBSECRET:
			# secret-tool reads the secret from stdin by design, with no length
			# limit. Read back anyway — a half-written key fails in a way that
			# looks like a bad key, which is a miserable thing to debug.
			var stored := _run_with_stdin(
				["store", "--label=Godot Pet", "service", SERVICE, "account", key],
				value)
			return stored and _read_uncached(key) == value
		Backend.DPAPI:
			return _dpapi_write(key, value) and _read_uncached(key) == value
	return false


## PowerShell takes the key on stdin and writes only the ciphertext back out, so
## the plaintext never reaches argv or the disk. It reads a single line rather
## than to EOF, because closing the pipe is what would end the process and the
## ciphertext still has to be written after that.
static func _dpapi_write(key: String, value: String) -> bool:
	var path := _dpapi_path(key)
	if path.is_empty():
		return false
	if DirAccess.make_dir_recursive_absolute(DPAPI_DIR) != OK:
		push_warning("SecretStore: cannot create %s" % DPAPI_DIR)
		return false
	var script := (
		"$p=[Console]::In.ReadLine();"
		+ "if(-not $p){exit 1};"
		+ "[IO.File]::WriteAllText(%s," % _ps_literal(ProjectSettings.globalize_path(path))
		+ "(ConvertFrom-SecureString (ConvertTo-SecureString $p -AsPlainText -Force)))")
	return _run_with_stdin(_ps_args(script), value + "\n")


## `-w` with no value makes security prompt, and it asks for confirmation, so
## the secret goes in twice. `-U` updates an existing item instead of failing.
static func _keychain_write_via_stdin(key: String, value: String) -> bool:
	return _run_with_stdin(
		["add-generic-password", "-a", key, "-s", SERVICE, "-U", "-w"],
		"%s\n%s\n" % [value, value])


static func _keychain_write_via_argv(key: String, value: String) -> bool:
	var args := ["add-generic-password", "-a", key, "-s", SERVICE, "-U", "-w", value]
	return OS.execute(_tool, PackedStringArray(args), []) == 0


static func erase(key: String) -> bool:
	_cache.erase(key)
	var args: Array
	match backend():
		Backend.KEYCHAIN:
			args = ["delete-generic-password", "-a", key, "-s", SERVICE]
		Backend.LIBSECRET:
			args = ["clear", "service", SERVICE, "account", key]
		Backend.DPAPI:
			# No tool needed — the ciphertext is ours, in our own user dir.
			var path := _dpapi_path(key)
			if path.is_empty() or not FileAccess.file_exists(path):
				return false
			return DirAccess.remove_absolute(path) == OK
		_:
			return false
	return OS.execute(_tool, PackedStringArray(args), []) == 0


# --- PowerShell / DPAPI helpers -----------------------------------------------

## One ciphertext file per key. The name goes straight into a path, so anything
## that isn't a plain identifier is refused rather than escaped — every key this
## app stores is already of the form OPENAI_API_KEY.
static func _dpapi_path(key: String) -> String:
	if key.is_empty() or not key.is_valid_identifier():
		push_warning("SecretStore: %s is not usable as a filename" % key)
		return ""
	return "%s/%s.dpapi" % [DPAPI_DIR, key]


static func _ps_args(script: String) -> Array:
	# -NoProfile because a user profile can print banners onto our stdout, and
	# -NonInteractive so a broken script fails instead of waiting on a prompt.
	return ["-NoProfile", "-NonInteractive", "-Command", script]


## Single-quoted PowerShell string: nothing inside is expanded, so a Windows
## path's backslashes stay literal and only the quote itself needs doubling.
## Every script here is built with single quotes for that reason — the whole
## thing is then passed as one argv entry, which never reaches a shell.
static func _ps_literal(value: String) -> String:
	return "'%s'" % value.replace("'", "''")


## Spawn the tool, feed it the secret over stdin, and wait for it to exit.
## Blocks the main thread, which is fine: this only runs when the user is
## deliberately saving a key. Milliseconds for `security` and `secret-tool`, up
## to about a second on Windows, where the cost is PowerShell starting at all.
static func _run_with_stdin(args: Array, payload: String) -> bool:
	var process := OS.execute_with_pipe(_tool, PackedStringArray(args))
	if process.is_empty():
		push_warning("SecretStore: cannot run %s" % _tool)
		return false

	var stdio: FileAccess = process["stdio"]
	stdio.store_string(payload)
	# Closing the write end is what tells the tool the secret is complete.
	stdio.close()

	var pid: int = process["pid"]
	var waited := 0
	while OS.is_process_running(pid) and waited < TIMEOUT_MS:
		OS.delay_msec(POLL_MS)
		waited += POLL_MS
	if OS.is_process_running(pid):
		OS.kill(pid)
		push_warning("SecretStore: %s did not finish" % _tool)
		return false
	return OS.get_process_exit_code(pid) == 0
