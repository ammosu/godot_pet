extends RefCounted
class_name SecretStore

## Keeps API keys in the OS credential store rather than a file next to the
## project.
##
## Backends are chosen at runtime by looking for the tool:
##   macOS   `security`     — the login Keychain, always present
##   Linux   `secret-tool`  — libsecret / GNOME Keyring, from libsecret-tools
##   other   none, and Config falls back to .env or config.cfg
##
## Secrets are written over the child process's stdin where possible, because
## argv is readable through `ps` by anything running as the same user. Every
## write is read back before it's reported as successful — see write().

const SERVICE := "godot-pet"

## Both tools are quick; this is only a guard against a hung prompt.
const TIMEOUT_MS := 4000
const POLL_MS := 10

enum Backend { NONE, KEYCHAIN, LIBSECRET }

const KEYCHAIN_PATHS := ["/usr/bin/security"]
const LIBSECRET_PATHS := [
	"/usr/bin/secret-tool", "/bin/secret-tool", "/usr/local/bin/secret-tool",
]

static var _backend := -1
static var _tool := ""


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
	var output := []
	var args: Array
	match backend():
		Backend.KEYCHAIN:
			args = ["find-generic-password", "-a", key, "-s", SERVICE, "-w"]
		Backend.LIBSECRET:
			args = ["lookup", "service", SERVICE, "account", key]
		_:
			return ""
	# Both tools exit non-zero when the item simply isn't there.
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
	match backend():
		Backend.KEYCHAIN:
			# security's prompt truncates at 128 characters, exits 0 and says
			# nothing — and an OpenAI project key is longer than that. So a stdin
			# write is only trusted if it reads back intact, and otherwise gets
			# redone through argv, which has no such limit. A key briefly visible
			# to `ps` is a far smaller problem than one silently cut in half.
			if _keychain_write_via_stdin(key, value) and read(key) == value:
				return true
			return _keychain_write_via_argv(key, value) and read(key) == value
		Backend.LIBSECRET:
			# secret-tool reads the secret from stdin by design, with no length
			# limit. Read back anyway — a half-written key fails in a way that
			# looks like a bad key, which is a miserable thing to debug.
			var stored := _run_with_stdin(
				["store", "--label=Godot Pet", "service", SERVICE, "account", key],
				value)
			return stored and read(key) == value
	return false


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
	var args: Array
	match backend():
		Backend.KEYCHAIN:
			args = ["delete-generic-password", "-a", key, "-s", SERVICE]
		Backend.LIBSECRET:
			args = ["clear", "service", SERVICE, "account", key]
		_:
			return false
	return OS.execute(_tool, PackedStringArray(args), []) == 0


## Spawn the tool, feed it the secret over stdin, and wait for it to exit.
## Blocks the main thread, which is fine: this only runs when the user is
## deliberately saving a key, and it takes milliseconds.
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
